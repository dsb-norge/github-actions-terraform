# Workflow [`terraform-ci-cd-default`](../.github/workflows/terraform-ci-cd-default.yml)  

Default DSB CI/CD workflow for terraform projects that performs various operations depending on from what github event it was called and given input. Default behavior (when not modified by inputs):

1. Install `latest` version of terraform
2. Install `latest` version of TFLint
3. Run `terraform init`
4. Run `terraform fmt -check`
5. Run `terraform validate`
6. Perform linitng with TFLint
7. If `terraform init` was successful, run `terraform plan`
8. If called from `pull_request` event, reconcile PR comments (per-env validation summaries and a per-env plan extract, plus optional per-group rolled-up tables). Heads are pre-allocated at the top of the run in deterministic order and PATCHed in place across runs; plan tags are GC'd between runs. See [Workflow-pr-comments.md](./Workflow-pr-comments.md) for the full spec, including the heads + tags model and the optional `pr-comment-group` field that collapses several envs into one combined-table head
9. If any of the steps `init`, `format`, `validate`, `lint` or  `plan` failed, stop the  workflow with a failure
10. If called from either of events `push` or `workflow_dispatch` on the default branch of the calling repo and `plan` step was successful, run `terraform apply`. I.e. the default is to perform terraform apply when merging PRs.

What steps to execute and when can be modified using the input `goals-yml`, see description pf the input documented in the [workflow](.github/workflows/terraform-ci-cd-default.yml).

#### **Inputs**

All inputs are documented in the [workflow declaration](.github/workflows/terraform-ci-cd-default.yml).

The input `environments-yml` is required all others are optional, see description of each in the [workflow declaration](.github/workflows/terraform-ci-cd-default.yml).

##### **`environments-yml`**

Specification of environments to run this terraform workflow and it's stages for. Minimum 1 environment must be specified.

Type: YAML list (as string) with specifications of environments to execute stages for.

Given that this is a list of environments (potentially with differing configuration), multiple entries in this list will cause parallel GitHub jobs to be spawned.

Only one field is required for each entry in this yaml list: **`environment`** - string. Using default behavior this is the name of a directory found within the `/envs` directory in the root of the calling repo. This directory is where all workflow steps are executed.

**Example** have the workflow execute steps within `/envs/my-tf-environment` of the calling repo:

```yaml
environments-yml: |
  - environment: "my-tf-environment"
```

