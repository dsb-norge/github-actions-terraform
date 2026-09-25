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
| 3 | Terraform tests: the test stage, lanes, environments, provider sets, summary | — (branch `feat/terraform-tests`: the spec updated with the open-question probes) | paused before implementation, pending the Entra and Azure questions of §3 | no |
| 4 | Dispatch and trigger events; the `goals-granted` gate switch | — | outstanding | no |
| 5 | Environment ordering: stage assignment, the three stage jobs, held-back reporting | — | outstanding | no |
| 6 | v1 released to callers: minors begin, migration guide complete, templates on `@v1` | — | outstanding | — |

### Outside the road steps

Changes the road does not list, made on the v1 line because a step's review surfaced them.

| What | Pull request | State | In `v1` |
|---|---|---|---|
| Heredoc captures hardened: free text (`pr-comment`'s body, `pr-comments-reconcile`'s YAML, the module cache's paths) captured as `toJSON` of the input, out of envp; every capture under a unique delimiter; structural test F9; the implementation guide's input rule | [#60](https://github.com/dsb-norge/github-actions-terraform/pull/60) | merged 2026-09-24 | yes |
| The engine reviewed for what should change after the port: per-environment values of workflow inputs take the inputs' types (per-environment booleans were silently ignored by the gates), environment names follow one rule, one environment per github-environment | [#61](https://github.com/dsb-norge/github-actions-terraform/pull/61) | merged 2026-09-24 | yes |

## 2. Status per spec

| Spec | Decided | Implemented | Verified on the test bed | As built |
|---|---|---|---|---|
| Decision-engine.md | yes | the port (#59); rule 4 and the comment manifest (#62); rules 2, 3, 5 and 6 come with steps 3-5 | the port, #59 (§4): identical matrices to `@v0` | the port, relevance and the manifest |
| Path-relevance.md | yes | yes (#62) | the §9 scenarios on pull requests and pushes (§4); auto-merge by tests only | yes |
| Terraform-tests.md | yes; D20 (discovery in the create-matrix adapter) and D21 (one test job) added 2026-09-25 | no | probes only (see §3) | no |
| Dispatch-and-triggers.md | yes | no | dispatch inputs inside a called workflow, `schedule` actor | no |
| Environment-ordering.md | yes | no | mechanics (anchors across matrix jobs, guard conditions) | no |
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
| Dispatch-and-triggers.md | may the global `trigger-events-yml` include `schedule` | **for the maintainer to decide**, before step 4 |
| Dispatch-and-triggers.md | a later `test-file` dispatch input | deferred by the spec |
| Terraform-tests.md | the step anchor, `artifact-url`, `hashFiles` on a matrix path, `pr-comment` delete matching, an environment root with a real backend, job-name length, an empty environment name, `deployment: false` and the token subject, environment secrets in a called job, the may-break value, init with a copied lock, the module cache from a test root | closed 2026-09-25 by test-bed probes, a local Terraform 1.16 lab and the documentation; answers in the spec's text. Corrections: one test job (D21), the module cache needs a new input (§9.9), git sources are impossible in run blocks, read-only init fails an environment root whose tests need an extra provider |
| Terraform-tests.md | isolation end to end; a real environment lane; case in flexible credential `matches`; the role that sets environment secrets; Dependabot runs and OIDC; fork runs and environment creation; the copied lock and the runner's platform; the shared plugin-cache key; the step anchor in the web view | open (spec §12): the first three need Entra and Azure, the next three a write-role account, a Dependabot pull request and a fork, two are design choices for the maintainer, one needs a browser |
| Environment-ordering.md | held-back finalisation; hand-off latency | open, answered in step 5 |
| Road-to-v1.md | the v0 support period | closed: fixes only on `release/v0` until the last caller moves (Road-to-v1.md §7) |
| Road-to-v1.md | the module CI workflow on the engine in v1 or after | open |

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

## 5. Findings to carry

Recorded while building, not fixed in the step that found them, each waiting for its own change:

- Run blocks that paste values straight into shell, with no heredoc: `matrix.vars.github-environment`
  (caller-configured, now held to the name rule by #61) in several steps of the default workflow, `matrix.test-file` in module CI and
  `inputs.test-file` in `terraform-test` (file names from the repository under test), and path
  inputs in `terraform-apply` and `terraform-init`. The same risk family #60 fixes for heredocs;
  GitHub's advice is `env:` for every one. For the maintainer to decide whether it joins the v1
  line.

- The required-fields list lacks `runs-on` and `format-check-in-root-dir`, which the workflow reads
  (Decision-engine.md §9).
- `ubuntu-latest` moving to ubuntu-26.04 brings Python 3.14 to `create-matrix`; the engine is
  standard library only, and CI runs its suite on the newest 3.x as well as the 3.12 floor.
- The tests spec describes its fact-gathering (`create-tftest-matrix`) as a composite shim; under
  Decision-engine.md D13 it becomes an adapter-side module unless something outweighs it, as
  relevance's did (Path-relevance.md D12). Decide when step 3 starts.
- `verify-terraform-lock`'s test 12 failed once when every suite ran in parallel on one machine and
  passed alone; CI runs each suite in its own job. Worth a look if it recurs.
