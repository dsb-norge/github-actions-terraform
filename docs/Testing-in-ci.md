# Testing in CI

Living spec for the workflow that runs this repo's composite-action test suites on every pull request and reports the result as a single aggregated PR comment.

This doc is the source of truth for *what* gets tested, *why*, and *how*. Code in [`.github/workflows/action-tests.yml`](../.github/workflows/action-tests.yml) and [`.github/scripts/`](../.github/scripts/) is expected to conform to this spec. If the design changes, update this file first.

Out of scope: the test suites themselves (their layout is described in [Action-implementation-guide.md](Action-implementation-guide.md)), branch-protection configuration on the GitHub side, and any tests for the reusable workflows under `.github/workflows/terraform-*.yml`.

## 1. Goals and non-goals

### Goals

- Run every modern `run_all_tests.sh` suite automatically on each PR, in parallel.
- Surface the result as a single PR comment so reviewers see at a glance which actions were exercised and which aren't.
- Expose a single, stable status check (`tests-conclusion`) that can later be required by branch protection — independent of how the matrix grows.
- Make the not-tested set visible too, so the comment doubles as a nudge toward modernization.

### Non-goals

- Running tests for actions that don't yet have a `run_all_tests.sh` (those rows just appear under "Not tested yet").
- Per-step granularity in the PR comment (suite-level pass/fail + counts is enough; job logs cover detail).
- Running on PRs from forks — see §7.

## 2. Workflow shape

Four jobs, in this order:

```text
discover  ─►  test (matrix, fan-out)  ─►  summary  ─►  tests-conclusion
                                          (PR comment)   (required check)
```

### 2.1 `discover`

Scans top-level `*/action.yml` files in the checkout. For each action directory, classifies as:

- **has-tests** if `run_all_tests.sh` exists, *and* the directory is not on the explicit exclusion list (§3).
- **no-tests** otherwise.

Emits two job outputs:

- `tests-matrix` — JSON array of action names with tests, fed straight into the `test` matrix.
- `no-tests-list` — JSON array of action names without tests, consumed by `summary`.

Dynamic discovery means newly-added test suites are picked up automatically; no workflow edit is needed when a legacy action gets modernized.

### 2.2 `test` (matrix)

One job per entry in `tests-matrix`. `fail-fast: false` so all suites run regardless of any single failure. Each job has two steps:

1. **🧪 Run `<action>` tests** — runs `bash <action>/run_all_tests.sh`, tee's stdout to a log file, enforces the canonical summary-line contract (§4), parses counts (§4), resolves the matrix job URL, writes the result JSON (§5), emits any failure/drift annotation (§11), and finally exits with the suite's real exit code.
2. **📤 Upload result artifact** (`if: always()`) — uploads the result JSON as `test-result-<action>` so the summary job can aggregate it.

All the per-action logic lives inside step 1 because GitHub Actions does **not** propagate `steps.<id>.outputs.*` from a step that exits non-zero. If parsing/annotating happened in a follow-up step reading those outputs, the log path would be empty on failure and counts would always render as `?`. Doing everything in one shell means the same process that has the log path also writes the artifact.

When a suite fails (real test failure, format drift, or non-zero exit for any other reason), the run-tests step exits non-zero → the matrix job fails → `tests-conclusion` (§2.4) catches it via `needs.test.result`. The upload step uses `if: always()`, so the result JSON is still produced and uploaded even when the run-tests step failed. The summary job uses `if: !cancelled()`, so it still runs and posts/upserts the comment even when some matrix entries failed.

### 2.3 `summary`

Runs after `discover` + `test`. Conditions:

- `if: !cancelled() && github.event_name == 'pull_request' && github.event.pull_request.head.repo.fork == false`
- `permissions: pull-requests: write, contents: read`

Steps:

1. Downloads all `test-result-*` artifacts (merge-multiple).
2. Calls [`.github/scripts/aggregate-action-tests.sh`](../.github/scripts/aggregate-action-tests.sh), which builds the markdown (§6) and:
   - upserts the PR comment via `gh api`;
   - appends the same body to `$GITHUB_STEP_SUMMARY` so the run page shows it inline (§11);
   - emits a single headline annotation summarizing the totals (§11).

