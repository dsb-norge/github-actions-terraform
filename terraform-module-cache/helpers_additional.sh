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

# ---------------------------------------------------------------------------
# Test files: the module blocks of 'run' blocks
# ---------------------------------------------------------------------------

# read-test-run-modules <dir> <test-directory>
#
# Emits one '<dot-path>\t<source>\t<version>' line per 'module' block inside a
# 'run' block of every test file terraform loads for <dir>: '<dir>/*.tftest.hcl'
# and '<dir>/<test-directory>/*.tftest.hcl', the two places 'terraform init'
# reads, and neither recursively. Init installs the run-block modules of every
# one of them whatever '-filter' later names, so every one of them counts.
#
# The dot-path is the key terraform records for the module in modules.json:
# 'test.' plus the file's path relative to <dir> with '.tftest.hcl' dropped and
# '/' turned into '.', plus the run label ('test.tests.unit-net.basic',
# 'test.top.x'). A remote module the run block reaches through a local source
# lands under '<that>.<child label>', as the local-source walk already keys it.
#
# An EMPTY source column means "this could not be read", and the caller must
# treat it as disqualifying: a module block whose source the patterns missed,
# and any '*.tftest.json' file, whose run blocks this does not parse. Reading
# too little is the unsafe direction (§4.5.1), so what cannot be read is not
# guessed at.
#
# Only the module sub-block is read — a 'variables' block of the same run can
# carry a 'version' or 'source' variable, and attributing one of those to the
# module is the mis-attribution §4.5.1 describes. The sub-block is bounded by
# brace depth (quoted strings stripped first), not by indentation, so an
# unformatted file is read the same as a formatted one. Comment lines are
# skipped because terraform skips them too; a commented-out pinned 'version'
# ahead of a live range would otherwise read as pinned.
function read-test-run-modules {
  local dir="${1}" test_dir="${2}"
  local f rel fkey
  local -a files=()
  local -A seen=()

  for f in "${dir}"/*.tftest.hcl "${dir}"/*.tftest.json \
    "${dir}/${test_dir}"/*.tftest.hcl "${dir}/${test_dir}"/*.tftest.json; do
    [ -f "${f}" ] || continue
    # A test directory of '.' names the root's own files a second time.
    rel="$(realpath -m --relative-to="${dir}" -- "${f}")"
    [ -n "${seen[${rel}]:-}" ] && continue
    seen["${rel}"]=1
    files+=("${rel}")
  done

  for rel in "${files[@]}"; do
    fkey="${rel%.tftest.hcl}"
    fkey="${fkey%.tftest.json}"
    fkey="${fkey//\//.}"
    if [[ "${rel}" == *.tftest.json ]]; then
      printf 'test.%s\t\t\n' "${fkey}"
      continue
    fi
    awk -v fkey="${fkey}" '
      function flush() {
        if (inmod) printf "test.%s.%s\t%s\t%s\n", fkey, run, src, ver
        inmod = 0; src = ""; ver = ""; depth = 0
      }
      function depth_of(s,   t, o, c) {
        t = s
        gsub(/"([^"\\]|\\.)*"/, "", t)
        o = gsub(/\{/, "{", t)
        c = gsub(/\}/, "}", t)
        return o - c
      }
      # The value of <name> = ... on this line: the quoted string when there
      # is one, else the bare expression, which the classifier then refuses
      # (only a literal exact version is immutable).
      function value_of(s, name,   t) {
        t = s
        if (!match(t, "(^|[^[:alnum:]_-])" name "[[:space:]]*=[[:space:]]*")) return ""
        t = substr(t, RSTART + RLENGTH)
        if (substr(t, 1, 1) == "\"") {
          t = substr(t, 2)
          sub(/".*$/, "", t)
          return t
        }
        sub(/[[:space:]}#].*$/, "", t)
        return t
      }
      function take(s) {
        if (src == "") src = value_of(s, "source")
        if (ver == "") ver = value_of(s, "version")
      }
      incomment { if ($0 ~ /\*\//) incomment = 0; next }
      /^[[:space:]]*\/\*/ { if ($0 !~ /\*\//) incomment = 1; next }
      /^[[:space:]]*(#|\/\/)/ { next }
      /^[[:space:]]*run[[:space:]]+"[^"]+"/ {
        # A module block that never closed must not borrow from the next run.
        flush()
        line = $0
        sub(/^[[:space:]]*run[[:space:]]+"/, "", line)
        sub(/".*$/, "", line)
        run = line
        next
      }
      !inmod && /^[[:space:]]*module[[:space:]]*\{/ {
        inmod = 1
        rest = $0
        sub(/^[[:space:]]*module[[:space:]]*/, "", rest)
        take(rest)
        depth = depth_of(rest)
        if (depth <= 0) flush()
        next
      }
      inmod {
        take($0)
        depth += depth_of($0)
        if (depth <= 0) flush()
        next
      }
      END { flush() }
    ' "${dir}/${rel}"
  done
}

# walk-test-run-modules <dir> <test-directory>
#
# The run-block declarations of read-test-run-modules, each followed by what a
# local one reaches: every declaration itself (local or registry, since they
# are what the key is over and a local one's manifest entry changes with it
# too), then, for a local source, every remote module reachable from it under
# the declaration's dot-path. Same line format and same stdout contract as
# walk-remote-modules.
#
# A local source is relative to <dir>, the root 'terraform test' runs in, and
# NOT to the test file: '../module' from a root-level 'tests/' directory means
# the root's parent. Confined to GITHUB_WORKSPACE like the walk it hands to.
function walk-test-run-modules {
  local dir="${1}" test_dir="${2}"
  local abs line rest dot_path src ver child
  abs="$(cd "${dir}" 2>/dev/null && pwd)" || return 0

  # Split by hand: 'read' with a tab IFS collapses the empty source of an
  # unreadable declaration and hands its version over as the source.
  while IFS= read -r line; do
    dot_path="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    src="${rest%%$'\t'*}"
    ver="${rest#*$'\t'}"
    [ -z "${dot_path}" ] && continue
    printf '%s\t%s\t%s\n' "${dot_path}" "${src}" "${ver}"
    [ -z "${src}" ] && continue
    [ "$(classify-source config "${src}" "${ver}")" == 'local' ] || continue
    child="$(realpath -m "${abs}/${src}")"
    if [[ "${child}" != "${GITHUB_WORKSPACE}" && "${child}" != "${GITHUB_WORKSPACE}"/* ]]; then
      log-warn "run-block module source '${src}' of '${dot_path}' resolves outside the workspace, not walked" >&2
      continue
    fi
    if [ ! -d "${child}" ]; then
      log-warn "run-block module source '${src}' of '${dot_path}' does not exist, skipping" >&2
      continue
    fi
    walk-remote-modules "${child}" "${dot_path}."
  done < <(read-test-run-modules "${abs}" "${test_dir}")
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
