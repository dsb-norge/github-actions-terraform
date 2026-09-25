#!/bin/env bash
#
# Source for the run-tests step.
#
# Runs 'terraform test' for one test file and classifies the outcome from the
# JSON stream (docs/Terraform-tests.md §5.4-§5.8): status and reason, counts,
# per-run and per-diagnostic files, the providers the root resolved, error
# annotations, and a block in the job's step summary. Every file lives under
# $RUNNER_TEMP/<slug>/; step outputs are paths, counts and short strings only.
#
# Outcomes of earlier steps (the credential check, the lock check, init) come
# in as inputs. When one of them failed, terraform is not run and the step
# reports that as its status, so the job's metadata always carries one.
#
# Required environment variables:
#   input_test_file              - test file, relative to input_working_directory;
#                                  a bare name under tests/ when that is empty
#   input_working_directory      - the test root, relative to the workspace or
#                                  absolute. Empty: the legacy call shape (the
#                                  workspace, 'tests/<test-file>', no version
#                                  floor)
#   input_junit                  - 'true' passes -junit-xml (Terraform >= 1.11)
#   input_slug                   - directory name under RUNNER_TEMP; derived
#                                  from root and file when empty
#   input_status_credentials     - outcome of the credential check, or empty
#   input_status_lock            - outcome of the lock check, or empty
#   input_status_init            - outcome of init, or empty
#   input_environments_lock_file - the environment lock the root's lock was
#                                  copied from (or an environment root's own),
#                                  relative to the workspace or absolute; empty
#                                  for no comparison
#
# Standard GitHub environment variables used:
#   GITHUB_WORKSPACE, RUNNER_TEMP, RUNNER_OS, RUNNER_ARCH, GITHUB_STEP_SUMMARY
#
# Exit code: 0 when the status is 'pass', else 1.
#

set +o nounset # optional inputs are checked explicitly

# Load helpers (provides tt-* and the TT_* limits)
source "${GITHUB_ACTION_PATH}/helpers.sh"

# ============================================================================
# Steps of main
# ============================================================================

# Sets TT_STATUS/TT_REASON when an earlier step's outcome means terraform must
# not run (§5.5 rows 0, 0b, 1). An empty outcome means the caller did not say.
function classify_earlier_steps {
  case "${input_status_credentials}" in
    failure | cancelled) TT_STATUS="error" TT_REASON="no-credentials"; return ;;
  esac
  case "${input_status_lock}" in
    failure | cancelled) TT_STATUS="error" TT_REASON="lock-platform"; return ;;
  esac
  if [ -n "${input_status_init}" ] && [ "${input_status_init}" != "success" ]; then
    TT_STATUS="error" TT_REASON="init"
  fi
}

# Reads the Terraform version and applies the floor (§3.5, row 2).
function check_terraform_version {
  if ! command -v terraform &>/dev/null; then
    TT_VERSION_MESSAGE="terraform is not available on PATH; install it with hashicorp/setup-terraform (terraform_wrapper: false)."
    TT_STATUS="error" TT_REASON="terraform-version"
    return
  fi
  TT_TERRAFORM_VERSION="$(terraform version -json 2>/dev/null | jq -r '.terraform_version // empty' 2>/dev/null || true)"
  if [ -z "${TT_TERRAFORM_VERSION}" ]; then
    TT_VERSION_MESSAGE="could not read the Terraform version from 'terraform version -json'."
    TT_STATUS="error" TT_REASON="terraform-version"
    return
  fi
  log-info "using Terraform ${TT_TERRAFORM_VERSION}"
  # The floor exists for the test-root layouts of the default workflow; the
  # legacy call shape runs from a module root, which older versions handle.
  if [ -n "${input_working_directory}" ] && ! tt-version-ge "${TT_TERRAFORM_VERSION}" "${TT_VERSION_FLOOR}"; then
    TT_VERSION_MESSAGE="Terraform ${TT_TERRAFORM_VERSION} is below the floor ${TT_VERSION_FLOOR} for terraform test (docs/Terraform-tests.md §3.5 in dsb-norge/github-actions-terraform)."
    TT_STATUS="error" TT_REASON="terraform-version"
  fi
}

