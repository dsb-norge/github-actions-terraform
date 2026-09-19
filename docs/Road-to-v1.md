# Road to v1

The one document for the next major release of
[`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml): what v1
contains, what changes for a caller, what a caller can newly switch on and whether it should, how a
repository moves, in which order the pieces are built, and how the release is cut. Every spec that
joins v1 appends its rows here in the same change; the document is complete when v1 is tagged.

Status: **living.** Rows marked *pending* belong to specs not yet written.

## 1. Why a major version

The features under specification change what a run does by default: a change outside an
environment's paths no longer plans it, test files run without being wired up, a schedule no
longer applies every environment, and dispatch inputs are read by name. A rolling `v0` tag that
every caller follows automatically cannot carry defaults like that. v1 is a new major tag; callers
move deliberately, one repository at a time, with this document.

## 2. Scope

| Spec | What it brings | Needs it answers |
|---|---|---|
| [Decision-engine.md](Decision-engine.md) | One Python core that decides what a run does, with a decision record, invariants and a 100 percent coverage gate; the port of today's matrix builder | the foundation for everything below |
| [Path-relevance.md](Path-relevance.md) | Per-environment relevance from `paths`, the workflow always runs, the conclusion states when there was nothing to verify | 3, 4 |
| [Terraform-tests.md](Terraform-tests.md) | `terraform test` as a stage: one job per file, credential lanes, GitHub Environments per lane, provider versions inherited from the environments, one summary comment | 1, 2, 10 |
| [Dispatch-and-triggers.md](Dispatch-and-triggers.md) | Run one environment with a chosen goal from a standard dispatch block; per-environment trigger events; schedule opt-in | 9 |
| ordering between environments | *pending* | 5 |
| concurrency queueing | *pending*; candidate for a `v0` minor, see §6 | 6 |
| apply reporting hardening | *pending*; candidate for a `v0` minor, see §6 | 7 |
| notifications | *pending* | 8 |

The required check keeps its name, `tf / Terraform conclusion`, in every spec. Nothing in v1
touches branch protection.

## 3. Breaking changes

What a caller on `v0` must know before changing `@v0` to `@v1`. "Breaking" here means a default or
a rule changed; a caller that does nothing gets the new behaviour.

| Change | v0 | v1 | Action |
|---|---|---|---|
| Relevance per environment | every environment runs on every event | absent `paths` means the standard layout, with `**/*.md` ignored; unaffected environments are skipped and shown as such | remove `on.paths` and `on.paths-ignore` from the calling workflow; review `paths` for an environment that reads files outside `<project-dir>/**`, `main/**`, `modules/**`, the additional init dirs and `.tflint.hcl`; `paths: ["**"]` or `path-relevance-enabled: false` keeps the old behaviour |
| Terraform tests | not run by this workflow | every committed `*.tftest.hcl` runs on pull requests and pushes, one job per file, and a failing one blocks the merge | nothing for a repository without test files; `terraform-test-enabled: false` to opt out; test roots need Terraform 1.12 or later |
| Schedule | a `schedule` on the calling workflow applied every environment | `schedule` is opt-in per environment through `trigger-events` | the two repositories that schedule the workflow add `trigger-events: [pull_request, push, workflow_dispatch, schedule]` to the scheduled environment, then fold the nightly file into the main workflow |
| Dispatch inputs | ignored | `environment`, `goal` and `reason` are read from the calling workflow's `workflow_dispatch.inputs` | add the standard block; a caller whose dispatch block already uses `environment` or `goal` for something else renames its own |
| Runner for `create-matrix` | bash | Python 3.10 or later | nothing on GitHub-hosted runners; a self-hosted pool named in the workflow-level `runs-on` must carry it |
| Validation | a duplicated environment name passed | it is an error | fix the duplicate |
| Unsupported run events | ran with whatever the gates allowed | `merge_group`, `pull_request_target`, `release` and other events are a validation error | trigger only on pull request, push, dispatch and schedule |

## 4. New optional features and recommendations

Everything below is off, or at a safe default, unless a caller switches it on. The recommendation
column is what to do in a standard project repository.

| Feature | Spec | Switch | Recommendation |
|---|---|---|---|
| Path rules per environment | Path-relevance.md §3 | `paths`, `paths-ignore` per environment | Keep `auto`. Add `paths: [auto, "<dir>/**"]` only for an environment that reads a directory outside the standard set. Set `paths-ignore: []` only when a configuration reads Markdown through `file()`. |
| Relevance kill switch | Path-relevance.md D10 | `path-relevance-enabled: false` | Use during migration only, then remove. |
| Auto-merge of docs-only pull requests | Path-relevance.md §8 | existing `pr-auto-merge-*` inputs | Nothing new to set; a docs-only change is eligible under the same actor and enabled checks. |
| Test lanes | Terraform-tests.md §3.2 | `terraform-test-lanes-yml` | One lane per identity. Keep unit tests in a lane with no credentials and name them `unit-*`. |
| GitHub Environment per lane | Terraform-tests.md §3.6 | `github-environment: auto` on a lane | Use it for every credentialed lane: secrets scoped to the lane, a lane-specific OIDC subject, no admin needed to fill it. Never add protection rules to a `tftest-*` environment. |
| Tolerated test failures | Terraform-tests.md D3 | `allow-failing-terraform-tests`, globally or per lane | Only while a lane is being brought up. |
| Test runner and timeout | Terraform-tests.md §3.1 | `terraform-test-runs-on`, `terraform-test-timeout-minutes`, per lane | Keep `ubuntu-latest`; set `runs-on` on a lane only when it must reach a restricted network. Keep timeouts short: a killed test leaves objects nothing can destroy. |
| Test file exclusions | Terraform-tests.md §3.1 | `terraform-test-exclude-paths-yml` | Add `envs/**` if anyone places test files in environment directories; tests belong at the repository root or beside modules. |
| Provider sets for tests | Terraform-tests.md §5.3 | `providers-from` per lane | Leave unset; one job per distinct environment lock set is the point. Narrow only for a lane whose module is used by one environment. |
| Module cache for tests | Terraform-tests.md §5.3 | `cache-terraform-modules`, per lane | Keep on. |
| Standard dispatch block | Dispatch-and-triggers.md §3.1 | copy the block into the calling workflow | Do it in every repository, even ones that never dispatch today; it is the recovery button. Use `reason`. |
| Trigger events | Dispatch-and-triggers.md §3.2 | `trigger-events-yml`, `trigger-events` per environment | Leave the default. Opt exactly the environments that should reconcile nightly into `schedule`. |
| Environment grouping in comments | Workflow-pr-comments.md | `pr-comment-group` | Group environments when a repository has more than three; unaffected environments then take one column, not one comment. |
| ordering between environments | *pending* | | |
| notifications | *pending* | | |

## 5. Migration checklist per repository

1. Read §3 and note which rows apply; read §4 and decide which features to switch on now.
2. On a branch: change `@v0` to `@v1` in every calling workflow file; remove `on.paths` and
   `on.paths-ignore`; add the dispatch block; add `trigger-events` where a schedule exists; add
   lanes if the repository has credentialed tests.
3. Open a pull request that touches only documentation and confirm a green conclusion with every
   environment "not affected". Then one that touches one environment. Then, if tests exist, one
   that breaks a test and confirm the conclusion goes red.
4. Merge and read the first push run's summary: the decision record says why each environment ran
   or did not.
5. Delete the workflow files the move made redundant: a path-filtered second workflow, a nightly
   file.
6. For credentialed test lanes, complete the environment bring-up of Terraform-tests.md §3.6 and
   re-run the failed jobs.

## 6. Implementation order across specs

Each spec has its own commit order; this is the order of the specs, and where a piece can go out
early.

| Step | What | Why here |
|---|---|---|
| 0 | Concurrency `queue: max` and the apply-reporting invariant and fixtures (needs 6 and 7, specs pending) as **`v0` minors** | Both are additive and safe on the rolling tag; callers get them without waiting for v1, and v1 inherits them. To be confirmed when those specs are written. |
| 1 | Decision-engine.md §12: the engine, the port behind goldens, the shim, CI discovery | Everything after this puts logic into the engine; building features in bash first means writing them twice. |
| 2 | Path-relevance.md §15: relevance rules, adapter, seed and aggregator changes, the conclusion rewrite, auto-merge | The conclusion rewrite is what the other stages' `needs` entries depend on, and it fixes the blocked pull request. |
| 3 | Terraform-tests.md §13: the test stage, lanes, environments, provider sets, summary | Depends on the conclusion table and the engine. |
| 4 | Dispatch-and-triggers.md §11: trigger events, dispatch, the `goals-granted` gate switch | Depends on the engine; the smallest of the four. |
| 5 | Ordering, notifications (specs pending) | Ordering depends on relevance and dispatch; notifications on the metadata all stages produce. |
| 6 | Tag v1 | After every spec's open questions are closed on the test-bed and the specs read as built (§8). |

## 7. Release mechanics

- v1 is cut as [Development-and-release.md](Development-and-release.md) describes for a major
  release: a new annotated tag, no force-move. Its annotation starts a fresh changelog. Every
  v1 minor after that moves `v1` the way `v0` moves today.
- Preview refs work unchanged for pull requests on the v1 line; the test-bed calling repository
  is switched to `@preview/pr-<n>` for each verification.
- `v0` stays at its last minor. Policy to record when decided: the recommendation is fixes only
  for a stated period after v1 is tagged, no features, and the two `v0` minors of §6 step 0 before
  the freeze.
- The project template moves to `@v1` and gains the dispatch block; the module template is
  unaffected until the module CI workflow migrates.

## 8. How the specs are written

- A spec describes the system **as built**. While its feature is unimplemented it carries a
  status line saying so and an open-questions section; when implementation and the test-bed run
  have closed those questions, the status line goes, the text stays in the present tense, the
  decisions section remains as the record, and "what implementation taught the spec" holds what
  changed.
- A spec that changes a default, adds an input, or asks a caller to do something appends its rows
  to §3, §4, §5 and §6 here in the same change.
- Public repository: no internal repository, tenant or environment names anywhere in `docs/`.

## 9. Status

| Spec | Decided | Implemented | Verified on the test-bed | As built |
|---|---|---|---|---|
| Decision-engine.md | yes | no | no | no |
| Path-relevance.md | yes | no | no | no |
| Terraform-tests.md | yes | no | no | no |
| Dispatch-and-triggers.md | yes | no | no | no |
| ordering between environments | no | | | |
| concurrency queueing | no | | | |
| apply reporting hardening | no | | | |
| notifications | no | | | |

## 10. Open cross-cutting questions

1. Which of needs 6 and 7 ship as `v0` minors before the freeze (§6 step 0).
2. The `v0` support period after v1 (§7).
3. Whether the module CI workflow moves to the engine and the test summary in v1 or after.
