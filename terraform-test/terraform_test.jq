# jq definitions for step_run_tests.sh, loaded with
#   jq -L "${GITHUB_ACTION_PATH}" 'include "terraform_test"; …'
#
# Every program reads the messages of one `terraform test -json` log, slurped
# into an array (messages.jsonl: the JSON objects of test.json, one per line,
# non-JSON lines dropped).

# Milliseconds since the epoch for Terraform's '@timestamp'
# ("2026-09-25T18:58:09.187762+02:00", or with 'Z'). fromdateiso8601 takes
# neither fractions nor offsets, so both are handled here.
def ts_ms:
  capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<frac>\\.[0-9]+)?(?<tz>Z|[+-][0-9]{2}:[0-9]{2})$") as $c
  | ($c.base + "Z" | fromdateiso8601) as $seconds
  | ("0" + ($c.frac // ".0") | tonumber) as $fraction
  | (if $c.tz == "Z" then 0
     else ($c.tz[1:3] | tonumber) * 3600 + ($c.tz[4:6] | tonumber) * 60
       | if $c.tz[0:1] == "+" then . else -. end
     end) as $offset
  | ($seconds - $offset + $fraction) * 1000;

# Diagnostics that mean the root was not initialised for this configuration
# (§5.5 row 3). "Missing required provider" and the checksum mismatch are
# what Terraform 1.16 reports for a root never initialised and for a lock
# whose checksums do not match the installed package.
def not_initialised_pattern:
  "Module not installed|there is no package for|Inconsistent dependency lock file|missing or corrupted provider plugins|Missing required provider|does not match any of the checksums recorded in the dependency lock file|Required plugins are not installed";

def error_diagnostics:
  [ .[] | select(.type == "diagnostic" and .diagnostic.severity == "error") ];

# {status, reason} for the log (§5.5 rows 3-9). $rel is the -filter value,
# $exit terraform's exit code as a string.
def classify($rel; $exit):
  . as $messages
  | ($messages | error_diagnostics) as $errors
  | ([ $messages[] | select(.type == "test_abstract") ] | first) as $abstract
  | ([ $messages[] | select(.type == "test_summary") ] | first) as $summary
  | [ $messages[] | select(.type == "test_run" and .test_run.progress == "complete") | .test_run.status ] as $runs
  | ([ $messages[] | select(.type == "test_file" and .test_file.progress == "complete" and .test_file.path == $rel) | .test_file.status ] | first) as $file_status
  | if any($errors[]; .diagnostic.summary | test(not_initialised_pattern)) then
      {status: "error", reason: "not-initialised"}
    elif $abstract == null then
      {status: "error", reason: "invalid"}
    elif ($abstract.test_abstract | has($rel) | not) then
      {status: "error", reason: "not-discovered"}
    elif $file_status == "error" and (any($runs[]; . == "error" or . == "fail") | not) then
      {status: "error", reason: "file"}
    elif any($runs[]; . == "error") then
      {status: "error", reason: "run"}
    elif any($runs[]; . == "fail") then
      {status: "fail", reason: "assertion"}
    elif $exit != "0" or ($summary.test_summary.status // "") != "pass" then
      # Nothing above explains a failed run; never report it as a pass.
      {status: "error", reason: "invalid"}
    else
      {status: "pass", reason: ""}
    end;

# One object per run block, in order: {run, status, elapsed-ms}.
def runs:
  reduce (.[] | select(.type == "test_run")) as $message ({order: [], by: {}};
    $message.test_run.run as $name
    | (if .by[$name] == null then .order += [$name] | .by[$name] = {run: $name, status: null, start: null, end: null} else . end)
    | if $message.test_run.progress == "starting" then .by[$name].start = ($message["@timestamp"] | ts_ms)
      elif $message.test_run.progress == "complete" then
        .by[$name].status = $message.test_run.status
        | .by[$name].end = ($message["@timestamp"] | ts_ms)
      else . end)
  | [ .order[] as $name | .by[$name]
      | {run, status: (.status // "unknown"),
         "elapsed-ms": (if .start != null and .end != null then (.end - .start | round) else null end)} ];

# One object per error diagnostic: {run, file, line, summary, detail}; file is
# prefixed with $prefix ("<root>/", or "" for the repository root).
def diagnostics($prefix):
  [ error_diagnostics[]
    | {run: (.["@testrun"] // ""),
       file: (if (.diagnostic.range.filename // "") != "" then $prefix + .diagnostic.range.filename else "" end),
       line: (.diagnostic.range.start.line // null),
       summary: (.diagnostic.summary // ""),
       detail: (.diagnostic.detail // "")} ];

# Milliseconds from the first test_file 'starting' to the test_file
# 'complete' message, or null.
def elapsed_ms:
  ([ .[] | select(.type == "test_file" and .test_file.progress == "starting") | .["@timestamp"] | ts_ms ] | first) as $start
  | ([ .[] | select(.type == "test_file" and .test_file.progress == "complete") | .["@timestamp"] | ts_ms ] | last) as $end
  | if $start != null and $end != null then ($end - $start | round) else null end;

def cut($n): if length > $n then .[0:($n - 1)] + "…" else . end;

# The failed, errored and skipped run blocks with their diagnostics, file-level
# diagnostics first: {run, status, file, line, summary, detail}. Input:
# {runs: <runs>, diagnostics: <diagnostics>}.
def failed_runs:
  .diagnostics as $diagnostics
  | [ ($diagnostics[] | select(.run == "")
        | {run: "", status: "error", file, line, summary: (.summary | cut(120)), detail: (.detail | cut(200))}),
      (.runs[] | . as $run
        | if .status == "fail" or .status == "error" then
            [ $diagnostics[] | select(.run == $run.run) ] as $own
            | if ($own | length) > 0 then
                $own[] | {run: $run.run, status: $run.status, file, line, summary: (.summary | cut(120)), detail: (.detail | cut(200))}
              else
                {run: $run.run, status: $run.status, file: "", line: null, summary: "", detail: ""}
              end
          elif .status == "skip" then
            {run: $run.run, status: "skip", file: "", line: null, summary: "", detail: ""}
          else empty end) ];

# Keeps whole elements from the head while the compact JSON fits $bytes.
def cap_bytes($bytes):
  reduce .[] as $element ({kept: [], omitted: 0, full: false};
    if .full then .omitted += 1
    elif ((.kept + [$element]) | tojson | utf8bytelength) <= $bytes then .kept += [$element]
    else .full = true | .omitted += 1 end)
  | {kept, omitted};

# Workflow-command escaping (the runner's rules for data and properties).
def escape_data: gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A");
def escape_property: escape_data | gsub(":"; "%3A") | gsub(","; "%2C");

# '::error' lines for the diagnostics (input: diagnostics), at most $max.
def annotations($status; $max):
  limit($max; .[]
    | ([ (if .file != "" then "file=" + (.file | escape_property) else empty end),
         (if .file != "" and .line != null then "line=" + (.line | tostring) else empty end),
         "title=" + ("Terraform test " + $status | escape_property) ] | join(",")) as $properties
    | ((if .run != "" then .run + ": " else "" end)
       + .summary
       + (if .detail != "" then " — " + .detail else "" end)) as $message
    | "::error " + $properties + "::" + ($message | escape_data));

def clock_ms: if . == null then "—" else (. / 1000 | floor) as $s | "\($s / 60 | floor):\($s % 60 | tostring | if length < 2 then "0" + . else . end)" end;

# Markdown bullets for the step summary (input: failed_runs output).
def summary_bullets:
  .[]
  | (if .run != "" then "`" + .run + "`" else "(file)" end) as $name
  | if .status == "skip" then "- " + $name + " — skipped"
    else
      ((.detail | split("\n") | map(select(length > 0)) | first) // "") as $detail
      | "- " + $name + " — " + .status
        + (if .summary != "" then ": " + .summary else "" end)
        + (if $detail != "" then ": " + $detail else "" end)
        + (if .file != "" then " (`" + .file + (if .line != null then ":" + (.line | tostring) else "" end) + "`)" else "" end)
    end;
