# Workflow [`terraform-module-ci`](../.github/workflows/terraform-module-ci.yaml)

This GitHub Actions workflow is designed for Continuous Integration (CI) of Terraform modules.

## Requirements

- The calling workflow must grant the following permissions:

```text
   permissions:
     id-token: write       # Required for Azure password-less authentication
     contents: write        # Required for actions/checkout and to update readme by PR.
     pull-requests: write  # Required for commenting on PRs
```

- Additionally an app must be installed in the GitHub organization with read+write access to the calling repository. Metadata for this app is expected as follows:
  - Action variables:
    - vars.ORG_TF_CICD_APP_IDSTALLATION_ID
  - Action secrets:
    - secrets.ORG_TF_CICD_APP_PRIVATE_KEY

**Note:** for more details about the app see [workflows/terraform-module-ci.yaml](../.github/workflows/terraform-module-ci.yaml)

### Inputs

- terraform-version: The version of Terraform to use for the tests (required).
- tflint-version: The version of tflint (required)
- readme-file-path: path to README.md file. By default repo root used.

### Secrets

There are two possibilities to pass secrets to this action.
Either use of ```secrets: inherit``` or through environment variables:

- ARM_TENANT_ID: Azure Tenant ID (from REPO secrets)
- ARM_SUBSCRIPTION_ID: Azure Subscription ID (from REPO secrets)
- ARM_CLIENT_ID: Azure Service Principal Client ID (from REPO secrets)

Env variables below are required.

- ARM_USE_OIDC: Enable OIDC for Azure authentication
- ARM_USE_AZUREAD: Enable Azure AD for authentication
- TF_IN_AUTOMATION: Set to true to indicate Terraform is running in automation

### Jobs

 1. create-matrix:
    - Steps:
      - Clean workspace
      - Checkout working branch
      - Create job matrix that contains list of test files to run ( for parallelism ).
      - Setup Terraform
      - install tfflint
      - Setup terraform  provider plugin cache
      - Terraform Init
      - Terraform Format
      - Terraform Validate
      - tflint
      - Create init report
      - Add validation summary as pull request comment
      - Validate outcomes of init, validate, format and tflint steps

 2. terraform-module-ci:
    - Steps:
      - Checkout working branch
      - Setup Terraform
      - Terraform Test
      - Create test report
      - Add validation summary as pull request comment
      - Validate outcomes of init and test

 3. generate-docs:
    - Steps:
      - Checkout working branch
      - Terraform-docs
      - Validate outcome of terraform-docs

 4. conclusion:
    - Steps:
      - Exit with status 1 if any of the previous jobs failed or were cancelled

### Example

```yaml
name: "Terraform module CI"

on:
  pull_request:
    branches:
      - main
    types: [opened, synchronize, reopened]
  workflow_dispatch: # allows manual build

jobs:
  tf:
    uses: dsb-norge/github-actions-terraform/.github/workflows/terraform-module-ci.yaml@v0
    secrets: inherit
    permissions:
      contents: write # required for checkout action.
      id-token: write # required for Azure password-less login
      pull-requests: write # required for commenting on PR
    with:
      terraform-version: "1.11.x"
      tflint-version: "v0.55.1"
```