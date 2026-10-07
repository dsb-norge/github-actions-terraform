# DSB's github actions for terraform

Collection of DSB custom GitHub actions and reusable workflows for terraform projects.  
For workflow and development documentation start at the [documentation index](docs/README.md).
Every release, and what it changed: [CHANGELOG.md](CHANGELOG.md). Pin `@v1` to follow v1's releases, or an exact release such as `@v1.2.0`.

## Actions

The actions are used by the CI/CD workflow(s) in [.github/workflows](.github/workflows).  

```text
.
├── aggregate-validation-summaries  --> reconciles the per-group validation summary PR comments from the matrix jobs' metadata artifacts
├── annotate-terraform-outcome      --> per-env job-summary block + ::notice/::error for apply and destroy outcomes
├── auto-merge-pr                   --> merges an eligible pull request with the rebase strategy
├── capture-matrix-job-meta         --> captures a matrix job's step outputs, outcomes and matrix context into one JSON file for artifact upload
├── create-run-summary              --> run-level table of every environment on the run page
├── create-test-summary             --> one structured summary of the terraform test stage, for both workflows (PR comment and run summary)
├── create-tf-vars-matrix           --> creates the environment matrix and decides which environments a change is relevant to; in mode module, a module's test matrix (runs the engine's create-matrix adapter)
├── create-validation-summary       --> renders the per-env head, plan/apply/destroy-plan/destroy tag bodies and job-summary block (as files)
├── decide-notifications            --> decides what a run tells Teams: the events, their messages and one deliver row each (runs the engine)
├── evaluate-automerge-eligibility  --> decides whether a pull request may be auto-merged, from the plans' changes, the limits and the actor
├── export-env-vars                 --> export environment variables and secrets (by mapping or by name prefix) for subsequent steps
├── lint-with-tflint                --> run linting of terraform code with TFLint
├── parse-terraform-apply           --> parses apply/destroy console output: counts, completed flag, tick-free copy
├── parse-terraform-plan            --> counts what a plan adds, changes, destroys, imports, moves and removes
├── parse-terraform-warnings        --> annotates and summarises the Warning: blocks in a terraform console output
├── post-teams-notification         --> posts one markdown text message to a Teams notification relay, with bounded retries; never fails the job
├── pr-comment                      --> upsert/delete a single PR/issue comment by HTML marker (body or body-file)
├── pr-comments-reconcile           --> bulk seed + GC PR/issue comments by HTML marker
├── record-notifications            --> merges a run's notifications and the relay's answers into the incident state (runs the engine)
├── resolve-goal-envs               --> resolves the environment variables of every terraform goal (global and per-goal maps, secrets expanded)
├── setup-terraform-plugin-cache    --> setup and configure plugin cache on runners
├── setup-tflint                    --> install TFLint and make available to subsequent action steps
├── terraform-docs                  --> inject terraform-docs config and terraform module documentation into README.md
├── terraform-fmt                   --> checks if terraform code is formatted
├── terraform-init                  --> run terraform init in directory, and in additional directories
├── terraform-module-cache          --> decides what of terraform's .terraform/modules trees may be cached, under what key
├── terraform-plan                  --> run terraform plan in directory
├── terraform-apply                 --> run terraform apply in directory
├── terraform-test                  --> run and classify one terraform test file (the test stage of both workflows)
├── terraform-validate              --> run terraform validate in directory
└── verify-terraform-lock           --> fails if .terraform.lock.hcl lacks h1: hashes for a required platform
```

The decision engine the matrix is built by lives in [engine](engine), a Python 3.12+ standard-library
package with its own test suite: [docs/Decision-engine.md](docs/Decision-engine.md).
Which environments a pull request or push runs is its path relevance:
[docs/Path-relevance.md](docs/Path-relevance.md).

## Workflows

```text
.
└── .github/workflows                     --> directory for reusable workflows
    ├── terraform-ci-cd-default.yml       --> default ci/cd workflow for DSB's terraform projects
    ├── terraform-module-release.yaml     --> tag and release module. Creates release plan PR.
    └── terraform-module-ci.yaml          --> default ci workflow for module testing
```

### Workflow [`terraform-ci-cd-default`](.github/workflows/terraform-ci-cd-default.yml)

Default DSB CI/CD workflow for terraform projects that performs various operations depending on from what github event it was called and given input.
See [docs](docs/Workflow-terraform-ci-default.md) for workflow information, configuration and behavior.
Moving from `@v0` to `@v1`: [Migration-v0-to-v1.md](docs/Migration-v0-to-v1.md) for a project repository, [Migration-v0-to-v1-modules.md](docs/Migration-v0-to-v1-modules.md) for a module repository, and every change in [V1-changes.md](docs/V1-changes.md).

### Workflow [`terraform-module-ci`](.github/workflows/terraform-module-ci.yaml)

This GitHub Actions workflow is designed for Continuous Integration (CI) of Terraform modules.  
See [docs](docs/Workflow-terraform-module-ci.md) for workflow information, configuration and behavior. 

### Workflow [`terraform-module-release`](.github/workflows/terraform-module-release.yaml)

Workflow for release of terraform modules (Semver tag + github release).  
See [docs](docs/Workflow-terraform-module-release.md) for workflow information, configuration and behavior.  

## Development and maintenance

- [Development-and-release.md](docs/Development-and-release.md) — testing a PR from a calling repo (preview refs), cutting a release, moving the major tag.
- [Preview-refs.md](docs/Preview-refs.md) — how `pr-preview.yml` publishes a `preview/pr-<N>` tag for every PR, and the one-time GitHub App bootstrap.
- [Testing-in-ci.md](docs/Testing-in-ci.md) — the per-action test suites that gate every PR.
- [contract-tests/](contract-tests/README.md) — real terraform, the newest `newest-minors` minors (six today), weekly: proves the console parsers' fixtures are still what terraform prints (`.github/workflows/terraform-contract-tests.yml`).
- [Action-implementation-guide.md](docs/Action-implementation-guide.md) — how a composite action in this repo is built and tested.