# Runs terraform test from the root; stdout and stderr go to the JSON file,
# never through a variable (P15).
function run_terraform_test {
  local -a args=(test -json -no-color "-filter=${TT_REL}")
  if [ "${input_junit}" == "true" ] && tt-version-ge "${TT_TERRAFORM_VERSION}" "${TT_JUNIT_FROM}"; then
    args+=("-junit-xml=${TT_JUNIT_FILE}")
  fi

  log-info "running 'terraform ${args[*]}' in '${TT_ROOT}'"
  # '|| exit_code=$?': GitHub runs the step under 'bash -e', and a failing
  # test must not end the step before it is classified.
  local exit_code=0
  (cd "${TT_ROOT_ABS}" && TF_IN_AUTOMATION=true terraform "${args[@]}") >"${TT_JSON_FILE}" 2>&1 || exit_code=$?
  TT_EXIT_CODE="${exit_code}"
  log-info "terraform exited with ${exit_code}"

  # The JSON objects of the log, one per line; anything else (a stray stderr
  # line, a crash) is dropped here and shown in the log below.
  jq -c -R 'fromjson? | select(type == "object")' "${TT_JSON_FILE}" >"${TT_MESSAGES_FILE}"

  start-group "terraform test output"
  jq -r -R '(fromjson? | select(type == "object") | .["@message"] // empty) // .' "${TT_JSON_FILE}"
  end-group
}

function classify_log {
  local verdict
  verdict="$(tt-jq -r -s --arg rel "${TT_REL}" --arg exit "${TT_EXIT_CODE}" \
    'include "terraform_test"; classify($rel; $exit) | "\(.status) \(.reason)"' "${TT_MESSAGES_FILE}")"
  TT_STATUS="${verdict%% *}"
  TT_REASON="${verdict#* }"
}

