# Workflow [`terraform-ci-cd-default`](../.github/workflows/terraform-ci-cd-default.yml)  

Default DSB CI/CD workflow for terraform projects that performs various operations depending on from what github event it was called and given input. Default behavior (when not modified by inputs):

0. On `pull_request` and `push`, run only the environments the change is relevant to, see [which environments run](#which-environments-run-path-relevance)
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
11. After `apply` (and `destroy-plan` / `destroy` when those goals are set), report the outcome: the PR comments from step 8 are updated with one block per operation and one tag comment per operation that ran, and — on every event, PR or not — each matrix job writes its environment's block to its `$GITHUB_STEP_SUMMARY` with a `::notice` / `::error` for the apply result, and a `run-summary` job writes one table covering every environment to the run page. An environment that neither applies nor destroys renders exactly the comment it always did. If `apply`, `destroy-plan` or `destroy` failed, stop the workflow with a failure (same `allow-failing-terraform-operations` escape hatch as step 9). See [Apply-and-destroy-reporting.md](./Apply-and-destroy-reporting.md).

What steps to execute and when can be modified using the input `goals-yml`, see description pf the input documented in the [workflow](.github/workflows/terraform-ci-cd-default.yml).

#### **Inputs**

All inputs are documented in the [workflow declaration](.github/workflows/terraform-ci-cd-default.yml).

The input `environments-yml` is required all others are optional, see description of each in the [workflow declaration](.github/workflows/terraform-ci-cd-default.yml).

##### **`environments-yml`**

Specification of environments to run this terraform workflow and it's stages for. Minimum 1 environment must be specified.

Type: YAML list (as string) with specifications of environments to execute stages for.

Given that this is a list of environments (potentially with differing configuration), multiple entries in this list will cause parallel GitHub jobs to be spawned.

Across workflow runs, jobs for the same environment are serialised. Each job sits in a GitHub concurrency group named after the environment's `github-environment` field (defaults to `environment`), so a run that arrives while another is in progress for that environment waits its turn — an in-progress apply is never cancelled, and neither is a run that is already waiting. Pending runs start in the order they began waiting (best-effort, not guaranteed), up to 100 per environment; GitHub cancels anything beyond that. This deliberately opts out of GitHub's default queue depth of one, where a third run cancels the one already waiting and the cancelled run's `Terraform conclusion` check then fails. Three things to know about the group: it is the bare `github-environment` value, case-insensitive and shared by every workflow in the repository that uses it, so a scheduled reconcile and a merge apply for the same environment queue behind each other; ordering is best-effort, so after a burst of merges two runs queued close together may in rare cases start in the other order and leave the environment on the older commit until the next run; and a `cancel-in-progress: true` group on the calling workflow still cancels the whole run, including an in-progress or waiting environment job, so use one only on workflows that never apply.

Only one field is required for each entry in this yaml list: **`environment`** - string. Using default behavior this is the name of a directory found within the `/envs` directory in the root of the calling repo. This directory is where all workflow steps are executed.

**Example** have the workflow execute steps within `/envs/my-tf-environment` of the calling repo:

```yaml
environments-yml: |
  - environment: "my-tf-environment"
```

See more examples under [example usage](#example-usage) further down.

There are several optional fields for each entry in `environments-yml`, see description of each in the [workflow declaration](.github/workflows/terraform-ci-cd-default.yml).

#### Which environments run: path relevance

On `pull_request` and `push`, an environment runs only when the change touches a file that is relevant to it. A pull request is judged on its whole diff, a push on everything it carried. On `schedule` and `workflow_dispatch` every environment runs. The full design is [Path-relevance.md](./Path-relevance.md).

Two optional fields per environment decide what is relevant:

| Field | Default | Meaning |
|---|---|---|
| `paths` | `[auto]` | Files that make this environment relevant. A list containing `auto` is the standard set plus the other entries; a list without it replaces the standard set. `["**"]` means always relevant. |
| `paths-ignore` | `["**/*.md"]` when `paths` uses `auto`, otherwise `[]` | Files that never make this environment relevant, applied after `paths`. `[]` means ignore nothing. |

`auto` is the environment's `project-dir` (`envs/<environment>/**` by default), `main/**`, `modules/**`, every directory of its `terraform-init-additional-dirs-yml`, and the repository root's `.tflint.hcl` (`/.tflint.hcl`). Patterns follow a small glob grammar: `*` within one directory level, `**` any number of levels, `?` one character, and a pattern without `/` matches the file name anywhere unless a leading `/` anchors it at the root (`/Makefile` is the root's only, `Makefile` any). There is no negation, no `[…]` and no `{…}`. An environment that reads files from outside the standard set, such as a `-var-file` passed through `TF_CLI_ARGS_*`, a local module outside `main/` and `modules/`, or Markdown through `file()`, must list them in `paths`.

```yaml
environments-yml: |
  - environment: prod                      # auto
  - environment: staging
    paths: [auto, "scripts/**"]            # the standard set plus one directory
    paths-ignore: ["**/*.md", "**/*.txt"]  # replaces the implied ignore
  - environment: sandbox
    paths: ["**"]                          # every change
```

Every uncertainty runs every environment: a change under `.github/workflows/`, a force push, a pull request whose head moved since the run started, more files than the API lists, or an API that cannot answer. The run page says which applied, in a notice such as `relevance diff (diff): 1 of 3 environments affected`, and in the run summary.

**Remove `paths` and `paths-ignore` from the `on:` block of your calling workflow.** A workflow skipped by `on.paths` reports no check at all, so a required `Terraform conclusion` check stays pending and blocks the pull request. Relevance lives inside the workflow instead, and a pull request that touches nothing relevant runs one short job and reports a green check. Before:

```yaml
on:
  pull_request:
    branches: [main]
    paths: ["envs/staging/**", "main/**", "modules/**"]
```

After:

```yaml
on:
  pull_request:
    branches: [main]
```

To keep every environment running on every change, for instance while you review your `paths`, set the input `path-relevance-enabled: false`. It applies to all environments; to run one environment on every change, give it `paths: ["**"]`.

What a pull request shows for an environment the change does not touch: an ungrouped environment's summary comment says "➖ Not affected by this pull request" with its path rules, and its old plan comments are removed; in a group's table the environment keeps its column, filled with `—`, and a line under the table names it as not affected. A pull request that touches no environment is eligible for auto-merge, under the same enabled and actor checks as any other.

Examples, for `prod` ungrouped and `staging` and `sandbox` in the group `platform`:

| Change | Runs | Conclusion |
|---|---|---|
| `README.md`, `docs/runbook.md` | nothing | green, nothing to verify |
| `envs/staging/main.tf` | `staging` | green if `staging` passes |
| `modules/net/main.tf` | all three | as always |
| `envs/prod/README.md` | nothing (the implied ignore) | green |
| `.github/workflows/terraform.yml` | all three (the workflow changed) | as always |
| A push to `main` merging the `staging` change | `staging` | green if the apply passes |

Three things to know:

- An apply that failed on one push is not retried by a later push that does not touch that environment. Run the workflow by `workflow_dispatch` to reconcile it; a dispatch always runs every environment.
- A pull request with a merge conflict gets no run at all, so its check stays "Expected" until the conflict is resolved. That is GitHub's behaviour, not relevance.
- The repository's Environments view shows the last deployment of each environment, which may be from an older change than the latest run when later changes did not touch it.

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

Terraform's own `TF_CLI_ARGS_<subcommand>` mechanism already works through plain `extra-envs-yml` with no per-goal configuration at all, and covers anything expressible as a CLI flag. Reach for it first. One caveat: `TF_CLI_ARGS_plan` applies to **both** plan invocations, `plan` and `destroy-plan`. Another: `-compact-warnings` changes the diagnostic shape — one `Warnings:` list of summaries instead of a `Warning:` block per diagnostic — so `parse-terraform-warnings` counts zero and the warning annotations and the warnings section of the plan comment disappear; the count parsers are unaffected.

Full design, including why the values are passed as a file path rather than as a payload: [Per-goal-environment-variables.md](./Per-goal-environment-variables.md).

#### Module downloads are authenticated

`terraform init` installs a remote module by shelling out to `git clone`. The public registry resolves a module such as `Azure/avm-res-keyvault-vault/azurerm` to `git::https://github.com/Azure/terraform-azurerm-avm-res-keyvault-vault?ref=<sha>`, so a configuration with no `git::` sources of its own still ends up cloning from github.com — once per module.

Those clones are fresh repositories under `.terraform/modules`. They inherit nothing from the workspace repository, so the credentials `actions/checkout` wrote into *its* local config do not apply, and without help the clones are anonymous. GitHub budgets unauthenticated traffic at **60 requests/hour counted against the source IP**, which every runner behind the same NAT address shares. A module set of any size spends that quickly, and when it is gone the pack negotiation is refused with a `401`; git has no credentials and no tty, so it fails with

```text
fatal: could not read Username for 'https://github.com': No such device or address
```

which terraform reports as `Failed to download module` — for a subset of the modules that varies run to run, since it is a throttle and not a misconfiguration. The workflow therefore hands `${{ github.token }}` to `terraform-init`, which authenticates the clones so they are budgeted per repository (1 000 requests/hour) instead. Nothing is required of the calling repository; `contents: read` is enough.

Two things worth knowing:

- **A runner that already has github.com credentials keeps them.** When the runner's global or system git config carries an `extraheader`, a credential helper or an `insteadOf` rewrite for github.com, the token is not injected — a repository whose private modules are cloned with runner-level credentials must keep working. The init log says which of the two happened.
- **The error is annotated.** If a clone is refused for want of credentials anyway, the init step emits an annotation naming the host and the likely cause, rather than leaving `Failed to download module` to be diagnosed from first principles.

Note that the module cache normally hides this problem: on a cache hit nothing is cloned at all, so the failure surfaces only when the cache misses — after a module pin changes, for instance. See [Terraform-module-cache.md](./Terraform-module-cache.md).

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