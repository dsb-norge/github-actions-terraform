#!/bin/env bash
#
# Action-specific helpers for terraform-module-cache.
#
# Shared by both phases of the action. The pre-init 'resolve' phase reads
# terraform configuration; the post-init 'verify' phase reads the resolved
# module graph from modules.json. Both classify module sources, and they must
# do so through the SAME function — see docs/Terraform-module-cache.md §4.5.2.
#
# ARG_MAX discipline (CLAUDE.md): these run under 'set -o allexport'. File
# contents are never assigned to shell variables here — awk and jq stream from
# disk, and only short derived strings (labels, sources, digests) live in
# variables.
#

# ---------------------------------------------------------------------------
# Source classification
# ---------------------------------------------------------------------------

# classify-source <input-kind> <source> [version-constraint]
#
#   input-kind  'config'   - source/version as written in a .tf file
#               'manifest' - a Source string recorded in modules.json
#   Echoes: local | immutable | mutable
#
# The input-kind argument is not decoration. The two inputs have different
# expressive power and cannot yield identical verdicts: modules.json records
# the version terraform RESOLVED, never the constraint that was asked for
# (§2.7), so a registry entry read from a manifest can never be shown to be
# mutable. Callers must not assume the two agree.
function classify-source {
  local kind="${1}" src="${2}" constraint="${3:-}"
  local ref

  # The root module: no source at all.
  [ -z "${src}" ] && { echo 'local'; return 0; }

  # Local paths are never downloaded (§2.3). Not cached, not disqualifying,
  # but the caller is expected to walk into them.
  case "${src}" in
  ./* | ../*)
    echo 'local'
    return 0
    ;;
  esac

  # Git, in all the spellings terraform accepts. Checked before the generic
  # http rule below, because 'git::https://…' matches both.
  if [[ "${src}" == git::* ]] ||
    [[ "${src}" == github.com/* ]] ||
    [[ "${src}" == git@* ]] ||
    [[ "${src}" == bitbucket.org/* ]] ||
    [[ "${src}" == *.git ]] ||
    [[ "${src}" == *.git\?* ]] ||
    [[ "${src}" == *\?*ref=* ]]; then
    # No ref pins nothing — the default branch moves under us (§3).
    [[ "${src}" != *ref=* ]] && { echo 'mutable'; return 0; }
    ref="${src##*ref=}"
    ref="${ref%%&*}"
    # A commit sha is content-addressed.
    if [[ "${ref}" =~ ^[0-9a-fA-F]{40}$ ]]; then
      echo 'immutable'
      return 0
    fi
    # A version tag is immutable by convention. This is the one assumption in
    # the audit that a determined force-push can violate (§4.5).
    if [[ "${ref}" =~ ^v?[0-9]+(\.[0-9]+){0,2}([-+].+)?$ ]]; then
      echo 'immutable'
      return 0
    fi
    echo 'mutable'
    return 0
  fi

  # Archive and object-store sources: nothing in the URL fixes the content.
  case "${src}" in
  s3::* | gcs::* | hg::* | http://* | https://*)
    echo 'mutable'
    return 0
    ;;
  esac

  # Everything left is a registry address, '[<host>/]<ns>/<name>/<provider>'.
  if [ "${kind}" == 'manifest' ]; then
    # §2.7: the constraint is simply not recoverable here. Reporting 'mutable'
    # would fail every registry module in the graph; reporting 'immutable' is
    # the documented blind spot, covered for top-level modules by the config
    # pass and left open for transitive ones (§4.5.3).
    echo 'immutable'
    return 0
  fi

  # Config: only an exact pin resolves to one release.
  if [[ "${constraint}" =~ ^[[:space:]]*=?[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?[[:space:]]*$ ]]; then
    echo 'immutable'
    return 0
  fi
  echo 'mutable'
}

# ---------------------------------------------------------------------------
# Reading terraform configuration
# ---------------------------------------------------------------------------

# read-module-blocks <dir>
#
# Emits one '<label>\t<source>\t<version>' line per module block declared in
# <dir>/*.tf. Streams through awk; file contents never enter a variable.
#
# Deliberately over-reads within a module block: an '_override.tf' variant, or a
# commented-out 'source' line ahead of the real one, both count. That direction
# is safe — the reachable set becomes a superset and "any mutable source
# excludes" is monotone over supersets — while under-reading is not (§4.5.1).
#
# The block boundary matters for exactly that reason. A 'terraform' block's
# 'required_providers' carries its own source and version arguments, and if a
# module block were allowed to run on until the next module header, an unpinned
# registry module followed by a provider's 'version' would look pinned and get
# cached — an unpinned module resolves to the latest release, so that is the §3
# hazard, arrived at through the parser. Blocks therefore end at a '}' in
# column zero, which 'terraform fmt' guarantees for a top-level block, or at
# the next top-level keyword.
function read-module-blocks {
  local dir="${1}"
  local f
  for f in "${dir}"/*.tf; do
    [ -f "${f}" ] || continue
    awk '
      function flush() {
        if (label != "") printf "%s\t%s\t%s\n", label, src, ver
        label = ""; src = ""; ver = ""
      }
      # End of a top-level block, per terraform fmt.
      /^}/ { flush(); next }
      # A new top-level block of any kind.
      /^[a-z_]+[[:space:]]/ && !/^[[:space:]]*module[[:space:]]+"/ { flush() }
      /^[[:space:]]*module[[:space:]]+"[^"]+"/ {
        flush()
        line = $0
        sub(/^[[:space:]]*module[[:space:]]+"/, "", line)
        sub(/".*$/, "", line)
        label = line
      }
      label != "" && src == "" && /[[:space:]]*source[[:space:]]*=[[:space:]]*"/ {
        line = $0
        sub(/^.*source[[:space:]]*=[[:space:]]*"/, "", line)
        sub(/".*$/, "", line)
        src = line
      }
      label != "" && ver == "" && /[[:space:]]*version[[:space:]]*=[[:space:]]*"/ {
        line = $0
        sub(/^.*version[[:space:]]*=[[:space:]]*"/, "", line)
        sub(/".*$/, "", line)
        ver = line
      }
      END { flush() }
    ' "${f}"
  done
}

# ---------------------------------------------------------------------------
# The local-source walk
# ---------------------------------------------------------------------------

# walk-remote-modules <dir> [dot-path-prefix]
#
# Emits one '<dot-path>\t<source>\t<version>' line for every REMOTE module
# reachable from <dir>, following local sources recursively (§4.4.1).
#
# STDOUT IS THE DATA CHANNEL — the caller parses it. Every diagnostic goes to
# stderr, and no workflow command is emitted from here; step_resolve.sh owns
# all '::notice::' output so there is one place that decides what the run page
# is told.
#
# Local modules live in the repository, so this is deterministic and needs no
# network and no init. It is also the difference between working and useless on
# a repo whose environments are thin wrappers over a shared module tree: such a
# directory declares only '../../main' yet ends up holding that tree's entire
# remote closure (§2.3).
#
# Memoised per resolved directory so a diamond is walked once; cycle-guarded on
# the current chain so mutually-referencing local modules terminate; confined to
# GITHUB_WORKSPACE, since a source resolving outside it is something terraform
# would fail on anyway.
declare -gA _WALK_MEMO=()
declare -gA _WALK_CHAIN=()

function walk-remote-modules {
  local dir="${1}" prefix="${2:-}"
  local abs label src ver child
  abs="$(cd "${dir}" 2>/dev/null && pwd)" || return 0

  if [ -n "${_WALK_CHAIN[${abs}]:-}" ]; then
    log-warn "local module cycle at '$(ws-path "${abs}")', not descending further" >&2
    return 0
  fi
  _WALK_CHAIN["${abs}"]=1

  if [ -z "${_WALK_MEMO[${abs}]+set}" ]; then
    _WALK_MEMO["${abs}"]="$(read-module-blocks "${abs}")"
  fi

  while IFS=$'\t' read -r label src ver; do
    [ -z "${label}" ] && continue
    case "$(classify-source config "${src}" "${ver}")" in
    local)
      [ -z "${src}" ] && continue
      # Resolved lexically ('realpath -m'), not by entering it: a source that
      # escapes the workspace must be reported as escaping whether or not
      # anything happens to exist at that path.
      child="$(realpath -m "${abs}/${src}")"
      if [[ "${child}" != "${GITHUB_WORKSPACE}" && "${child}" != "${GITHUB_WORKSPACE}"/* ]]; then
        log-warn "local module source '${src}' in '$(ws-path "${abs}")' resolves outside the workspace, not walked" >&2
        continue
      fi
      if [ ! -d "${child}" ]; then
        log-warn "local module source '${src}' in '$(ws-path "${abs}")' does not exist, skipping" >&2
        continue
      fi
      walk-remote-modules "${child}" "${prefix}${label}."
      ;;
    *)
      printf '%s%s\t%s\t%s\n' "${prefix}" "${label}" "${src}" "${ver}"
      ;;
    esac
  done <<<"${_WALK_MEMO[${abs}]}"

  unset '_WALK_CHAIN[${abs}]'
}

# normalize-dir <path>
#
# Strips a leading './' and any trailing '/', so './main' and 'main' produce
# one cache path and one digest entry rather than two (§4.3).
function normalize-dir {
  local d="${1#./}"
  d="${d%/}"
  [ -z "${d}" ] && d='.'
  echo "${d}"
}

# reset-walk-state
#
# Clears the memo and cycle guard. Production calls the walk once per
# invocation so this matters mainly to the test suites, which drive many
# fixtures through the same shell.
function reset-walk-state {
  _WALK_MEMO=()
  _WALK_CHAIN=()
}

# ---------------------------------------------------------------------------
# Manifest handling, shared by the snapshot and verify phases
# ---------------------------------------------------------------------------

# manifest-slug <cache-path>
#
# Deterministic before-image filename for one cache path. Lives here rather
# than in workflow YAML so the writer (snapshot) and the reader (verify) cannot
# drift apart.
#
# The readable part is for whoever is looking in RUNNER_TEMP; the hash is what
# makes it unique. Flattening separators alone is not injective — 'a/b' and
# 'a_b' both flatten to 'a_b', and two directories sharing one before-image
# would compare each against the other's manifest.
function manifest-slug {
  local path="${1}" readable hash
  readable="$(printf '%s' "${path}" | sed 's|[^[:alnum:]]\+|_|g')"
  hash="$(printf '%s' "${path}" | sha256sum | cut -c1-8)"
  printf '%s-%s' "${readable}" "${hash}"
}

# normalize-manifest <modules.json path>
#
# Emits the manifest's module list reduced to the fields that describe the
# resolved graph, sorted by Key. Array order is not meaningful, so normalising
# keeps a reordering from reading as a change (§4.4.2). jq streams from disk —
# the manifest never enters a variable.
function normalize-manifest {
  jq -S '[.Modules[]? | {Key, Source, Version, Dir}] | sort_by(.Key)' "${1}" 2>/dev/null
}
