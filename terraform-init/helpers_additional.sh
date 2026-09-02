#!/bin/env bash
#
# Action-specific helpers for terraform-init.
# Auto-loaded by helpers.sh.
#

# Apply a JSON environment-variable map to the current shell
# ==========================================================
# Applies the resolved environment for this action's goal, as produced by the
# 'resolve-goal-envs' action. A JSON null unsets the variable rather than
# emptying it — $GITHUB_ENV cannot express that, and the distinction matters for
# anything that treats "" as a meaningful value.
#
# Takes a path, not the JSON itself: the values may be secrets, and nothing here
# may hold the payload in a shell variable while allexport is in scope (ref. the
# ARG_MAX rule in CLAUDE.md). jq reads the file and the loop consumes a stream,
# so only one key and one value transit shell variables at a time.
#
# NUL-delimited (jq --raw-output0, requires jq 1.7) so multiline values such as
# PEM keys and values containing shell metacharacters survive verbatim, with no
# encoding hop and no per-variable subshell. The sentinel marks a JSON null; an
# empty field is a genuine empty-string value.
#
# Call this early in main, BEFORE the action's own exports: there is no
# reserved-name list, so that ordering is what decides who wins. See
# docs/Per-goal-environment-variables.md §6.2 and §6.3.
#
# Locals are underscore-prefixed on purpose — a caller whose variable is named
# 'file', 'key' or 'value' must not collide with them. Not 'readonly' either:
# helpers.sh being sourced twice in one shell would then hard-fail.
_EXTRA_ENVS_UNSET='__DSB_UNSET__'
_EXTRA_ENVS_FILTER='to_entries[] | (.key, (if .value == null then "__DSB_UNSET__" else (.value | tostring) end))'