# runs.json, diagnostics.json and the counts, from the log when there is one.
function extract_log {
  local prefix=""
  [ "${TT_ROOT}" != "." ] && prefix="${TT_ROOT}/"

  if [ -s "${TT_MESSAGES_FILE}" ]; then
    tt-jq -s 'include "terraform_test"; runs' "${TT_MESSAGES_FILE}" >"${TT_RUNS_FILE}"
    tt-jq -s --arg prefix "${prefix}" 'include "terraform_test"; diagnostics($prefix)' "${TT_MESSAGES_FILE}" >"${TT_DIAGNOSTICS_FILE}"
    read -r TT_PASSED TT_FAILED TT_ERRORED TT_SKIPPED < <(tt-jq -r -s '
      ([ .[] | select(.type == "test_summary") | .test_summary ] | first // {}) as $s
      | "\($s.passed // 0) \($s.failed // 0) \($s.errored // 0) \($s.skipped // 0)"' "${TT_MESSAGES_FILE}")
    TT_ELAPSED_MS="$(tt-jq -r -s 'include "terraform_test"; elapsed_ms // ""' "${TT_MESSAGES_FILE}")"
    TT_SUMMARY="$(jq -r -s '[ .[] | select(.type == "test_summary") | .["@message"] ] | first // "" | gsub("[\r\n]"; " ")' "${TT_MESSAGES_FILE}")"
  else
    echo '[]' >"${TT_RUNS_FILE}"
    echo '[]' >"${TT_DIAGNOSTICS_FILE}"
  fi
  TT_TOTAL=$((TT_PASSED + TT_FAILED + TT_ERRORED + TT_SKIPPED))

  local capped
  capped="$(tt-jq -c -n --slurpfile runs "${TT_RUNS_FILE}" --slurpfile diagnostics "${TT_DIAGNOSTICS_FILE}" \
    --argjson bytes "${TT_FAILED_RUNS_BYTES}" \
    'include "terraform_test"; {runs: $runs[0], diagnostics: $diagnostics[0]} | failed_runs | cap_bytes($bytes)')"
  TT_FAILED_RUNS_JSON="$(jq -c '.kept' <<<"${capped}")"
  TT_FAILED_RUNS_OMITTED="$(jq -r '.omitted' <<<"${capped}")"
}

# providers.json: the lock Terraform wrote, each provider compared with the
# environment lock (§5.3).
function extract_providers {
  echo '[]' >"${TT_PROVIDERS_FILE}"
  TT_PROVIDERS_SUMMARY=""
  TT_PROVIDERS_FLOATING=0
  local written="${TT_ROOT_ABS}/.terraform.lock.hcl"
  [ -f "${written}" ] || return 0

  local written_json="${TT_OUT_DIR}/.written-lock.json"
  local environments_json="${TT_OUT_DIR}/.environments-lock.json"
  tt-lock-to-json "${written}" "${written_json}"
  echo '[]' >"${environments_json}"

  local mode="root"
  if [ -n "${input_environments_lock_file}" ]; then
    local environments_lock="${input_environments_lock_file}"
    [[ "${environments_lock}" == /* ]] || environments_lock="${GITHUB_WORKSPACE}/${environments_lock}"
    if [ -f "${environments_lock}" ]; then
      tt-lock-to-json "${environments_lock}" "${environments_json}"
      mode="compare"
    else
      log-warn "environments lock '${input_environments_lock_file}' not found; provider origins are not compared"
    fi
  fi

  jq -n --slurpfile written "${written_json}" --slurpfile environments "${environments_json}" --arg mode "${mode}" '
    ($environments[0] | map({(.name): .version}) | add // {}) as $env
    | $written[0]
    | map(. + if $mode == "compare"
               then {origin: (if $env[.name] == .version then "environments" else "floating" end),
                     "environments-version": $env[.name]}
               else {origin: "root", "environments-version": null} end)' >"${TT_PROVIDERS_FILE}"
  rm -f "${written_json}" "${environments_json}"

  TT_PROVIDERS_SUMMARY="$(jq -r 'map("\(.name | split("/") | last) \(.version) \(.origin)") | join(" · ") | if length > 1000 then .[0:999] + "…" else . end' "${TT_PROVIDERS_FILE}")"
  TT_PROVIDERS_FLOATING="$(jq -r 'map(select(.origin == "floating")) | length' "${TT_PROVIDERS_FILE}")"
}

function headline {
  local elapsed
  elapsed="$(jq -rn --argjson ms "${TT_ELAPSED_MS:-null}" -L "${GITHUB_ACTION_PATH}" 'include "terraform_test"; $ms | clock_ms')"
  local verdict
  case "${TT_STATUS}" in
    pass) verdict="✅ pass" ;;
    fail) verdict="❌ fail" ;;
    *) verdict="❌ error (${TT_REASON})" ;;
  esac
  echo "${verdict} · ${TT_PASSED} passed · ${TT_FAILED} failed · ${TT_ERRORED} errored · ${TT_SKIPPED} skipped · ⏱ ${elapsed}"
}

# report.txt: summary, one line per run block, every error diagnostic.
# Tail-trimmed to TT_REPORT_BYTES on a line boundary.
function write_report {
  local full="${TT_OUT_DIR}/.report-full.txt"
  {
    echo "Terraform test: ${TT_FILE_PATH}"
    echo "Working directory: ${TT_ROOT}"
    echo "Result: $(headline)"
    [ -n "${TT_SUMMARY}" ] && echo "Summary: ${TT_SUMMARY}"
    local message
    message="$(tt-reason-message "${TT_REASON}")"
    [ -n "${message}" ] && echo "${message}"
    [ -n "${TT_PROVIDERS_SUMMARY}" ] && echo "Providers: ${TT_PROVIDERS_SUMMARY}"
    echo ""
    echo "Run blocks:"
    jq -r 'if length == 0 then "  (none)" else .[] |
      "  \(.status | . + (" " * ([7 - length, 1] | max)))\(.run)\(if .["elapsed-ms"] != null then " (\(.["elapsed-ms"] / 1000 * 100 | round / 100)s)" else "" end)" end' "${TT_RUNS_FILE}"
    echo ""
    echo "Diagnostics:"
    jq -r 'if length == 0 then "  (none)" else .[] |
      "  \(if .run != "" then "[" + .run + "] " else "" end)\(if .file != "" then .file + (if .line != null then ":\(.line)" else "" end) + ": " else "" end)\(.summary)",
      (.detail | split("\n")[] | "    " + .) end' "${TT_DIAGNOSTICS_FILE}"
  } >"${full}"

  if [ "$(wc -c <"${full}")" -le "${TT_REPORT_BYTES}" ]; then
    mv "${full}" "${TT_REPORT_FILE}"
  else
    # Cut on a line boundary so no UTF-8 sequence is split.
    head -c "${TT_REPORT_BYTES}" "${full}" | sed '$d' >"${TT_REPORT_FILE}"
    echo "… (truncated, see test.json)" >>"${TT_REPORT_FILE}"
    rm -f "${full}"
  fi
}

# At most TT_MAX_ANNOTATIONS '::error' lines, then one '::warning' with the
# remainder (P17). Errors without a diagnostic get one annotation naming the
# reason.
function emit_annotations {
  [ "${TT_STATUS}" == "pass" ] && return 0
  local total
  total="$(jq 'length' "${TT_DIAGNOSTICS_FILE}")"
  if [ "${total}" -eq 0 ]; then
    local message
    message="$(tt-reason-message "${TT_REASON}")"
    tt-jq -r -n --arg file "${TT_FILE_PATH}" --arg status "${TT_STATUS}" --arg reason "${TT_REASON}" --arg message "${message}" \
      'include "terraform_test"; "::error title=" + ("Terraform test \($status) (\($reason))" | escape_property) + "::" + ("\($file): \($message)" | escape_data)'
    return 0
  fi
  tt-jq -r --arg status "${TT_STATUS}" --argjson max "${TT_MAX_ANNOTATIONS}" \
    'include "terraform_test"; annotations($status; $max)' "${TT_DIAGNOSTICS_FILE}"
  if [ "${total}" -gt "${TT_MAX_ANNOTATIONS}" ]; then
    echo "::warning title=Terraform test::$((total - TT_MAX_ANNOTATIONS)) more error diagnostics in the report (${TT_FILE_PATH})"
  fi
}

# The per-job block in $GITHUB_STEP_SUMMARY (§5.8).
function write_step_summary {
  [ -n "${GITHUB_STEP_SUMMARY}" ] || return 0
  {
    echo "### 🧪 Terraform test \`${TT_FILE_PATH}\`"
    echo ""
    headline
    if [ "${TT_STATUS}" != "pass" ]; then
      echo ""
      tt-reason-message "${TT_REASON}"
      local bullets="${TT_OUT_DIR}/.bullets.md"
      tt-jq -r -n --slurpfile runs "${TT_RUNS_FILE}" --slurpfile diagnostics "${TT_DIAGNOSTICS_FILE}" \
        'include "terraform_test"; {runs: $runs[0], diagnostics: $diagnostics[0]} | failed_runs | summary_bullets' >"${bullets}"
      local count
      count="$(wc -l <"${bullets}")"
      if [ "${count}" -gt 0 ]; then
        echo ""
        head -n "${TT_SUMMARY_BULLETS}" "${bullets}"
        if [ "${count}" -gt "${TT_SUMMARY_BULLETS}" ]; then
          echo "- … $((count - TT_SUMMARY_BULLETS)) more in the report"
        fi
      fi
      rm -f "${bullets}"
    fi
    if [ -n "${TT_PROVIDERS_SUMMARY}" ]; then
      echo ""
      echo "Providers: ${TT_PROVIDERS_SUMMARY}"
    fi
    echo ""
  } >>"${GITHUB_STEP_SUMMARY}"
}

function set_outputs {
  set-output "status" "${TT_STATUS}"
  set-output "reason" "${TT_REASON}"
  set-output "passed" "${TT_PASSED}"
  set-output "failed" "${TT_FAILED}"
  set-output "errored" "${TT_ERRORED}"
  set-output "skipped" "${TT_SKIPPED}"
  set-output "total" "${TT_TOTAL}"
  set-output "elapsed-ms" "${TT_ELAPSED_MS}"
  set-output "summary" "${TT_SUMMARY}"
  set-output "exit-code" "${TT_EXIT_CODE}"
  set-output "terraform-version" "${TT_TERRAFORM_VERSION}"
  set-output "test-file-path" "${TT_FILE_PATH}"
  set-output "json-file" "${TT_JSON_OUTPUT}"
  set-output "report-file" "${TT_REPORT_FILE}"
  set-output "junit-file" "${TT_JUNIT_OUTPUT}"
  set-output "runs-json-file" "${TT_RUNS_FILE}"
  set-output "diagnostics-json-file" "${TT_DIAGNOSTICS_FILE}"
  set-output "providers-json-file" "${TT_PROVIDERS_FILE}"
  set-output "providers-summary" "${TT_PROVIDERS_SUMMARY}"
  set-output "providers-floating-count" "${TT_PROVIDERS_FLOATING}"
  set-output "failed-runs-json" "${TT_FAILED_RUNS_JSON}"
  set-output "failed-runs-omitted" "${TT_FAILED_RUNS_OMITTED}"
  # Names the legacy action published; module CI reads them.
  set-output "json" "${TT_JSON_OUTPUT}"
  set-output "report" "${TT_REPORT_FILE}"
}

# ============================================================================
# Main
# ============================================================================

function main {
  TT_STATUS="" TT_REASON="" TT_EXIT_CODE="" TT_TERRAFORM_VERSION="" TT_VERSION_MESSAGE=""
  TT_PASSED=0 TT_FAILED=0 TT_ERRORED=0 TT_SKIPPED=0 TT_TOTAL=0 TT_ELAPSED_MS="" TT_SUMMARY=""
  TT_FAILED_RUNS_JSON="[]" TT_FAILED_RUNS_OMITTED=0
  TT_PROVIDERS_SUMMARY="" TT_PROVIDERS_FLOATING=0

  if [ -z "${input_test_file}" ]; then
    log-error "input 'test-file' is required"
    return 1
  fi

  # The runner's platform is always published: the summary names it in the
  # lock-platform fix even when this step ran nothing.
  TT_RUNNER_PLATFORM="$(tt-runner-platform)"
  set-output "runner-platform" "${TT_RUNNER_PLATFORM}"
  # Published so a summary names the floor without keeping a copy of it.
  set-output "terraform-version-floor" "${TT_VERSION_FLOOR}"

  # Root and filter. The legacy call shape (no working directory) is what
  # terraform-module-ci.yaml passes: a bare file name under tests/, run from
  # the workspace.
  if [ -z "${input_working_directory}" ]; then
    TT_ROOT_ABS="${GITHUB_WORKSPACE}"
    TT_REL="tests/${input_test_file}"
  else
    TT_ROOT_ABS="${input_working_directory}"
    [[ "${TT_ROOT_ABS}" == /* ]] || TT_ROOT_ABS="${GITHUB_WORKSPACE}/${TT_ROOT_ABS}"
    TT_REL="${input_test_file#./}"
  fi
  TT_ROOT="$(realpath -m --relative-to="${GITHUB_WORKSPACE}" "${TT_ROOT_ABS}")"
  TT_FILE_PATH="${TT_REL}"
  [ "${TT_ROOT}" != "." ] && TT_FILE_PATH="${TT_ROOT}/${TT_REL}"

  local slug="${input_slug}"
  [ -n "${slug}" ] || slug="$(tt-slug "${TT_ROOT}" "${TT_REL}")"
  TT_OUT_DIR="${RUNNER_TEMP}/${slug}"
  mkdir -p "${TT_OUT_DIR}"
  TT_JSON_FILE="${TT_OUT_DIR}/test.json"
  TT_JUNIT_FILE="${TT_OUT_DIR}/junit.xml"
  TT_REPORT_FILE="${TT_OUT_DIR}/report.txt"
  TT_RUNS_FILE="${TT_OUT_DIR}/runs.json"
  TT_DIAGNOSTICS_FILE="${TT_OUT_DIR}/diagnostics.json"
  TT_PROVIDERS_FILE="${TT_OUT_DIR}/providers.json"
  TT_MESSAGES_FILE="${TT_OUT_DIR}/.messages.jsonl"
  # A re-run of the step in the same job must not report the previous log.
  rm -f "${TT_JSON_FILE}" "${TT_JUNIT_FILE}" "${TT_MESSAGES_FILE}"
  : >"${TT_MESSAGES_FILE}"

  log-info "test file '${TT_FILE_PATH}' (root '${TT_ROOT}', filter '${TT_REL}'), files in '${TT_OUT_DIR}'"

  classify_earlier_steps
  # A failed init still reads the version: below the floor, the version is the
  # likelier cause (1.12 and older refuse a test file's variable blocks, which
  # fails init for the whole root), and the floor names the fix.
  if [ -z "${TT_STATUS}" ] || [ "${TT_REASON}" == "init" ]; then
    check_terraform_version
  fi
  if [ -z "${TT_STATUS}" ] && [ ! -d "${TT_ROOT_ABS}" ]; then
    log-error "working directory '${TT_ROOT}' does not exist"
    TT_STATUS="error" TT_REASON="not-discovered"
  fi
  if [ -z "${TT_STATUS}" ]; then
    run_terraform_test
    classify_log
  fi

  extract_log
  case "${TT_REASON}" in
    no-credentials | lock-platform | init | terraform-version) ;;
    *) extract_providers ;;
  esac

  TT_JSON_OUTPUT=""
  [ -f "${TT_JSON_FILE}" ] && TT_JSON_OUTPUT="${TT_JSON_FILE}"
  TT_JUNIT_OUTPUT=""
  [ -f "${TT_JUNIT_FILE}" ] && TT_JUNIT_OUTPUT="${TT_JUNIT_FILE}"
  rm -f "${TT_MESSAGES_FILE}"

  write_report
  set_outputs
  emit_annotations
  write_step_summary

  log-multiline "report" "$(cat "${TT_REPORT_FILE}")"
  log-info "status '${TT_STATUS}'${TT_REASON:+, reason '${TT_REASON}'}"

  [ "${TT_STATUS}" == "pass" ] && return 0
  return 1
}

main
_main_exit_code=$?
exit ${_main_exit_code}
