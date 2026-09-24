# DSB's github actions for terraform

Collection of DSB custom GitHub actions and reusable workflows for terraform projects.  
For workflow and development documentation refer to the [docs](/docs).

## Actions

The actions are used by the CI/CD workflow(s) in [.github/workflows](.github/workflows).  

```text
.
├── annotate-terraform-outcome    --> per-env job-summary block + ::notice/::error for apply and destroy outcomes
├── create-run-summary            --> run-level table of every environment on the run page
├── create-test-report            --> renders the terraform test report body for the module-ci PR comment (body-file)
├── create-tf-vars-matrix         --> creates the environment matrix and decides which environments a change is relevant to (runs the engine's create-matrix adapter)
├── create-tftest-matrix          --> creates matrix for running terraform module test
├── create-validation-summary     --> renders the per-env head, plan/apply/destroy-plan/destroy tag bodies and job-summary block (as files)
├── export-env-vars               --> export environment variables for use in subsequent action steps
├── lint-with-tflint              --> run linting of terraform code with TFLint
├── parse-terraform-apply         --> parses apply/destroy console output: counts, completed flag, tick-free copy
├── pr-comment                    --> upsert/delete a single PR/issue comment by HTML marker (body or body-file)
├── pr-comments-reconcile         --> bulk seed + GC PR/issue comments by HTML marker
├── setup-terraform-plugin-cache  --> setup and configure plugin cache on runners
├── setup-tflint                  --> install TFLint and make available to subsequent action steps
├── terraform-docs                --> inject terraform-docs config and terraform module documentation into README.md
├── terraform-fmt                 --> checks if terraform code is formatted
├── terraform-plan                --> run terraform plan in directory
├── terraform-apply               --> run terraform apply in directory
└── terraform-test                --> run terraform test in directory
```

The decision engine the matrix is built by lives in [engine](engine), a Python 3.12+ standard-library
package with its own test suite: [docs/Decision-engine.md](docs/Decision-engine.md).
Which environments a pull request or push runs is its path relevance:
[docs/Path-relevance.md](docs/Path-relevance.md).

## Workflows

```text
.
└── .github/workflows                           --> directory for reusable workflows
    ├── terraform-terraform-ci-cd-default.yml   --> default ci/cd workflow for DSB's 
    ├── terraform-module-release                --> tag and release module. Creates release plan PR. 
    └── terraform-module-ci                     --> default ci workflow for module testing
    terraform projects
```

### Workflow [`terraform-ci-cd-default`](.github/workflows/terraform-ci-cd-default.yml)

Default DSB CI/CD workflow for terraform projects that performs various operations depending on from what github event it was called and given input.
See [docs](docs/Workflow-terraform-ci-default.md) for workflow information, configuration and behavior.

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
