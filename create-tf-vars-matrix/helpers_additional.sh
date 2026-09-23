#!/bin/env bash
#
# Helpers for step_create_matrix.sh: everything the decision engine must not do itself.
#
# The engine (../engine, docs/Decision-engine.md) reads one JSON document and never touches
# YAML, the network or the filesystem. These helpers build that document: YAML inputs parsed
# with yq, the default branch, which project directories exist. Every value travels through a
# file, never a shell variable, because the step runs under allexport and a large variable
# there reaches envp and breaks the next exec (CLAUDE.md, ARG_MAX).
#

# jq: strip trailing newlines, as the bash builder's command substitutions did.
_JQ_RSTRIP_NL='def rstrip_nl: if endswith("\n") then .[:-1] | rstrip_nl else . end;'

function require-python {
  if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
    log-error "the decision engine needs Python 3.10 or later on the runner, found: $(python3 --version 2>&1)"
    return 1
  fi
}

# Write the calling repository's default branch to $2. The event payload carries it for every
# event this workflow runs on, schedule included; the API is the fallback.
function resolve-default-branch {
  local from_event="${1}" out_file="${2}" response
  if [[ -n "${from_event}" ]]; then
    printf '%s' "${from_event}" >"${out_file}"
    return 0
  fi
  response="$(mktemp)"
  if ! gh api "repos/${input_repository}" >"${response}" 2>&1 \
    || ! jq -j -e '.default_branch | strings' "${response}" >"${out_file}"; then
    log-error "could not resolve the default branch of '${input_repository}': $(head -c 500 "${response}")"
    return 1
  fi
}

# Parse the YAML text in $1 with yq into $2. Prints the parse result {"ok", "value"}.
function _parse-yaml-file {
  local raw_file="${1}" parsed_file
  parsed_file="$(mktemp)"
  if yq e -o=json - <"${raw_file}" >"${parsed_file}" 2>/dev/null; then
    jq -c '{ok: true, value: .}' "${parsed_file}"
  else
    jq -nc '{ok: false, value: null}'
  fi
}

# Parse every '*-yml' input of the inputs JSON in $1 into the map written to $2.
#
# The bash builder read each input with `jq -r … | select(. != null)` inside a command
# substitution and fed it to yq through `echo`: null is the empty string, trailing newlines
# are stripped and exactly one is added back.
function parse-yaml-inputs {
  local inputs_file="${1}" out_file="${2}" name raw
  raw="$(mktemp)"
  printf '{}' >"${out_file}"
  while IFS= read -r name; do
    jq -j --arg name "${name}" "${_JQ_RSTRIP_NL}"'(.[$name] // "" | tostring | rstrip_nl) + "\n"' \
      "${inputs_file}" >"${raw}"
    _parse-yaml-file "${raw}" \
      | jq -c --arg name "${name}" --slurpfile map "${out_file}" '$map[0] + {($name): .}' >"${out_file}.new"
    mv "${out_file}.new" "${out_file}"
  done < <(jq -r 'keys[] | select(endswith("-yml"))' "${inputs_file}")
}

# Parse every '*-yml' field of every environment into a list aligned with the environments,
# written to $2. $1 holds the parsed environments-yml value.
#
# The bash builder read a field with the same `jq -r` filter and fed it to yq through
# `printf '%s'`: trailing newlines stripped, none added back. A non-string value arrives as
# JSON text, which yq reads back unchanged.
function parse-environment-yaml {
  local environments_file="${1}" out_file="${2}" count index field raw
  raw="$(mktemp)"
  printf '[]' >"${out_file}"
  count="$(jq 'if type == "array" then length else 0 end' "${environments_file}")"
  for ((index = 0; index < count; index++)); do
    printf '{}' >"${out_file}.env"
    while IFS= read -r field; do
      jq -j --argjson i "${index}" --arg field "${field}" "${_JQ_RSTRIP_NL}"'
        .[$i][$field] | if . == null then "" elif type == "string" then rstrip_nl else tojson end
      ' "${environments_file}" >"${raw}"
      _parse-yaml-file "${raw}" \
        | jq -c --arg field "${field}" --slurpfile env "${out_file}.env" '$env[0] + {($field): .}' >"${out_file}.new"
      mv "${out_file}.new" "${out_file}.env"
    done < <(jq -r --argjson i "${index}" '.[$i] | objects | keys[] | select(endswith("-yml"))' "${environments_file}")
    jq -c --slurpfile env "${out_file}.env" '. + $env' "${out_file}" >"${out_file}.new"
    mv "${out_file}.new" "${out_file}"
  done
  rm -f "${out_file}.env"
}

# Write {"<path>": true|false} to $2 for every directory an environment in $1 may use as its
# project-dir: the one it names, or ./envs/<environment>. Paths are spelled the way the engine
# spells them (jq -r rendering), relative to the working directory.
function check-project-dirs {
  local environments_file="${1}" out_file="${2}" path exists
  printf '{}' >"${out_file}"
  while IFS= read -r -d '' path; do
    if [[ -d "${path}" ]]; then exists=true; else exists=false; fi
    jq -c --arg path "${path}" --argjson exists "${exists}" '. + {($path): $exists}' "${out_file}" >"${out_file}.new"
    mv "${out_file}.new" "${out_file}"
  done < <(jq -j "${_JQ_RSTRIP_NL}"'
    def text: if type == "string" then rstrip_nl elif . == null then "null" else tojson end;
    if type == "array" then .[] else empty end
    | objects | select(has("environment"))
    | (if has("project-dir") then .["project-dir"] | text else "./envs/" + (.environment | text) end) + "\u0000"
  ' "${environments_file}")
}

# Build the engine's input document at $2 from the inputs JSON at $1. The event facts come from
# input_event_name, input_ref_name and input_repository; the default branch from the file $3.
function build-input-document {
  local inputs_file="${1}" out_file="${2}" default_branch_file="${3}" work
  work="$(mktemp -d)"

  parse-yaml-inputs "${inputs_file}" "${work}/yaml-inputs.json"
  jq -c '.["environments-yml"].value // null' "${work}/yaml-inputs.json" >"${work}/environments.json"
  parse-environment-yaml "${work}/environments.json" "${work}/yaml-environments.json"
  check-project-dirs "${work}/environments.json" "${work}/directories.json"

  jq -n \
    --arg repository "${input_repository}" \
    --rawfile default_branch "${default_branch_file}" \
    --arg event_name "${input_event_name}" \
    --arg ref_name "${input_ref_name}" \
    --slurpfile inputs "${inputs_file}" \
    --slurpfile yaml_inputs "${work}/yaml-inputs.json" \
    --slurpfile yaml_environments "${work}/yaml-environments.json" \
    --slurpfile directories "${work}/directories.json" \
    '{
      schema_version: 1,
      caller: {repository: $repository, default_branch: $default_branch},
      event: {name: $event_name, ref_name: $ref_name},
      workflow_inputs: $inputs[0],
      yaml: {inputs: $yaml_inputs[0], environments: $yaml_environments[0]},
      directories_exist: $directories[0]
    }' >"${out_file}"
  rm -rf "${work}"
}

# Append the multi-line output $1 with the contents of file $2 to $GITHUB_OUTPUT.
function set-multiline-output-from-file {
  local name="${1}" file="${2}" delimiter
  delimiter="EOF_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  {
    echo "${name}<<${delimiter}"
    cat "${file}"
    echo
    echo "${delimiter}"
  } >>"${GITHUB_OUTPUT}"
}
