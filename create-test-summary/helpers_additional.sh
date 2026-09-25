#!/bin/env bash
#
# Action-specific helpers for create-test-summary.
# Auto-loaded by helpers.sh.
#
# Every large value (the Jobs API response, the metadata files, the matrix,
# the body) lives in a file; only paths and small scalars pass through shell
# variables, because the step runs under 'set -o allexport' and anything
# large in a variable reaches envp (the ARG_MAX rule of CLAUDE.md).
#

# The test job's step ids and the test step's display name. The workflow's
# test job must use exactly these (docs/Terraform-tests.md §5.2); the summary
# reads their outcomes and outputs from the job metadata and finds the test
# step by name in the Jobs API for the '#step:<number>:1' anchor.
TEST_STEP_ID="test"
TEST_STEP_NAME="🧪 Terraform test"
OUTPUT_UPLOAD_STEP_ID="upload-test-output"
CREDENTIALS_STEP_ID="verify-credentials"
LOCK_STEP_ID="provider-versions"
INIT_STEP_ID="init"

# Title shared with the seed placeholder: the head must not rename itself
# mid-run (docs/Terraform-tests.md P23).
SUMMARY_TITLE="### Terraform tests summary"

# The body must stay at or under this many characters (P15, P21).
BODY_BUDGET_CHARS=65000

# Every job of the run, one array across all pages. Each page is an object
# {total_count, jobs: [...]}; --jq '.jobs' leaves one array per page for
# normalise_jobs_file to join. The default filter is 'latest': the current
# attempt's jobs, which is where a re-run's new job ids are (§6.2).
function _gh_list_run_jobs {
  local repo="${1}" run_id="${2}"
  gh api --paginate "repos/${repo}/actions/runs/${run_id}/jobs" --jq '.jobs'
}

