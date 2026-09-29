# Documentation

Start with the row that fits what you are doing; every document in this folder is listed below,
once, under the kind of document it is.

| You want to … | Read |
|---|---|
| call the default workflow from a Terraform project repository | [Workflow-terraform-ci-default.md](Workflow-terraform-ci-default.md) |
| set up CI and releases for a Terraform module repository | [Workflow-terraform-module-ci.md](Workflow-terraform-module-ci.md), [Workflow-terraform-module-release.md](Workflow-terraform-module-release.md) |
| move a repository from `@v0` to `@v1` | [Migration-v0-to-v1.md](Migration-v0-to-v1.md) (project) or [Migration-v0-to-v1-modules.md](Migration-v0-to-v1-modules.md) (module), and [V1-changes.md](V1-changes.md) |
| understand why a run did what it did | [Decision-engine.md](Decision-engine.md), then the spec of the feature concerned |
| change an action or a workflow in this repository | [Development-and-release.md](Development-and-release.md) and [Action-implementation-guide.md](Action-implementation-guide.md) |

## Kinds of document

- **User guide.** How to call a workflow: inputs, configuration and worked examples. Written for
  the maintainers of calling repositories.
- **Migration.** What changed between two major versions and how to move a calling repository.
- **Spec.** The authoritative description of one feature as built: its design, the decisions and
  their reasons, the pitfalls met (`P<n>`) and how it is tested. Written for whoever changes the
  feature; a spec and its code change together.
- **Contributor guide.** How this repository is developed, tested and released.

## User guides

| Document | Covers |
|---|---|
| [Workflow-terraform-ci-default.md](Workflow-terraform-ci-default.md) | The default workflow for Terraform projects: every input, `environments-yml`, and worked examples from a single environment to ordered stages, dispatch and test lanes. |
| [Workflow-terraform-module-ci.md](Workflow-terraform-module-ci.md) | The module workflow: terraform-docs, validation, `terraform test` with or without credentials. |
| [Workflow-terraform-module-release.md](Workflow-terraform-module-release.md) | The module release workflow: release-please and the App token. |

## Migration

| Document | Covers |
|---|---|
| [V1-changes.md](V1-changes.md) | Every change a caller meets from v0.33 to v1, breaking or not, with the reason. |
| [Migration-v0-to-v1.md](Migration-v0-to-v1.md) | Moving a project repository to `@v1`, step by step, with validation, rollback and pitfalls. |
| [Migration-v0-to-v1-modules.md](Migration-v0-to-v1-modules.md) | The same for a module repository. |

## Specs

The engine and what it decides:

| Document | Covers |
|---|---|
| [Decision-engine.md](Decision-engine.md) | The Python engine behind `create-tf-vars-matrix`: the input and output documents, the rules in order, the invariants and the test kinds. |
| [Configuration-validation.md](Configuration-validation.md) | What the engine accepts from a caller, and the error each mistake gets. |
| [Dispatch-and-triggers.md](Dispatch-and-triggers.md) | Which events each environment takes part in, and what a manual dispatch may run. |
| [Path-relevance.md](Path-relevance.md) | Which environments a change is relevant to, and the `Terraform conclusion` check. |
| [Environment-ordering.md](Environment-ordering.md) | `depends-on`: one environment applying before another, in up to three stages. |

Stages and features:

| Document | Covers |
|---|---|
| [Terraform-tests.md](Terraform-tests.md) | The `terraform test` stage: discovery, lanes, credentials, provider sets and the summary. |
| [Module-ci.md](Module-ci.md) | The module workflow's design: the engine's module mode and the jobs shared with the default workflow. |
| [Terraform-module-cache.md](Terraform-module-cache.md) | Caching downloaded Terraform modules across runs. |
| [Per-goal-environment-variables.md](Per-goal-environment-variables.md) | Environment variables and secrets that apply to one goal only. |
| [Auto-merge.md](Auto-merge.md) | Merging a pull request automatically when its plan stays within limits. |

Reporting:

| Document | Covers |
|---|---|
| [Workflow-pr-comments.md](Workflow-pr-comments.md) | Every pull-request comment the default workflow writes: markers, lifecycle and body shapes. |
| [Apply-and-destroy-reporting.md](Apply-and-destroy-reporting.md) | How apply, destroy plan and destroy results reach the comments, annotations and step summaries. |
| [Plan-warnings.md](Plan-warnings.md) | Terraform `Warning:` diagnostics in comments and annotations. |

## Contributor guides

| Document | Covers |
|---|---|
| [Development-and-release.md](Development-and-release.md) | Testing a change from a calling repository, validating on a test bed, release lines and tags, documentation conventions. |
| [Action-implementation-guide.md](Action-implementation-guide.md) | How a composite action is laid out, written and tested, and the traps that shaped the rules. |
| [Testing-in-ci.md](Testing-in-ci.md) | The workflow that runs every suite on a pull request, the sharded mutation gate and the results comment. |
| [Preview-refs.md](Preview-refs.md) | The `preview/pr-<N>` tags that let a calling repository run a pull request's code. |

Outside this folder: [CHANGELOG.md](../CHANGELOG.md) lists every release and what it changed,
and [contract-tests/](../contract-tests/README.md) runs real Terraform weekly to prove the console
parsers' fixtures still match what Terraform prints.

A new document gets a row here, under its kind, in the change that adds it.