### 2.4 `tests-conclusion`

Single, no-matrix terminal job. `needs: [discover, test]`, with the same fork guard as §7:

```yaml
if: always() && (github.event_name != 'pull_request' || github.event.pull_request.head.repo.fork == false)
```

Fails if `needs.discover.result != success`, or if `needs.test.result` is `failure` or `cancelled`. Treats `success` and `skipped` as passing (`skipped` happens when `tests-matrix` is empty). This is the stable check name that branch protection will be configured to require — independent of which suites exist at any given time.

## 3. Discovery rules and exclusions

Discovery globs `*/action.yml` from the repo root. The following directories are **excluded by name**, regardless of whether `run_all_tests.sh` is present:

| Excluded | Reason |
|---|---|
| `create-tf-vars-matrix` | Has a known-flaky `test_action_source.sh` harness that requires a real tty and may fail on pristine main. Documented in [`CLAUDE.md`](../CLAUDE.md). Not yet ported to the modern `run_all_tests.sh` shape. |

`.github/` is naturally excluded because the glob is `*/action.yml`, not `**/action.yml`.

When an excluded directory gets a real `run_all_tests.sh` later, drop it from the exclusion list in the same PR.

## 4. Test-count parsing contract

The per-action test job parses these three lines from the suite's stdout:

```text
Tests run:    <N>
Tests passed: <N>
Tests failed: <N>
```

