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
| 1 | The decision engine: the port behind goldens, the create-matrix adapter, both gates, the Python 3.12 floor tested in CI; `main` becomes the v1 line (internal refs `@v1`) | [#59](https://github.com/dsb-norge/github-actions-terraform/pull/59) | draft | no |
| 2 | Path relevance: rules, adapter, seed and aggregator changes, the conclusion rewrite, auto-merge | — | outstanding | no |
| 3 | Terraform tests: the test stage, lanes, environments, provider sets, summary | — | outstanding | no |
| 4 | Dispatch and trigger events; the `goals-granted` gate switch | — | outstanding | no |
| 5 | Environment ordering: stage assignment, the three stage jobs, held-back reporting | — | outstanding | no |
| 6 | v1 released to callers: minors begin, migration guide complete, templates on `@v1` | — | outstanding | — |

## 2. Status per spec

| Spec | Decided | Implemented | Verified on the test bed | As built |
|---|---|---|---|---|
| Decision-engine.md | yes | the port (#59); rules 2-6 come with steps 2-5 | the port, #59 (§4): identical matrices to `@v0` | the port |
| Path-relevance.md | yes | no | the empty-matrix short-circuit and the push payload fields | no |
| Terraform-tests.md | yes | no | no | no |
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
| Path-relevance.md | `changed_files` accuracy; re-run check attempt; the `created` improvement | open, answered in step 2 |
| Dispatch-and-triggers.md | `github.event.inputs` inside a called workflow | closed: the caller's inputs; `null` without a block; empty strings absent (test-bed probe) |
| Dispatch-and-triggers.md | `github.actor` on `schedule` | closed, as above |
| Dispatch-and-triggers.md | callers with dispatch inputs named `environment`, `goal`, `reason` | closed: none (survey of the callers) |
| Dispatch-and-triggers.md | may the global `trigger-events-yml` include `schedule` | **for the maintainer to decide**, before step 4 |
| Dispatch-and-triggers.md | a later `test-file` dispatch input | deferred by the spec |
| Terraform-tests.md | seventeen items (§12) | open, answered in step 3 |
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

## 5. Findings to carry

Recorded while building, not fixed in the step that found them, each waiting for its own change:

- The required-fields list lacks `runs-on` and `format-check-in-root-dir`, which the workflow reads
  (Decision-engine.md §9).
- A per-environment YAML boolean stays a JSON boolean in `vars`, so `format-check-in-root-dir:
  false` per environment does not do what it says (Decision-engine.md P11). Retyping is its own
  change with a release note.
- `ubuntu-latest` moving to ubuntu-26.04 brings Python 3.14 to `create-matrix`; the engine is
  standard library only, and CI runs its suite on the newest 3.x as well as the 3.12 floor.
- The relevance and tests specs describe their fact-gathering (`resolve-changed-files`,
  `create-tftest-matrix`) as composite shims; under Decision-engine.md D13 they become adapter-side
  modules unless something outweighs it. Decide when each step starts.