# normalise_jobs_file <in> <out>: one flat JSON array of jobs from a file
# holding the Jobs API response in any of the shapes a caller or a fixture
# may hand over: one array per page (the helper's output), a page object
# with .jobs, or several of either. Returns 1 when nothing usable is in it.
function normalise_jobs_file {
  local in="${1}" out="${2}"
  [ -s "${in}" ] || return 1
  jq -s '
    if length == 0 then error("empty") else . end
    | map(if type == "array" then . elif type == "object" then (.jobs // error("no jobs")) else error("not jobs") end)
    | add // []
    | map(select(type == "object"))
  ' "${in}" >"${out}" 2>/dev/null
}

# resolve_jobs_file <out>: fills <out> with the run's jobs as one array and
# returns 0, or returns 1 when they cannot be had. Uses input_jobs_json_file
# when set (tests, or a caller that listed the jobs itself), else the Jobs
# API. Never fails the step: a missing job link is a degraded body, not a
# red job (P18).
function resolve_jobs_file {
  local out="${1}"
  if [ -n "${input_jobs_json_file:-}" ]; then
    if normalise_jobs_file "${input_jobs_json_file}" "${out}"; then
      log-info "jobs read from '${input_jobs_json_file}': $(jq 'length' "${out}") job record(s)"
      return 0
    fi
    log-warn "jobs file '${input_jobs_json_file}' is missing or holds no jobs; job links and job conclusions are unavailable"
    return 1
  fi
  if [ -z "${GH_TOKEN:-}" ]; then
    log-warn "no github-token; job links and job conclusions are unavailable"
    return 1
  fi
  if [ -z "${GITHUB_REPOSITORY:-}" ] || [ -z "${GITHUB_RUN_ID:-}" ]; then
    log-warn "GITHUB_REPOSITORY or GITHUB_RUN_ID is not set; job links and job conclusions are unavailable"
    return 1
  fi
  local raw
  raw=$(mktemp)
  if ! _gh_list_run_jobs "${GITHUB_REPOSITORY}" "${GITHUB_RUN_ID}" >"${raw}" 2>"${raw}.err"; then
    log-warn "listing the run's jobs failed: $(head -c 500 "${raw}.err")"
    rm -f "${raw}" "${raw}.err"
    return 1
  fi
  rm -f "${raw}.err"
  if ! normalise_jobs_file "${raw}" "${out}"; then
    log-warn "the Jobs API response could not be parsed; job links and job conclusions are unavailable"
    rm -f "${raw}"
    return 1
  fi
  rm -f "${raw}"
  log-info "jobs read from the Jobs API: $(jq 'length' "${out}") job record(s)"
  return 0
}

# write_matrix_file <out>: the builder's matrix rows as one JSON array, from
# input_tests_matrix_json (the shim's capture of toJSON(inputs.tests-matrix-json),
# so a JSON string holding the matrix, or the matrix itself when a caller
# passed an object). Written with printf, a builtin: the value never reaches
# argv or envp. An unusable value gives [] and a warning; the body is then
# built from the metadata alone.
function write_matrix_file {
  local out="${1}"
  local raw
  raw=$(mktemp)
  printf '%s' "${input_tests_matrix_json:-}" >"${raw}"
  if [ ! -s "${raw}" ]; then
    printf '[]' >"${out}"
    rm -f "${raw}"
    return 0
  fi
  if ! jq '
      (if type == "string" then (if . == "" then {} else fromjson end) else . end)
      | if type == "object" then (.include // []) elif type == "array" then . elif . == null then [] else error("not a matrix") end
      | map(select(type == "object" and ((.slug // "") | type) == "string" and (.slug // "") != ""))
    ' "${raw}" >"${out}" 2>/dev/null; then
    log-warn "tests-matrix-json is not a matrix; rows without metadata cannot be reconciled"
    printf '[]' >"${out}"
  fi
  rm -f "${raw}"
  return 0
}

# write_not_run_file <out>: the not-run entries as one JSON array of
# {file, lane, reason}, from input_not_run_file: the matrix builder's
# relevance.json (its tests.not_run) or a bare array of entries. A missing
# file is expected (the artifact download is continue-on-error) and gives [].
function write_not_run_file {
  local out="${1}" in="${input_not_run_file:-}"
  printf '[]' >"${out}"
  [ -z "${in}" ] && return 0
  if [ ! -f "${in}" ]; then
    log-warn "not-run file '${in}' not found; the not-run list is omitted"
    return 0
  fi
  if ! jq '
      (if type == "array" then . elif type == "object" then (.tests.not_run // .not_run // []) else error("no") end)
      | map(select(type == "object" and ((.file // "") | type) == "string" and (.file // "") != ""))
      | map({file: .file, lane: ((.lane // "") | tostring), reason: ((.reason // "") | tostring)})
    ' "${in}" >"${out}.tmp" 2>/dev/null; then
    log-warn "not-run file '${in}' holds no not-run list; the not-run list is omitted"
    rm -f "${out}.tmp"
    return 0
  fi
  mv "${out}.tmp" "${out}"
  return 0
}

# collect_metadata <out> <file>...: one JSON array with what the summary reads
# from each metadata file. A malformed file, or one of an unknown schema
# major, is skipped with a warning; the others still render.
function collect_metadata {
  local out="${1}"
  shift
  local ndjson
  ndjson=$(mktemp)
  local file version
  for file in "$@"; do
    if ! jq -e 'type == "object"' "${file}" >/dev/null 2>&1; then
      log-warn "skipping malformed metadata file: ${file}"
      continue
    fi
    version=$(jq -r '.metadata.schema_version // "" | tostring' "${file}")
    if [ "${version%%.*}" != "2" ]; then
      log-warn "skipping ${file}: unknown metadata schema version '${version}'"
      continue
    fi
    jq -c \
      --arg ts "${TEST_STEP_ID}" --arg us "${OUTPUT_UPLOAD_STEP_ID}" \
      --arg cs "${CREDENTIALS_STEP_ID}" --arg ls "${LOCK_STEP_ID}" --arg is "${INIT_STEP_ID}" '
      {
        slug: ((.matrix_context.slug // .metadata.environment // "") | tostring),
        test: (.matrix_context.test // {} | if type == "object" then . else {} end),
        outputs: (.steps[$ts].outputs // {} | if type == "object" then . else {} end),
        artifact_url: ((.steps[$us].outputs["artifact-url"] // "") | tostring),
        credentials: ((.steps[$cs].outcome // "") | tostring),
        lock: ((.steps[$ls].outcome // "") | tostring),
        init: ((.steps[$is].outcome // "") | tostring)
      }
      | select(.slug != "")
    ' "${file}" >>"${ndjson}" 2>/dev/null || log-warn "skipping ${file}: its fields could not be read"
    if [ "$(tail -c 1 "${ndjson}" 2>/dev/null)" != "" ]; then printf '\n' >>"${ndjson}"; fi
  done
  jq -s '.' "${ndjson}" >"${out}"
  rm -f "${ndjson}"
}

# build_rows <matrix> <meta> <jobs|""> <out>: one row per matrix row and per
# metadata file the matrix does not list, with status, category, counts,
# links and times resolved. Rows whose job left no metadata are rendered
# from the Jobs API conclusion (§6.2 step 5, P33).
function build_rows {
  local matrix="${1}" meta="${2}" jobs="${3}" out="${4}"
  local jobs_arg="${jobs}"
  if [ -z "${jobs_arg}" ]; then
    jobs_arg=$(mktemp)
    printf 'null' >"${jobs_arg}"
  fi
  jq -n \
    --slurpfile matrix "${matrix}" \
    --slurpfile meta "${meta}" \
    --slurpfile jobs "${jobs_arg}" \
    --arg step_name "${TEST_STEP_NAME}" \
    -f <(_rows_program) >"${out}"
  local rc=$?
  [ -z "${jobs}" ] && rm -f "${jobs_arg}"
  return ${rc}
}

function _rows_program {
  cat <<'JQ'
def num: if type == "number" then . elif type == "string" and test("^[0-9]+$") then tonumber else null end;
def truthy: . == true or . == "true";
def ts: if type == "string" and . != "" then (sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) else null end;

($matrix[0]) as $rows_in
| ($meta[0]) as $metas
| ($jobs[0]) as $jobs_in
| ([$rows_in[] | .test["provider-set"] // ""] + [$metas[] | .test["provider-set"] // ""] | map(select(. != "")) | unique | length) as $nsets
| [
    ($rows_in[] | . as $r | {
      slug: $r.slug,
      test: (((first($metas[] | select(.slug == $r.slug)) // {}).test // {}) + ($r.test // {})),
      meta: (first($metas[] | select(.slug == $r.slug)) // null),
      orphan: false
    }),
    ($metas[] | . as $m | select(any($rows_in[]; .slug == $m.slug) | not) | {slug: $m.slug, test: $m.test, meta: $m, orphan: true})
  ]
| map(
    . as $e
    | $e.test as $t
    | (($t.file // "") | tostring) as $file
    | ($t["provider-set-environments"] // [] | if type == "array" then map(tostring) else [] end) as $envs
    # The row's own name is the job's; the engine suffixes only a file that runs in more than one set.
    | ((($t.name // "") | tostring) as $name
       | if $name != "" then $name
         else "Terraform test (" + $file + ")" + (if $nsets > 1 then " [providers: " + ($envs | join(", ")) + "]" else "" end) end) as $suffix
    | (if $jobs_in == null or $file == "" then null else first($jobs_in[] | select(((.name // "") | tostring) | endswith($suffix))) // null end) as $job
    | $e.meta as $m
    | ($m.outputs // {}) as $o
    | (if $m == null then
         (if ($job.conclusion // "") == "success" then {status: "pass", reason: ""} else {status: "error", reason: "job did not run"} end)
       else
         (($o.status // "") | tostring) as $st
         | if $st == "pass" or $st == "fail" or $st == "error" then {status: $st, reason: (($o.reason // "") | tostring)}
           elif $m.credentials == "failure" then {status: "error", reason: "no-credentials"}
           elif $m.lock == "failure" then {status: "error", reason: "lock-platform"}
           elif $m.init == "failure" or $m.init == "cancelled" then {status: "error", reason: "init"}
           else {status: "error", reason: "no-result"}
           end
       end) as $s
    | {
        slug: $e.slug,
        file: (if $file == "" then $e.slug else $file end),
        root: (($t.root // ".") | tostring | if . == "" then "." else . end),
        lane: (($t.lane // "") | tostring),
        set: (($t["provider-set"] // "") | tostring),
        set_envs: $envs,
        lock: (($t["provider-set-lock"] // "") | tostring),
        github_environment: (($t["github-environment"] // "") | tostring),
        root_kind: (($t["root-kind"] // "") | tostring),
        status: $s.status,
        reason: $s.reason,
        conclusion: (if $job == null then (if $jobs_in == null then "unknown" else "not found" end) else (($job.conclusion // $job.status // "unknown") | tostring) end),
        passed: ($o.passed | num),
        failed: ($o.failed | num),
        errored: ($o.errored | num),
        skipped: ($o.skipped | num),
        total: ($o.total | num),
        elapsed_ms: ($o["elapsed-ms"] | num),
        failed_runs: (($o["failed-runs-json"] // []) | (if type == "string" then (try fromjson catch []) else . end) | if type == "array" then map(select(type == "object")) else [] end),
        omitted: (($o["failed-runs-omitted"] | num) // 0),
        floating: (($o["providers-floating-count"] | num)
                   // (($o["providers-summary"] // "") | tostring | split(" · ") | map(select(test(" floating$"))) | length)),
        platform: (($o["runner-platform"] // "") | tostring),
        job_url: (if $job == null or (($job.html_url // "") == "") then ""
                  else ($job.html_url | tostring) as $u
                  | (first(($job.steps // [])[] | select(.name == $step_name) | .number) // null) as $n
                  | if $n != null then "\($u)#step:\($n):1" else "\($u)#logs" end
                  end),
        artifact_url: ($m.artifact_url // ""),
        started: ($job.started_at | ts),
        completed: ($job.completed_at | ts),
        category: (if $s.status == "pass" then "passed"
                   elif $m != null and ($t["allow-failing-terraform-tests"] | truthy) then "tolerated"
                   else "failed" end),
        nometa: ($m == null),
        orphan: $e.orphan
      }
  )
| {
    nsets: $nsets,
    rows: .,
    wall: ([.[] | select(.started != null and .completed != null)] as $timed
           | if ($timed | length) == 0 then null
             else (($timed | map(.completed) | max) - ($timed | map(.started) | min)) end)
  }
JQ
}

# render_body <rows> <not-run> <level> <links-ok> <footer> <out>
#   level 0: everything; 1: failed and tolerated <details> capped at 2 000
#   characters; 2: per-root tables collapsed to their summary line; 3: the
#   not-run table collapsed to its summary line; 4: a last-resort cut of the
#   whole body to the budget (§6.4 budget order, then a guard so a 256-row
#   failure still posts something rather than nothing).
function render_body {
  local rows="${1}" not_run="${2}" level="${3}" links_ok="${4}" footer="${5}" out="${6}"
  local run_url="${input_run_url:-}"
  [ -z "${run_url}" ] && run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
  jq -nr \
    --slurpfile doc "${rows}" \
    --slurpfile notrun "${not_run}" \
    --argjson level "${level}" \
    --argjson links_ok "${links_ok}" \
    --argjson footer "${footer}" \
    --argjson budget "${BODY_BUDGET_CHARS}" \
    --arg title "${SUMMARY_TITLE}" \
    --arg run_url "${run_url}" \
    --arg repo "${GITHUB_REPOSITORY:-<owner>/<repo>}" \
    --arg run_id "${GITHUB_RUN_ID:-<run-id>}" \
    --arg actor "${GITHUB_ACTOR:-}" \
    -f <(_render_program) >"${out}"
}

function _render_program {
  cat <<'JQ'
def pad2: tostring | if length < 2 then "0" + . else . end;
def clock: (. / 1000 | floor) as $s | "\($s / 60 | floor):\($s % 60 | pad2)";
def timecell: if . == null then "—" else "`" + clock + "`" end;
def cell: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
def html: tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("\""; "&quot;");
def plural($n; $one; $many): if $n == 1 then "\($n) \($one)" else "\($n) \($many)" end;
def dirname: split("/") | .[:-1] | join("/") | if . == "" then "." else . end;

($doc[0]) as $d
| ($notrun[0]) as $nr
| $d.rows as $rows
| ($d.nsets > 1) as $sets

| def providers: if $sets and (.set_envs | length) > 0 then "providers from " + (.set_envs | join(", ")) else "" end;
  def filecell: "`" + (.file | cell) + "`" + (providers | if . == "" then "" else " · " + . end);
  def lanecell: if .lane == "" then "—" else (.lane | cell) end;
  def runs:
    if (.total | type) == "number" and .total > 0 then "\(.passed // 0)/\(.total)"
    elif .category == "passed" and .nometa then "<span title=\"the job succeeded but left no metadata\">—</span>"
    elif .category == "passed" then "\(.passed // 0)/\(.total // 0)"
    else "<span title=\"\(.status) (\(.reason | html))\">\(.status)</span>" end;
  def links:
    [ (if .job_url != "" then "[job log](\(.job_url))" else empty end),
      (if .artifact_url != "" then "[output](\(.artifact_url))" else empty end) ] | join(" · ");
  def reason_text:
    if .reason == "no-credentials" then
      (if .github_environment != "" then "no credentials in <code>\(.github_environment | html)</code>" else "no credentials" end)
    elif .reason == "lock-platform" then "the provider lock records no checksum for the runner's platform"
    elif .reason == "init" then "terraform init failed"
    elif .reason == "terraform-version" then "Terraform is below the 1.12.0 floor"
    elif .reason == "not-initialised" then "the test root is not initialised"
    elif .reason == "invalid" then "a configuration or test file is invalid"
    elif .reason == "not-discovered" then "Terraform did not discover the file"
    elif .reason == "file" then "the file failed before its first run block"
    elif .reason == "job did not run" then "the job did not run (\(.conclusion | html))"
    elif .reason == "no-result" then "the job reported no test result"
    else "\(.status) (\(.reason | html))" end;
  def describe:
    if .reason == "assertion" or (.status == "fail" and (.total | type) == "number") then
      "\(.failed // 0) of \(.total // 0) run blocks failed"
    elif .reason == "run" and (.total | type) == "number" then
      [ (if (.failed // 0) > 0 then "\(.failed) failed" else empty end),
        (if (.errored // 0) > 0 then plural(.errored; "error"; "errors") else empty end),
        (if (.skipped // 0) > 0 then "\(.skipped) skipped" else empty end) ] | join(", ")
      | if . == "" then "error (run)" else . end
    else reason_text end;
  def bullet:
    ((.run // "") | tostring) as $run
    | ((.status // "") | tostring) as $st
    | if $st == "skip" then
        (if $run == "" then empty else "- `\($run | cell)` — skipped: a previous run block errored" end)
      else
        ((.summary // "") | tostring | gsub("\n"; " ")) as $sum
        | ((.detail // "") | tostring | gsub("\n"; " ")) as $det
        | ((.file // "") | tostring) as $f
        | (.line // null) as $l
        | "- "
          + (if $run != "" then "`\($run | cell)` — " else "" end)
          + (if $sum == "" and $det == "" then $st
             elif $det == "" then $sum
             elif $sum == "" then $det
             else "\($sum): \($det)" end)
          + (if $f != "" then " (`" + $f + (if $l != null then ":\($l)" else "" end) + "`)" else "" end)
      end;
  def lockfile:
    if .root_kind == "environment" or .lock == "" then
      (if .root == "." then ".terraform.lock.hcl" else .root + "/.terraform.lock.hcl" end)
    else .lock end;
  def special:
    if .reason == "no-credentials" then
      (if .github_environment == "" then "<environment>" else .github_environment end) as $env
      | "The lane's GitHub Environment `\($env)` has no `ARM_TENANT_ID` or `ARM_CLIENT_ID`. "
        + "A collaborator with write access sets the secrets, the identity's owner adds a federated credential "
        + "for the environment's subject, then the failed jobs are re-run "
        + "([bring-up](https://github.com/dsb-norge/github-actions-terraform/blob/main/docs/Terraform-tests.md#36-github-environments-per-lane)):\n\n"
        + "```bash\n"
        + "gh secret set ARM_TENANT_ID       --repo \($repo) --env \($env) --body '<tenant-id>'\n"
        + "gh secret set ARM_CLIENT_ID       --repo \($repo) --env \($env) --body '<client-id>'\n"
        + "gh secret set ARM_SUBSCRIPTION_ID --repo \($repo) --env \($env) --body '<subscription-id>'   # subscription lanes only\n"
        + "gh secret list --repo \($repo) --env \($env)\n"
        + "gh run rerun \($run_id) --repo \($repo) --failed\n"
        + "```"
    elif .reason == "lock-platform" then
      (if .platform == "" then "<os>_<arch>" else .platform end) as $p
      | lockfile as $lf
      | "The provider lock `\($lf)` records no `h1:` checksum for the runner's platform `\($p)`. "
        + "Add it where the lock lives (after `terraform init` there) and commit the lock"
        + (if .root_kind != "environment" and (.set_envs | length) > 1
           then "; every environment of this provider set needs it: " + (.set_envs | map("`" + . + "`") | join(", "))
           else "" end)
        + ":\n\n```bash\nterraform -chdir=\($lf | dirname) providers lock -platform=\($p)\n```"
    elif .reason == "init" then
      "- `terraform init` failed in `\(.root)`; the job log's init step has the error. A syntax error in any test file "
        + "of a root fails init for every test file there, so the cause may be a sibling of this file."
    elif .reason == "job did not run" then
      "- The job left no metadata: it was refused by an environment protection rule, cancelled, or is still waiting (job conclusion: `\(.conclusion)`)."
    else
      "- No run block reported a diagnostic; see the job log."
    end;
  def content:
    if (.failed_runs | length) > 0 then
      ([.failed_runs[] | bullet] + (if .omitted > 0 then ["- … \(.omitted) more in the job log"] else [] end)) | join("\n")
    else special end;
  def cap($max; $head; $tail):
    . as $c
    | if ($head | length) + ($c | length) + ($tail | length) <= $max then $c
      else
        "… (truncated, see job log)" as $mark
        | ($max - ($head | length) - ($tail | length) - ($mark | length) - 8) as $room
        | (reduce ($c | split("\n"))[] as $line ({out: [], len: 0, full: false};
             if .full then .
             elif .len + ($line | length) + 1 <= $room then .out += [$line] | .len += ($line | length) + 1
             else .full = true end))
        | .out as $kept
        | ([$kept[] | select(test("^\\s*```"))] | length) as $fences
        | ($kept + (if $fences % 2 == 1 then ["```"] else [] end) + [$mark]) | join("\n")
      end;
  def details($icon):
    ("<details><summary>" + $icon + " <code>" + (.file | html) + "</code> — " + describe
      + (providers | if . == "" then "" else " · " + . end) + "</summary>\n\n") as $head
    | "\n\n</details>" as $tail
    | $head + (content | if $level >= 1 then cap(2000; $head; $tail) else . end) + $tail;

  ($rows | map(select(.category == "failed")) | sort_by(.file, (.set_envs | join(",")))) as $failed
| ($rows | map(select(.category == "tolerated")) | sort_by(.file, (.set_envs | join(",")))) as $tolerated
| ($rows | map(select(.category == "passed"))) as $passed
| ($nr | sort_by(.file)) as $notrun
| ([$rows[].file] + [$notrun[].file] | unique | length) as $nfiles
| ([$rows[].lane] + [$notrun[].lane] | map(select(. != "")) | unique | length) as $nlanes

| (if ($rows | length) == 0 and ($notrun | length) == 0 then
     [$title + "\nNo test files found."]
   else
     [ $title,
       ([ (if ($failed | length) > 0 then "❌ \($failed | length) failed" else empty end),
          (if ($tolerated | length) > 0 then "⚠️ \($tolerated | length) tolerated" else empty end),
          (if ($passed | length) > 0 then "✅ \($passed | length) passed" else empty end),
          (if ($notrun | length) > 0 then "⏭️ \($notrun | length) not run" else empty end) ] | join(" · "))
       + " — " + plural($nfiles; "file"; "files")
       + " · " + plural($nlanes; "lane"; "lanes")
       + (if $sets then " · \($d.nsets) provider sets" else "" end)
       + " · ⏱ " + (if $d.wall == null then "—" else ($d.wall * 1000 | clock) end)
     ]
     | join("\n")
     | [.]
     + (if ($failed | length) > 0 then
          [ "**❌ Failed (\($failed | length))**",
            ([ "| Test file | Lane | Runs | Time | Links |", "|---|:---:|:---:|:---:|---|" ]
             + [ $failed[] | "| \(filecell) | \(lanecell) | \(runs) | \(.elapsed_ms | timecell) | \(links) |" ] | join("\n")) ]
          + [ $failed[] | details("❌") ]
        else [] end)
     + (if ($tolerated | length) > 0 then
          [ "**⚠️ Tolerated (\($tolerated | length))**",
            ([ "| Test file | Lane | Result | Runs | Time | Links |", "|---|:---:|:---:|:---:|:---:|---|" ]
             + [ $tolerated[] | "| \(filecell) | \(lanecell) | <span title=\"\(.status) (\(.reason | html)): allowed to fail\">⚠️ \(.status)</span> | \(runs) | \(.elapsed_ms | timecell) | \(links) |" ] | join("\n")) ]
          + [ $tolerated[] | details("⚠️") ]
        else [] end)
     + ( $passed
         | group_by([.root, (if $sets then (.set_envs | join(", ")) else "" end)])
         | sort_by([(.[0].root != "."), .[0].root, (.[0].set_envs | join(", "))])
         | map(
             sort_by(.file) as $g
             | ($g | map(.lane) | unique) as $lanes
             | ($g | map(.elapsed_ms) | map(select(. != null))) as $times
             | ($g | map(.floating) | max) as $floating
             | ("✅ <code>" + ($g[0].root | html) + "</code> — "
                + plural($g | length; "file"; "files") + " · \($g | length) passed · "
                + (if ($lanes | length) == 1 then (if $lanes[0] == "" then "lane —" else "lane " + ($lanes[0] | html) end) else "\($lanes | length) lanes" end)
                + " · ⏱ " + (if ($times | length) == 0 then "—" else ($times | add | clock) end)
                + ($g[0] | providers | if . == "" then "" else " · " + . end)
                + (if $floating > 0 then " · " + plural($floating; "test-only provider"; "test-only providers") + " floating" else "" end)) as $line
             | if $level >= 2 then $line
               else
                 "<details><summary>" + $line + "</summary>\n\n"
                 + ([ "| Test file | Lane | Runs | Time | Links |", "|---|:---:|:---:|:---:|---|" ]
                    + [ $g[] | "| `\(.file | cell)` | \(lanecell) | \(runs) | \(.elapsed_ms | timecell) | \(links) |" ] | join("\n"))
                 + "\n\n</details>"
               end ) )
     + (if ($notrun | length) > 0 then
          ("⏭️ Not run (\($notrun | length))") as $line
          | if $level >= 3 then [$line]
            else
              [ "<details><summary>" + $line + "</summary>\n\n"
                + ([ "| Test file | Lane | Reason |", "|---|:---:|---|" ]
                   + [ $notrun[]
                       | "| `\(.file | cell)` | \(if .lane == "" then "—" else (.lane | cell) end) | "
                         + (if .reason == "misplaced" then "misplaced: not in a test root (see docs)"
                            elif .reason == "secrets unavailable" or .reason == "secrets-unavailable" then
                              "secrets unavailable (" + (if $actor == "dependabot[bot]" then "Dependabot pull request" else "fork pull request" end) + ")"
                            else (.reason | cell) end)
                         + " |" ] | join("\n"))
                + "\n\n</details>" ]
            end
        else [] end)
   end)
| . + (if $links_ok or (($rows | length) == 0) then [] else ["_Job links are unavailable: the run's jobs could not be read from the Jobs API._"] end)
| (if $footer then ["[Workflow log](\($run_url))"] else [] end) as $foot
| (join("\n\n")) as $main
| if $level < 4 then ([$main] + $foot | join("\n\n"))
  else
    "\n\n… (truncated to fit a comment, see the workflow log)" as $mark
    | (($foot | join("")) | length) as $flen
    | ($main[0:($budget - $flen - ($mark | length) - 40)] | sub("\n[^\n]*$"; "")) as $cut
    | ([$cut | scan("```")] | length) as $fences
    | (([$cut | scan("<details>")] | length) - ([$cut | scan("</details>")] | length)) as $open
    | ($cut + (if $fences % 2 == 1 then "\n```" else "" end)
       + ([range(0; $open)] | map("\n\n</details>") | join(""))
       + $mark) as $trimmed
    | ([$trimmed] + $foot | join("\n\n"))
  end
JQ
}