See more examples under [example usage](#example-usage) further down.

There are several optional fields for each entry in `environments-yml`, see description of each in the [workflow declaration](.github/workflows/terraform-ci-cd-default.yml).

#### Variables and secrets

Normally you'll have the need to pass some variables or secrets to terraform in order to perform authentication or otherwise configure the terraform operations. This can be achieved by specifying them in `extra-envs-yml` and/or `extra-envs-from-secrets-yml`.

For _global_ values, those to be passed for all terraform environments specified in `environments-yml` use the workflow **inputs** `extra-envs-yml` and `extra-envs-from-secrets-yml`.

For environment specific values specify **the fields** `extra-envs-yml` and `extra-envs-from-secrets-yml` for one or more environment defined in the `environments-yml` workflow input.

#### Variables for a single goal

`extra-envs-yml` and `extra-envs-from-secrets-yml` reach every step of the job. When the correct value differs per stage — `plan` may need a much higher `GOMEMLIMIT` than `validate`, and a `GOGC` low enough to keep `plan` inside a runner's memory would needlessly slow down `lint` — use `extra-envs-per-goal-yml` and `extra-envs-from-secrets-per-goal-yml` instead. Both exist as workflow inputs and as per-environment fields, like their global counterparts.

```yaml
      extra-envs-yml: |
        ARM_USE_OIDC: true
        GOGC: 50
        GOMEMLIMIT: 6GiB

      extra-envs-per-goal-yml: |
        plan:
          GOMEMLIMIT: 12GiB
          GOGC: 25
        apply:
          GOMEMLIMIT: ~          # cleared for apply
        lint:
          GOGC: 400

      environments-yml: |
        - environment: dev
        - environment: prod
          extra-envs-per-goal-yml:
            plan:
              GOMEMLIMIT: 24GiB
```

Valid goal keys are the ones you write in `goals-yml`: `init`, `format`, `validate`, `lint`, `plan`, `apply`, `destroy-plan`, `destroy`. Three things to know about them:

- The key is **`format`**, even though the workflow step is called `fmt`.
- **`destroy-plan` and `destroy` are separate** from `plan` and `apply`, so a destroy plan can be tuned independently.
- **There is no `all` key.** `all` is not a stage, it is shorthand expanded inside each step's condition, so there is nothing to attach values to — the every-goal layer is `extra-envs-yml`. Writing `all:` is a hard error rather than a silent no-op.

An unknown goal key, a secret name that is not available to the workflow, an environment variable name that is not a valid one, or a value that is a list or a mapping all fail the job early, before any terraform runs.

Effective value for a given (environment, goal, variable), last wins:

1. global `extra-envs-yml`
2. global `extra-envs-from-secrets-yml`
3. per-goal `extra-envs-per-goal-yml[goal]`
4. per-goal `extra-envs-from-secrets-per-goal-yml[goal]`

So specificity beats source — a per-goal plain value overrides a global secret-sourced one for the same variable — while within one level, secret-sourced wins, which is what the global maps already did before this existed. Per-environment values are merged into the global ones first, per goal and per variable: the `prod` example above ends up with `GOMEMLIMIT: 24GiB` **and** `GOGC: 25` for `plan`.

For the resulting table across the example:

| | `GOGC` | `GOMEMLIMIT` |
|---|---|---|
| dev · init/validate/format/destroy-* | 50 | 6GiB |
| dev · plan | 25 | 12GiB |
| dev · lint | 400 | 6GiB |
| dev · apply | 50 | *unset* |
| **prod · plan** | **25** | **24GiB** |

##### Clearing a variable

`GOMEMLIMIT: ~` (YAML null) **unsets** the variable for that goal. `GOMEMLIMIT: ""` sets it to the empty string, which is a different thing for anything that treats an empty value as meaningful. Being able to express *unset* at all is the main functional gain over routing these through `$GITHUB_ENV`, which has no unset mechanism.

##### Two caveats

**Per-goal secrets do not swap cloud identity.** The values reach the terraform/tflint process for that goal — not the workflow's `Login to Azure` step, which runs once, early, and reads job-wide environment variables. A reader service principal for `plan` and a contributor for `apply` therefore does **not** work through `extra-envs-from-secrets-per-goal-yml`: handing terraform a different `ARM_CLIENT_ID` after the OIDC token was already minted for another identity changes nothing. Use it for values terraform or a provider reads directly.

**Overriding a variable the workflow manages itself is allowed, and who wins depends on how the workflow sets it.** There is no reserved-name list. A variable the action exports at runtime — `TF_PLUGIN_CACHE_DIR` in `init` — wins over your value, so provider plugin caching cannot be disabled by accident. A variable set in the step's environment — `TF_IN_AUTOMATION`, and `GITHUB_TOKEN` for `lint` — is overridden by your value. The asymmetry is a consequence of when each assignment happens, not a policy.

##### The cheaper alternative

Terraform's own `TF_CLI_ARGS_<subcommand>` mechanism already works through plain `extra-envs-yml` with no per-goal configuration at all, and covers anything expressible as a CLI flag. Reach for it first. One caveat: `TF_CLI_ARGS_plan` applies to **both** plan invocations, `plan` and `destroy-plan`.

Full design, including why the values are passed as a file path rather than as a payload: [Per-goal-environment-variables.md](./Per-goal-environment-variables.md).

#### Example usage

#### Basic

Basic example of how to add terraform CI/CD to a github repo containing one environment under `/envs/my-tf-environment`. This would result in:

- On PRs in the calling repo:
  - Perform: `init`, `format`, `validate`, `lint` and `plan`
  - Add comment on PR with results
- When merging PRs in the calling repo:
  - First perform: `init`, `format`, `validate`, `lint` and `plan`
  - If successful, perform `apply`

The following would be saved as `.github/workflows/ci-cd.yml` in the calling repo.

For simplicity variables and secrets for authentication etc. have been left out.

```yaml
name: "CI/CD"

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main
    types: [opened, synchronize, reopened]
  workflow_dispatch: # allows manual build

jobs:
  tf:
    uses: dsb-norge/github-actions-terraform/.github/workflows/terraform-ci-cd-default.yml@v0
    secrets: inherit # pass all secrets, ok since we trust our own workflow
    permissions:
      contents: read # required for actions/checkout
      pull-requests: write # required for commenting on PRs
    with:
      environments-yml: |
        - environment: "my-tf-environment"
```

#### Multiple environments

Example of how to add terraform CI/CD with default operations to a github repo containing multiple environments **not** stored under the `/envs` directory.

```yaml
# snip, 'name:' and 'on:' fields removed
jobs:
  tf:
    uses: dsb-norge/github-actions-terraform/.github/workflows/terraform-ci-cd-default.yml@v0
    secrets: inherit # pass all secrets, ok since we trust our own workflow
    permissions:
      contents: read # required for actions/checkout
      pull-requests: write # required for commenting on PRs
    with:
      environments-yml: |
        - environment: "proj1"
          project-dir: "./terraform-projects/project-1"
        - environment: "proj2"
          project-dir: "./terraform-projects/project-2"
```

#### Advanced

Various examples of how to modify behavior.

```yaml
# snip, 'name:' and 'on:' fields removed
jobs:

  # you can achieve passwordless auth to Azure
  tf-1:
    uses: dsb-norge/github-actions-terraform/.github/workflows/terraform-ci-cd-default.yml@v0
    secrets: inherit # pass all secrets, ok since we trust our own workflow
    permissions:
      id-token: write # required for Azure password-less auth
      contents: read # required for actions/checkout
      pull-requests: write # required for commenting on PRs
    with:
      # these envs are 'global' and will be passed for all terraform environments specified below
      extra-envs-yml: |
        ARM_USE_OIDC: true
        ARM_USE_AZUREAD: true # ref. https://nedinthecloud.com/2022/06/08/using-oidc-authentication-with-the-azurerm-backend/
      # these values are not really secret but we load them from GitHub secrets either way
      # these envs are also 'global'
      extra-envs-from-secrets-yml: |
        ARM_CLIENT_ID: GITHUB_SECRETS_CLIENT_ID
        ARM_TENANT_ID: GITHUB_SECRETS_TENANT_ID
      # observe how each env can target different Azure subscriptions. 
      #You can also override default runner ('dsb-terraformer') via "runs-on" variable per environment
      environments-yml: |
        - environment: "my-oidc-env-for-sub-1"
          extra-envs-from-secrets-yml:
            ARM_SUBSCRIPTION_ID: GITHUB_SECRETS_SUBSCRIPTION_1_ID
        - environment: "my-oidc-env-for-sub-2"
          extra-envs-from-secrets-yml:
            ARM_SUBSCRIPTION_ID: GITHUB_SECRETS_SUBSCRIPTION_2_ID
          runs-on: "ubuntu-latest"

  # hardcoded versions and modify what steps are executed
  tf-2:
    uses: dsb-norge/github-actions-terraform/.github/workflows/terraform-ci-cd-default.yml@v0
    secrets: inherit # pass all secrets, ok since we trust our own workflow
    permissions:
      contents: read # required for actions/checkout
      pull-requests: write # required for commenting on PRs
    with:
      terraform-version: "1.9.8"
      tflint-version: "v0.47.0"
      # First environment without apply step on PR merge, only validation
      # Second environment with all supported steps
      #   suitable ex. for integration tests etc. where the infra is always torn down
      environments-yml: |
        - environment: "only-validation"
          goals-yml: [init, format, validate, lint]
        - environment: "all-steps"
          goals-yml: [all, destroy-plan, destroy, apply-on-pr, destroy-on-pr]
```