This format is set by the template in [Action-implementation-guide.md §`run_all_tests.sh`](Action-implementation-guide.md#run_all_testssh--automated-tests) and is currently emitted by all 8 modern suites.

Multi-step orchestrator scripts (e.g. [`aggregate-validation-summaries/run_all_tests.sh`](../aggregate-validation-summaries/run_all_tests.sh)) emit these lines once **per delegated step script**. The parser sums them, so the action's totals are the sum across its sub-suites.

ANSI color codes around the numbers are tolerated — the parser greps with a regex that allows optional escape sequences before the digit.

### 4.1 What if a new suite diverges from this format?

Two options, in order of preference:

1. Fix the suite to match the convention (it's three lines of `echo`).
2. Add a fallback parser to the workflow that handles the divergence.

(2) is a last resort. Drift makes the spec less useful.

### 4.2 Drift is enforced by CI

The workflow validates each suite's stdout against this format and **fails the test job** if any of the three lines is missing. The drifted suite shows up in the PR comment as ❌ Fail with `?` for counts, and the run page gets a `::error title=Suite format drift` annotation pointing here.

This means a new (or modified) suite that doesn't emit the canonical lines will block merge through the [`tests-conclusion`](#24-tests-conclusion) check. The check is intentionally strict — quiet drift would erode the comment's usefulness over time.

## 5. Result-JSON artifact shape

Each `test-result-<action>` artifact contains exactly one file `result-<action>.json` with this shape:

```json
{
  "action": "parse-terraform-plan",
  "outcome": "success",
  "tests-run": 20,
  "tests-passed": 20,
  "tests-failed": 0,
  "duration-seconds": 14,
  "job-url": "https://github.com/.../actions/runs/123/job/456"
}
```

- `outcome` is `success` (suite exited 0 and emitted the canonical summary lines) or `failure` (any other case — non-zero exit and/or format drift). Cancelled jobs never reach the artifact-write step, so `cancelled`/`skipped` outcomes never appear on disk.
- `job-url` points to the specific matrix job's page. Resolved at runtime via `gh api /repos/{owner}/{repo}/actions/runs/{run_id}/jobs`, filtering for the job whose name ends with `(<action>)`. Falls back to the run page URL if the lookup fails.
- On format drift (§4.2), `tests-run`/`tests-passed`/`tests-failed` are all `null` and the comment renders them as `?`. On a non-drift failure the counts are always parseable, so they're always integers.

## 6. PR comment shape

Single comment per PR. Identified by an HTML-comment marker on the first line. Upsert semantics: if a comment matching the marker exists, edit in place; otherwise post fresh.

Marker:

```html
<!-- action-tests-summary -->
```

This is *not* a backtick-delimited heading prefix like the `aggregate-validation-summaries` action uses, because we only have one comment per PR — substring collision isn't a concern, and an HTML comment is invisible to readers.

Body layout (red example shown; on a green run the row table is all ✅ and the headline drops the trailing "… suite(s) not passing" clause):

````markdown
<!-- action-tests-summary -->
### 🧪 Action test results

**Total: 212 tests across 8 suites — 210 passed, 2 failed, 1 suite(s) not passing**

**Tested (8)**

| Action | Result | Tests | Details |
|---|:---:|:---:|---|
| aggregate-validation-summaries | ✅ Pass | 28 / 28 | [job log](…) |
| auto-merge-pr | ✅ Pass | 24 / 24 | [job log](…) |
| parse-terraform-plan | ❌ Fail | 5 / 7 | [job log](…) |
| … | … | … | … |

**Not tested yet (10)** — modernization candidates

<details><summary>Show list</summary>

- create-tf-vars-matrix
- export-env-vars
- terraform-init
- …

</details>

_Run: [workflow run](https://github.com/…/actions/runs/<id>) · Commit: `<sha>`_
````

Conventions:

- Status icons match `aggregate-validation-summaries`: ✅ success, ❌ failure, ⚠ cancelled, ⏭ skipped. In practice only ✅ and ❌ show up — see §5 (outcomes that reach the artifact).
- The headline has two variants: `… <passed> passed, <failed> failed` on a fully green run, and `… <passed> passed, <failed> failed, <N> suite(s) not passing` whenever any suite isn't a clean pass. Same logic powers the headline annotation (§11.2).
- The "Tests" column shows `passed / run`. Failed count = `run - passed`; not shown explicitly to keep the table tight. A drifted suite shows as `?` here.
- "Not tested yet" is collapsed by default (`<details>`) so it doesn't dominate once it shrinks. It is *always* present, even when empty — an empty list communicates "we test everything", which is a meaningful state.
- Both action lists are alphabetically sorted.
- Tested rows are sorted alphabetically. Failed rows are *not* hoisted to the top — relative ordering stays stable across PRs and the status icon already draws the eye.

### 6.1 Upsert mechanics

[`aggregate-action-tests.sh`](../.github/scripts/aggregate-action-tests.sh):

1. `gh api --paginate /repos/{owner}/{repo}/issues/{pr}/comments` to list comments.
2. Filter to those whose body starts with `<!-- action-tests-summary -->`.
3. If exactly one match: `gh api -X PATCH /repos/{owner}/{repo}/issues/comments/{id} -F body=@<file>` (edit in place).
4. If zero matches: `gh api -X POST /repos/{owner}/{repo}/issues/{pr}/comments -F body=@<file>` (fresh).
5. If two or more matches (shouldn't happen, but guard anyway): delete all but the oldest, then PATCH the oldest.

GitHub API failure during list/post: log a warning, exit non-zero, fail the `summary` job. The `tests-conclusion` job does *not* depend on `summary`, so a posting failure doesn't gate the PR — but it does light up the workflow with a clear red signal.

## 7. Triggers and fork handling

```yaml
on:
  pull_request:
  workflow_dispatch:
```

Fork guard:

```yaml
if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.fork == false
```

This guard lives on `discover`, `summary`, and `tests-conclusion`. The `test` matrix job is implicitly gated because it has `needs: discover` — when discover is skipped, the matrix is too. The summary job has the same fork condition AND-ed into its existing `if:`.

The workflow does **not** run on PRs from forks. `GITHUB_TOKEN` is read-only on fork PRs and the summary job couldn't post the comment; running the matrix without a working summary defeats the purpose. DSB's working model is internal contributors, so this is acceptable. If a fork-PR use case appears later, revisit — the safe path would be to skip-only-the-comment, not switch to `pull_request_target`.

`workflow_dispatch` is included for manual triggering during development of the workflow itself.

Path filters: intentionally omitted. Suites are cheap (seconds each), and "did this workflow run at all" being load-bearing for branch protection is simpler with no filters.

## 8. Files involved

| Path | Purpose |
|---|---|
| `docs/Testing-in-ci.md` | This doc. |
| `.github/workflows/action-tests.yml` | The PR workflow (§2). |
| `.github/scripts/discover-actions.sh` | Discovery script (§2.1, §3). |
| `.github/scripts/aggregate-action-tests.sh` | Summary builder + PR-comment upsert (§6). |
| `<action>/run_all_tests.sh` | The actual test suites — owned by each action, not by this workflow. |

The two `.github/scripts/` files follow the script conventions from [Action-implementation-guide.md](Action-implementation-guide.md): `#!/bin/env bash`, `set -o nounset`, a `main` function, and an explicit `exit ${_main_exit_code}` at the end. They do *not* live inside composite actions — they're internal to this one workflow.

`jq`, `yq`, `gh`, `python3`, and standard coreutils are assumed to be present on the `ubuntu-latest` runner. No install logic is bundled.

## 9. Adding a new test suite

When a legacy action gets modernized and gains a `run_all_tests.sh`:

1. Make sure the suite prints the three `Tests run:` / `Tests passed:` / `Tests failed:` lines (§4).
2. Drop the action name from the §3 exclusion list if it was there.
3. That's it — discovery picks it up automatically on the next PR run.

## 10. Removing a test suite

If a suite needs to be skipped (e.g. genuinely flaky on CI, pending fix):

1. Add the action's directory name to the §3 exclusion table with a short reason and a tracking link.
2. Re-run CI and confirm the action moves from the "Tested" section to "Not tested yet".

Don't disable suites by deleting their `run_all_tests.sh` — the exclusion table is the audit trail.

## 11. Run-page reporting

The PR comment (§6) is the primary view, but it lives on the PR conversation timeline and is hidden on non-PR triggers like `workflow_dispatch`. To make the same information visible directly on the **workflow run page**, the workflow also emits annotations and writes a step summary.

### 11.1 Per-suite annotations

Each `test` matrix job emits at most one annotation via the workflow log commands (`::error`, `::warning`, `::notice`) depending on the suite's outcome:

| Outcome | Annotation level | Title | Message |
|---|---|---|---|
| `success` | _(silent)_ | — | — |
| `failure` (format drift, §4.2) | `::error` | `Suite format drift` | `<action>/run_all_tests.sh did not emit canonical summary lines (missing: …). See docs/Testing-in-ci.md §4 and docs/Action-implementation-guide.md.` |
| `failure` (suite exited non-zero, format OK) | `::error` | `Action tests failed` | `<action>: <passed>/<run> tests passed (<failed> failed)` |
| `cancelled` | _(silent)_ | — | — |

Two emissions never coexist: drift is detected before parsing, and a drifted suite is always classified as `failure` with the drift annotation. A non-drift failure always has parseable counts because the drift check passed first.

Success is deliberately silent — a green run with 8 passing matrix entries shouldn't produce 8 noise annotations. Cancelled jobs are also silent because the merged run-tests step never reaches the annotation code when SIGTERM'd; GitHub's own "Job was cancelled" marker covers the case.

### 11.2 Aggregate headline annotation

The `summary` job emits **one** annotation summarizing the whole run:

| Condition | Level | Title | Message |
|---|---|---|---|
| Any `tests-failed > 0` or any suite `outcome != "success"` | `::error` | `Action tests: failures` | `<run> tests across <suites> suites — <passed> passed, <failed> failed, <N> suite(s) not passing` |
| All suites passed | `::notice` | `Action tests: all green` | `<run> tests across <suites> suites — <passed> passed, 0 failed` |

The `outcome != "success"` condition matters because a suite hit by §4.2 format drift (or any crash before the count lines are emitted) has `tests-failed = null`, which would otherwise count as zero. The suite-level outcome catches it.

This guarantees every PR run has at least one annotation in the Annotations panel — green runs get one notice with the headline numbers; red runs get the headline error plus one per-suite error.

### 11.3 Step summary

The `summary` job also appends the full markdown body (the same one used for the PR comment, §6) to `$GITHUB_STEP_SUMMARY`. This renders on the workflow run page's "Summary" tab. The HTML marker on the first line is invisible there.

Step summaries are scoped to a single run — they don't accumulate or get reconciled across runs, so the upsert mechanics from §6.1 don't apply here.

### Why two mechanisms

The PR comment, annotations, and step summary serve different audiences:

- **PR comment** — for reviewers scanning the PR conversation. Persistent, edits in place across re-runs.
- **Annotations** — for anyone scanning a workflow run for what went wrong. Short, high-signal, surfaced in multiple places in the GitHub UI (the run page, the PR checks pane, status check tooltips).
- **Step summary** — for anyone on the run page who wants the full picture without opening a comment or clicking through to a PR. Also the only run-page view that survives for non-PR triggers.

The same totals appear in all three, so they stay consistent — there's a single source of truth (the result-JSON artifacts) feeding all three.

## 12. Verification

When changing anything in this workflow — the YAML, either of the scripts, or the spec — verify it both locally before pushing and live in CI after pushing. Skip these steps and you risk breaking the only signal that catches regressions across this whole repo.

### 12.1 Local smoke tests (before pushing)

**YAML and bash syntax** — fast sanity check:

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/action-tests.yml'))"
bash -n .github/scripts/discover-actions.sh
bash -n .github/scripts/aggregate-action-tests.sh
```

**Discovery script** — confirm it partitions actions correctly:

```bash
bash .github/scripts/discover-actions.sh
# Expect: tests-matrix=[...] and no-tests-list=[...] on stdout, with create-tf-vars-matrix
# in the no-tests list (regardless of file presence — see §3).
```

**Aggregator script** — exercise it with fixture results in DRY_RUN so it builds the markdown without trying to post:

```bash
results_dir=$(mktemp -d)
cat > "${results_dir}/result-foo.json" <<'JSON'
{"action":"foo","outcome":"success","tests-run":10,"tests-passed":10,"tests-failed":0,"duration-seconds":3,"job-url":"https://example.com/job/1"}
JSON
cat > "${results_dir}/result-bar.json" <<'JSON'
{"action":"bar","outcome":"failure","tests-run":8,"tests-passed":6,"tests-failed":2,"duration-seconds":5,"job-url":"https://example.com/job/2"}
JSON

DRY_RUN=true \
GITHUB_STEP_SUMMARY=/tmp/step-summary.md \
RESULTS_DIR="${results_dir}" \
NO_TESTS_LIST='["create-tf-vars-matrix","terraform-init"]' \
PR_NUMBER=1 \
GITHUB_REPOSITORY=dsb-norge/github-actions-terraform \
GITHUB_SERVER_URL=https://github.com \
GITHUB_RUN_ID=1 \
GITHUB_SHA=0000000 \
bash .github/scripts/aggregate-action-tests.sh
# Expect: markdown body printed on stderr, ::error annotation for 2 failures,
# step summary appended to /tmp/step-summary.md, "DRY_RUN=true — skipping comment upsert."
```

**Suite-format conformance sweep** — every suite must emit the canonical lines (§4). Run them all and grep:

```bash
for d in */run_all_tests.sh; do
  log=$(bash "${d}" 2>&1)
  stripped=$(echo "${log}" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g')
  for needle in 'Tests run:' 'Tests passed:' 'Tests failed:'; do
    if ! echo "${stripped}" | grep -qE "^${needle}[[:space:]]+[0-9]+"; then
      echo "DRIFT: ${d} missing '${needle}'"
    fi
  done
done
# Expect: no DRIFT output. CI enforces this too (§4.2), but catching it locally is faster.
```

**End-to-end dry run** — chain discover + every suite + aggregator and inspect the rendered comment body. Useful when changing the markdown layout:

```bash
tmp=$(mktemp); GITHUB_OUTPUT="${tmp}" bash .github/scripts/discover-actions.sh
tests_matrix=$(grep '^tests-matrix='   "${tmp}" | cut -d= -f2-)
no_tests_list=$(grep '^no-tests-list=' "${tmp}" | cut -d= -f2-)
rm -f "${tmp}"

results_dir=$(mktemp -d)
for a in $(echo "${tests_matrix}" | jq -r '.[]'); do
  out=$(bash "${a}/run_all_tests.sh" 2>&1) || true
  stripped=$(echo "${out}" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g')
  r=$(awk '/^Tests run:[[:space:]]+[0-9]+/    {s+=$3} END {print s+0}' <<<"${stripped}")
  p=$(awk '/^Tests passed:[[:space:]]+[0-9]+/ {s+=$3} END {print s+0}' <<<"${stripped}")
  f=$(awk '/^Tests failed:[[:space:]]+[0-9]+/ {s+=$3} END {print s+0}' <<<"${stripped}")
  jq -n --arg a "$a" --arg o success --argjson r "$r" --argjson p "$p" --argjson f "$f" --argjson d 0 \
    --arg u "https://github.com/dsb-norge/github-actions-terraform/actions/runs/0" \
    '{action:$a,outcome:$o,"tests-run":$r,"tests-passed":$p,"tests-failed":$f,"duration-seconds":$d,"job-url":$u}' \
    > "${results_dir}/result-${a}.json"
done

DRY_RUN=true RESULTS_DIR="${results_dir}" NO_TESTS_LIST="${no_tests_list}" \
  PR_NUMBER=0 GITHUB_REPOSITORY=dsb-norge/github-actions-terraform \
  GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=0 GITHUB_SHA=0000000 \
  bash .github/scripts/aggregate-action-tests.sh 2>&1
rm -rf "${results_dir}"
```

### 12.2 Live CI verification (after pushing)

Push the branch and open a draft PR. Then confirm each surface works.

**Job status** — every job in the workflow should turn green (or `tests-conclusion` should turn red if any suite legitimately failed):

```bash
gh pr checks <pr-number>
```

Expect rows for `🔎 Discover actions`, one `🧪 Test (<action>)` per modern suite, `📝 Aggregate summary`, and `tests-conclusion` (the gate job is intentionally plain so the required-check label reads cleanly).

**PR comment** — should appear once on the first run, edit in place on subsequent runs (`updated_at` advances; the comment count stays at one):

```bash
gh api repos/<owner>/<repo>/issues/<pr-number>/comments \
  --jq '.[] | select(.body | startswith("<!-- action-tests-summary -->")) | {id, created_at, updated_at}'

# Body footer should reference the latest workflow run id:
gh api repos/<owner>/<repo>/issues/comments/<id> --jq '.body' | grep '_Run:'
```

**Annotations** — both per-suite and headline annotations should appear:

```bash
run_id=<from gh pr checks output>
for job_id in $(gh api "repos/<owner>/<repo>/actions/runs/${run_id}/jobs" --paginate --jq '.jobs[].id'); do
  job_name=$(gh api "repos/<owner>/<repo>/actions/jobs/${job_id}" --jq '.name')
  anns=$(gh api "repos/<owner>/<repo>/check-runs/${job_id}/annotations" \
    --jq '.[] | "[" + .annotation_level + "] " + (.title // "") + ": " + (.message // "")' 2>/dev/null)
  [[ -n "${anns}" ]] && { echo "--- ${job_name} ---"; echo "${anns}"; }
done
```

Expect: at minimum a `[notice]` headline from the `📝 Aggregate summary` job; on a red run, also one `[error]` per failed suite from the corresponding `🧪 Test (<action>)` jobs.

**Step summary** — open the workflow run page in the browser; the "Summary" tab should render the same markdown as the PR comment (totals, tested table, not-tested-yet list, footer with run link). This is the only surface that's not API-accessible; visual check only.

**Deprecation warnings** — scan all job logs to ensure no action version is throwing deprecation notices:

```bash
for job_id in $(gh api "repos/<owner>/<repo>/actions/runs/${run_id}/jobs" --paginate --jq '.jobs[].id'); do
  gh api "repos/<owner>/<repo>/actions/jobs/${job_id}/logs" 2>/dev/null \
    | grep -iE 'node\.js [0-9]+ actions are deprecated|deprecation' \
    | head -2
done
```

(Internal Node `Buffer()` warnings from third-party actions can be ignored; they're not actionable from this workflow.)

### 12.3 Suite-conformance sweep on legacy modernization

When converting a legacy action to gain a `run_all_tests.sh`, run the conformance sweep from §12.1 against just the new file before opening the PR. CI will catch drift on push (§4.2), but failing fast locally saves a round-trip.
