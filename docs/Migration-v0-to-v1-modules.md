# Migrating a module repository from v0 to v1

How to move a Terraform module repository from `@v0` of
[`terraform-module-ci.yaml`](../.github/workflows/terraform-module-ci.yaml) and
[`terraform-module-release.yaml`](../.github/workflows/terraform-module-release.yaml) to `@v1`: what
you must change, what you should change, and what v1 offers besides. The design is
[Module-ci.md](Module-ci.md), the user guides are
[Workflow-terraform-module-ci.md](Workflow-terraform-module-ci.md) and
[Workflow-terraform-module-release.md](Workflow-terraform-module-release.md), and every change is
listed in [V1-changes.md §11](V1-changes.md). A project repository, one that plans and applies
environments, moves with [Migration-v0-to-v1.md](Migration-v0-to-v1.md).

The short version: change the ref, raise Terraform to 1.13 or later, add `actions: read`, turn the
calling workflow's `env:` block into a lane, and make sure there is at least one test file.

## 1. Pre-flight checklist

| Check | Where |
|---|---|
| Both calling workflows (`test.yaml`, `tag-and-release.yaml` or their equivalents) found | §2.1 |
| The Terraform version the tests run with is 1.13 or later | §2.2 |
| The calling job grants `actions: read` | §2.3 |
| Which credentials the tests need: none, one, or several | §2.4 |
| At least one test file, or `terraform-test-required: false` for the move | §2.5 |
| Every test file committed, under `tests/` or beside the module's `.tf` files | §2.6 |
| The README is current (regenerated with terraform-docs 0.20) | §2.7 |
| The App's variable and secret reach the repository | §2.8 |
| `.tflint.hcl` committed (the template's `.gitignore` matches it) | §6 |

## 2. Must do / check

### 2.1 The ref, in both workflows

`@v0` becomes `@v1` in the calling workflow of `terraform-module-ci.yaml` and in the one of
`terraform-module-release.yaml`. Move both together.

### 2.2 Terraform 1.13 or later

The test jobs refuse Terraform below 1.13 with the reason `terraform-version`. Set
`terraform-version: "1.14.x"`, for example; a lane may set its own with `terraform-version`.

### 2.3 Permissions

```yaml
    permissions:
      id-token: write      # OIDC, for the test jobs
      contents: read       # checkout; the docs commit is pushed with the App token
      pull-requests: write # the validation and tests heads
      actions: read        # job links in the tests head
    secrets: inherit
```

`actions: read` is new, and required: the tests summary job declares it, and GitHub does not start
a called workflow whose job asks for a permission the calling job did not grant; the run fails at
startup, with no job and no check. v0's `contents: write` may stay, but is no longer needed.

### 2.4 Credentials move into a lane

v0 gave every test file the repository's Azure principal through the called workflow's own
`env:`. v1 gives credentials only through lanes. The `env:` block most calling workflows carry
with the same three secrets never reached the called workflow; delete it. Then pick the case:

- **No credentials**: every test mocks its providers (`mock_provider`). No lane is needed.
- **One credential, v0's behaviour**: one lane without `match` maps the three secrets for every
  file:

  ```yaml
      with:
        terraform-test-lanes-yml: |
          - name: azure
            extra-envs-yml:
              ARM_USE_OIDC: true
              ARM_USE_AZUREAD: true
            extra-envs-from-secrets-yml:
              ARM_TENANT_ID: REPO_AZURE_DSB_TENANT_ID
              ARM_SUBSCRIPTION_ID: REPO_AZURE_SUBSCRIPTION_ID
              ARM_CLIENT_ID: REPO_AZURE_TERRAFORM_USER_SERVICE_PRINCIPAL
  ```

- **Unit tests without, integration tests with** (§3.1), or several credentials: one lane per
  identity, each with its `match`.

A unit test that does not mock its providers needs credentials to configure them. Such a file
fails in a lane without them, so mock the provider or keep it in the credentialed lane.

### 2.5 At least one test file

A module needs at least one test file, a unit suite: with none, the conclusion is red and says
`a module needs at least one test file`. Add `tests/unit-tests.tftest.hcl`:

```hcl
mock_provider "azurerm" {}

run "the_module_plans" {
  command = plan
}
```

Or set `terraform-test-required: false` for the move and add the suite after.

### 2.6 Test files where Terraform finds them

Discovery reads the committed files, and runs a file only where Terraform finds it: in `tests/`,
or beside the module's `.tf` files. A file anywhere else is listed as misplaced and does not run.
A file that is not committed is not seen at all.

### 2.7 The README

Only a pull request from the repository itself gets a docs commit from the App. On a push, a
dispatch, a schedule, a fork's pull request or a Dependabot pull request, a README that needs
regenerating fails the docs check. Regenerate it before the move, with terraform-docs 0.20, the
version of the pinned action, or let a pull request do it.

### 2.8 The App

Both workflows read `vars.ORG_TF_CICD_APP_ID` and `secrets.ORG_TF_CICD_APP_PRIVATE_KEY`, which the
repository must have access to, and the App must be installed on it.
`ORG_TF_CICD_APP_INSTALLATION_ID` is no longer read.

## 3. Should do / check

### 3.1 Take unit tests off the credential

Put a `unit` lane without credentials before the credentialed one, so a unit test can never use
the principal:

```yaml
      terraform-test-lanes-yml: |
        - name: unit
          match: ["**/unit-*.tftest.hcl"]
        - name: integration
          match: ["**/integration-*.tftest.hcl"]
          extra-envs-yml:
            ARM_USE_OIDC: true
            ARM_USE_AZUREAD: true
          extra-envs-from-secrets-yml:
            ARM_TENANT_ID: REPO_AZURE_DSB_TENANT_ID
            ARM_SUBSCRIPTION_ID: REPO_AZURE_SUBSCRIPTION_ID
            ARM_CLIENT_ID: REPO_AZURE_TERRAFORM_USER_SERVICE_PRINCIPAL
```

### 3.2 Isolate the credential in a GitHub Environment

Replace the mapped secrets with `github-environment: auto`. The lane's jobs then run in the
GitHub Environment `tftest-<lane>`:

```yaml
        - name: integration
          match: ["**/integration-*.tftest.hcl"]
          github-environment: auto
```

1. The first run creates `tftest-integration`, and its jobs fail with `no-credentials`, printing
   the commands that set the secrets.
2. Someone with write access sets `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID` and `ARM_CLIENT_ID` as the
   environment's secrets.
3. The identity's owner adds a federated credential for
   `repo:<owner>/<repo>:environment:tftest-integration`.
4. Re-run the failed jobs.

`ARM_USE_OIDC` is on by default in an environment lane. Never add protection rules to a
`tftest-*` environment. The full procedure is [Terraform-tests.md §3.6](Terraform-tests.md).

### 3.3 Narrow the principal once the lane runs

When the environment lane has run, remove the three repository secrets and every federated
credential of the principal that trusts a `pull_request` or branch subject. A test file in a pull
request is code anyone with write access can change; only the environment subject should reach
the identity.

### 3.4 Require only the conclusion

`tf / Terraform conclusion` is the one check to require, as on v0. Test jobs are now named
`Terraform test (<file>)`.

## 4. Could do / check

- **A nightly schedule.** A module's tests run on `schedule` and on `workflow_dispatch` too. An
  `on.schedule` in the calling workflow catches provider and API drift between pull requests.
- **Several credentials**, one lane per identity.
- **Per-lane settings**: `runs-on`, `timeout-minutes`, `terraform-version`, `cache-terraform-modules`,
  and `allow-failing-terraform-tests` while a lane is brought up.
- **Exclusions**: `terraform-test-exclude-paths-yml` for files discovery should not run.

## 5. The calling workflows, before and after

A typical v0 `test.yaml`:

```yaml
name: "Terraform module CI"

on:
  pull_request:
    branches: [main]
    types: [opened, synchronize, reopened]
  workflow_dispatch:

env:
  ARM_TENANT_ID: ${{ secrets.REPO_AZURE_DSB_TENANT_ID }}
  ARM_SUBSCRIPTION_ID: ${{ secrets.REPO_AZURE_SUBSCRIPTION_ID }}
  ARM_CLIENT_ID: ${{ secrets.REPO_AZURE_TERRAFORM_USER_SERVICE_PRINCIPAL }}
  ARM_USE_OIDC: true
  ARM_USE_AZUREAD: true
  TF_IN_AUTOMATION: true

jobs:
  tf:
    uses: dsb-norge/github-actions-terraform/.github/workflows/terraform-module-ci.yaml@v0
    secrets: inherit
    permissions:
      contents: write
      id-token: write
      pull-requests: write
    with:
      terraform-version: "1.11.x"
      tflint-version: "v0.55.1"
```

The same on v1, with unit tests off the credential (§3.1):

```yaml
name: "Terraform module CI"

on:
  pull_request:
    branches: [main]
    types: [opened, synchronize, reopened]
  workflow_dispatch:

jobs:
  tf:
    uses: dsb-norge/github-actions-terraform/.github/workflows/terraform-module-ci.yaml@v1
    secrets: inherit
    permissions:
      id-token: write
      contents: read
      pull-requests: write
      actions: read
    with:
      terraform-version: "1.14.x"
      tflint-version: "v0.64.0"
      terraform-test-lanes-yml: |
        - name: unit
          match: ["**/unit-*.tftest.hcl"]
        - name: integration
          extra-envs-yml:
            ARM_USE_OIDC: true
            ARM_USE_AZUREAD: true
          extra-envs-from-secrets-yml:
            ARM_TENANT_ID: REPO_AZURE_DSB_TENANT_ID
            ARM_SUBSCRIPTION_ID: REPO_AZURE_SUBSCRIPTION_ID
            ARM_CLIENT_ID: REPO_AZURE_TERRAFORM_USER_SERVICE_PRINCIPAL
```

The `integration` lane has no `match`, so it takes every file the `unit` lane does not. The
release workflow changes only its ref:

```yaml
jobs:
  tag-and-release:
    uses: dsb-norge/github-actions-terraform/.github/workflows/terraform-module-release.yaml@v1
    secrets: inherit
```

## 6. Validating the move

Open the change as a pull request and read its runs; green is necessary, not sufficient.

1. **The move's own pull request** runs every test file. Check:
   - `Create test matrix` succeeded; its log's decision record lists each file with its lane,
     e.g. `tests/unit-tests.tftest.hcl: run, lane unit`.
   - Unit jobs ran without logging in; credentialed jobs logged in (`🔑 Login to Azure`).
   - One `Terraform tests summary` comment replaces v0's per-file comments, which this first run
     deletes, and the validation head reads "Terraform validation summary for module:
     `<repository>`".
   - `Terraform conclusion` is green: `conclusion: green — validation succeeded; tests: <n>`.
2. **A pull request that changes an input** gets a docs commit from the App. That run concludes
   `documentation regenerated and pushed; the run it started decides`, and the next run tests the
   commit.
3. **A broken unit test** turns the conclusion red.
4. **After the merge**, release-please opens or updates the release pull request, and module CI
   runs on it: the App token starts it.

## 7. Rolling back

`v0` stays frozen at v0.33 and takes fixes only. To move back, change both refs to `@v0` and
remove the v1-only inputs from `with:` (`terraform-test-lanes-yml` and the other test inputs,
`runs-on`, `add-pr-comment`, `cache-terraform-modules`): GitHub refuses a call with an input the
called workflow does not declare. v0's called workflow reads the three repository secrets itself,
so nothing else is needed; a repository whose secrets were removed after the move (§3.3) needs
them back.

## 8. Pitfalls

| Pitfall | What happens | What to do |
|---|---|---|
| The `env:` block kept, no lane | Tests that need Azure fail to configure the provider | Replace it with a lane (§2.4) |
| A repository without test files | The conclusion is red | Add a unit suite, or `terraform-test-required: false` (§2.5) |
| Terraform below 1.13 | Every test job fails with `terraform-version` | Raise `terraform-version` (§2.2) |
| A unit test without `mock_provider` in a lane without credentials | The provider fails to configure | Mock it, or give the lane the credential (§3.1) |
| `.tflint.hcl` not committed | Lint fails: "could not find a TFLint config file" | The template's `.gitignore` matches `**/.tflint.hcl`; keep it force-added (`git add -f .tflint.hcl`) |
| A stale README on a push, dispatch, schedule, fork or Dependabot pull request | The docs check fails | Regenerate with terraform-docs 0.20, or through a pull request (§2.7) |
| The App variable or secret missing | The docs job fails on a pull request | Give the repository access to both (§2.8) |
| A test file outside `tests/` or not committed | It is misplaced or not seen | Move it, commit it (§2.6) |
| `actions: read` missing | The run fails at startup, with no job and no check | Grant it (§2.3) |
