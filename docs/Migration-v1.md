# Migrating a caller from v0 to v1

Living guide for a calling repository moving from
`dsb-norge/github-actions-terraform/.github/workflows/terraform-ci-cd-default.yml@v0` to `@v1`.
Every spec that changes a default or asks something of callers appends its rows here; the guide is
complete when v1 is tagged, not before.

Status: **draft, grows with the specs.** Nothing here is released.

## 1. Why a major version

The features under specification change what a run does by default: a change outside an
environment's paths no longer plans it, test files run without being wired up, a schedule no
longer applies every environment, and dispatch inputs are read by name. A rolling `v0` tag that
every caller follows automatically cannot carry defaults like that. v1 is a new major tag; callers
move deliberately, one repository at a time, with this guide.

`v0` stays at its last minor. What it receives after v1 is tagged is a policy decision recorded
here once made: the recommendation is fixes only, for a stated period, and no new features.

## 2. What changes for a caller

| Change | v0 | v1 | What to do |
|---|---|---|---|
| Relevance per environment ([Path-relevance.md](Path-relevance.md)) | every environment runs on every event; path filtering only via `on.paths` on the calling workflow | absent `paths` means the standard layout (`<project-dir>/**`, `main/**`, `modules/**`, additional init dirs, `.tflint.hcl`), with `**/*.md` ignored; unaffected environments are skipped and reported | remove `on.paths` / `on.paths-ignore` from the calling workflow; review each environment's `paths` if it reads files outside the standard set; `paths: ["**"]` or `path-relevance-enabled: false` restore the old behaviour |
| The conclusion check ([Path-relevance.md](Path-relevance.md) §7) | pending forever when the workflow was skipped by `on.paths` | always reports; green when nothing needed verifying | nothing beyond removing `on.paths`; docs-only pull requests merge without a dummy commit; the check name is unchanged |
| Terraform tests ([Terraform-tests.md](Terraform-tests.md)) | none in this workflow | every committed `*.tftest.hcl` runs, one job per file, on pull requests and pushes | nothing if the repository has no test files; `terraform-test-enabled: false` to opt out; lanes and `tftest-*` environments for credentialed tests; Terraform 1.12 or later for test roots |
| Schedule ([Dispatch-and-triggers.md](Dispatch-and-triggers.md)) | a `schedule` on the calling workflow applied every environment | `schedule` is opt-in per environment through `trigger-events` | the two repositories that schedule the workflow add `trigger-events: [pull_request, push, workflow_dispatch, schedule]` to the scheduled environment; their nightly file can then fold into the main workflow |
| Dispatch ([Dispatch-and-triggers.md](Dispatch-and-triggers.md)) | ran every environment with `goals-yml` | reads `environment`, `goal` and `reason` from the calling workflow's `workflow_dispatch.inputs` | add the standard inputs block from the guide; a caller whose dispatch block already uses `environment` or `goal` for something else renames its own |
| Matrix builder ([Decision-engine.md](Decision-engine.md)) | bash and `jq` | a Python core; `create-matrix` needs Python 3.10 or later on its runner | nothing on GitHub-hosted runners; a self-hosted pool named in the workflow-level `runs-on` must carry Python 3.10 |
| Validation strictness ([Decision-engine.md](Decision-engine.md) §9) | a duplicated environment name was not detected | it is an error | fix the duplicate |

## 3. Checklist per repository

1. Read §2 and note which rows apply.
2. On a branch, change `@v0` to `@v1` in every calling workflow file, remove `on.paths` and
   `on.paths-ignore`, add the dispatch inputs block, and add `trigger-events` where a schedule
   exists.
3. Open a pull request that touches only documentation and confirm it reports a green conclusion
   with every environment "not affected". Then one that touches one environment.
4. Merge, and watch the first push run's summary: the decision record says why each environment
   ran or did not.
5. Delete the workflow files the move made redundant (a path-filtered second workflow, a nightly
   file).

## 4. Release procedure notes

- v1 is tagged as [Development-and-release.md](Development-and-release.md) describes for a major
  release; preview refs work for v1 branches unchanged.
- The `v1` major tag's annotation starts a fresh changelog; `v0`'s is left as it is.
- The project template moves to `@v1` and gains the dispatch inputs block.

## 5. Specs still to append rows

Ordering between environments, concurrency queueing, apply reporting, notifications.
