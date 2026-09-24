# Path relevance and the conclusion check

Authoritative spec for two things that turn out to be one design: which environments a change is
relevant to, decided inside [`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml)
per environment, and what the single required check `tf / Terraform conclusion` means when some or
all of the work was skipped.

Status: **specification, not yet implemented.** Decisions in §2 are settled; §14 lists what still
needs a real run. §17 is reserved for what implementation teaches the spec.

Related: [Terraform-tests.md](Terraform-tests.md) defines the test stage whose jobs the conclusion
also reads; [Workflow-pr-comments.md](Workflow-pr-comments.md) is the comment model this spec
extends.

## 1. Why

Two needs from the developers of a calling repository, and one root cause.

**An environment should say which changes it cares about.** Path filtering exists today only as
`on.paths` on the calling workflow, so the one way to keep an unrelated change from planning against
a test tenant was a second workflow file with its own copy of every input. Two files to keep in
sync, and a second check that could not be required.

**A pull request that changes nothing an environment cares about must still be mergeable.** Today a
docs-only pull request in a repository whose calling workflow has `on.paths` never runs the
workflow. GitHub then leaves the required check `tf / Terraform conclusion` in "Expected — waiting
for status to be reported" forever, and the pull request needs an admin override or a dummy change
to merge. GitHub's own guidance is "avoid requiring workflows that can be skipped".

The root cause of the second is the first: relevance decided outside the workflow means the
workflow does not run, and a workflow that does not run cannot report. Moving relevance inside
makes the workflow run on every pull request and lets the conclusion state, explicitly, that there
was nothing to verify.

## 2. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Relevance is decided per environment inside the workflow, from `paths` / `paths-ignore` keys in `environments-yml`, evaluated against the changed files of the run. | One workflow file, one configuration, one check that always reports. |
| D2 | **Absent `paths` means `auto`**: the standard project layout (§3.2). `paths: ["**"]` restores always-run. | Every caller gets docs-only pull requests that run nothing and still merge, without configuration. This is a default change and therefore part of the **v1** major release. |
| D3 | Relevance is evaluated on the **whole change**, never per commit: the pull request's full diff against its merge base, or everything a push carried. | An environment the pull request touches is affected on every run of that pull request; every commit of a rebase merge is in scope on push. |
| D4 | Every uncertainty **fails open** to "everything is relevant". Running too much is the safe error. | A missed environment is silent drift; an extra plan costs minutes. |
| D5 | Relevance applies on pull requests and on push. An environment whose apply failed on one push is not retried by an unrelated later push. | Symmetry with the need; the escape hatch is a dispatch, which is always mode `all`. |
| D6 | An unaffected environment **keeps its comment surface**: an ungrouped environment's head says "not affected", a grouped environment keeps its column with dashes and the group head gains a footer line. No new comment kinds, no run-level overview comment. | A repository's pull requests carry the same set of heads whatever changed, so nothing looks missing; the pattern does not differ between grouped and ungrouped repositories. |
| D7 | The conclusion is green when everything that should have run succeeded, **including when nothing should have run**. It reads named job results and the matrix builder's counts, never `contains(needs.*.result, …)`. | "Skipped" alone cannot distinguish "nothing to verify" from "something upstream broke"; only the builder's count can. |
| D8 | A pull request that affected no environment is **auto-merge eligible**, subject to the same configuration, enabled and actor checks as any other. | Nothing can exceed the plan limits, but an actor-restricted repository must stay restricted. |
| D9 | Callers remove `on.paths` and `on.paths-ignore` from their calling workflows. The user guide says so in bold with before and after. | It is the filter that leaves the check pending forever. |
| D10 | A global input `path-relevance-enabled` (default `true`) switches relevance off for a caller. | A caller moving to v1 must be able to keep today's always-run behaviour in one line while it sorts out its paths. |
| D11 | Tests (Terraform-tests.md) are not relevance-filtered in this spec. | Their `root` field is the hook for a later refinement. |
| D12 | The changed files are fetched by the decision engine's create-matrix **adapter**, inside the `create-matrix` step, not by a separate action. | The adapter already runs there with `gh` behind its `Tools` object, so the fetching and every fail-open rule sit under the engine's coverage and mutation gates, and the file list never crosses a step boundary ([Decision-engine.md](Decision-engine.md) D13). |
| D13 | A push that **creates a branch** is diffed against the default branch: `compare/<default-branch>...<after>`. | Everything the new branch carries that the default branch does not, which is what GitHub's own path filter approximates; one request instead of running every environment. Any failure of that request fails open. |

## 3. Caller-facing API

### 3.1 New keys in `environments-yml`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `paths` | list of globs, or the token `auto` in the list | `[auto]` | Files that make this environment relevant. A list containing `auto` is the standard set plus the other entries; a list without it replaces the standard set entirely. |
| `paths-ignore` | list of globs | implied `["**/*.md"]` when `paths` is or contains `auto`; otherwise `[]` | Files that never make this environment relevant, applied after `paths`. An explicit `paths-ignore: []` means no ignore, and is distinct from absent. |

Both keys are per environment only; there is no workflow-level default beyond `auto`, because the
standard set is already relative to each environment's `project-dir`.

```yaml
environments-yml: |
  - environment: prod                      # absent paths = auto
  - environment: staging
    paths: [auto, "scripts/**"]            # standard set plus one directory
    paths-ignore: ["**/*.md", "**/*.txt"]  # replaces the implied ignore
  - environment: sandbox
    paths: ["**"]                          # always relevant, as today
```

### 3.2 The `auto` set

For an environment with `project-dir` normalised to `envs/prod` (leading `./` stripped), `auto`
expands to:

- `envs/prod/**`
- `main/**`
- `modules/**`
- `<dir>/**` for each entry of the environment's resolved `terraform-init-additional-dirs-yml`
- `.tflint.hcl` at the repository root (the environment's own `.tflint.hcl` is inside `envs/prod/**`)

with the implied ignore `**/*.md`. Nothing in this workflow reads Markdown; a configuration that
does through `file()` or `templatefile()` sets `paths-ignore: []`.

Not in the set, on purpose: `.github/workflows/**` is a fail-open trigger (§4.2), not a path rule;
`.tflint/**` is read by nothing in this workflow; `.terraform-version`, `.tool-versions` and
`.terraformrc` are not consulted, the version comes from the `terraform-version` input and module
authentication from the token. Files Terraform can read that live elsewhere, such as a `-var-file`
or `-backend-config` target passed through `TF_CLI_ARGS_*`, or a local module sourced from outside
`main/` and `modules/`, are invisible to the builder; an environment that uses them lists them in
`paths` explicitly (P9).

### 3.3 Grammar and matching

The grammar is the one Terraform-tests.md §4.4 defines: `*` matches within one segment, `**` any
number of segments including none, `?` one character, a pattern without `/` matches the basename,
no negation, no character classes, no braces. Patterns are matched against repository-relative
paths without a leading `./`.

A file is relevant to an environment when it matches at least one `paths` entry and no
`paths-ignore` entry. An environment is affected when at least one changed file is relevant to it.
A renamed file is tested under both its old and its new path. Every change status counts: added,
modified, removed, renamed, copied.

The matcher is the same helper `create-tf-vars-matrix` and `create-tftest-matrix` share, with the
fixtures of Terraform-tests.md §11 plus the cases of §13 here.

### 3.4 New workflow input

| Input | Type | Default | Meaning |
|---|---|---|---|
| `path-relevance-enabled` | boolean | `true` | When `false`, relevance mode is `all` for every run: every environment runs, exactly as before this spec. The per-environment keys are validated but ignored. |

### 3.5 Caller migration

Remove `on.pull_request.paths`, `on.pull_request.paths-ignore`, `on.push.paths` and
`on.push.paths-ignore` from the calling workflow, and move what they expressed into the affected
environments' `paths` (usually nothing, because `auto` covers the standard layout). Before:

```yaml
on:
  pull_request:
    branches: [main]
    paths: ["envs/staging/**", "main/**", "modules/**"]
```

After:

```yaml
on:
  pull_request:
    branches: [main]
```

with the environment's `paths` left at `auto`. The workflow now runs on every pull request; a pull
request that touches nothing relevant runs one short job and reports a green check (§7).

## 4. Computing the changed set

### 4.1 Events and sources

Computed once per run, in the `create-matrix` step, by the decision engine's adapter (D12).

| Event | Source | Diff semantics |
|---|---|---|
| `pull_request` | `GET /repos/{owner}/{repo}/pulls/{n}` for `changed_files` and `head.sha`, then `GET …/pulls/{n}/files` paginated at 100 | The pull request's three-dot diff against its merge base: what the Files tab shows, regardless of how far the base has advanced. After "Update branch" the merge commit's conflict resolutions count, which is right, they are the pull request's changes now. |
| `push` | `GET /repos/{owner}/{repo}/compare/{before}...{after}` | Everything the push carried. For any non-forced push `before` is an ancestor of `after`, so the three-dot diff equals the union of the pushed commits' changes: a rebase merge of N commits, a squash, a merge commit and a direct push are all covered. |
| `push` creating a branch | `GET /repos/{owner}/{repo}/compare/{default-branch}...{after}` | Everything the new branch carries that the default branch does not (D13). |
| `schedule`, `workflow_dispatch` | none | Mode `all`. A dispatch is the manual "run it all" button until the single-environment dispatch spec adds a filter. |

The `github` context inside a reusable workflow describes the caller's event, which the workflow
already relies on for the pull request number and the ref name.

### 4.2 Fail-open rules

Mode `all` with the reason recorded, in this order of evaluation:

| Reason | Trigger |
|---|---|
| `disabled` | `path-relevance-enabled: false` |
| `event` | `schedule` or `workflow_dispatch` |
| (not a fail-open) | `push` with `github.event.created == true`, or `before` all zeros (the documented field first, the zero SHA as belt and braces), is diffed against the default branch (D13); only a failure of that compare fails open, as `api-error` or `too-many-files`. |
| `forced` | `push` with `github.event.forced == true`: the merge base is no longer `before`, reverted files would be invisible |
| `branch-deleted` | `push` with `github.event.deleted == true` |
| `pr-head-moved` | `pull_request` where the API's `head.sha` differs from `github.event.pull_request.head.sha`: a re-run of an older attempt, or an overlapping run; the file list is live but the run is pinned to its SHA, and a newer run governs the check anyway |
| `too-many-files` | `changed_files > 3000` on the pull request, or 3000 files paged, or 300 or more files in a compare response; neither endpoint signals truncation, so the caps are the signal |
| `api-error` | any non-2xx response or unparseable JSON |
| `workflow-changed` | any changed file under `.github/workflows/`: the calling workflow file carries the `uses:` ref and every input, and a caller may route through a local reusable workflow |

The action **never exits non-zero**; fail-open is a result, not an error. Only `environments-yml`
validation may redden `create-matrix`.

### 4.3 Fetching in the adapter

The adapter reads the event facts from the event payload file (`GITHUB_EVENT_PATH`): the pull
request number and head SHA, `before`, `after`, `created`, `forced`, `deleted`. It calls `gh api`
with the job token for the pull request object, the paginated files list and the compare
endpoints, reports the facts raw (`available`, `truncated`, `error`, the pull request's live head
SHA, the count and the file list) in the input document, and decides nothing: the core turns them,
together with the event, into the mode and reason of §4.2. The file list never becomes a step or job
output: three thousand paths are a quarter of a megabyte and would enter envp through the steps
context the first time a step interpolated them (P5). A renamed file is listed under both its old
and its new path. A failed call is a fact, never an exception: the step does not fail for it.

### 4.4 Cost and permissions

A docs-only pull request costs `create-matrix` (checkout, builder, two to four API requests),
`seed-pr-comments`, `pr-comment-aggregator`, `run-summary`, `terraform-test-summary` when tests are
active, and `conclusion`: five short jobs and no runner minutes on environments. Cheaper than
today's skipped-and-blocked state, not free.

Permissions used by `create-matrix`: `pull-requests: read` for the pull request endpoints,
`contents: read` for compare, `metadata: read` for the repository. The caller already grants
`pull-requests: write` and `contents: read`; a fork's read-only token satisfies both reads.

## 5. Applying relevance in the matrix builder

### 5.1 Row selection

The decision engine, called by `create-tf-vars-matrix`, receives the adapter's facts and the
changed-file path, derives the mode and reason of §4.2, and for each environment resolves `paths`
(expanding `auto` with the environment's normalised `project-dir` and additional dirs) and
`paths-ignore`, then:

- mode `all`: every environment is affected, matched rule `all:<reason>`.
- mode `diff`: an environment is affected when any changed file is relevant to it (§3.3); the
  first matching rule is recorded.

Unaffected environments are dropped from the matrix. The two new keys are YAML lists inside
`environments-yml`, so they get explicit handling like the other `*-yml` fields rather than the
generic scalar-forwarding loop, plus `REQ_FIELDS` entries and fixtures (P7).

### 5.2 Outputs

| Output | Content |
|---|---|
| `matrix-json` | affected rows only, as today |
| `affected-count`, `unaffected-count` | integers as strings |
| `relevance-mode`, `relevance-reason`, `changed-count` | passed through |
| `envs-json` | every environment of `environments-yml`, affected or not: `environment`, `github-environment`, `add-pr-comment`, `pr-comment-group`, `goals`, the resolved `pr-auto-merge-*` values, `relevance` (`affected` / `unaffected`), `matched-rule`, resolved `paths` and `paths-ignore`. Small: names and rules, no file lists. |

`envs-json` is also uploaded as the artifact `relevance` (file `relevance.json`) for the jobs that
work from artifacts: the aggregator, the run summary and the auto-merge evaluator. Every download of
it carries `continue-on-error: true`, because a download by name of a missing artifact throws
(P8).

### 5.3 The environment job

```yaml
terraform-ci-cd:
  needs: [create-matrix, seed-pr-comments]
  if: |
    !cancelled()
    && needs.create-matrix.result == 'success'
    && fromJSON(needs.create-matrix.outputs.affected-count) > 0
```

Two changes. The count gate keeps an empty matrix away from GitHub, which rejects it ("Matrix
vector … does not contain any values"); a false job-level `if:` short-circuits matrix evaluation,
which is widely relied on and undocumented and was verified on the test bed (P13), so no sentinel
row is needed. And the clause on `seed-pr-comments`'s
result is dropped: the seed's steps are already `continue-on-error`, `needs:` alone keeps the
ordering, and the old clause meant a broken seed skipped the matrix silently while the conclusion
stayed green (P3). The concurrency group is unchanged; an unaffected environment no longer takes
its lock, so a docs-only pull request stops queueing behind production's apply.

## 6. What the pull request shows

### 6.1 Ungrouped environment, not affected

Written **once, at seed time, as the final body**; the matrix job that normally finalises the head
will not run. The title follows today's rule (`Terraform summary` when the environment mutates on
pull request, else `Terraform validation summary`), so the head never renames itself between runs.
No Mode line, no table.

```markdown
### Terraform validation summary for environment: `staging`

➖ Not affected by this pull request: no changed file matches this environment's paths (run #4711 attempt #1).

<details><summary>Path rules</summary>

Included: `envs/staging/**` · `main/**` · `modules/**` · `.tflint.hcl`
Ignored: `**/*.md`
Relevance: `diff`, pull request #87, 3 changed files

</details>
```

The relevance line is what lets a reviewer tell a `diff` run apart from a fail-open `all` run, in
which no head says "not affected" at all.

### 6.2 Grouped environment, not affected

The group head is rendered by the aggregator, as today, and the unaffected member keeps its column:
every cell `<span title="not affected by this pull request">—</span>`, excluded from the group-wide
gates (plan data, warnings, operations), an empty Links cell, and one footer line above the
workflow-log line:

```markdown
|  | Step | prod | staging |
|:---:|---|:---:|:---:|
| <span title="Initialization">⚙️</span> | Initialization | <span title="success">✅</span> | <span title="not affected by this pull request">—</span> |
| … | … | … | — |

➖ Not affected by this pull request: `staging`

[Workflow log](<run-url>)
```

A group whose members are all unaffected renders the same table with every cell a dash. It is never
deleted and never left at the seed placeholder (P4).

### 6.3 Seed-job algorithm

Inputs: `needs.create-matrix.outputs.envs-json` (every environment, unfiltered), `relevance-mode`,
`relevance-reason`, `changed-count`, the run id and attempt. The job's `if:` is unchanged.

1. **Group heads**: for each distinct non-empty `pr-comment-group` among environments with
   `add-pr-comment: true`, affected or not, in first-seen order: today's title rule and today's
   `⏳ Awaiting results…` placeholder. Always a placeholder: the aggregator finalises every group on
   every pull-request event, including all-unaffected ones, and the seed may be skipped on a re-run
   while the aggregator is not.
2. **Environment heads**: for each ungrouped environment with `add-pr-comment: true`, in
   `environments-yml` order: affected → today's placeholder with the Mode line when it mutates on
   pull request; unaffected → the final body of §6.1.
3. **Tests head**: after the environment heads, as Terraform-tests.md §6.3 says.
4. **Tag purge**: for each unaffected environment with `add-pr-comment: true`, four `gc-yml` rules,
   marker prefix `<!-- tf:tag:<kind>:<env>:` for `plan`, `apply`, `destroy-plan`, `destroy`, empty
   keep-substring. The matrix job purges its own tags today and will not run for these
   environments; without this a plan from an earlier run stays visible under a head that says "not
   affected" (P2). Affected environments' tags are untouched, so the re-run argument of
   Workflow-pr-comments.md §3.1 holds: the seed only removes tags nobody will re-post.
5. Mode `all`: every environment is affected and the manifest is byte-identical to today's.

### 6.4 Aggregator changes

`aggregate-validation-summaries` gains an optional `relevance-file` input. Its desired set of
groups becomes the union of the groups declared in `relevance.json` for environments with
`add-pr-comment: true` and the groups seen in metadata. Today the set comes from metadata alone,
so with relevance an all-unaffected group would be deleted as an orphan when another group ran, and
left at its placeholder when none ran (P4). Unaffected members render as §6.2; the "any environment
wants comments" gate consults the file too, so a run whose only commenting environments are
unaffected still reconciles. Without the file the action behaves exactly as today.

### 6.5 Run summary and notice

`create-run-summary` gains an optional `relevance-file` input: the headline becomes
`N environments · A affected · U not affected · X applied · Y failed`, unaffected environments get
a row of dashes with the tooltip "not affected", and a line states the mode and reason. Without the
file, today's "No environments" line and the existing golden stay.

`create-matrix` emits one annotation per run: `::notice title=Terraform CI::relevance <mode>
(<reason>): <A> of <N> environments affected` and, when `A` is zero, `nothing to verify for this
change`. This and the run summary are the only surfaces on push runs.

### 6.6 Re-runs

"Re-run failed jobs" skips `create-matrix` and the seed, both of which succeeded, so their outputs
and the attempt-one heads and purge are already final for unaffected environments; relevance is
identical across attempts by construction. "Re-run all jobs" recomputes everything. A pull request
whose head moved between attempts is caught by the `pr-head-moved` rule and runs everything.

## 7. The conclusion check

### 7.1 Root cause of the blocked pull request

A required check is satisfied by `success`, `skipped` or `neutral`. A job skipped by an `if:`
reports success and does not block merging. A **workflow** skipped by `on.paths`, `on.paths-ignore`
or a branch filter reports nothing, and its checks stay "Pending" and block merging. Every
docs-only pull request that needed an admin was this. GitHub's older workaround, a second workflow
with a same-named job that reports success without verifying anything, is worse: two files with
hand-maintained complementary filters, two same-named check runs on one SHA when a pull request
spans the boundary, and a green check on zero verification.

### 7.2 Normative result

`conclusion` keeps `if: always()`, so it reports on cancelled runs too (a cancelled required check
blocks merging, which is right: the work was not verified).

| Condition | Result |
|---|---|
| `needs.create-matrix.result != 'success'` (invalid `environments-yml`, bad `paths`, builder crash; never a relevance API failure, which is mode `all`) | red |
| `needs.terraform-ci-cd.result == 'success'`, including tolerated failures under `allow-failing-terraform-operations` | ok |
| `needs.terraform-ci-cd.result == 'skipped'` and `affected-count == '0'` | ok: nothing to verify, with a notice |
| `needs.terraform-ci-cd.result == 'skipped'` and `affected-count > 0` | red: the matrix should have run and something upstream prevented it |
| `needs.terraform-ci-cd.result` is `failure` or `cancelled` | red |
| test jobs: `success`, or `skipped` while the builder's `tests-active` / `tests-env-active` is not `'true'` | ok |
| test jobs: `skipped` while active, `failure`, `cancelled` | red |
| run cancelled | red |
| seed, aggregator, run summary or test summary failed | ignored; not in `needs` |

Green therefore means: everything that should have run, ran and succeeded. Zero affected
environments and zero tests is a legitimate instance of that. Tests and environments are judged
independently: a docs-only pull request in a repository whose tests are not path-filtered still
runs its tests, and a failing one is red.

### 7.3 Job wiring

```yaml
conclusion:
  if: always()
  name: "Terraform conclusion"
  needs: [create-matrix, terraform-ci-cd, terraform-test, terraform-test-env]
  steps:
    - name: "🛑 Verify everything that should have run, ran and passed"
      env:
        CREATE_MATRIX_RESULT: ${{ needs.create-matrix.result }}
        AFFECTED_COUNT:       ${{ needs.create-matrix.outputs.affected-count }}
        UNAFFECTED_COUNT:     ${{ needs.create-matrix.outputs.unaffected-count }}
        RELEVANCE_MODE:       ${{ needs.create-matrix.outputs.relevance-mode }}
        RELEVANCE_REASON:     ${{ needs.create-matrix.outputs.relevance-reason }}
        ENVIRONMENTS_RESULT:  ${{ needs.terraform-ci-cd.result }}
        TESTS_ACTIVE:         ${{ needs.create-matrix.outputs.tests-active }}
        TESTS_ENV_ACTIVE:     ${{ needs.create-matrix.outputs.tests-env-active }}
        TESTS_RESULT:         ${{ needs.terraform-test.result }}
        TESTS_ENV_RESULT:     ${{ needs.terraform-test-env.result }}
      run: |
        # Evaluate §7.2 case by case; print one summary line; exit 1 on any red case
```

Named results in `env:`, one `case` per row of §7.2, one summary line to the log, the step summary
and a `::notice` or `::error`: `conclusion: green — environments: 1 affected, 2 not affected (diff:
pull request #87, 3 changed files); tests: 12 passed`. The structural test in
[`evaluate-automerge-eligibility`](../evaluate-automerge-eligibility/) asserts the `needs` list and
that no `contains(needs.*.result, …)` remains.

`run-summary`, `pr-comment-aggregator` and `terraform-test-summary` stay out of `needs`; a
reporting job must never redden a run.

### 7.4 Fork pull requests, merge conflicts, cancelled runs

- **Fork pull requests** behave as today: the seed job is skipped, affected environments run
  without secrets and fail on authentication, the conclusion reports red. A docs-only fork pull
  request affects nothing and reports green, which is correct: nothing was left unverified. The
  conclusion is never green for a fork that skipped verification it should have done.
- **A pull request with a merge conflict** gets no `pull_request` run at all; GitHub documents
  that. Its check stays "Expected" until the conflict is resolved. Not a relevance problem, and the
  user guide says so, because it will be reported as one.
- **A cancelled run** reports red. Concurrency displacement of a superseded pull-request run
  produces a red check on a SHA a newer run already covers; the newer run's check is what branch
  protection reads.

## 8. Auto-merge with zero affected environments

Two defects in the current wiring would otherwise make D8 a dead letter.

1. The `automerge` job's `if:` has no status function, so GitHub prepends `success()` and the job
   is skipped whenever `terraform-ci-cd` is skipped. It becomes:

   ```yaml
   automerge:
     needs: [create-matrix, terraform-ci-cd, conclusion]
     if: |
       !cancelled()
       && needs.conclusion.result == 'success'
       && (
         needs.terraform-ci-cd.result == 'success'
         || (needs.terraform-ci-cd.result == 'skipped' && needs.create-matrix.outputs.affected-count == '0')
       )
       && inputs.pr-auto-merge-enabled == true
       && github.event_name == 'pull_request'
       && github.event.action != 'closed'
       && github.event.action != 'converted_to_draft'
       && github.event.pull_request.draft != true
   ```

2. `evaluate-automerge-eligibility` evaluates every check, including `pr-auto-merge-enabled` and
   the actor allowlist, per metadata file; with zero files it returns not eligible. Returning
   eligible blindly would auto-merge any actor's docs-only pull request in a repository that
   restricts auto-merge to a bot. The rule, with a new optional `relevance-file` input:

   - Completeness: every affected environment must have exactly one metadata file. A missing one
     means the job was cancelled or crashed before capture: not eligible, reason named. Stricter
     than today, where a missing environment is invisible.
   - Affected environments: today's checks, unchanged.
   - Unaffected environments: configuration validation, `pr-auto-merge-enabled` and actor
     authorisation from the resolved values in `relevance.json`; the plan-based checks are recorded
     as `NOT AFFECTED`.
   - Eligible when every environment, affected or not, passes. The set is never empty, the builder
     rejects an empty `environments-yml`.
   - Without the file, today's behaviour.

## 9. Examples

These go into the user guide as they stand. All use this configuration unless stated:

```yaml
environments-yml: |
  - environment: prod
  - environment: staging
    pr-comment-group: platform
  - environment: sandbox
    pr-comment-group: platform
```

| Scenario | Changed files | Affected | What the reviewer sees | Conclusion |
|---|---|---|---|---|
| Docs-only pull request | `README.md`, `docs/runbook.md` | none | `prod` head: "not affected"; group head `platform`: two dash columns, footer names both; tests head if tests exist | green, "nothing to verify" |
| One environment | `envs/staging/main.tf` | `staging` | `prod` head "not affected"; group head: `staging` full column, `sandbox` dashes, footer names `sandbox` | green if staging passes |
| Shared code | `modules/net/main.tf` | all three | today's comments, unchanged | as today |
| README inside an environment | `envs/prod/README.md` | none (implied ignore) | as docs-only | green |
| Environment with `paths-ignore: []` | `envs/prod/README.md` | `prod` | prod plans | as today |
| Workflow file | `.github/workflows/terraform.yml` | all (fail-open `workflow-changed`) | today's comments; no head says "not affected" | as today |
| Force push to the pull request branch | any | all on the next push run (`forced`); the pull request run itself is `diff` from the pull request's files | as today | as today |
| "Update branch" from a base that changed `envs/prod/**` | the pull request's own files only | unchanged from the previous run | unchanged | unchanged |
| Push to main after merging the one-environment pull request | `envs/staging/main.tf` | `staging` | no comments; run summary lists `prod`, `sandbox` as not affected | green if the apply passes |
| Failed apply on push N, unrelated push N+1 | push N+1 touches `envs/prod/**` only | `prod` only | `staging` is not retried | green; the notice lists `staging` as not affected; a dispatch reconciles it |
| Pull request with a merge conflict | any | no run at all | nothing | "Expected", until the conflict is resolved |
| Converting a repository that has `on.paths` today | the workflow file itself | all (`workflow-changed`) | today's comments | as today; from the next pull request on, docs-only changes merge without a dummy commit |
| `path-relevance-enabled: false` | any | all (`disabled`) | as today | as today |

## 10. Interplay with other specs

| Concern | Relationship |
|---|---|
| Test stage | Tests are not filtered here (D11). The conclusion judges them independently (§7.2). The test jobs' `if:` drop their `seed-pr-comments` result clause for the same reason as §5.3. |
| Ordering between environments ([Environment-ordering.md](Environment-ordering.md)) | Conditionality comes for free: a dependency on an environment that is not in the run is satisfied trivially, and is recorded. `envs-json` carries what the stage builder needs. The conclusion rule for a stage skipped while its row count is non-zero is shared with that spec. |
| Single-environment dispatch (later) | `workflow_dispatch` is mode `all` until that spec adds a filter; a dispatched environment is always affected. |
| Test-root lock files (later) | Unchanged. |

## 11. Actions: new and changed

All follow [Action-implementation-guide.md](Action-implementation-guide.md).

- **The create-matrix adapter**: §4.3. Tests with a fake `gh`: a small pull request, a renamed
  file, a 100-per-page pagination, a pull request at the cap, a compare at 300 files, a forced push
  payload, a created branch compared against the default branch, a moved head, an API error; every
  case asserts the facts, and the core's tests the mode and reason.
- **`create-tf-vars-matrix`**: §5. Fixtures: `auto` expansion with and without additional dirs,
  `project-dir` normalisation, `auto` plus extras, replacement lists, implied and explicit ignore,
  `paths-ignore: []`, renamed files, mode `all`, all-unaffected, `envs-json` shape, validation
  errors for a bad glob and a non-list `paths`.
- **`pr-comments-reconcile`**: unchanged; the seed job composes `gc-yml` for unaffected
  environments from existing primitives.
- **`aggregate-validation-summaries`**: §6.4, `relevance-file` input, goldens for an unaffected
  column, an all-unaffected group, a group absent from metadata but present in relevance, and the
  no-file case unchanged.
- **`create-run-summary`**: §6.5, `relevance-file` input, goldens for zero and mixed.
- **`evaluate-automerge-eligibility`**: §8, `relevance-file` input, goldens for zero affected with
  an allowed and a disallowed actor, a missing affected environment, and the no-file case unchanged.
- **Workflow**: `create-matrix` steps and outputs, `seed-pr-comments` manifest, the environment
  job's `if:`, the test jobs' `if:`, `conclusion`, `automerge`; structural tests for the `needs`
  lists and the named-results form.

## 12. Pitfalls

| # | Pitfall | Consequence | Rule |
|---|---|---|---|
| P1 | `on.paths` on the calling workflow skips the whole workflow; a required check that never reports blocks the pull request. | Docs-only pull requests need an admin or a dummy change. | Callers remove `on.paths`; relevance lives inside (§3.5). |
| P2 | The matrix job purges its own environment's old plan tags; for an unaffected environment it does not run. | A plan from an earlier run stays visible under a head that says "not affected". | The seed job purges unaffected environments' tags (§6.3). |
| P3 | The matrix job's `if:` also tested the seed job's result, and the seed is not in the conclusion's `needs`. | A broken seed skipped every environment and the conclusion stayed green with no plan. | Drop the clause; gate "skipped is benign" on `affected-count` (§5.3, §7.2). |
| P4 | The aggregator's desired set comes from metadata only, and its orphan pass deletes group heads outside the set. | An all-unaffected group's head is deleted when another group ran, or left at "Awaiting results" when none ran. | Desired set = relevance ∪ metadata (§6.4). |
| P5 | Three thousand paths in a job output enter envp through the steps context. | Exit 126, "Argument list too long", in production only. | The file list travels by path; outputs carry counts and mode (§4.3). |
| P6 | The builder's existing `curl` to the API has no error handling and degrades to `null`. | Out of scope here, but the same pattern must not be copied. | `gh api` with tempfiles and explicit fail-open (§4.3). |
| P7 | `paths` and `paths-ignore` are lists; the builder's generic forwarding loop copies scalars. | The keys would be silently dropped. | Explicit handling like the `*-yml` fields (§5.1). |
| P8 | `download-artifact` by name throws when the artifact is missing; by pattern it succeeds with zero matches. | A reporting or auto-merge job fails on a run that had no reason to upload. | `continue-on-error: true` on every `relevance` download (§5.2). |
| P9 | Files Terraform reads from outside the `auto` set: `-var-file` and `-backend-config` targets via `TF_CLI_ARGS_*`, local modules outside `main/` and `modules/`, Markdown read by `file()`. | An environment is not planned for a change that affects it. | Explicit `paths`, `paths-ignore: []` (§3.2). |
| P10 | Neither the pull request files endpoint nor compare signals truncation. | A capped list looks complete. | `changed_files` from the pull request object; 300 files in a compare response is the cap (§4.2). |
| P11 | The pull request files list is live while a re-run is pinned to its SHA. | Relevance computed for commits the run does not test. | `pr-head-moved` fail-open (§4.2). |
| P12 | `github.event.before` all zeros on branch creation is folklore; `created` and `forced` are documented. | A fail-open keyed only on the zero SHA can miss. | Key on the documented fields, keep the zero SHA as backup (§4.2). |
| P13 | An empty matrix fails the job; whether a false job-level `if:` avoids evaluating it is undocumented. | A docs-only pull request could redden on the matrix job. | Verified on the test bed: GitHub evaluates the job-level condition first, so an empty matrix behind a false one is no error and no sentinel row is needed ([Environment-ordering.md](Environment-ordering.md) P4). |
| P14 | The `automerge` job's `if:` has no status function. | Implicit `success()` skips it when the matrix is skipped. | `!cancelled()` plus explicit results (§8). |
| P15 | Auto-merge eligibility with no metadata skipped the enabled and actor checks. | Any actor's docs-only pull request would auto-merge in an actor-restricted repository. | Checks one to three from `relevance.json` (§8). |
| P16 | A failed apply on push N is not retried by an unrelated push N+1. | Drift until the next relevant change. | The notice lists the environment; a dispatch is mode `all` (D5). |
| P17 | The Environments view shows the last affected run's deployment for an environment. | A reviewer may read an old deployment as current. | Documented in the user guide. |
| P18 | A pull request with a merge conflict gets no run. | Its check stays "Expected", which looks like this feature failing. | Documented (§7.4). |
| P19 | Relevance is the default in v1. | A caller's docs-only changes stop planning on the move to v1, and a change outside the `auto` set with an environment that reads it silently stops planning that environment. | `path-relevance-enabled` (D10); the migration guide's checklist asks each caller to review its `paths`. Never shipped on a rolling major tag. |

## 13. Test coverage

**Must**

- The adapter's fetching: every fact behind the fail-open reasons of §4.2; pagination at 100;
  renamed files listed under both paths; `changed_files > 3000` short-circuits without paging; a
  compare with 300 files is truncated; a failed call is an error fact, never a failed step; a
  created branch is compared against the default branch; the file list never reaches
  `$GITHUB_OUTPUT`.
- `create-tf-vars-matrix`: the fixtures of §11; the environment job's matrix excludes unaffected
  rows; `affected-count` and `unaffected-count` sum to the environment count; `envs-json` carries
  every environment with its resolved rules; mode `all` reproduces today's matrix byte for byte.
- Seed manifest: unaffected ungrouped environments get the §6.1 body with the correct title;
  affected ones the placeholder; `gc-yml` holds four rules per unaffected commenting environment and
  none for affected ones; mode `all` produces today's manifest.
- `aggregate-validation-summaries`: goldens of §11; an all-unaffected group is rendered, not
  deleted; the no-file path is byte-identical to the existing goldens.
- `evaluate-automerge-eligibility`: goldens of §11; the structural test asserts the `automerge`
  `if:` contains `!cancelled()` and the affected-count clause, the conclusion's `needs`, and the
  absence of `contains(needs.*.result`.
- `create-run-summary`: goldens of §11.

**Should**

- The glob helper's shared fixtures pass from both builders.
- A `paths` list containing `auto` twice, or `auto` with a trailing slash, is normalised or
  rejected with a clear message.

**Could**

- A property-style test that for random changed-file lists, `affected ∪ unaffected` equals the
  environment set and no environment appears in both.

**What tests cannot cover**: the pull request files list equalling the Files tab, the empty-matrix
short-circuit, which attempt's check run branch protection reads after a re-run, `github.event.created`
inside a reusable workflow, and the docs-only pull request merging without an admin. All verified on
the test-bed and recorded in §17. Two are settled already: a false job-level condition keeps an empty
matrix from failing the run (P13), and `github.event.created`, `forced` and `deleted` are populated
inside a called workflow on push, a branch creation reading `created: true` with `before` all zeros
and a force push reading `forced: true`.

## 14. Open questions

None open. The pull request object's `changed_files` equals the number of entries the files
endpoint pages out: five pull requests of up to 283 files matched, and on the test bed a rename
counted once, listed once with status `renamed` and the old path in `previous_filename`. Which
attempt's check run branch protection reads after "Re-run failed jobs" is not documented, and the
design does not depend on it: it holds for any re-run, with or without relevance. The `created`
case is decided (D13).

## 15. Implementation order

1. `docs:` this spec.
2. `feat(engine):` the adapter's fetching of the changed files (D12), with a fake `gh`.
3. `feat(create-tf-vars-matrix):` `paths`, `paths-ignore`, `auto`, relevance inputs, `envs-json`
   and counts; fixtures. The glob helper is shared with `create-tftest-matrix`; whichever spec is
   implemented first lands it.
4. `feat(aggregate-validation-summaries):` `relevance-file`, unaffected columns, footer, desired
   set; goldens.
5. `feat(create-run-summary):` `relevance-file`; goldens.
6. `feat(evaluate-automerge-eligibility):` `relevance-file`, completeness rule, unaffected checks;
   goldens; structural tests.
7. `feat(workflow):` `create-matrix` steps, outputs and artifact; seed manifest and `gc-yml`;
   environment job `if:`; conclusion rewrite; `automerge` `if:` and `needs`; header comment on
   permissions; structural tests.
8. `docs:` user guide (inputs, keys, migration, examples of §9), PR comments spec, apply reporting
   spec references, README, CLAUDE.md.
9. Validation through a preview ref on the test-bed repository: the scenarios of §9, the open
   questions of §14; findings into §17.

AI-assistant configuration files are never in these commits.

## 16. Documentation to update

- [Workflow-terraform-ci-default.md](Workflow-terraform-ci-default.md): `paths`, `paths-ignore`,
  `auto`, `path-relevance-enabled`; the migration of §3.5 in bold; the examples of §9; the
  merge-conflict and Environments-view notes.
- [Workflow-pr-comments.md](Workflow-pr-comments.md): §3.1 seed reads the full environment list and
  purges unaffected environments' tags (the "seed does not GC" sentence becomes "seed GCs only
  unaffected environments"); §3.3 desired set; §4 re-runs; §5.1 the "not affected" body; §5.3 the
  dash column and footer; §6 configuration; §8.1 orphan rule keyed on relevance ∪ metadata.
- [Apply-and-destroy-reporting.md](Apply-and-destroy-reporting.md): run-summary headline and rows;
  group head; pitfall index entries for P3, P4, P14, P15.
- [Terraform-tests.md](Terraform-tests.md): §5.1 job `if:` without the seed clause; §7 defers to
  §7.2 here; §8 gains this spec's row.
- Workflow header comment: `create-matrix` now uses `pull-requests: read` and `contents: read`.
- `README.md` action index; `CLAUDE.md` overview and docs list; `create-tf-vars-matrix/action.yml`
  inline docs; `evaluate-automerge-eligibility/action.yml` behaviour notes.

## 17. What implementation taught the spec

Reserved.