function apply-extra-envs {
  local _extra_envs_file="${1}" _extra_envs_key _extra_envs_value _extra_envs_type

  if [ -z "${_extra_envs_file}" ]; then
    log-info "no per-goal environment variables file configured."
    return 0
  fi
  if [ ! -f "${_extra_envs_file}" ]; then
    log-error "the per-goal environment variables file '${_extra_envs_file}' does not exist!"
    return 1
  fi

  # Validated before anything is applied. Without this an unparseable, empty or
  # truncated file applies nothing at all and the step carries on as if it had —
  # the consequence then surfaces as an OOM or a wrong-credentials error far
  # from its cause, which is the failure mode this whole feature exists to
  # avoid. resolve-goal-envs already guarantees a JSON object; this is the last
  # line of defence, and cheap.
  if ! _extra_envs_type=$(jq -r 'type' "${_extra_envs_file}" 2>/dev/null); then
    log-error "the per-goal environment variables file '${_extra_envs_file}' is not valid JSON!"
    return 1
  fi
  if [ ! "${_extra_envs_type}" == 'object' ]; then
    log-error "the per-goal environment variables file '${_extra_envs_file}' must hold a JSON object, got '${_extra_envs_type:-nothing}'!"
    return 1
  fi

  # How many entries must end up applied. 'length' works on any jq, which is
  # the point: it is the cross-check that catches a jq too old for
  # --raw-output0 (ref. docs/Per-goal-environment-variables.md §9.2). Without
  # it, such a jq makes the read loop consume nothing and the step continues
  # having applied nothing — silently, and only on the runner images where it
  # happens to be old.
  local _extra_envs_expected _extra_envs_applied=0
  if ! _extra_envs_expected=$(jq -r 'length' "${_extra_envs_file}"); then
    log-error "unable to count the entries in '${_extra_envs_file}'!"
    return 1
  fi

  start-group "applying per-goal environment variables"
  while IFS= read -r -d '' _extra_envs_key && IFS= read -r -d '' _extra_envs_value; do
    # 'export' cannot be relied on to reject a bad name: given the key 'FOO=BAR'
    # and the value 'x' it happily assigns 'BAR=x' to FOO — silently setting a
    # different variable than the caller asked for. Hence the explicit check.
    if [[ ! "${_extra_envs_key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      log-error "'${_extra_envs_key}' is not a valid environment variable name!"
      end-group
      return 1
    fi
    if [ "${_extra_envs_value}" == "${_EXTRA_ENVS_UNSET}" ]; then
      log-info "unsetting '${_extra_envs_key}'"
      if ! unset "${_extra_envs_key}"; then
        log-error "'${_extra_envs_key}' is not a usable environment variable name!"
        end-group
        return 1
      fi
    else
      log-info "setting '${_extra_envs_key}'"
      # Still guarded: a readonly variable makes 'export' fail even though the
      # name itself is valid.
      if ! export "${_extra_envs_key}=${_extra_envs_value}"; then
        log-error "'${_extra_envs_key}' is not a usable environment variable name!"
        end-group
        return 1
      fi
    fi
    _extra_envs_applied=$((_extra_envs_applied + 1))
  done < <(jq --raw-output0 "${_EXTRA_ENVS_FILTER}" "${_extra_envs_file}")

  if [ ! "${_extra_envs_applied}" == "${_extra_envs_expected}" ]; then
    log-error "applied ${_extra_envs_applied} of ${_extra_envs_expected} environment variable(s) from '${_extra_envs_file}'!"
    log-error "this usually means jq is older than 1.7 and does not support '--raw-output0' — check the runner image."
    end-group
    return 1
  fi
  end-group

  return 0
}

# Echo any git credentials the runner itself has configured for github.com
# ======================================================================
# --global and --system only. actions/checkout writes its extraheader into the
# LOCAL config of the workspace repository, and the init step runs inside that
# repository — a scope-less lookup would find checkout's header on every real
# run and skip the injection always, which is the whole fix quietly doing
# nothing.
#
# Every lookup is '|| true' and the function ends in 'return 0'. 'git config
# --get' exits 1 when the key is absent, which is the normal case here, and the
# runner sources this in a 'bash -e -o pipefail' shell where that status ends
# the step before terraform ever runs.
function _github_credentials_in_runner_config {
  local _scope _key

  for _scope in --global --system; do
    for _key in 'http.https://github.com/.extraheader' \
      'credential.https://github.com.helper' \
      'credential.helper'; do
      git config "${_scope}" --get-all "${_key}" 2>/dev/null || true
    done
    git config "${_scope}" --get-regexp '^url\..*github\.com.*\.insteadof$' 2>/dev/null || true
  done

  return 0
}

# Authenticate terraform's github.com module clones
# =================================================
# Terraform installs a registry module by shelling out to 'git clone' — the
# registry resolves e.g. 'Azure/avm-res-keyvault-vault/azurerm' to
# 'git::https://github.com/Azure/terraform-azurerm-avm-res-keyvault-vault?ref=<sha>'
# — and each clone is a brand new repository under '.terraform/modules'. It
# inherits nothing from the workspace repository, so the extraheader
# actions/checkout wrote into that repository's local config does not apply and
# the clone goes out unauthenticated.
#
# Unauthenticated github.com traffic is budgeted at 60 requests/hour against the
# source IP, which every runner behind the same NAT address shares. A single init
# with a few dozen modules is 2-3 requests each, so the budget goes quickly. Once
# it is spent GitHub answers the pack negotiation with a 401; git, having no
# credentials and no tty to ask on, gives up with
#
#   fatal: could not read Username for 'https://github.com'
#
# which terraform reports as "Failed to download module" — for a subset of the
# modules that varies run to run, because the refusal is a throttle and not a
# configuration error. Authenticated requests are budgeted per repository
# instead (1 000/hour for GITHUB_TOKEN), which this traffic does not come close
# to.
#
# 'http.<url>.extraheader' rather than 'url.<base>.insteadOf': git sends an
# extraheader on the very first request, while credentials embedded in a
# rewritten URL are only offered after a request has already been refused.
# Only the former keeps the anonymous budget out of the picture altogether,
# rather than relying on GitHub to keep answering with a challenge the retry
# can satisfy.
#
# GIT_CONFIG_COUNT rather than 'git config --global': it adds to git's existing
# configuration instead of replacing it, needs no file on disk and no cleanup,
# and cannot outlive this step. '--global' would leave the token in
# ~/.gitconfig, which on a long-lived self-hosted runner is a shared home
# directory; a job-scoped GIT_CONFIG_GLOBAL file avoids that but discards
# whatever the runner image put in the global config, and setting the same
# extraheader job-wide makes git send TWO Authorization headers for any
# operation on the workspace repository — where checkout's own local one already
# applies — which github.com answers with a 400.
#
# Skipped when the runner already has github.com credentials of its own: a
# preemptive header overrides them, and a repository whose private modules are
# cloned with a runner-level credential helper must keep working.
function configure-github-clone-auth {
  local _token="${1}" _existing _b64 _idx

  if [ -z "${_token}" ]; then
    log-info "no github token supplied, terraform's module clones will be unauthenticated."
    return 0
  fi

  _existing="$(_github_credentials_in_runner_config)"
  if [ -n "${_existing}" ]; then
    log-info "the runner already has git credentials configured for github.com, leaving them alone."
    log-info "terraform's module clones will use those instead of the supplied token."
    return 0
  fi

  _b64="$(printf 'x-access-token:%s' "${_token}" | base64 -w0)"

  # The runner masks the token wherever it appears verbatim, but its base64 form
  # is a different string and is not masked by that. Without this a 'git config
  # --list' or an 'env' dump in any later step prints a usable credential into
  # the log.
  echo "::add-mask::${_b64}"

  # Additive: honour a GIT_CONFIG_COUNT something else already set rather than
  # overwriting its entries. A non-numeric value is garbage that would make git
  # itself fail, so it is simply replaced.
  _idx="${GIT_CONFIG_COUNT:-0}"
  [[ "${_idx}" =~ ^[0-9]+$ ]] || _idx=0

  export "GIT_CONFIG_KEY_${_idx}=http.https://github.com/.extraheader"
  export "GIT_CONFIG_VALUE_${_idx}=Authorization: Basic ${_b64}"
  export GIT_CONFIG_COUNT=$((_idx + 1))

  log-info "terraform's github.com module clones will be authenticated."
  return 0
}

# ==========================================================
log-info "'$(basename ${BASH_SOURCE[0]})' loaded."
