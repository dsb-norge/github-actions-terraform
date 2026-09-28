# V1 progress

The tracking document for the road to v1: what has been delivered, in which pull request, what is
outstanding, and which open questions are closed. The plan it tracks is
[Road-to-v1.md](Road-to-v1.md); the specs describe the system and never point here.

Updated in every v1 pull request, as its last documentation step before validation.

## 1. Delivery

One pull request per step of Road-to-v1.md §6, targeting `main`. After a merge, `v1` moves to
`main` with a changelog block for that pull request (Road-to-v1.md §7).

| Step | What | Pull request | State | In `v1` |
|---|---|---|---|---|
| 0 | Concurrency `queue: max`; apply-reporting invariant, fixtures, contract tests | [#56](https://github.com/dsb-norge/github-actions-terraform/pull/56), [#57](https://github.com/dsb-norge/github-actions-terraform/pull/57) | merged, released in `v0.33` | inherited |
| 1 | The decision engine: the port behind goldens, the create-matrix adapter, both gates, the Python 3.12 floor tested in CI; `main` becomes the v1 line (internal refs `@v1`) | [#59](https://github.com/dsb-norge/github-actions-terraform/pull/59) | merged 2026-09-24 | yes, `v1` created on it |
| 2 | Path relevance: the glob matcher, the relevance rules and the seed manifest in the engine, the adapter's changed-file fetch and published decision, the aggregator, run summary and auto-merge evaluator on `relevance-file`, the workflow wiring and the conclusion rewrite | [#62](https://github.com/dsb-norge/github-actions-terraform/pull/62) | merged 2026-09-25 | yes |
| 3 | Terraform tests: the test stage in the engine (`tests.py`, the adapter's test facts), `terraform-test` rewritten as runner and classifier, `create-test-summary`, `export-env-vars` with the prefix export, `terraform-init`, `capture-matrix-job-meta` and `terraform-module-cache` extended, the test job and the tests summary job | [#64](https://github.com/dsb-norge/github-actions-terraform/pull/64) | merged 2026-09-26 | yes |
| 4 | Dispatch and trigger events: `triggers.py` in the engine (trigger events, the dispatch filter, the granted goals and the dispatch cap), the adapter's dispatch facts, the run summary's trigger lines, the `trigger-events-yml` input and the `goals-granted` gate switch | [#65](https://github.com/dsb-norge/github-actions-terraform/pull/65) | merged 2026-09-27 | yes |
| 5 | Hardening of caller configuration and auto-merge (§5): configuration validation in the engine (keys, goals and prerequisites, variables as written, init directories, auto-merge settings, the ref type, dispatch inputs), counts from the JSON plan, the evaluator and the merger hardened, the workflow wiring, and a thorough docs refresh with flow charts of the engine and worked examples | [#66](https://github.com/dsb-norge/github-actions-terraform/pull/66) | merged 2026-09-28 | yes |
| 6 | Environment ordering: `ordering.py` in the engine (the declared graph validated, the stages assigned), the adapter's per-stage matrices, the three stage jobs sharing one step list, held-back reporting in the run summary, the PR comments and the auto-merge reason | [#67](https://github.com/dsb-norge/github-actions-terraform/pull/67) | merged 2026-09-28 | yes |
| 7 | Open questions pass: every question bearing on implementation, delivery or v1 closed, and the fixes it turned up | — (branch `feat/open-questions`) | in progress | no |
| 8 | CI optimisation: this repository's CI time brought down, coverage and gates kept | — | outstanding | no |
| 9 | Module CI on v1: the module workflows ported, updated and improved; module repositories on v1 | — | outstanding | no |
| 10 | Docs finalisation: gaps in the refresh, as built everywhere, the road docs' content captured, the migration guide, the v1 changes document | — | outstanding | no |
| 11 | v1 released to callers: minors begin, migration guide complete, templates on `@v1` | — | outstanding | — |

### Outside the road steps

Changes the road does not list, made on the v1 line because a step's review surfaced them.

| What | Pull request | State | In `v1` |
|---|---|---|---|
| Heredoc captures hardened: free text (`pr-comment`'s body, `pr-comments-reconcile`'s YAML, the module cache's paths) captured as `toJSON` of the input, out of envp; every capture under a unique delimiter; structural test F9; the implementation guide's input rule | [#60](https://github.com/dsb-norge/github-actions-terraform/pull/60) | merged 2026-09-24 | yes |
| The engine reviewed for what should change after the port: per-environment values of workflow inputs take the inputs' types (per-environment booleans were silently ignored by the gates), environment names follow one rule, one environment per github-environment | [#61](https://github.com/dsb-norge/github-actions-terraform/pull/61) | merged 2026-09-24 | yes |

## 2. Status per spec

| Spec | Decided | Implemented | Verified on the test bed | As built |
|---|---|---|---|---|
| Decision-engine.md | yes | the port (#59); rule 4 and the comment manifest (#62); rules 2, 3 and 5 came with step 4 (#65), rule 1 whole with step 5 (#66), rule 6 with step 6 | the port, #59 (§4): identical matrices to `@v0`; ordering, step 6 (§4) | yes; flow charts with #66 and step 6 |
| Path-relevance.md | yes | yes (#62) | the §9 scenarios on pull requests and pushes (§4); auto-merge by tests only | yes |
| Terraform-tests.md | yes; D20 (discovery in the create-matrix adapter) and D21 (one test job) added 2026-09-25 | yes (step 3) | open-question probes (§3); every classification, lanes, an environment, two provider sets and the summary, through #64's preview ref (§4) | yes |
| Dispatch-and-triggers.md | yes; schedule per environment only (D7) decided 2026-09-26 | yes (step 4) | dispatch inputs inside a called workflow, `schedule` actor; the §6 dispatch and schedule rows on pull requests, pushes, dispatches and a schedule (§4) | yes |
| Environment-ordering.md | yes | yes (step 6) | mechanics during design; every held-back surface, the bypass and a cycle through a test tag (§4) | yes |
| Configuration-validation.md | yes (step 5) | yes (#66) | every refused kind in one run, the accepted shapes, a tag, a dispatch block without the standard inputs (§4) | yes |
| Auto-merge.md | yes (step 5) | yes (#66) | the evaluator on real plans, the merge pins against GitHub (§4) | yes |
| concurrency queueing (#56) | yes | yes | yes | no spec |
| apply reporting hardening (#57) | yes | yes | in CI on six Terraform minors | no spec |

## 3. Open questions

Every spec's open questions, and what closed them. Closed answers live in the spec's text; this
table only says where.

| Spec | Question | State |
|---|---|---|
| Decision-engine.md | Python on self-hosted pools | closed: no caller names a workflow-level `runs-on`; `create-matrix` runs on ubuntu-24.04, Python 3.12 (survey of the callers) |
| Decision-engine.md | `pipx run coverage` on the hosted image | closed: runs, reports branches, gate at 100 percent in CI on #59; `pipx run` drops `PYTHONPATH` (P17) |
| Decision-engine.md | default branch on `schedule` | closed: in the payload, inside a called workflow too (test-bed probe) |
| Decision-engine.md | `github.actor` on `schedule` | closed: the account that last pushed the cron line (test-bed probe) |
| Path-relevance.md | empty matrix behind a false `if:` | closed: no error, no sentinel (ordering test bed) |
| Path-relevance.md | `created`, `forced` inside a called workflow | closed: populated (test-bed probe) |
| Path-relevance.md | `changed_files` accuracy | closed: equals the paged count; a rename is one `renamed` entry with `previous_filename` (test-bed probe pull request) |
| Path-relevance.md | which attempt's check branch protection reads after a re-run | closed: undocumented, and the design holds for any attempt (Path-relevance.md §14) |
| Path-relevance.md | a push that creates a branch | closed: compared against the default branch (Path-relevance.md D13) |
| Path-relevance.md | the root `.tflint.hcl` of `auto` matched every `.tflint.hcl` (basename rule) | closed: the maintainer chose a root anchor in the grammar (a leading `/` or `./`); `auto` uses `/.tflint.hcl` |
| Dispatch-and-triggers.md | `github.event.inputs` inside a called workflow | closed: the caller's inputs; `null` without a block; empty strings absent (test-bed probe) |
| Dispatch-and-triggers.md | `github.actor` on `schedule` | closed, as above |
| Dispatch-and-triggers.md | callers with dispatch inputs named `environment`, `goal`, `reason` | closed: none (survey of the callers) |
| Dispatch-and-triggers.md | may the global `trigger-events-yml` include `schedule` | closed 2026-09-26 by the maintainer: no, per environment only; `schedule` in the global list is a validation error (spec D7) |
| Dispatch-and-triggers.md | a later `test-file` dispatch input | deferred by the spec |
| Terraform-tests.md | the step anchor, `artifact-url`, `hashFiles` on a matrix path, `pr-comment` delete matching, an environment root with a real backend, job-name length, an empty environment name, `deployment: false` and the token subject, environment secrets in a called job, the may-break value, init with a copied lock, the module cache from a test root | closed 2026-09-25 by test-bed probes, a local Terraform 1.16 lab and the documentation; answers in the spec's text. Corrections: one test job (D21), the module cache needs a new input (§9.9), git sources are impossible in run blocks, read-only init fails an environment root whose tests need an extra provider |
| Terraform-tests.md | the role that sets environment secrets; the step anchor in the web view | closed 2026-09-25: a write-role account set, updated, listed and deleted environment secrets with `gh`, but could not create, configure or delete the environment; the maintainer confirmed the anchor opens the right step |
| Terraform-tests.md | isolation end to end; a real environment lane; case in flexible credential `matches` | closed 2026-09-25 in a session with the maintainer, with throwaway identities and a resource group in a sandbox subscription: an environment-only credential refused tokens to jobs outside its environment, the flexible credential granted one only to `tftest-*` jobs, a lane ran a `command = apply` test and cleaned up, and `matches` is case-sensitive |
| Terraform-tests.md | Dependabot runs and OIDC; fork runs and environment creation | open (spec §12): the first needs a Dependabot pull request, fork creation is blocked by the organisation's fork policy for private repositories; neither changes the design |
| Terraform-tests.md | a real OIDC login in an environment lane, run through the workflow on the test bed | open: deferred by the maintainer on 2026-09-25, not gating step 3 (the Entra probes before implementation covered the identities, the test bed the lane mechanics with placeholder secrets); **required before v1 is tagged** (Road-to-v1.md §6, step 11) |
| Terraform-tests.md | lower-case `TF_VAR_` names from environment secrets; the version floor | decided 2026-09-25 by the maintainer after the test bed showed GitHub upper-casing secret names and 1.12 refusing a test file's `variable` block: environment lanes export a lower-cased copy of every `TF_VAR_*` secret, and the floor is 1.13 |
| Terraform-tests.md | the copied lock and the runner's platform; the shared plugin-cache key | decided 2026-09-25 by the maintainer: every lock a test job uses must record the runner's platform, checked before init as `lock-platform`; the test job's cache key gets a `-tftest` suffix and falls back to the environment job's |
| Configuration-validation.md, Auto-merge.md | auto-merge with no actors; a per-environment actor list; goals whose prerequisite is missing | decided 2026-09-27 by the maintainer: an error that says plainly what is wrong; it replaces the global list; an error |
| Auto-merge.md | the merge after the base moved; auto-merge for other base branches; the JSON plan artifact | decided 2026-09-27 by the maintainer: refused; default branch only; no longer uploaded |
| Auto-merge.md | whether a tolerated failure (`allow-failing-terraform-operations`, `allow-failing-terraform-tests`) blocks auto-merge | decided 2026-09-27 by the maintainer, split: a tolerated Terraform operation blocks it; a tolerated test does not (the lever to auto-merge despite a failing lane), and is named in the log and a notice |
| Auto-merge.md | GitHub's wording for a stale `--match-head-commit` | closed 2026-09-27 on the test bed: `GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)` (spec §13) |
| Auto-merge.md | whether a `-target` plan, `complete: false`, should count | decided 2026-09-27 while building: counted, with completeness reported apart (`plan-complete`) and required only by auto-merge, so the comment keeps real counts (spec §5.2, §13) |
| Configuration-validation.md | a `codeowners` value for the actor list, resolved from CODEOWNERS | dropped 2026-09-27 by the maintainer, after the facts: teams resolve only with an organisation Members permission no workflow token has, email owners cannot be mapped, and an owner merging their own change past review defeats it |
| Environment-ordering.md | held-back finalisation; hand-off latency | closed 2026-09-28 on the test bed: the aggregator finalised a held-back head and group columns; three seconds between stages, uncontended (spec §13) |
| Environment-ordering.md | a strict opt-in for tolerated failures | deferred by the spec: not in v1 |
| Road-to-v1.md | the v0 support period | closed: fixes only on `release/v0` until the last caller moves (Road-to-v1.md §7) |
| Road-to-v1.md | the module CI workflow on the engine in v1 or after | decided 2026-09-28 by the maintainer: in v1, as step 9, after CI optimisation (step 8) |

## 4. Validation log

### Step 1, #59: the engine port

- CI: every suite green, `engine` at 100 percent line and branch coverage under `pipx`.
- Negative coverage, after review asked whether 100 percent coverage meant the rejections were
  tested: a mutation run found 44 unnoticed faults at full coverage (40 of the 43 validation
  checks, the directory check's fail-closed default, CLI usage errors exiting with the
  configuration code). All now have tests; the engine suite gained a mutation gate that fails on
  any surviving fault (524 mutants, all killed, none listed as equivalent). The shim no longer
  blames the caller's YAML for a broken `yq`, and keeps caller values from starting workflow
  commands in the log.
- Test bed, through `preview/pr-59`, on the seven-environment configuration (apply on pull
  request, destroy plan and destroy, outputs, allow-failing, a deliberately failing apply):
  - `workflow_dispatch`: the matrix is identical to a `@v0` run of the same configuration, all
    seven environments, apart from `caller-repo-calling-branch` (each run's own branch). Every
    job green, as at `@v0`.
  - `pull_request`: the matrix equals the dispatch run's apart from the ref (`<n>/merge`, not on
    the default branch, as `@v0` sets it); the decision record is in the log; the whole graph
    ran, and the only failure is the environment whose apply fails by design, at its apply step,
    with the conclusion red for it.
  - `push` to the default branch (one validate-only environment): green,
    `caller-repo-is-on-default-branch` `"true"`.
  - On all three events the default branch came from the payload; no API call was made.
- The bash shim replaced by the Python create-matrix adapter, after review asked whether the
  heredoc capture was safe and whether driving Python from bash was the way: the adapter sits
  under both gates (837 mutants at first; tests reading the module's own constants let 33
  survive until they compared against literals; all killed, none equivalent), rebuilds all 73
  input documents byte for byte, and runs isolated (`python3 -I`) after a caller's `json.py` was
  shown to shadow the standard library. The floor is Python 3.12, by the maintainer's decision,
  tested in CI on 3.12 (3.12.14) and the newest 3.x (3.14.7), all mutants killed on both.
- Test bed re-run through the adapter (`preview/pr-59` at the adapter commit): on
  `workflow_dispatch` the matrix is identical to the `@v0` baseline apart from the calling branch,
  every job green; on `pull_request` the whole graph ran and the only failure is the environment
  whose apply fails by design. The step's log group is titled by the run block's description
  comment, and `python3 -I -B` resolved the engine from the preview ref.

### #60: hardened heredoc captures

- Review caught the first version moving free text into `env:`, which reversed the May 2026 fixes
  that took large values out of envp after production E2BIG failures (`f9594c2` for this very
  body), and whose size argument was wrong (128 KiB is bytes, the body cap 65536 characters).
  Reworked: free text is captured as `toJSON` of the input, which closes the injection and keeps
  it out of envp; a 150 KB body (50000 three-byte characters) now posts intact, and fails the test
  when the step leaves it exported. Re-run on the test bed: GitHub rendered `toJSON` of the
  multi-line `heads-yml` as one line with every newline escaped; the seed job decoded and parsed
  the seven heads and patched each in place, none duplicated; fifteen operation comments posted
  through `pr-comment`, which decoded the empty inline body (`toJSON("")`) as no body; the only
  failure is the environment whose apply fails by design.

- CI: every suite green, the new structural test F9 included (16 captures, 17 call sites); F9
  shown to fail on a bare `EOF` delimiter and on a call site passing a plain string.
- Test bed, through `preview/pr-60` on a pull request with the seven-environment configuration:
  the only failure is the environment whose apply fails by design; the seed job's reconcile,
  reading its YAML through `env:`, posted each of the seven environment heads exactly once; the
  environment export, per-goal resolution and metadata capture passed under their new delimiters.
  The module cache's `cache-paths` steps did not run (no environment there resolves cacheable
  modules), so that move rests on its suite.

### #61: field types, the name rule, one environment per github-environment

- Test first: `test_fields.py` failed against the unchanged engine on every new rule (47 failing
  subtests and 1 error across 18 test methods) before any rule existed; each rule then landed in
  its own commit, green on its own with the mutation gate (881, 900, 911 mutants, all killed).
- Five port cases record the old behaviour as deviations; three `-v1` cases hold the valid paths;
  `fixture-happy-day-v1` equals the bash builder's golden apart from the renamed environment and
  the one normalised boolean. Every calling repository's names fit the rule; none sets
  github-environment.
- Test bed, one environment with `add-pr-comment` and `verify-lock-file` false globally and YAML
  `true` for the environment, run through `preview/pr-61` and, as a control, at `@v1`:
  - `@v1` (before): the lock-file check and both head upserts **skipped**; the head stayed
    "⏳ Awaiting results" for good, and the run was green although the lock file lacks hashes.
  - #61: the lock-file check ran and failed on the missing hashes (the test bed's own lock file
    covers only one of the three required platforms), and the head reached its final validation
    table. Both per-environment booleans took effect.

### Step 2, #62: path relevance

- Test first for every engine module: the glob matcher, the relevance rules, the adapter's fetch,
  the seed manifest and the published decision, each shown failing before it existed. Gates at the
  last engine commit: 300 tests, 100 percent of lines and branches, 1885 mutants all killed. The
  aggregator, run summary and auto-merge evaluator each gained their tests beside unchanged old
  ones (14, 22 and 19 new); structural test F10 was shown failing against the old workflow.
- The seed manifest in mode `all` against the old seed job's jq: 300 random configurations, no
  difference.
- Test bed through `preview/pr-62`, three environments on `auto` (`noop-poc` ungrouped,
  `outputs-kept-poc` and `destroy-plan-poc` in the group `platform`), every case green and as §9
  of the spec says:
  - push to `main` changing the calling workflow: all three, `all (workflow-changed)`;
  - documentation only (a README at the root and one inside an environment): nothing ran,
    "nothing to verify"; `noop-poc`'s head its final "not affected" body with the path rules, the
    group all dashes with the footer;
  - one environment: only `outputs-kept-poc`, its group neighbour a dash column, `noop-poc` not
    affected;
  - shared code under `main/`: all three, matched by `main/**`;
  - `path-relevance-enabled: false`: all three, `all (disabled)`;
  - a pull request that had run all three, then turned documentation-only: the seed purged the
    three environments' plan tags and the heads flipped to "not affected";
  - the push that merged the one-environment pull request: only `outputs-kept-poc`, from the
    compare;
  - the run summary's headline, relevance line and dash rows, and the relevance notice, on every
    run.
- Not exercised on the test bed, covered by tests: auto-merge (the test bed has no merge app), a
  force push, a push that creates a branch (the test bed's workflow runs on pushes to `main`
  only), a pull request whose head moved, the API caps.
- After the hand-off, at the maintainer's request: a root anchor in the glob grammar (`auto` uses
  `/.tflint.hcl`, so one environment's own tflint configuration no longer runs every environment),
  and a coverage pass that closed the gaps it found. The readers are now tested against the
  `relevance.json` the engine publishes, not only hand-written files. Structural test F11 runs
  the seed job's script and pins how the file travels to every reader. The action suite covers
  every fetch path end to end: two pages, a new branch, a forced push and relevance switched off,
  the last two asserting no request at all. Engine gates: 307 tests, 1900 mutants all killed. On the
  test bed, a change to one environment's own `.tflint.hcl` ran that environment alone, and the
  others' "not affected" bodies list `/.tflint.hcl`.

### Step 3, #64: Terraform tests

- Test first for the engine side (`tests.py`, the adapter's test facts), gates at the last engine
  commit: 100 percent of lines and branches, 2734 mutants all killed. Each converted action
  (`export-env-vars`, `terraform-test`) had its behaviour pinned as goldens in the commit before
  its conversion, goldens untouched by the conversion. `terraform-test`'s classifier replays JSON
  logs captured from a real Terraform 1.16.2.
- Test bed through `preview/pr-64`, pull request dsb-norge/azure-terraform-peder-tester#61, 17
  test jobs in seven lanes over two provider sets (a new environment pins `random` older than
  `outputs-kept-poc` and lacks `linux_amd64`). The first run reported `lock-platform` for every
  job: `verify-terraform-lock` needs an initialised directory and checks the directory's
  configuration, not the lock (Terraform-tests.md P42); it gained a lock-only mode. The same run
  showed job links missing for every row but the two-set file (P43). The second run found an
  environment secret `TF_VAR_needed` arriving as `TF_VAR_NEEDED` (P44), and Terraform 1.11 and
  1.12 refusing a test file's `variable` block, which failed init under the version-floor lane
  and hid the version (P45; 1.12 reproduced locally). The third run, on the fixes, matched
  expectations on every row:
  - pass; assertion failure (1/2); run error with a skipped follower (1/3); file errors from a
    required variable and from an unknown provider;
  - a parse error in one file failing init for its sibling too, both `init`, with the new detail
    naming the sibling cause;
  - `terraform-version` for the 1.11.4 lane although its init failed;
  - `no-credentials` in `tftest-nocreds`, which the run itself created, with no protection rules;
  - `lock-platform` on the `pinned-poc` set, a pass on the other set of the same file;
  - a tolerated failure, green job, rendered as tolerated;
  - a secret mapping plus a plain variable; an environment's upper-cased `TF_VAR_*` secret;
    placeholder `ARM_*` secrets passing the credential check;
  - an environment root's own `tests/` on its read-only lock, and an empty repository-root
    `tests/` whose `null` provider floats;
  - two misplaced files listed with warnings, an excluded file absent;
  - job links, artifacts and inline annotations on every row; the lock check hashing offline
    from the warm `-tftest` cache.
- Not exercised on the test bed, covered by tests: a push run of the stage (the test bed runs on
  pushes to `main` only), fork and Dependabot drops, the 256 cap. A real OIDC login in a lane was
  probed with throwaway identities before implementation and is due on the test bed before v1 is
  tagged (§3).
- After the hand-off, on the maintainer's decisions: environment lanes also export a lower-cased
  copy of every `TF_VAR_*` secret (`export-env-vars` gained `lower-case-copies-for-prefixes-json`),
  and the version floor moved to 1.13, which `terraform-test` now publishes so the summary no longer
  keeps its own copy. A fourth test-bed run showed both: the test declaring the lower-case `needed`
  passed from the environment's `TF_VAR_NEEDED` beside the upper-case one, and the version lane at
  1.12.2 reported "Terraform 1.12.2 is below the 1.13.0 floor"; every other row as in the third run.

### Step 4, #65: dispatch and trigger events

- Test first for `triggers.py`: every row of the spec's §6 and every error of §4.3 as a table case,
  generated cases across events, trigger-events, dispatch inputs, branches and goals, and the
  invariants I1, I2, I3, I15, I16 and I17 derived apart from the module. Gates: 451 tests, 100
  percent of lines and branches, 3181 mutants all killed (six survivors on the first run: two
  redundant pieces removed, four cases tested). Every port golden changed only by `goals-granted`.
  Structural test F13 was shown failing on a gate put back on the raw goals and on a destroy gate
  that accepted schedule.
- Test bed through `preview/pr-65`, pull request dsb-norge/azure-terraform-peder-tester#62, the
  spec's roles on local-backend environments (`outputs-kept-poc` prod with `[all, destroy-plan]`,
  `noop-poc` staging with `[all]` and schedule, `destroy-plan-poc` scratch with the destroy goals
  and no pull requests), every result as the spec says:
  - pull request: the two taking part planned without apply; `destroy-plan-poc` skipped with
    `trigger-events: pull_request not enabled`, its head saying it takes no part in pull requests;
  - dispatch from the branch with `goal: apply`: refused in create-matrix, naming the default
    branch; a fleet-wide `goal: plan` from the branch capped all three (scratch to `init, plan`),
    the dispatch line the first notice and quoted in the run summary;
  - the push that merged it to the test bed's `main`: apply where granted, destroy only in
    `destroy-plan-poc`, through the switched gates;
  - dispatches on `main`: the recovery apply ran `noop-poc` alone, planned and applied; scratch on
    `default` planned, applied, destroy-planned and destroyed; `goal: destroy-plan` on prod ran its
    destroy plan only, the gates skipping plan and apply; a misspelt name and `destroy-plan` for an
    environment without it failed with the spec's messages;
  - a five-minute schedule on `main`: the scheduled run planned and applied `noop-poc` alone, the
    other two skipped with `trigger-events: schedule not enabled`. The cron was removed and the
    test bed's `main` restored to `@v1` right after.
- Not exercised on the test bed, covered by tests: a dispatch without an inputs block after the
  move (the port cases and the adapter tests), a re-run by another actor, an unsupported event.
- After the hand-off, on the maintainer's review: goals are a list of known names (a list written
  without its dashes had held `destroy`), and a dispatch's `goal: apply` no longer brings the
  destroy goals. Gates: 454 tests, 100 percent of lines and branches, 3210 mutants all killed. On
  the test bed, a dispatch with `noop-poc`'s goals written as a `|` block without dashes failed in
  create-matrix naming the string `init plan destroy-plan` and how to list goals, and no
  environment ran; a `goal: apply` dispatch of `destroy-plan-poc` on `main` planned and applied and
  skipped its destroy plan and destroy. The test bed's `main` went back to `@v1` right after.

### Step 5, #66: hardening of caller configuration and auto-merge

- Engine, test first where the rule was new: every message of Configuration-validation.md §3 as a
  literal, the auto-merge settings both ways, the ref type and the dispatch lines. Gates on the
  tip: 519 tests, 100 percent of lines and branches, every mutant killed; the first mutation run on
  the new rules left 17 survivors in 3718 (redundant code removed, untested edges tested, each in
  the commit that brought it). Every port input gained `ref_type` and a dispatch's `inputs` with no
  golden changing; the deliberate changes are recorded deviations.
- Actions: `parse-terraform-plan` 87 tests on seven real Terraform 1.16 captures (the injected
  summary among them, its console miscount pinned), `terraform-plan` 204, `evaluate-automerge-eligibility`
  138, `auto-merge-pr` 39. Each agent-built rule was also broken by hand in a scratch copy, and
  every break failed a test. The contract tests count every plan from its JSON plan on the six
  newest minors, in CI; no JSON count differed from the console's. F14 was shown failing on the
  unwired workflow.
- Test bed through `preview/pr-66`, dsb-norge/azure-terraform-peder-tester#63, every result as the
  specs say:
  - one dispatch holding one mistake of each kind reported all ten in one run, in the specs'
    words (an unsuffixed key, a near miss, a suffixed plain setting, a workflow-only input, goals
    without dashes, a goal without its prerequisite, an empty init directory, actors without
    dashes, a quoted and a misspelt limit);
  - an accepted configuration: a per-environment null removed a global variable, `1.10` and
    `012345678901` reached the row as written, a single init directory written alone was
    initialised, a destroy plan ran alone, the inert per-environment `pr-auto-merge-enabled: true`
    was a warning, and a dispatch through a block of its own named the input it delivered;
  - from a tag, a dispatched apply was refused naming the tag, and a default dispatch was granted
    no apply (`caller-repo-is-on-default-branch` false);
  - pull-request runs with a dummy App, so an eligible pull request stops at resolving the key: an
    environment out of pull requests the change touched made it ineligible, with all three taking
    part it was eligible (a lower-cased login matching the actor), and a `-target` plan was
    counted in the comment and refused as not complete. Counts came from the JSON plan
    (`counts-source: json`) and no JSON plan artifact was uploaded.
  - the merger's step, run with the maintainer's token against dsb-norge/azure-terraform-peder-tester#64:
    a stale head was refused by GitHub and named with both heads, a moved base was refused before
    any merge call, and the up-to-date pins merged the pull request.
- The user guide's worked examples were each produced by running the adapter, the evaluator, the
  conclusion's run block or the step concerned on the configuration shown. Doing so found one
  engine gap, fixed in the step: a global variable's problem was blamed on the first environment
  inheriting it.

### Step 6: environment ordering

- Engine, test first: every case of the spec's §12 and every message of §5, 600 generated graphs
  across events, goals, changed files and dispatches, and the invariants I18 to I24 derived apart
  from `ordering.py`. The first mutation run left 11 survivors, all in `ordering.py`: two untested
  edges (a run that only destroys, a bypass naming two dependencies) now tested, and search
  optimisations no test could see, replaced by a cycle search without them. One mutant is listed as
  equivalent, the first in the list: the environment a cycle's walk starts from, which the
  rotation to the first-declared member makes irrelevant. Without depends-on every port golden is
  unchanged.
- Actions: `create-run-summary` 152 tests, `aggregate-validation-summaries` 91,
  `evaluate-automerge-eligibility` 154 (F15 new, F10 pinning the conclusion's lines, F12 fixed for
  output names with digits). The conclusion's old and new scripts agreed on 20,736 one-stage cases.
  Each renderer's rules were broken by hand in scratch copies; every break failed a test but one
  the report explains (a lookup skipped for a held-back member, which cannot change output).
- Test bed through a hand-published tag, which runs no CI in this repository, on
  dsb-norge/azure-terraform-peder-tester#65 and its `main`, every result as the spec says:
  - no depends-on: stage 1 alone, the other two stage jobs skipped, the conclusion's line as before;
  - a pull request whose stage 1 failed an apply on the pull request: stage 2 held back, the
    conclusion `stage 1 failed; stage 2 held back (3 environment(s))`, the run summary's ⏭️ rows and
    stage listing, the held-back environment's own head and the group head's columns finalised;
  - a cycle refused in create-matrix, named from its first-declared member;
  - pushes to `main`: two stages in order (stage 2 started three seconds after stage 1 ended); a
    failed stage 1 holding stage 2 back; a tolerated failure releasing it, named in the footer; a
    change to one environment alone leaving its dependency out, with the notice and the footer
    sentence;
  - a single-environment dispatch with `goal: apply` bypassing its dependency, with the notice.
  The test bed's `main` went back to `@v1`, identical to before, and the tag was deleted.

### Step 7: the open-questions pass

An inventory of every open question, deferred decision and carried finding in the docs and the code
comments (60 items), each classified by whether it bears on implementation, delivery or v1, and
closed or assigned. Decisions of the maintainer on 2026-09-28 are marked as such.

| Item | Decision | Where |
|---|---|---|
| A real OIDC login in a Terraform test lane, "required before v1 is tagged" | the maintainer: in step 7, with the maintainer's Azure session and the test bed | step 7 |
| Auto-merge end to end with a real merge App | the maintainer: a throwaway App on the test bed, with the test bed's `main` ruleset requiring an approval and the conclusion and the App on its bypass list; a docs-only and a plan-within-limits pull request through it | step 7 |
| Values pasted into `run:` blocks instead of `env:` | the maintainer: every `${{ inputs.* }}` and `${{ matrix.* }}` in a `run:` block moves to `env:`, and a structural test forbids new ones outside heredoc captures. Only small scalars move, so the envp limits of CLAUDE.md are respected; large values stay in their heredoc captures | step 7 |
| Docs-only pull requests auto-merged for any author | the maintainer: no; the actor list stays the only rule | closed |
| `actions/download-artifact@v4` (Node 20) | the maintainer: v8, with a test-bed check that a by-pattern download with zero matches still succeeds | step 7 |
| The PR comment's mode row reading the raw goals | the maintainer: on a pull request it reads what was granted | step 7 |
| How v1 is cut (`v1.0`, the changelog) | the maintainer: decided at step 11; release-please is one option | step 11 |
| The test job without `queue: max` | a third overlapping run cancels a pending test job, which turns the conclusion red; it gains `queue: max` as the stage jobs have | step 7 |
| "nothing to verify for this change" on schedules and dispatches | the notice and the conclusion stop saying "this change" where there is none | step 7 |
| The lock-file notice on every run of a repository without test files | only when there are test files | step 7 |
| `runs-on` and `format-check-in-root-dir` missing from the required row fields | added | step 7 |
| A private repository's name in `auto-merge-pr/run_local_step_auto_merge_pr.sh` | removed | step 7 |
| The engine's `validate` and `render-summary` commands, specified but not built | dropped from the spec; P12 described as built | step 7 |
| Contradictory caller advice on `cancel-in-progress` (the PR-comments spec against the user guide) | the user guide's warning holds | step 7 |
| Cases covered by tests only (ordering's overlapping runs, a force push, a push creating a branch, a dispatch without an inputs block, a re-run by another actor) | exercised on the test bed | step 7 |
| Dependabot runs and OIDC; a fork run creating an environment | bear on nothing in v1: deferred | closed |
| A single-test-file dispatch input; relevance for tests | after v1 | closed |
| Suites writing to a fixed `/tmp` file | step 8, with the parallel runs | step 8 |
| Module CI's inline actions without suites; the module workflow docs | step 9 | step 9 |
| Specs' status lines and progress markers; the stale statements the inventory listed (eleven); the self-hosted runner requirements; the secret naming precondition | step 10 | step 10 |
| The required `tests-conclusion` check on this repository | closed: a merge of #66 was refused while it was pending | closed |
| The mode row's raw goals elsewhere: the engine's seed placeholder (`comments.py`) and the aggregator's group head (`_extract_goal_flag`) | found while fixing the per-environment row; the same fix, what was granted on a pull request | step 7, still to do |
| Non-breaking spaces inside `${{ secrets.… }}` in `terraform-module-ci.yaml` (actionlint flags them) | may break those expressions | step 9 |
| A per-environment `runs-on` written as a list of runner labels is refused as not a string (the rule of #61 for string inputs); no surveyed caller writes one | for the migration guide | step 10 |
| The test-bed round of this step: the OIDC lane login, auto-merge through the App, a zero-match download under v8, the cases covered by tests only | needs the maintainer's Azure session for the first; the rest through a hand-published tag | step 7, still to do |

## 5. Findings to carry

### Step 5 scope: hardening of caller configuration and auto-merge

All fourteen were resolved in #66; the specs record how. An audit during the step-4 review, looking for v0 habits the engine carried over that turn a
caller's mistake into a different action. #65 fixed the two in its own rules: goals are a list of
known names (a list written without its dashes had destroyed), and a dispatch's `goal: apply` no
longer brings the destroy goals. The rest is step 5, each item verified against the code:

1. Unknown keys in an `environments-yml` entry are silently forwarded or dropped. A per-environment
   `goals:` without `-yml` took the global goals instead (a plan-only intent applied); so did
   `extra-envs:`, `pr-auto-merge-from-actors:` and the other unsuffixed names. `trigger-events-yml:`,
   a misspelt `github-environment` (which falls back to a new, unprotected environment) and `path:`
   are ignored.
2. Goals whose prerequisite is missing are granted but never run: `apply` without `plan`, `destroy`
   without `destroy-plan`, `plan` without `init`.
3. The auto-merge evaluator reads the raw goals, not `goals-granted`; with a string or other-cased
   goals it skipped every plan limit (the goals rule of #65 removes those shapes, not the reader).
4. The auto-merge actor list: a string or a list without its dashes never matches, `""`, `~`, `{}`
   or `0` allow every actor; a per-environment list is added to the global one instead of narrowing
   it; and the default empty list allows every actor. For the maintainer to decide how it fails.
5. The auto-merge limits: a misspelt per-environment key is ignored over a permissive global value,
   and the workflow's comment names `destroy-plan` limits that do not exist.
6. The merge is not pinned to the evaluated commit (`gh pr merge --admin` without
   `--match-head-commit`), and a re-run keeps the original actor.
7. Plan counts are read from the text: an unanchored `No changes.` and the first line holding
   `Plan: ` let content inside the plan zero every count, which hides the plan in the comment and
   passes every auto-merge limit. The JSON plan is the reliable source.
8. "On the default branch" compares the short ref name, so a tag named like the default branch
   counts as it.
9. `terraform-init-additional-dirs-yml` as a string (or a list without dashes) inits nothing, and
   the init loop splits unquoted.
10. `extra-envs*` values are YAML-coerced (a leading zero dropped, `1.10` read as `1.1`), and `~`
    is exported as the literal `null`.
11. A dispatch whose inputs block holds none of the standard names runs every environment with its
    full goals and says only "environment (all), goal default".
12. A per-environment `pr-auto-merge-enabled: true` does nothing while the global input is
    `false` (the auto-merge job never runs); a per-environment `false` is read and makes that
    environment ineligible. Nothing says the `true` is inert.
13. The merger's retry waits for a mergeable state spelt `NOT_MERGEABLE`, which GitHub never
    reports (`MERGEABLE`, `CONFLICTING`, `UNKNOWN`), and the auto-merge job has no fork condition.
14. The JSON plan exists (`terraform show -json`, with stderr in the same file) but nothing reads it.

The specs are [Configuration-validation.md](Configuration-validation.md) and
[Auto-merge.md](Auto-merge.md).

### Other findings

Recorded while building, not fixed in the step that found them, each waiting for its own change:

- With three stage jobs, every run shows two more `Terraform` entries in its checks, skipped for a
  repository without depends-on; like the skipped test job's unevaluated name, cosmetic. For the
  v1 changes document.
- CI time: on #66 the engine job on the newest Python took 67 minutes, the one on 3.12 38; the
  mutation gate is the long pole (step 8).

- `auto-merge-pr/run_local_step_auto_merge_pr.sh` has carried a private repository's name as its
  default since the action was added; this repository is public. Found in step 5, left for its own
  change.
- `actions/download-artifact@v4` targets Node 20, which the runner now forces onto Node 24 with a
  deprecation warning on every job that downloads; v5 exists.
- On a schedule no environment opted into, and on a dispatch, the relevance notice and the
  conclusion's line still say "nothing to verify for this change", which Dispatch-and-triggers.md
  §5 keeps out of the run summary only.
- With the test stage on and no test files, every pull request and push posts one notice per
  environment without a lock file ("its providers take no part in the test stage").
- `create-validation-summary`'s mode row reads the raw goals, not `goals-granted`; it can say
  "applies on PR" for a pull request against another base branch, where nothing applies.

- Run blocks that paste values straight into shell, with no heredoc: `matrix.vars.github-environment`
  (caller-configured, now held to the name rule by #61) in several steps of the default workflow, `matrix.test-file` in module CI and
  `inputs.test-file` in `terraform-test` (file names from the repository under test), and path
  inputs in `terraform-apply` and `terraform-init`. The same risk family #60 fixes for heredocs;
  GitHub's advice is `env:` for every one. For the maintainer to decide whether it joins the v1
  line.

- The required-fields list lacks `runs-on` and `format-check-in-root-dir`, which the workflow reads
  (Decision-engine.md §9).
- A skipped matrix job shows its unevaluated name: the test job appears as `matrix.test.name` when
  the stage does not run. GitHub does not evaluate a skipped job's matrix name; cosmetic.
- `ubuntu-latest` moving to ubuntu-26.04 brings Python 3.14 to `create-matrix`; the engine is
  standard library only, and CI runs its suite on the newest 3.x as well as the 3.12 floor.
- `verify-terraform-lock`'s test 12 failed once when every suite ran in parallel on one machine and
  passed alone; CI runs each suite in its own job. `capture-matrix-job-meta` did the same in step 3.
  Four suites (`capture-matrix-job-meta`, `create-validation-summary`, `parse-terraform-plan`,
  `verify-terraform-lock`; `evaluate-automerge-eligibility` moved to its own file in step 5) write
  step output to a fixed `/tmp/test_output.txt`, so two of them running at once overwrite each other's;
  a per-suite `mktemp` would end it. `export-env-vars` failed one test once in step 3 and passed on
  every re-run; its output file is fixed too, though named for the suite.
