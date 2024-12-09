# DSB's github actions for terraform

Collection of DSB custom GitHub actions and reusable workflows for terraform projects.  
For workflow and development documentation refer to the [docs](/docs).

## Actions

The actions are used by the CI/CD workflow(s) in [.github/workflows](.github/workflows).  

```text
.
├── create-test-report            --> creates comment report with terraform test action results
├── create-tf-vars-matrix         --> creates common DSB terraform CI/CD variables
├── create-tftest-matrix          --> creates matrix for running terraform module test
├── create-validation-summary     --> creates summary comment in table format
├── export-env-vars               --> export environment variables for use in subsequent action steps
├── lint-with-tflint              --> run linting of terraform code with TFLint
├── setup-terraform-plugin-cache  --> setup and configure plugin cache on runners
├── setup-tflint                  --> install TFLint and make available to subsequent action steps
├── terraform-docs                --> inject terraform-docs config and terraform module documentation into README.md
├── terraform-fmt                 --> checks if terraform code is formatted
├── terraform-plan                --> run terraform plan in directory
├── terraform-apply               --> run terraform apply in directory
└── terraform-test                --> run terraform test in directory
```

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
