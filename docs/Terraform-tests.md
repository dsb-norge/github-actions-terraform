# Terraform tests in the default workflow

Authoritative spec for the `terraform test` stage of
[`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml): how test files are
discovered, how each one becomes a job, how credentials reach a test, how results reach the pull
request and the run page, and how a failing test blocks a merge.

Status: **specification, not yet implemented.** The decisions in §2 are settled; the questions
that probes on the test bed, a local Terraform and the documentation could answer are answered in
the text, and §12 lists what is still open. §15 is reserved for what implementation teaches the
spec.

Out of scope: [`terraform-module-ci.yaml`](../.github/workflows/terraform-module-ci.yaml) keeps its
own test job and per-file comments for now (§9.7); per-environment path relevance and single-file
dispatch are separate specs that hook into this one (§8).

## 1. Why

Repositories that manage infrastructure with this workflow are starting to write native
`terraform test` files: unit tests with `mock_provider` for module contracts, and integration tests
that create and destroy real objects in a sandbox tenant or subscription. Today the only place the
shared workflows run tests is the module CI workflow; a project repository has to wire its own job,
its own credentials and its own reporting. The need, as its developers stated it:

- `terraform test` runs as an ordinary part of a normal CI run, not per-repository wiring.
- **One job per test file, in parallel.** Files are independent and some are slow.
- **A repository with no tests is unaffected.** Most have none; the capability must not turn their
  runs red or require an opt-out.
- **Results where the reviewer already looks**: the pull request, without opening a job log.
- **A failure must be able to block a merge.**
- **Credentials selectable per test file**, because a unit lane needs none, and two integration
  lanes need two different, deliberately less privileged identities.
- **Provider versions that match the environments.** A test that resolves newer providers than any
  environment runs verifies nothing an environment does; a test pinned on its own drifts the other
  way and needs its own upgrade discipline.

Most of the machinery exists. The module CI workflow already discovers test files, runs one matrix
job per file and posts a comment per file. This spec lifts that into the default workflow, fixes
what the module CI actions get wrong for a project layout, and replaces per-file comments with one
structured summary.

## 2. Decisions

Recorded here so the rest of the document can be normative. Each was chosen from options with the
trade-offs written out; the rationale is kept short.

| # | Decision | Rationale |
|---|---|---|
| D1 | The stage lives inside the default workflow (option "1A"), not in a separate reusable workflow. | Keeps `tf / Terraform conclusion` the one required check; a second workflow would need fleet-wide branch-protection changes to block merges. |
| D2 | **Enabled by default** (`terraform-test-enabled: true`). Opt-out, not opt-in. | A repository with test files that silently never run is the worse state. A repository without test files sees no change (§4, §7). |
| D3 | `allow-failing-terraform-tests` (default `false`) tolerates failing tests, globally or per lane. | Mirrors `allow-failing-terraform-operations`. A tolerated failure is rendered as such, never hidden. |
| D4 | **Both test-root layouts** are supported: a repository-root `tests/` with an empty root, and `tests/` beside any module, `main/` or environment directory. | Both exist in real repositories; discovery is generic either way. Files Terraform would not discover from any sensible root are reported as misplaced (§4.3). Environment roots are supported but discouraged (§4.9). |
| D5 | Credentials come from **lanes** with glob matching: `terraform-test-lanes-yml`, first match wins, an optional match-less fallback lane, otherwise no credentials. | Same mental model and the same keys as environments. Unit tests run anywhere with nothing. |
| D6 | **Workflow-level `extra-envs-*` inputs and per-goal maps never flow into test jobs.** | Those carry the apply identity. A test must never borrow it by accident. |
| D7 | Tests run on `pull_request` and `push` only. Not on `schedule`, not on `workflow_dispatch`. No events input. | Unattended reconciles must not create or destroy test objects; a manual dispatch is often a recovery action. Single-file dispatch is a later spec (§8). |
| D8 | Test jobs run **in parallel with** the environment jobs; nothing waits for them. | The required check and auto-merge already block on a failed test. Waiting would delay every plan by the slowest test and would skip every environment when a test fails. |
| D9 | Test jobs default to `ubuntu-latest`, overridable per lane. | Many short jobs; a unit lane needs registry access only. Lanes that must reach a restricted network set `runs-on` themselves. |
| D10 | **One PR comment** for all tests, shape A (§6.4): headline, failed files first with their failed run blocks, everything else collapsed per test root. Job logs and output artifacts are linked, never inlined. | A comment per file is noise at 30 files; a 65 k body cannot hold logs. |
| D11 | Terraform **1.13.0 is the floor**, enforced at runtime. | The empty-root layout needs 1.12 (§4.2), and a test file's `variable` blocks, which carry lane variables into run-block modules, need 1.13 (§3.2); one floor keeps one authoring rule. |
| D12 | Credentials reach a lane in two ways, both supported: explicit secret-name mapping from the caller's secrets, and a **GitHub Environment per lane** (§3.6). | The mapping is the environments' existing model; the environment adds lane-scoped secrets, a lane-specific OIDC subject and a place collaborators can fill without admin rights. |
| D13 | Environment names are computed: `github-environment: auto` means `tftest-<lane>`. An explicit name must carry the same prefix. | Predictable names make the federated-credential wildcard and the bring-up steps identical in every repository. The prefix is one nobody uses for a real environment and matches the prefix test objects carry. |
| D14 | Only lanes that opt in run inside an environment, and they run with `deployment: false`. | A unit lane has nothing to keep secret. `deployment: false` keeps the secrets and drops the deployment record, so nothing reaches the pull request timeline. |
| D15 | In an environment lane, secrets named `ARM_*` and `TF_VAR_*` are exported verbatim. Lanes without an environment get no prefix export. | Add two secrets to the environment and the lane works. Relies on the calling organisations' naming rule for organisation and repository secrets (§3.6, P28). |
| D16 | `ARM_USE_OIDC=true` is assumed for environment lanes unless the lane overrides it. | Federated credentials are the only authentication the pattern supports, and the workflow-level variables where callers set it do not flow into tests. |
| D17 | Isolation from plan and apply identities rests on two stated preconditions: apply credentials are environment secrets, and apply identities hold `environment:` federated credentials only (§3.6). | Client IDs are not secret; only the subject the identity trusts keeps a test job from minting its token. |
| D18 | Tests **inherit provider versions from the environments**: each file runs once per distinct environment lock set, and the set's lock is copied into a non-environment test root before init. No committed test lock, no verification step, no CLI change (§5.3). | The environments are the only version truth; a separate test lock drifts from it the moment one of them upgrades. Floating test-only providers are reported, not failed. |
| D19 | Test jobs cache provider plugins and modules exactly as the environment job does, and authenticate module downloads. | Thirty inits per pull request; every download is an opportunity for a transient failure. |
| D20 | **Discovery is the decision engine's**: the create-matrix adapter lists the committed test files, the directories holding `.tf` files and the environments' lock files in the same step that builds the environment matrix, and the engine's `tests.py` derives roots, lanes, environments, provider sets and rows. `create-tftest-matrix` is left as it is for the module CI workflow. | Every rule sits under the engine's coverage and mutation gates, the environments' lock files are already known there, and one step decides the whole run ([Decision-engine.md](Decision-engine.md) D7, D13). |
| D21 | **One test job**, with `environment: { name: <row's github-environment>, deployment: false }`: a name that evaluates to `''` means no environment. | Verified on the test bed: an empty name gives no environment, no environment secrets and a `ref:` token subject, in a called workflow too, and creates nothing; two jobs with one step list were only needed if it did not. |

## 3. Caller-facing API

### 3.1 New workflow inputs

| Input | Type | Default | Meaning |
|---|---|---|---|
| `terraform-test-enabled` | boolean | `true` | Runs the stage. `false` removes every test job, the summary job and the PR comment; the conclusion sees the test job as skipped. |
| `allow-failing-terraform-tests` | boolean | `false` | A failing or erroring test job does not fail the check. Rendered as tolerated (§6.4). Per-lane override with the same key. |
| `terraform-test-runs-on` | string | `ubuntu-latest` | Runner for test jobs. Per-lane override `runs-on`. Deliberately not the workflow's `runs-on` (D9). |
| `terraform-test-timeout-minutes` | number | `30` | `timeout-minutes` of each test job. Per-lane override `timeout-minutes`. See P12 for why a short default matters. |
| `terraform-test-lanes-yml` | string (YAML list) | `[]` | Lanes, §3.2. |
| `terraform-test-exclude-paths-yml` | string (YAML list) | `[]` | Glob patterns (§4.4 semantics) of test files discovery ignores, in addition to the built-in exclusions (§4.1). |

The Terraform version for test jobs is the workflow-level `terraform-version` input, overridable
per lane with `terraform-version`.

Booleans arrive in the matrix as JSON booleans where the workflow needs `fromJSON()`
(`allow-failing-terraform-tests`) and as strings otherwise, following the matrix builder's existing
convention.

There is no `extra-args` input. Callers who need `-verbose`, `-parallelism` or any other
`terraform test` flag set `TF_CLI_ARGS_test` in a lane's `extra-envs-yml` (Terraform honours it; see
P9 before reaching for `-verbose`).

### 3.2 Lanes: `terraform-test-lanes-yml`

A lane says which files it covers and what environment those files run with.

```yaml
terraform-test-lanes-yml: |
  - name: unit
    match:
      - "**/unit-*.tftest.hcl"
  - name: directory
    match:
      - "**/integration-directory-*.tftest.hcl"
    github-environment: auto          # → tftest-directory; ARM_* and TF_VAR_* secrets there are exported
  - name: subscription
    match:
      - "**/integration-subscription-*.tftest.hcl"
    github-environment: auto          # → tftest-subscription
    runs-on: "some-runner-group"
    timeout-minutes: 60
    allow-failing-terraform-tests: true
  - name: legacy
    match:
      - "**/integration-legacy-*.tftest.hcl"
    extra-envs-yml:                   # no environment: everything explicit, from repository secrets
      ARM_USE_OIDC: true
    extra-envs-from-secrets-yml:
      ARM_TENANT_ID: REPO_TESTS_LEGACY_TENANT_ID
      ARM_CLIENT_ID: REPO_TESTS_LEGACY_CLIENT_ID
```

| Key | Required | Meaning |
|---|---|---|
| `name` | yes | `[a-z0-9-]{1,40}`, unique. Appears in the summary and in job metadata. |
| `match` | no | List of glob patterns, §4.4. A lane without `match` is the **fallback lane** for files no other lane matches; at most one lane may omit it. |
| `extra-envs-yml` | no | Environment variables for every step of the test job, values verbatim. **Values are logged and stored in run artifacts**; anything sensitive belongs in the next key. |
| `extra-envs-from-secrets-yml` | no | Environment variables whose values are read from the caller's secrets by name, exactly as the workflow-level input of the same name. Requires `secrets: inherit` on the caller, as everything else does. |
| `runs-on` | no | Overrides `terraform-test-runs-on`. |
| `terraform-version` | no | Overrides `terraform-version`. |
| `timeout-minutes` | no | Overrides `terraform-test-timeout-minutes`. |
| `allow-failing-terraform-tests` | no | Overrides the global input. |
| `providers-from` | no | List of environment names. Restricts the provider sets this lane's files run against to those environments' lock files. Default: every distinct set (§5.3). |
| `cache-terraform-modules` | no | Overrides the global input for this lane's jobs. |
| `github-environment` | no | `auto` resolves to `tftest-<lane>`; an explicit value must match `^tftest-[a-z0-9-]{1,40}$`. The lane's jobs then run inside that GitHub Environment: its secrets, its OIDC subject, no deployment record. §3.6. |

Any other key is a validation error (P4). Per-lane keys reuse the global input names on purpose:
the "same key overrides" idiom from `environments-yml` applies unchanged.

Rules:

- **First match wins.** Lanes are evaluated in declared order; the first whose `match` covers the
  file owns it.
- **Unmatched files** go to the fallback lane if one is declared, else to the implicit lane
  `default`: global values, no credentials. If such a test needs credentials it fails visibly and
  the summary shows the lane it landed in.
- **Precedence** for a lane value: lane key, else global input, else the input's default.
  Nothing from `extra-envs-yml`, `extra-envs-from-secrets-yml`, `extra-envs-per-goal-yml` or
  `extra-envs-from-secrets-per-goal-yml` at workflow level reaches a test job (D6).
- A lane with `github-environment`, or with a non-empty `extra-envs-from-secrets-yml`, is a
  **credentialed lane**; its files are not runnable where secrets are unavailable (§4.7).
- In an environment lane, the exported variables are, in order: the prefix export of §3.6, then
  `extra-envs-yml`, then `extra-envs-from-secrets-yml`; a later source overrides an earlier one, so a
  lane can always pin a value explicitly. The mapping coming last is `export-env-vars`' own order,
  kept for its existing callers; it matters only for a name a lane sets in both maps.

Authoring note for lane variables: `TF_VAR_x` sets a variable `x` that the root module declares. A
test file that references `var.x` itself, to pass it to a run block's module say, declares
`variable "x" {}`; Terraform requires the block from 1.13, the floor (§3.5), and 1.12 refuses it
(P45). Verified with 1.12.2 and 1.16.2.

### 3.3 Login

`azure/login` runs in a test job only when `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID` and
`ARM_CLIENT_ID` are all set after the lane's variables are exported: the same rule the environment
job uses. A directory-only lane omits the subscription and never logs in; the `azuread` and
`azurerm` providers mint their own OIDC tokens from `ARM_USE_OIDC` plus client and tenant ID. The
job therefore always carries `permissions: id-token: write` (P14). Environment lanes get
`ARM_USE_OIDC=true` unless their `extra-envs-yml` sets it (D16); a lane that deliberately
authenticates with a client secret sets it to `false` there.

### 3.4 Events

| Event | Test jobs | PR comment | Step summary |
|---|---|---|---|
| `pull_request` (not `closed`, not `converted_to_draft`) | yes | yes, unless fork or `add-pr-comment: false` | yes |
| `push` | yes | no | yes |
| `workflow_dispatch` | no | no | no |
| `schedule` | no | no | no |

The rule is fixed in the job's `if:` (`github.event_name == 'pull_request' || github.event_name ==
'push'`), not an input (D7).

### 3.5 Version floor

The `terraform-test` action reads `terraform version -json` before running and fails with status
`error`, reason `terraform-version`, when the version is below **1.13.0**. Terraform 1.12 refuses
a `variable` block in a test file ("Unsupported block type"), which fails init for every test file
of the root, and a test file needs that block from 1.13 to use a lane variable itself (§3.2, P45).
Below 1.12 the empty-root layout does not initialise either ("Module not installed"),
`-parallelism` is unknown and run blocks cannot declare `parallel`. The version is read even when
init failed, and wins over `init` (§5.5), since an old version is the likelier cause. The message
names the floor and points here; the action publishes the floor as `terraform-version-floor`, and
the summary names it from there rather than keeping a copy.

Provider versions are not a version-floor concern: tests take them from the environments' lock
files (§5.3), so nothing in the test lane runs `terraform providers lock`.

### 3.6 GitHub Environments per lane

A lane that sets `github-environment` runs its jobs inside a GitHub Environment. That gives the lane
three things repository-level secrets cannot: secrets scoped to the lane, an OIDC subject that names
the lane, and a place a collaborator can fill without admin rights.

**Naming.** `auto` resolves to `tftest-<lane>`. An explicit value must match
`^tftest-[a-z0-9-]{1,40}$`; anything else is a validation error, so the wildcard credential below
always covers it. GitHub compares environment names case-insensitively; the builder lowercases and
rejects a lane environment equal to any Terraform environment's `github-environment` in the same
run. It cannot see environments other workflows in the repository reference (P30).

**What the job gets.** `environment: { name: tftest-<lane>, deployment: false }`. With
`secrets: inherit` the job's secret bag holds organisation, repository and this environment's
secrets, and a same-named environment secret shadows the levels above. `deployment: false` keeps
the secrets and variables and creates no deployment object, so no "deployed to" entry reaches the
pull request timeline and nothing flaps in the repository's Environments view; it cannot be combined
with a custom deployment protection rule (P27). Verified on the test bed, in a called workflow as in a
caller: no deployment record, and the OIDC token's subject is
`repo:<owner>/<repo>:environment:tftest-<lane>`, or with the immutable format
`repo:<owner>@<owner-id>/<repo>@<repo-id>:environment:tftest-<lane>`, and its `job_workflow_ref`
names this reusable workflow and the ref it was called at.

**Secret export.** Every secret in the bag whose name starts with `ARM_` or `TF_VAR_` is exported
as an environment variable of the same name, before `azure/login`. The explicit
`extra-envs-from-secrets-yml` mapping still works for any other name, and both maps override the
prefix export (§3.2). Lanes without an environment get no prefix export, so a unit lane can never
pick up a repository-level `ARM_*` secret by accident. The convention relies on a naming rule of the
calling organisations: organisation secrets are named `ORG_*` and repository secrets `REPO_*`, so
no `ARM_*` or `TF_VAR_*` secret exists above environment level and the prefix export can only ever
select the lane's own environment secrets (P28). A job cannot tell which level a secret came from;
the rule is what makes the export safe, and the guide states it as a precondition.

GitHub stores secret names upper-cased, so an environment secret created as `TF_VAR_tenant_id`
reaches the job as `TF_VAR_TENANT_ID`, which sets only a variable named `TENANT_ID`; Terraform
variable names are case-sensitive (verified on the test bed: the lower-case declaration reported
"Required variable not set", the upper-case one passed). The export therefore adds, for every
`TF_VAR_*` secret, a copy with the name after the prefix lower-cased: `TF_VAR_TENANT_ID` is also
exported as `TF_VAR_tenant_id`, so a test declaring either name gets the value, and Terraform
ignores the one nobody declares (P44). A mixed-case variable name cannot be recovered; such a lane
maps the secret explicitly, `extra-envs-from-secrets-yml: { TF_VAR_tenantId: TF_VAR_TENANTID }`.
The maps override a copy as they override the original. `ARM_*` names are upper case already.

**Credential check.** Before init, an environment lane verifies that `ARM_TENANT_ID` and
`ARM_CLIENT_ID` are set. When they are not, the job fails with reason `no-credentials` and prints
the bring-up commands below with the environment name filled in; the summary shows the same. That
is what the first run on a fresh repository looks like, by design.

**Bring-up.** Environments are created by admins, or by any workflow that references one: GitHub
documents that running a workflow which references an environment that does not exist creates it,
with no protection rules and no secrets. Environment secrets are set through the REST API by anyone
with write access to the repository: verified on an organisation repository with a write-role
account, which set, updated, listed and deleted an environment's secrets and variables with `gh`,
and the job read the secret. The Actions how-to's "admin" is the settings UI and the environment's
own configuration: the write role cannot create, configure or delete an environment through the API
(404), only a workflow run that references it creates one. `gh secret set --env` against an
environment that does not exist yet fails with `failed to fetch public key: HTTP 404` and creates
nothing. So:

1. Add the lane with `github-environment: auto` and open a pull request. The first run creates
   `tftest-<lane>`, and the lane's jobs fail with `no-credentials`. Set
   `allow-failing-terraform-tests: true` on the lane if the pull request must stay green meanwhile.
2. A collaborator with write access sets the secrets (the environment must exist first):

   ```bash
   gh secret set ARM_TENANT_ID       --repo <owner>/<repo> --env tftest-<lane> --body '<tenant-id>'
   gh secret set ARM_CLIENT_ID       --repo <owner>/<repo> --env tftest-<lane> --body '<client-id>'
   gh secret set ARM_SUBSCRIPTION_ID --repo <owner>/<repo> --env tftest-<lane> --body '<subscription-id>'   # subscription lanes only
   gh secret list --repo <owner>/<repo> --env tftest-<lane>
   ```

3. The identity's owner adds a federated credential for the lane's subject (below). The values it
   needs come from `gh api repos/<owner>/<repo> --jq '{id: .id, owner_id: .owner.id}'`, and
   `gh api repos/<owner>/<repo>/actions/oidc/customization/sub` shows whether the repository emits
   immutable subjects.
4. Re-run the failed jobs: `gh run rerun <run-id> --repo <owner>/<repo> --failed`. Environment
   secrets are read at job start.

Never add protection rules to a `tftest-*` environment: required reviewers put every job of every
pull request into "Waiting" and fail it after 30 days, and a deployment-branch policy without
`refs/pull/*/merge` refuses every pull-request run before a step runs (P29).

**Federated credentials.** Lanes that need different privilege levels get one identity each, with
a classic credential and an exact subject:

```json
{
  "name": "gha-<repo>-tftest-directory",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<owner>/<repo>:environment:tftest-directory",
  "audiences": ["api://AzureADTokenExchange"]
}
```

One identity for every test lane of a repository takes a flexible credential (preview; created
through Graph beta, the portal, or `azuread_application_flexible_federated_identity_credential`
from azuread provider 3.7.0; `repository_id` is mandatory for GitHub):

```json
{
  "name": "gha-<repo>-tftest-lanes",
  "issuer": "https://token.actions.githubusercontent.com",
  "audiences": ["api://AzureADTokenExchange"],
  "claimsMatchingExpression": {
    "value": "claims['sub'] matches 'repo:<owner>*/<repo>*:environment:tftest-*' and claims['repository_id'] eq '<repo-id>'",
    "languageVersion": 1
  }
}
```

Verified in Entra with a throwaway identity: created through the Graph beta API exactly as above, it
granted a token to a job in `tftest-probe` and refused one to a job with no environment, a job in
another environment, and a job in `TfTest-Case`. The last refusal settles the case question:
GitHub puts the environment's stored name, case and all, into the subject, and `matches` compares
case-sensitively (P35). A lane using it logged in through `ARM_USE_OIDC`, ran a `command = apply`
test that created and asserted on a user-assigned identity in a resource group where the identity
holds Contributor, and `terraform test` destroyed it again; nothing was left.

The `*` after the owner and repository names absorbs the optional `@<id>` of the immutable format,
so the credential survives the repository opting in; `repository_id` is what binds it. Appending
`and claims['job_workflow_ref'] matches 'dsb-norge/github-actions-terraform/.github/workflows/terraform-ci-cd-default.yml@*'`
also pins the workflow; keep the `@*` so preview refs keep working. Repositories created, renamed or
transferred after 15 July 2026 emit the immutable subject; read a real token's `sub` before writing a
classic credential, and remember that opting an existing repository in is repository-wide and
changes the plan and apply jobs' subjects too (P31). Once a lane has its own subject, a
repository-level `pull_request` or `ref:refs/heads/main` credential on the test identity is no
longer needed and should be removed.

**Isolation.** A test job can neither read nor use a plan or apply identity when two preconditions
hold, and the guide states both. Verified in Entra: an identity whose only credential trusts one
Terraform environment's subject refused a token to a job with no environment and to a job in a
`tftest-*` environment, and granted one to a job in its own environment; the refusals are
`AADSTS700213` for a classic credential and `AADSTS7002131` for a flexible one.

1. Plan and apply credentials are environment secrets of the Terraform environments, never
   repository or organisation secrets. Only a job that declares that environment sees them; test
   jobs declare `tftest-*` or nothing.
2. Plan and apply identities carry federated credentials for `environment:<terraform-environment>`
   subjects only. The environment job always runs with `environment:`, so it needs nothing else; a
   leftover `pull_request` or branch credential would accept the subject a no-environment test job
   presents on the same event (P32).

With both, the secrets are invisible and the token exchange is refused. Client IDs are not secret,
so the second precondition is what stops a lane author from borrowing the apply identity through
`extra-envs-yml`.

## 4. Discovery and the matrix

Discovery runs once per workflow run, in the existing `create-matrix` step: the create-matrix
adapter of the [decision engine](Decision-engine.md) gathers the facts and the engine decides (D20).
It produces the test matrix, the count, and the lists of files that are not run and why.

### 4.1 Source of files

`git ls-files -z -- '*.tftest.hcl' '*.tftest.json'` from the repository root: committed files
only. This keeps `.terraform/modules/**` (registry modules ship their own `tests/`), build output and
anything ignored out of the matrix by construction. Built-in exclusions on top: any path with a
segment starting with `.`, and every pattern in `terraform-test-exclude-paths-yml`.

Paths are sorted before anything else is derived from them, so slugs, job order and collision
suffixes are stable across runs (P5).

### 4.2 Test root rule

Terraform loads test files from exactly two places relative to the root module it runs in: the root
module directory itself, and the `tests` directory directly under it (`-test-directory` can move the
latter, never add a third). Nested directories under `tests/` are not searched. The rule below is
that rule inverted, so that running `terraform test -filter=<rel>` from `root` finds the file:

```
d = dirname(file)
if basename(d) == "tests":                 root = dirname(d); rel = "tests/<name>"
elif d contains *.tf or *.tf.json,
     or d is the repository root:          root = d;          rel = "<name>"
else:                                      misplaced
if any segment of root == "tests":         misplaced
```

Consequences, all supported:

| Layout | root | rel |
|---|---|---|
| `tests/unit-x.tftest.hcl`, repository root holds no `.tf` | `.` | `tests/unit-x.tftest.hcl` |
| `modules/net/tests/unit-net.tftest.hcl` | `modules/net` | `tests/unit-net.tftest.hcl` |
| `main/tests/unit-main.tftest.hcl` | `main` | `tests/unit-main.tftest.hcl` |
| `envs/prod/tests/smoke.tftest.hcl` | `envs/prod` | `tests/smoke.tftest.hcl` |
| `modules/net/net.tftest.hcl` (beside `.tf`) | `modules/net` | `net.tftest.hcl` |

The empty-root case (first row) relies on Terraform 1.12's ability to initialise a directory that
holds only test files: `terraform init` installs the modules each `run` block names and the providers
those modules require (§5.3). A `provider` or `mock_provider` block in a test file does not make init
install anything: a provider only such a block names is not installed, and the file fails with
"unknown provider". A run block's local `source` is relative to the root, not to the test file
(`../module` from a repository-root `tests/`, not `../../module`), and only local and registry
sources are accepted in run blocks. Init installs the run-block modules of **every** test file in
the root, whatever `-filter` names. Terraform accepts a run block without `module {}` in an empty
root (it runs against the empty module and asserts nothing useful), so "every run block in such a
file names its module" is an authoring rule, not something Terraform enforces.

### 4.3 Misplaced files

A file the rule rejects would never be discovered by Terraform from a sensible root:
`tests/setup/helper.tftest.hcl` (inside a helper module), `tests/scenario-a/x.tftest.hcl` (a
nested scenario directory), or a file in a directory that holds neither `.tf` files nor a `tests`
name. Terraform would happily run some of these from the wrong root and resolve every relative
`module` source against the wrong directory.

Misplaced files get no job. They are listed in the summary (§6.4) with reason `misplaced`, and the
matrix builder emits one `::warning` per file naming the rule. They do not fail the run: a stray
file is a bug in the repository, and the summary is where it is seen. Scenario directories, if ever
needed, are a later per-lane `test-directory` override; Terraform offers no multi-directory mode.

### 4.4 Glob semantics

One grammar for `match` and `terraform-test-exclude-paths-yml`, defined here because bash pattern
matching would silently do something else (P6):

- Patterns are matched against the repository-relative file path, `/`-separated, no leading `./`.
- `*` matches any run of characters **within one segment** (never `/`). `?` matches one such
  character.
- `**` matches any number of whole segments, including none: `**/unit-*.tftest.hcl` matches
  `unit-a.tftest.hcl` at the root and `modules/x/tests/unit-a.tftest.hcl`.
- A pattern containing no `/` is matched against the basename alone, unless a leading `/` or `./`
  anchors it at the repository root: `/.tflint.hcl` matches the root's file only. On a pattern
  that has another `/`, the anchor changes nothing.
- No negation, no character classes, no braces. A pattern that uses them is a validation error.

Implementation: translate each pattern to an anchored extended regex (`**/` → `(.*/)?`, `**` →
`.*`, `*` → `[^/]*`, `?` → `[^/]`, everything else escaped) in a helper with its own fixtures.

### 4.5 Row schema

The matrix is `{"include": [row, …]}` with `slug` at top level so GitHub's default naming and
`strategy.job-index` stay meaningful, and everything else under `test`:

```json
{
  "slug": "modules-net--unit-net",
  "test": {
    "file": "modules/net/tests/unit-net.tftest.hcl",
    "name": "Terraform test (modules/net/tests/unit-net.tftest.hcl)",
    "root": "modules/net",
    "rel": "tests/unit-net.tftest.hcl",
    "lane": "unit",
    "runs-on": "ubuntu-latest",
    "terraform-version": "1.15.x",
    "timeout-minutes": 30,
    "allow-failing-terraform-tests": false,
    "github-environment": "",
    "root-kind": "module",
    "provider-set": "a1b2c3",
    "provider-set-lock": "envs/prod/.terraform.lock.hcl",
    "provider-set-environments": ["prod", "staging"],
    "cache-terraform-modules": "true",
    "fork-safe": true,
    "extra-envs": {},
    "extra-envs-from-secrets": {}
  }
}
```

- `name` is the job's display name (§4.6), with the provider-set suffix already applied, because a
  job's `name:` expression cannot count the sets.
- `extra-envs` holds the lane's verbatim variables; `extra-envs-from-secrets` holds env-name to
  secret-name pairs. **Names only, never values.** The matrix JSON is printed in every job's setup
  log, as the environment matrix already is.
- `github-environment` is the resolved, lowercased environment name or empty; the one test job
  passes it as the environment's name, and empty means no environment (D21, §5.1).
- `root-kind` is `environment`, `module` or `repo-root`. `provider-set` identifies the distinct
  provider-version set (a short hash of the lock's provider versions), `provider-set-lock` the
  environment lock file the job copies in (empty for an environment root, which uses its own), and
  `provider-set-environments` the environments that share the set (§5.3).
- `fork-safe` is `false` for credentialed lanes. It is named for what it is, not
  `requires-credentials`: [`capture-matrix-job-meta`](../capture-matrix-job-meta/) strips any key
  whose name contains `secret`, `credential`, `token`, `auth` or `password`, and the summary needs
  this field from the metadata (P7). The same filter drops `extra-envs-from-secrets` from the
  artifact, which is fine.
- `allow-failing-terraform-tests` is a JSON boolean because the workflow passes it to `fromJSON()`
  in `continue-on-error`; `fromJSON('')` is a hard error, so the builder always emits one.

Outputs of the builder: `tests-matrix-json`, `tests-count` (rows that will run) and `tests-active`
(`'true'` when enabled, the event qualifies and the matrix has rows). The list of files that do not
run, `{file, lane, reason}` for misplaced and secrets-unavailable files, is `tests.not_run` in the
engine's output and travels in `relevance.json` with the other per-item lists, never as a job output
(Decision-engine.md §5); the summary reads it from there.

### 4.6 Slugs and names

`slug` = `<root with '/' replaced by '-', or 'root' for '.'>--<basename without extension>`, reduced
to `[A-Za-z0-9._-]` and at most 100 characters. Discovery is sorted, so on a collision the later
file appends `-<first 6 hex of sha256 of its path>`; the suffix is deterministic across runs.

The slug names the job's artifacts (`terraform-test-log-<slug>`, `terraform-test-meta-<slug>`),
which is why `/` cannot appear in it (artifact names forbid it, P3), and it is the metadata file's
entity name.

The job's display name is `Terraform test (<file>)` with the repository-relative path, unique by
construction and the key the summary uses to find the job in the Jobs API (§6.2). When the
environments yield more than one provider set (§5.3), a file appears once per set: the slug gains
`--<set-id>` and the name becomes `Terraform test (<file>) [providers: <env-a>, <env-b>]`. With one
set, which is the normal case, neither changes.

### 4.7 Fork and Dependabot pull requests

Secrets are not available to a pull request from a fork, and the token is read-only, so no OIDC
token can be minted either; Dependabot runs are treated like fork runs and see only Dependabot's own
secrets. Rows whose lane is credentialed, by environment or by mapping, are dropped by the builder
when `github.event.pull_request.head.repo.fork == true` or `github.actor == 'dependabot[bot]'`
(the actor GitHub's own guidance keys on), and listed with reason `secrets unavailable` (§6.4).
`github.actor`, not `github.triggering_actor`: a human who re-runs a Dependabot run is the
triggering actor, but the re-run keeps the original actor's privileges and still has no secrets.
Dropping them also keeps a fork run from referencing, and thereby creating, a `tftest-*`
environment in the base repository. Fork-safe rows run. On a fork the PR comment is not posted at
all (the seed job already skips forks); the step summary is.

### 4.8 Limits

GitHub caps a matrix at 256 jobs per run. The builder fails with a message naming the cap when the
count exceeds it. Nobody has 256 test files; if someone does, the answer is `terraform-test-exclude-
paths-yml` or a smaller repository.

### 4.9 Environment roots

A `tests/` directory inside an environment directory is a valid root and is discovered. It is
almost never what a caller wants, and the spec says so in the user guide:

- The environment's own `terraform init` and `terraform validate` load those test files too. A
  syntax error in one blocks plan and apply for that environment, and `allow-failing-terraform-tests`
  cannot help (P10).
- The environment's real `provider` blocks apply. Without `mock_provider` the lane needs the
  environment's identity, and a `command = apply` run block starts from Terraform's empty in-memory
  state: it plans to create the whole environment again.
- `terraform.tfvars` and `*.auto.tfvars` of the environment and of its `tests/` directory are loaded
  into the tests.
- A root with a real backend block works without credentials: init runs with `-backend=false` and
  `terraform test` keeps state in memory (verified with an `azurerm` backend, `mock_provider
  "azurerm"` and `command = plan`). Mocked data sources return random strings, which fail a module's
  own validation of, say, a tenant GUID; the test file sets `mock_data "azurerm_client_config" {
  defaults = { tenant_id = "<guid>", … } }` for those.

Recommended layouts are the repository-root `tests/` with mocks and `module { source = "./main" }`,
or `tests/` beside a module. Callers who want a guard rail add `envs/**` to
`terraform-test-exclude-paths-yml`; it is not a built-in exclusion.

## 5. The test job

### 5.1 Job definition

One job (D21). A row's `github-environment` becomes the job's environment name; an empty name means
no environment, which the test bed confirmed: no environment secrets, a `ref:` token subject rather
than an `environment:` one, and nothing created, in a called workflow as in a caller.

```yaml
terraform-test:
  name: ${{ matrix.test.name }}
  needs: [create-matrix, seed-pr-comments]
  if: |
    !cancelled()
    && needs.create-matrix.result == 'success'
    && needs.create-matrix.outputs.tests-active == 'true'
  runs-on: ${{ matrix.test.runs-on }}
  timeout-minutes: ${{ matrix.test.timeout-minutes }}
  permissions:
    contents: read
    id-token: write
  environment:
    name: ${{ matrix.test.github-environment }}
    deployment: false
  strategy:
    fail-fast: false
    matrix: ${{ fromJSON(needs.create-matrix.outputs.tests-matrix-json) }}
  concurrency:
    group: ${{ github.repository }}-terraform-test-${{ matrix.slug }}
    cancel-in-progress: false
  steps:
    # §5.2
```

- `tests-active` folds enabled, count and event into one output, because a job-level `if:` cannot
  parse YAML and a job must never receive an empty matrix (P1, P2).
- The seed job's result is deliberately not tested: its steps are `continue-on-error`, `needs:`
  alone keeps the ordering, and testing it let a broken seed skip a stage silently while the
  conclusion stayed green ([Path-relevance.md](Path-relevance.md) P3).
- Concurrency is **per test file**, not per lane: a per-lane group would leave one row running, one
  pending and cancel the rest of this run's own matrix, and cancelled reddens the conclusion (P11).
  Per-file groups serialise the same file across overlapping runs, which is what protects
  integration tests that create fixed-name objects, and leave sibling files parallel. The
  one-pending caveat of GitHub's default queue applies exactly as it does to the environment job; if
  the workflow later adopts `queue: max` there, it adopts it here too.
- `timeout-minutes` is per lane because a job killed mid-apply leaves objects that no state file
  knows about (P12).
- `deployment: false` is what keeps ten credentialed files from posting ten deployment entries per
  run; without it every job referencing an environment records a deployment (P27).

### 5.2 Steps, in order

Every step has a `name:`; the summary finds the test step by name in the Jobs API, and the log
groups need readable titles.

| # | Step | Notes |
|---|---|---|
| 1 | `⬇ Checkout` | `actions/checkout@v6`, as in the environment job. |
| 2 | `🔧 Export lane environment variables` | `export-env-vars@v1` with `extra-envs: toJSON(matrix.test.extra-envs)`, `extra-envs-from-secrets: toJSON(matrix.test.extra-envs-from-secrets)`, `secrets-json: toJSON(secrets)`, and `export-secrets-with-prefixes-json: '["ARM_","TF_VAR_"]'` and `lower-case-copies-for-prefixes-json: '["TF_VAR_"]'` when `matrix.test.github-environment != ''`, else `'[]'` for both (§3.6, §9.8). `ARM_USE_OIDC` is seeded as `true` for environment lanes before the lane's own `extra-envs`, by the engine in the row's `extra-envs`. |
| 3 | `🔐 Verify lane credentials` (id `verify-credentials`) | Environment lanes only (`if: matrix.test.github-environment != ''`). Fails when `ARM_TENANT_ID` or `ARM_CLIENT_ID` is empty, printing the bring-up commands of §3.6 with the environment name filled in. A failure skips init; the test step still runs and reports `no-credentials`. `continue-on-error: true`. |
| 4 | `🔑 Login to Azure` | `azure/login@v3`, `if:` the credential check did not fail and the three ARM variables are set (§3.3). `continue-on-error: true`: the providers log in on their own, and a failed login shows in the test. |
| 5 | `📥 Setup Terraform` | `hashicorp/setup-terraform@v4`, `terraform_version: matrix.test.terraform-version`, **`terraform_wrapper: false`** (the wrapper mangles the `-json` stream and the exit code). |
| 6 | `📋 Provide provider versions` (id `copy-lock`) | For a non-environment root with a provider set, copies `matrix.test.provider-set-lock` into the root as `.terraform.lock.hcl` (§5.3), and names the runner's platform (`runner.os` and `runner.arch` as `linux_amd64`, `linux_arm64`, …) and the directory where the effective lock is committed: the environment's for a copied lock, else the root. |
| 7 | `🗄️ Setup Terraform provider plugin cache`, then `🔏 Verify the lock covers this runner` (id `provider-versions`) | `setup-terraform-plugin-cache@v1`, then, when the root has a lock, `actions/cache` with key `terraform-provider-plugin-cache-<os>-<arch>-<hash of <root>/.terraform.lock.hcl>-tftest`, falling back through `restore-keys` to the environment job's key without the suffix: the effective lock, copied or the environment root's own, so every file of one set shares one entry that holds the test-only providers too, and a set's first test job starts from the environment job's warm cache (P13, P41). `hashFiles()` resolves a path built from a matrix value, and hashes the lock step 6 wrote, but returns `''` when nothing matches: an environment root without a lock would share one key with every other, so the key carries a fallback or the cache is skipped when there is no lock (P40). Then, when the root has a lock, `verify-terraform-lock` in **lock-only** mode, in step 6's committed-lock directory, with `platforms:` set to the runner's platform and `plugin-cache-directory:` the restored cache, checks that the lock records an `h1:` checksum for that platform for every provider it lists. Lock-only mode needs no init, which has not run yet, and ignores the directory's configuration, which for a copied lock is not what the lock describes (P42); on a warm cache it hashes the cached packages instead of downloading them, which is why it runs after the restore. A failure is reason `lock-platform`, and the summary names the environment lock and the `terraform providers lock -platform=<os>_<arch>` command that fixes it (P39). A failure skips init; the test step still runs and reports it. `continue-on-error: true`. |
| 8 | `🗄️ Resolve, restore and snapshot the module cache` | `terraform-module-cache@v1` phases `resolve` (with `test-directory: tests`, so it reads the run-block module declarations of every test file in the root, §5.3, §9.9), `restore` and `snapshot`, gated on `matrix.test.cache-terraform-modules == 'true'`, each `continue-on-error: true`. |
| 9 | `⚙️ Terraform init` | `terraform-init@v1` (id `init`), `if:` neither the credential check nor the lock check failed, `working-directory: matrix.test.root`, `additional-dirs-json: "[]"`, `github-token: github.token`, `backend: false`, `lockfile-mode:` `readonly-if-present` for an environment root, else `default`, `plugin-cache-directory:` step 7's directory and `plugin-cache-may-break-lock-file: true`, which exports the may-break variable only when the lock stays writable (§5.3). `continue-on-error: true`. |
| 10 | `🔎 Verify, prune and save the module cache` | `terraform-module-cache@v1` phases `verify`, `prune` and `save`, with the environment job's gates (init succeeded, no cache hit, safe to save), each `continue-on-error: true`. Right after init, before the test writes into module directories. |
| 11 | `🧪 Terraform test` (id `test`) | `terraform-test@v1`, `if: !cancelled()`, `working-directory: matrix.test.root`, `test-file: matrix.test.rel`, `slug: matrix.slug`, `status-credentials`, `status-lock` and `status-init` from the outcomes of steps 3, 7 and 9, so a failed earlier step is reported as `no-credentials`, `lock-platform` or `init` without running terraform, and `environments-lock-file:` the provider set's lock, or the environment root's own. `continue-on-error: true`. Records the resolved provider versions and writes its own per-job step summary block (§5.6, §5.8). |
| 12 | `📤 Upload test output` (id `upload-test-output`) | `actions/upload-artifact@v7`, name `terraform-test-log-<slug>`, the test step's JSON log, report and JUnit files, `if-no-files-found: ignore`. `if:` always, once the test step reported. `continue-on-error: true`. Its `artifact-url` output is what the summary links as "output". |
| 13 | `📦 Capture and upload test job metadata` (id `capture-metadata`) | `capture-matrix-job-meta@v1` with `entity-name: matrix.slug`, `artifact-name: terraform-test-meta-<slug>` (§9.4); the action uploads the artifact itself, so no separate upload step, which a second artifact of the same name would fail. `if: always()`, `continue-on-error: true`. |
| 14 | `🧐 Validation outcome: 🔐 Credentials` | `exit 1` when step 3 ran and failed. `continue-on-error: ${{ fromJSON(matrix.test.allow-failing-terraform-tests) }}`. |
| 15 | `🧐 Validation outcome: ⚙️ Init` | `exit 1` unless init succeeded. Same `continue-on-error`. |
| 16 | `🧐 Validation outcome: 🧪 Test` | `exit 1` unless the test status is `pass`. Same `continue-on-error`. |

The gates come **after** every reporting step, as in the environment job: a gate exits 1 and would
otherwise skip the very upload that explains the failure. Nothing needs shredding here; there is no
per-goal env file.

### 5.3 Init in the test root: provider versions and caches

**Provider versions come from the environments.** A test root that is not an environment has no
version truth of its own, and a lock file committed there would drift from the environments the
moment one of them upgrades. Instead the matrix builder reads every environment's committed
`.terraform.lock.hcl`, groups the environments by identical provider-version content, and runs each
test file once per **distinct set**: normally once, twice while two environments disagree, which is
exactly the situation worth a second run (P36). A lane narrows this with `providers-from` (§3.2).
An environment without a lock file is reported and contributes no set.

Before init, the job copies the set's lock into the test root. A normal init then keeps the
recorded version of every provider the tests need that the environments also use, drops the entries
nothing needs, and resolves any **test-only** provider, a `random` in a setup module say, to the
newest its constraints allow. Verified with Terraform 1.16: the copied lock's unneeded providers are
dropped, the needed ones keep their recorded version (the lock's `constraints` field is rewritten to
the test root's), test-only providers are added at their newest, and `terraform test` passes. A
provider the copied lock records at a version the test root's constraints exclude is not floated
but fails init ("locked provider … does not match configured version constraint"), which the
summary reports as an `init` error; so after a successful init every provider in the copied lock has
the environments' version, and "floating" means exactly "absent from the copied lock". Read-only
mode is never used on a copied lock: it rejects both the pruning and the addition (P8). A test root
that is an environment uses its own committed lock, read-only: its tests may use only providers that
lock records, because read-only init refuses to add one, unlike the environment job's writable init.

After init, the `terraform-test` action reads the lock Terraform wrote and records, per provider,
the version and whether it came from the environments or floated. The per-job summary and the
metadata carry it, `azuread 3.9.0 from prod, staging · random 3.9.1 test-only, floating`, and the
pull-request summary names the set when more than one exists (§6.4). A floating provider is
information, not a failure; a stricter rule can come later. A side benefit: `mock_provider` takes
its schema from the installed provider, so mocks match the version the environments run.

`terraform-init` gains two inputs (§9.5):

- `backend: false` adds `-backend=false`. `terraform test` keeps all state in memory and never
  touches a backend; an environment root's `backend` block would otherwise make init reach for real
  storage with whatever identity the lane has, or none.
- `lockfile-mode`: `readonly-if-present` for an environment root adds `-lockfile=readonly` when the
  lock exists; `default` for every other test root leaves the copied lock writable and, when a plugin
  cache directory is set, exports `TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=true` so the cache
  also serves the floating providers. Terraform serves a provider from the cache only when the lock
  records its checksum; the copied lock records none for test-only providers, and the lock in a
  non-environment test root is a throwaway, so its single-platform hashes cost nothing (P13).
  Terraform turns the setting on for any value other than empty or `0`, so `true` is right and even
  `false` would enable it. It has a cost: with it on, a cached package whose checksum the lock does
  not record for the runner's platform fails init ("doesn't match any of the checksums recorded in
  the dependency lock file") instead of being downloaded again, and read-only init on such a lock
  either passes with a warning and leaves a package later commands refuse, or, with the cache warm,
  fails outright. So every lock a test job uses,
  copied or an environment root's own, must record the runner's platform; the job checks it before
  init and names the failure `lock-platform` (§5.2 step 7, P39). It is an operability requirement,
  not a security one: a lock written by `terraform init` also records the registry's `zh:` zip
  checksums for every platform, and Terraform refuses a download that matches none of them, so a
  missing `h1:` never lets an unverified provider through. The verification step of the
  environment job (`verify-lock-file`) already requires the same platforms on pull requests.

**Caches mirror the environment job**, because thirty test jobs init what one environment job inits
once, and every download is a chance for a transient registry or network failure (P38):

- Provider plugins: `setup-terraform-plugin-cache@v0`, then `actions/cache` keyed on the runner OS
  and architecture and the hash of the effective lock, copied or the environment root's own, so all
  files of one set share one cache entry and the first job of a set warms it for the rest.
- Modules: the same resolve, restore, snapshot, init, verify, prune, save sequence the environment
  job runs with `terraform-module-cache@v0` ([Terraform-module-cache.md](Terraform-module-cache.md)),
  gated on `cache-terraform-modules` (global input, per-lane override), every step
  `continue-on-error` because caching is an optimisation and never a reason to fail. The classifier
  reads `module` blocks in `.tf` files; a `run` block's `module { source = … }` in a test file is
  invisible to it. Terraform accepts only local and registry sources in run blocks, so the exposure
  is a registry source with a version range, which a restored cache would pin to a stale version, and
  a local source that reaches a remote module, which the classifier would not cache at all. The
  resolve phase therefore takes the run-block declarations of **every** test file in the root, since
  init installs them all whatever the filter: a registry source goes through the version classifier,
  so a range keeps the cache off for the root, and a local source is walked for the remote modules it
  reaches. The declarations enter the cache key, which is per root (§9.9, P37). A root whose tests
  use only local sources that reach nothing remote is not cached, and its key is stable run to run.
- Module downloads authenticate with `github-token`, as the environment job's do, so thirty jobs do
  not share one anonymous per-address budget.

`init` installs what the tests need, including in an empty root: the modules each `run` block names
(under keys like `test.tests.unit-net.basic`) and the providers those modules require. A
`mock_provider` still needs the real provider package for its schema; a mocked provider nothing
requires is not installed and the run errors with "unknown provider". Two consequences worth
knowing: a test file added after a local init needs a re-init, and a parse error in **any** test
file of the root fails init for the whole root (P10).

### 5.4 The `terraform test` invocation

From `working-directory: <root>`, never `-chdir`: relative `module` sources, `-filter`, `-junit-xml`
and every path in the JSON output are root-relative either way, and a working directory reads
naturally in the log and matches how a developer runs it locally.

```
terraform test -json -no-color -filter=<rel> [-junit-xml=$RUNNER_TEMP/<slug>/junit.xml]
```

- `-filter` must equal the discovered path exactly (`tests/unit-net.tftest.hcl`); `./tests/…`, an
  absolute path or a bare basename all miss.
- `-junit-xml` is passed only when the version is 1.11 or later; on a parse error Terraform writes
  no XML at all, so the reporter never depends on it.
- `-verbose` and `-parallelism` are never passed by default (P9). Callers add them through
  `TF_CLI_ARGS_test`.
- stdout and stderr go to `$RUNNER_TEMP/<slug>/test.json`, never to a shell variable (ARG_MAX,
  P15). `TF_IN_AUTOMATION=true`.

Local parity: `cd <root> && terraform init -backend=false && terraform test -filter=<rel>`.

### 5.5 Classification of the outcome

**A filter that matches nothing exits 0 with zero files** (P16). The exit code alone therefore
cannot classify, and neither can the counts: a file-level error reports all-zero counts. The action
derives `status` and `reason` from the JSON stream, in this order:

| # | Condition | `status` | `reason` |
|---|---|---|---|
| 0 | the credential check of an environment lane failed (init and test skipped) | `error` | `no-credentials` |
| 0b | the effective lock records no checksum for the runner's platform (init and test skipped) | `error` | `lock-platform` |
| 1 | init step did not succeed (the test step is skipped), and the version is not below the floor: a failed init still reads the version, and row 2 wins, since an old version is the likelier cause (P45) | `error` | `init` |
| 2 | Terraform below the floor (§3.5) | `error` | `terraform-version` |
| 3 | diagnostics match "Module not installed", "there is no package for", "Inconsistent dependency lock file", "missing or corrupted provider plugins", "Missing required provider", "Required plugins are not installed" or "does not match any of the checksums recorded in the dependency lock file", with or without a `test_abstract` (an uninitialised root reports one, with the diagnostic as a run error) | `error` | `not-initialised` |
| 4 | no `test_abstract`; any other diagnostic (parse or configuration error, possibly in a **sibling** test file; the diagnostic's `range.filename` says which) | `error` | `invalid` |
| 5 | `test_abstract` does not contain `rel` (Terraform warned "Unknown test file") | `error` | `not-discovered` |
| 6 | `test_file.status == "error"` and no run with status `error` or `fail` (unknown provider, provider configuration, required variable at file level; the file's runs may still report `skip`) | `error` | `file` |
| 7 | any `test_run.status == "error"` (provider or API error, evaluation error, postcondition); the file's later runs report `skip` | `error` | `run` |
| 8 | any `test_run.status == "fail"` (assertion) | `fail` | `assertion` |
| 9 | otherwise | `pass` | `` |

`skip` as a run status is a consequence of an earlier error in the same file and is counted, never
a top-level status. A file is `pass` only when Terraform exited 0 and its `test_summary` says so;
anything else that fits no row, including output that is not a test run at all, is `invalid`, and a
missing working directory is `not-discovered`. The counts come from `test_summary`'s numeric
fields, never its text, which counts an errored run as failed. A tolerated job (`allow-failing-terraform-tests`) keeps its real `status`; the
summary renders the tolerance (§6.4).

### 5.6 Per-file extract and outputs

Everything is read from the JSON file on disk with `jq`, never captured into a variable first:

| Output | Source |
|---|---|
| `status`, `reason` | §5.5 |
| `passed`, `failed`, `errored`, `skipped`, `total` | `test_summary`; `total` is their sum |
| `elapsed-ms` | difference of `@timestamp` between the first `test_file` `starting` and the `test_file` `complete` message (`elapsed` is absent from `complete` messages) |
| `summary` | `test_summary.@message`, e.g. `Success! 8 passed, 0 failed.` |
| `runs-json-file` | one object per run block: `{run, status, elapsed-ms}` from `test_run` `starting` / `complete` timestamps |
| `diagnostics-json-file` | one object per error diagnostic: `{run, file, line, summary, detail}` from `diagnostic.range` plus `@testrun`; `file` is prefixed with `<root>/` so it is repository-relative |
| `providers-json-file` | one object per provider in the lock Terraform wrote: `{name, version, origin}` with `origin` `environments` (version equals the copied lock's) or `floating` (test-only, resolved at init); for an environment root every provider is `environments` (§5.3) |
| `json-file`, `report-file`, `junit-file` | paths under `$RUNNER_TEMP/<slug>/` |

`report-file` is a human-readable extract (at most 65 000 characters, tail-trimmed): the summary
line, one line per run block with its status and time, and every error diagnostic with its
location. It is uploaded for humans; the summary comment is built from the JSON files.

### 5.7 Annotations

For each error diagnostic, in order, the action emits
`::error file=<root>/<range.filename>,line=<start.line>,title=Terraform test <status>::<run>: <summary> — <detail>`.
GitHub renders at most ten error annotations per step and fifty per job; the action stops at ten
and emits one `::warning` saying how many more are in the report (P17). The `file=` prefix makes
the annotation land inline on the pull request's Files tab when the test file is part of the diff.

### 5.8 Per-job step summary

The action appends to `$GITHUB_STEP_SUMMARY`: a one-line headline (`✅ pass` / `❌ fail` /
`❌ error (<reason>)`, counts, elapsed) and, for anything but `pass`, the list of failed or errored
run blocks with their diagnostics. Enough to read the job page without the log; the run-level
rollup is the summary job's (§6.5).

### 5.9 Artifacts and metadata

Two artifacts per test job:

- `terraform-test-log-<slug>`: `test.json`, `report.txt`, `junit.xml` when written. Retention is
  the repository default; a JSON log with `-verbose` can be megabytes, which is one more reason
  `-verbose` is opt-in.
- `terraform-test-meta-<slug>`: the metadata JSON `capture-matrix-job-meta` produces, with the
  `steps` context (all `terraform-test` outputs, the upload step's `artifact-url`), the matrix row and
  the filtered `github` context. Its file basename is `terraform-test-meta-<slug>.json`, distinct
  from `matrix-job-meta-*.json` on purpose: the environment aggregator, the run summary and the
  auto-merge evaluator glob the latter and must never see a test row (P7).

Every output that reaches the metadata is small; the JSON log, the report and the run and diagnostic
lists are files referenced by path, never step outputs, exactly as `create-validation-summary`
publishes its bodies (P15).

### 5.10 Gates

Steps 12 and 13 in §5.2. A tolerated job ends green with red steps inside it; the summary and the
step summary say "tolerated". The conclusion job (§7) sees `success` for it.

## 6. The summary job

### 6.1 Job definition

```yaml
terraform-test-summary:
  name: "Terraform tests summary"
  needs: [create-matrix, terraform-test]
  if: |
    always()
    && needs.create-matrix.result == 'success'
    && inputs.terraform-test-enabled == true
    && (
      needs.create-matrix.outputs.tests-count != '0'
      || github.event_name == 'pull_request'
    )
  runs-on: ${{ inputs.runs-on }}
  permissions:
    pull-requests: write
    actions: read
```

It is **not** in the conclusion's `needs`: a reporting job must never redden a run (the run-summary
precedent, P20 in the apply reporting spec). Every step is `continue-on-error: true` and `if:
always()` where it reports. It runs on pull requests even when the count is zero so it can clean up
a head from an earlier push that had tests (§6.3).

### 6.2 Inputs: metadata, jobs, links

1. Download `terraform-test-meta-*` with `merge-multiple: true`, `continue-on-error: true` (zero
   matches is undocumented behaviour; the step must not fail the job).
2. Read the not-run list from `relevance.json` for the misplaced and secrets-unavailable rows,
   which have no metadata.
3. Resolve links from the Jobs API, once, paginated, through a temp file: match `jobs[].name` with
   `endswith("Terraform test (<file>)")` so the caller's `<job> / ` prefix does not matter (the API
   returns the full name however long; verified at 223 characters), take
   `html_url`, and find the step named `🧪 Terraform test` in `steps[]` for the `#step:<number>:1`
   anchor (verified in the web view). `<number>` is the step's `number` from the API, never its position: skipped steps keep
   their number and post steps jump ahead. A re-run keeps the step numbers but gives **every** job of
   the run, re-run or not, a new id, so links come from the current attempt's Jobs API; links posted
   by an earlier attempt stay valid. When the step is not found, link `html_url#logs`. When the API call fails, the Links
   column drops the job link and the body says so in one line; the job never fails (P18).
4. The output link is the `artifact-url` recorded in the metadata; absent when the upload failed.
   `upload-artifact` fills it inside a called workflow, and it survives `toJSON(steps)` into the
   metadata artifact intact.
5. Reconcile: every row of the matrix must appear in the body. A row with no metadata, because
   its job was refused by an environment protection rule, cancelled, or is still waiting, is rendered
   from the Jobs API conclusion with reason `job did not run`, so the body never silently loses a
   file the conclusion counts (P33).

### 6.3 The head comment

Marker: `<!-- tf:head:tests:<caller> -->`, where `<caller>` is `github.workflow` (the calling
workflow's name) reduced to `[A-Za-z0-9_-]`. The marker is scoped per caller because a repository
may call this workflow from two workflows on one pull request (Workflow-pr-comments.md §8.1);
with tests enabled by default both would otherwise discover the same files and fight over one head
(P19). The user guide tells such callers to set `terraform-test-enabled: false` in all but one.
Segment terminators keep it distinct from the module CI's `tf:head:test:<file>` (P8 in the apply
reporting spec). `pr-comment` deletes every comment that contains the marker as a substring; the
closing ` -->` is what keeps `…tests:ci -->` from matching `…tests:ci-x -->`. Two consequences: a
comment that quotes the raw marker, whoever wrote it, matches too, and two workflow names that
reduce to the same characters ("CI build", "CIbuild") share one head.

Lifecycle, in the terms of Workflow-pr-comments.md:

- **Seeded** by `seed-pr-comments`, after the group and environment heads, when `tests-count > 0`,
  the global `add-pr-comment` is true and the event is an eligible pull request. Placeholder body:
  `### Terraform tests summary` + `⏳ Awaiting results (run #<id> attempt #<n>)…`. The title is
  byte-identical to the final one so the head does not rename itself mid-run. Placement after the
  environment heads is deliberate: reviewers read plans first, and tests are usually green. A pull
  request opened before this ships gets the head at the bottom of its thread once; only new pull
  requests get the clean order.
- **PATCHed** by this job with the final body on every eligible pull-request run.
- **Deleted** by this job when the count is zero and the marker exists (the last test file was
  removed, or tests were disabled, on an open pull request). A pull request that never had tests has
  nothing to delete. Deleting loses the head's position; if tests return, the seed re-posts it at the
  bottom. Rare, and better than a stale result.

Not posted on forks, on `add-pr-comment: false`, or on `closed` / `converted_to_draft` actions,
matching the existing guards. Bodies travel as file paths into `pr-comment`'s `body-file`.

### 6.4 Body shape (normative)

Shape A. Rendered exactly like this, with the placeholders filled:

```markdown
### Terraform tests summary
❌ 1 failed · ⚠️ 1 tolerated · ✅ 12 passed · ⏭️ 2 not run — 16 files · 3 lanes · ⏱ 4:12

**❌ Failed (1)**

| Test file | Lane | Runs | Time | Links |
|---|:---:|:---:|:---:|---|
| `modules/group/tests/integration-directory-group.tftest.hcl` | directory | 5/6 | `2:40` | [job log](<job-url>#step:8:1) · [output](<artifact-url>) |

<details><summary>❌ <code>modules/group/tests/integration-directory-group.tftest.hcl</code> — 1 of 6 run blocks failed</summary>

- `group_is_created` — Test assertion failed: group display name must start with `tftest-` (`modules/group/tests/integration-directory-group.tftest.hcl:42`)

</details>

**⚠️ Tolerated (1)**

| Test file | Lane | Result | Runs | Time | Links |
|---|:---:|:---:|:---:|:---:|---|
| `modules/rg/tests/integration-subscription-rg.tftest.hcl` | subscription | <span title="error (run): allowed to fail">⚠️ error</span> | 2/4 | `1:05` | [job log](…) · [output](…) |

<details><summary>⚠️ <code>modules/rg/tests/integration-subscription-rg.tftest.hcl</code> — 1 error, 1 skipped</summary>

- `assign_role` — Error: authorization failed for the principal (`modules/rg/main.tf:31`)
- `verify_role` — skipped: a previous run block errored

</details>

<details><summary>✅ <code>.</code> — 8 files · 8 passed · lane unit · ⏱ 0:48</summary>

| Test file | Lane | Runs | Time | Links |
|---|:---:|:---:|:---:|---|
| `tests/unit-group.tftest.hcl` | unit | 8/8 | `0:12` | [job log](…) · [output](…) |
| … |

</details>

<details><summary>✅ <code>modules/group</code> — 4 files · 4 passed · lane unit · ⏱ 0:31</summary>

…

</details>

<details><summary>⏭️ Not run (2)</summary>

| Test file | Lane | Reason |
|---|:---:|---|
| `modules/rg/tests/integration-subscription-rg-extra.tftest.hcl` | subscription | secrets unavailable (fork pull request) |
| `tests/setup/helper.tftest.hcl` | — | misplaced: not in a test root (see docs) |

</details>

[Workflow log](<run-url>)
```

Rules:

- **Headline**: counts in the fixed order failed · tolerated · passed · not run, each present only
  when non-zero; then files, lanes, and the wall-clock time from the earliest job start to the latest
  job end. `failed` counts jobs whose status is `fail` or `error` and not tolerated; `tolerated`
  those whose status is `fail` or `error` under `allow-failing-terraform-tests`; `not run` the
  misplaced and secrets-unavailable files.
- **Failed** section: present only when non-zero. One table row per file, sorted by path, then one
  `<details>` per file with its failed and errored run blocks and their diagnostics, one bullet per
  diagnostic. An `error` row shows `<span title="error (<reason>)">error</span>` in the Runs column
  when there are no run counts (reasons `init`, `terraform-version`, `not-initialised`, `invalid`,
  `not-discovered`, `file`).
- **Tolerated** section: same shape as Failed, with `⚠️` and the Result column carrying the tooltip
  `<status> (<reason>): allowed to fail`.
- **Per-root** collapsed sections for everything that passed, sorted by root path with `.` first.
  The summary line carries the root, file count, passed count, the lane when every file in the root
  shares one (else `<n> lanes`), and the root's summed time. Inside: the plain table.
- **Provider sets**: with one set nothing is shown. With more, the per-root summary lines and the
  failed and tolerated rows name the set's environments (`providers from staging`), so a file that
  fails under one set and passes under the other reads as such. A root with a floating test-only
  provider adds `· 1 test-only provider floating` to its summary line.
- **Not run**: one collapsed section, present only when non-zero.
- **Time** cells are `` `m:ss` `` from `elapsed-ms`; an em-dash when unknown.
- **Links**: `[job log](…)` then `[output](…)`, `·`-separated; a missing link is omitted, an empty
  cell rather than stray text.
- **Footer**: `[Workflow log](<run-url>)`.

Budget (P15, P21): the body must stay under 65 000 characters. Priority order when it would not:
(1) headline, failed table, tolerated table and footer are never trimmed; (2) each failed or
tolerated `<details>` is capped at 2 000 characters, tail-trimmed with `… (truncated, see job
log)`; (3) per-root tables collapse to their summary line only; (4) the not-run table collapses to
its summary line. The renderer applies steps in that order until the body fits.

### 6.5 Run-level step summary

The same body, with `[Workflow log]` omitted, appended to the summary job's `$GITHUB_STEP_SUMMARY`
on every event. This is the only reporting surface on `push` runs and on fork pull requests.

### 6.6 Headline annotation

The summary job emits one annotation so the checks pane says something without opening a job:
`::notice title=Terraform tests::12 passed` when everything passed, `::error title=Terraform
tests::1 failed, 12 passed` otherwise (tolerated failures produce a `::warning`).

## 7. Conclusion and gating

`conclusion.needs` gains `terraform-test`. The normative result table lives in
[Path-relevance.md §7.2](Path-relevance.md); for the test job it says: `success` is fine; `skipped`
is fine only while the builder's `tests-active` is not `'true'` (stage disabled, no test files, event not applicable); `skipped` while active, `failure`
and `cancelled` are red. A tolerated failure is a green job and therefore green. Tests are judged
independently of the environments, so a docs-only pull request still runs and is judged on its
tests. A non-tolerated failing test blocks the merge; auto-merge already requires the conclusion,
so nothing else changes.

`terraform-test-summary` stays out of `needs`. The structural test in
[`evaluate-automerge-eligibility`](../evaluate-automerge-eligibility/) asserts that the test job is
in the list.

## 8. Interplay with the rest of the workflow and with other specs

| Concern | Relationship |
|---|---|
| Environment jobs | Independent of the tests: same `create-matrix` and `seed-pr-comments` dependencies, and no `needs` between tests and environments (D8). The environment *stages* do have `needs` between themselves ([Environment-ordering.md](Environment-ordering.md)), which does not change D8: gating the first stage on tests would still delay every plan on every pull request by the slowest test, and would cost the reviewer the plan as well as the test result. The environment matrix's 256-job cap and the test matrix's are separate. |
| Environment init | Loads test files in the environment root (§4.9). Not something this spec can change; documented. |
| Per-goal environment variables | Do not reach test jobs (D6). |
| GitHub Environments | Lane environments are `tftest-*`, disjoint from the Terraform environments' `github-environment` values; the builder rejects a collision. The isolation preconditions of §3.6 are about the Terraform environments' credentials and are stated in the user guide. |
| Explicit conclusion (separate spec) | Adds "skipped for a benign reason" precision and the fork guard; this spec only adds the `needs` entry. |
| Provider versions for tests (formerly a separate need) | Folded into this spec, §5.3: tests inherit the environments' lock files per distinct set. No committed test lock, no verification step, no CLI change. |
| Terraform module cache | The test job runs the same phases and gates as the environment job (§5.3); the classifier additionally receives run-block module sources from the test file. |
| Single-file dispatch (separate spec) | Will add `workflow_dispatch` to the event rule together with a `tests-filter` input; the lane and slug vocabulary is what it filters on. |
| Per-environment path relevance ([Path-relevance.md](Path-relevance.md)) | Tests are not filtered by relevance yet; the `root` field is the hook. The conclusion table there judges tests independently of environments, and the test jobs' `if:` drop the seed-result clause for the reason its P3 gives. |
| Module CI | Unchanged (§9.7). |

## 9. Actions: new and changed

All follow [Action-implementation-guide.md](Action-implementation-guide.md): thin `action.yml`
shim, logic in `step_*.sh`, `run_all_tests.sh` with the canonical summary lines, a `#` description
line opening every `run:` block, bodies and large data as files.

### 9.1 Discovery in the decision engine

The create-matrix adapter (`create-tf-vars-matrix`, D20) gathers the facts in the same step that
builds the environment matrix: the committed test files (`git ls-files`, §4.1), the directories
holding `.tf` or `.tf.json` files, and each environment's lock file by `project-dir`, read and
reduced to provider names and versions. It reports them raw in the engine's input document
(`tests` section, Decision-engine.md §4), and the engine's `tests.py` derives roots, lanes,
environments, provider sets and rows, and performs every validation of this spec (P4): lane schema,
unique names, at most one fallback lane, glob grammar, the `tftest-` name pattern, environment-name
collisions, the 256 cap. The step publishes `tests-matrix-json`, `tests-count` and `tests-active`,
and the not-run list goes into `relevance.json`. Fixtures: the layouts of §4.2, every misplaced case
of §4.3, glob cases of §4.4 including the root-level `**/` case, a collision, a fork run, a
Dependabot run, a disabled run, a `push` and a `schedule` event.

Provider sets (§5.3): the engine groups environments by the hash of their locks' provider names
and versions, and expands every non-environment-root file into one row per set the lane's
`providers-from` allows. An environment root's file gets its own lock and no copy.

`create-tftest-matrix` is untouched: the module CI workflow keeps using its `all-tests` output until
that workflow migrates.

### 9.2 `terraform-test` (modernised)

Inputs: `test-file` (used as `-filter`, a leading `./` dropped), `working-directory` (the test
root), `junit` (default true; only from 1.11), `slug` (the directory under `$RUNNER_TEMP`),
`status-credentials`, `status-lock` and `status-init` (the outcomes of the job's earlier steps, so a
failure there is reported as `no-credentials`, `lock-platform` or `init` without running terraform),
`environments-lock-file` (the lock the written one is compared with), and the compatibility switches
`azure-login` and `upload-artifact` (default `auto`, on only for the module CI call shape). Files go
under `$RUNNER_TEMP/<slug>/`, never `$GITHUB_WORKSPACE`: `test.json`, `report.txt`, `junit.xml`,
`runs.json`, `diagnostics.json`, `providers.json`.

Outputs, all small, large content only as a path: `status`, `reason`, `passed`, `failed`,
`errored`, `skipped`, `total`, `elapsed-ms`, `summary`, `exit-code`, `terraform-version`,
`runner-platform` (`linux_amd64`, …), `test-file-path`, `json-file`, `report-file`, `junit-file`,
`runs-json-file`, `diagnostics-json-file`, `providers-json-file`, `providers-summary`
(`null 3.2.3 environments · random 3.9.1 floating`), `providers-floating-count`, `failed-runs-json`
(the failed and errored runs with their first diagnostics, at most 3000 bytes) and
`failed-runs-omitted`; `json` and `report` stay as aliases for module CI. Behaviour: §3.5, §5.4,
§5.5, §5.7, §5.8. Fixtures: JSON logs captured from a real Terraform 1.16.2 with credential-free
providers for every classification of §5.5, with the version noted, and a fake `terraform` that
replays them.

### 9.3 `create-test-summary` (new)

Inputs, all optional and each degrading on its own: `metadata-files-pattern` (default
`terraform-test-meta-*.json`); `tests-matrix-json`, the builder's matrix, captured as
`toJSON(inputs.tests-matrix-json)` and written to a file, for reconciling rows without metadata
(§6.2 step 5); `not-run-file`, the path of `relevance.json` (read at `.tests.not_run`) or of a bare
list of `{file, lane, reason}`; `jobs-json-file`, the Jobs API's jobs, one list or object per page,
for tests; empty, the action pages the run's jobs itself through `gh api` into a temp file, which
needs `github-token` with `actions: read`; `run-url`; `output-file-suffix`. Outputs: `body-file`
(at most 65 000 characters, without the marker), `step-summary-file`, `head-marker`
(`<!-- tf:head:tests:<caller> -->`), `failed-count`, `tolerated-count`, `passed-count`,
`not-run-count`. The action appends the step summary to `$GITHUB_STEP_SUMMARY` and emits the
headline annotation of §6.6 itself, and always exits 0.

It reads from each metadata file `.metadata.schema_version`, the row under `.matrix_context`
(`slug`, `test.file`, `root`, `lane`, `allow-failing-terraform-tests`, `github-environment`,
`root-kind` and the provider-set fields), the `terraform-test` outputs under `steps.test.outputs`,
and `steps.upload-test-output.outputs.artifact-url`. When the test step left no status, the outcomes
of the steps with ids `verify-credentials`, `provider-versions` and `init` classify the row as
`no-credentials`, `lock-platform` or `init`. A matrix row without metadata whose job did not succeed
counts as failed with reason `job did not run`, never tolerated.

Goldens: all green; one failure; a tolerated error; an init error; a `no-credentials` error carrying
the bring-up commands; a `lock-platform` error with the fix; misplaced and secrets-unavailable rows;
rows without metadata; several provider sets; a body over budget at each trim step, and a last-resort
cut that closes open fences and `<details>`; a run with zero rows; missing job links. ARG_MAX: the
Jobs API response and every metadata file are read from disk with `jq --slurpfile` or `-f`; the body
is assembled by appending to a file, never in a shell variable.

### 9.4 `capture-matrix-job-meta`

Two optional inputs: `entity-name` (what `environment-name` really is; the old name stays as an
alias, and when both are given and differ `entity-name` wins with a warning) and `artifact-name`
(default `matrix-job-meta-<entity>`), which sets **both** the artifact name and the JSON file's
basename (P7) and is also an output. The JSON keeps `.metadata.environment` for the entity. Existing
callers see no change.

### 9.5 `terraform-init`

Inputs `backend` (boolean, default `true`), `lockfile-mode` (`default` | `readonly` |
`readonly-if-present`, default `default`) and `plugin-cache-may-break-lock-file` (boolean, default
`false`), as §5.3. The may-break export for the project init is an explicit opt-in, not implied by a
writable lock: the environment job inits a committed lock with the plugin cache set, and there the
variable would record new providers with one platform's checksum and fail init on a cached package
the lock does not cover. It applies only with a plugin cache directory set and a writable lock.
Unknown values fail the step before init runs. Existing callers see no change.

### 9.6 Workflow changes

- `create-matrix`: new job outputs `tests-matrix-json`, `tests-count`, `tests-active`, from the
  existing step (D20).
- `seed-pr-comments`: the tests head in the manifest after the environment heads (§6.3).
- The `terraform-test` job (§5) and the `terraform-test-summary` job (§6).
- `conclusion.needs` (§7).
- Structural tests: the new jobs' `with:` keys against their actions' inputs; gates after reporting
  steps; the test job in the conclusion's needs; `terraform-test-summary` not; the test job's
  environment name taken from the row.

### 9.7 Module CI

Untouched by this spec. `terraform-module-ci.yaml` keeps `create-tftest-matrix`'s `all-tests`
output and `create-test-report`, and calls `terraform-test` as before, with `test-file` only. That
call shape keeps the action's embedded login and upload (its `auto` switches), runs from the
workspace with `-filter=tests/<file>`, and applies no version floor. Visible changes for module CI:
a filter that matches no file is now red (`not-discovered`) instead of passing silently, the summary
line loses its JSON quotes (the report builder matches `Success!` either way), and the report has
the new format. Passing `working-directory` from module CI would switch its login and upload off;
migrating it to the summary job is a follow-up once this has run for a while.

### 9.8 `export-env-vars` (modernised)

Converted to the layout guide with its current behaviour pinned as goldens first, then one new
optional input, `export-secrets-with-prefixes-json` (JSON array of name prefixes, default `[]`):
every secret in `secrets-json` whose name starts with one of the prefixes is exported under its own
name, before the explicit mapping and the plain variables are applied, so those override it
(§3.2). Existing callers see no change. The prefix export is the only new code path; its tests
cover prefix selection, case, ordering and an empty list. An empty prefix is refused, since it
would export the whole secret bag, the token included. A second optional input,
`lower-case-copies-for-prefixes-json` (default `[]`), follows each prefix-exported secret whose name
starts with a listed prefix with a copy whose name after the prefix is lower-cased (P44); no copy
is made when a secret of the lower-cased name is itself exported, and the list is validated like the
prefix list, before anything is exported. The converted shim does not use
`allexport`: secret values pass through shell variables, and under it they would reach the
environment of every process the step starts.

### 9.9 `terraform-module-cache`

One new optional input for the resolve phase, `test-directory`: what `terraform test` gets as
`-test-directory`, normally `tests`. When it is set, the action reads the run-block `module {}`
declarations of every test file init loads for each directory it audits, `<dir>/*.tftest.hcl` and
`<dir>/<test-directory>/*.tftest.hcl`, itself rather than being handed them, so what it audits is
exactly what init installs. A registry declaration goes through the existing version classifier, so
a range keeps the root uncached; a local one is walked with the existing remote-module walk,
relative to the root. Every declaration enters the digest under Terraform's own module key,
`test.tests.<file>.<run>`; a declaration it cannot read (no literal source) and any `.tftest.json`
file keep the root uncached. Verify, snapshot and prune need no change: they classify by source and
the run-block modules sit under the root's own `.terraform/modules`. Empty, the default, reads
nothing; existing callers see no change.

### 9.10 `verify-terraform-lock`

Two new optional inputs. `lock-only: true` checks the lock file on its own, before any init: the
providers the lock records, at their locked versions, become a throwaway configuration in a
temporary directory, and `terraform providers lock -platform=…` runs there against a copy of the
lock. The committed file is never touched, the directory needs no `.terraform/`, and its own
configuration plays no part, which is what a copied lock needs (P42). `providers lock` rewrites the
copy's `constraints` to the exact version, so the comparison ignores constraints lines.
`plugin-cache-directory` lets lock-only mode hash the packages in a Terraform plugin cache
(`-fs-mirror`, whose unpacked layout the cache already has) when it holds every locked provider for
every required platform, and otherwise the packages are downloaded; a warm cache makes the check
offline. The default mode, which the environment job uses, is unchanged.

## 10. Pitfalls

Indexed so implementation commits and future specs can cite them.

| # | Pitfall | Consequence | Rule |
|---|---|---|---|
| P1 | A job-level `if:` cannot parse YAML; `contains(<yaml>, github.event_name)` is a substring test. | An events list input would misfire on `pull_request_target` or whitespace. | Fixed event rule in the `if:`; the builder folds the rest into `tests-active` (§5.1). |
| P2 | An empty matrix fails the job ("Matrix vector … does not contain any values"). | A repository without tests goes red. | Gate the job on `tests-active`. |
| P3 | Artifact names may not contain `/`, `:`, `"`, `<`, `>`, `\|`, `*`, `?`, `\`, newlines. | The old action's `test-results-output-<file>` breaks on a path-shaped file. | Slugs (§4.6) name artifacts. |
| P4 | A typo in a lane key or glob silently routes files to the wrong lane. | Tests run without credentials, or with the wrong ones. | Unknown lane keys and bad globs are validation errors; the summary shows the lane per file. |
| P5 | `find` order is filesystem-dependent. | Collision suffixes and job order swap between attempts; links break. | Sort paths before deriving slugs; hash-based suffix. |
| P6 | In bash, `**` is `*` and `*` crosses `/`. | `**/unit-*.tftest.hcl` misses a root-level file. | The grammar in §4.4 with its own fixtures. |
| P7 | `capture-matrix-job-meta` strips keys containing `secret`, `credential`, `token`, `auth`, `password`; its file is `matrix-job-meta-<name>.json`. | A field named `requires-credentials` vanishes; test metadata matches the environment aggregator's glob. | `fork-safe`; `artifact-name` sets the basename too. |
| P8 | `init -lockfile=readonly` on a copied lock rejects both the removal of providers the tests do not need and the addition of test-only ones. | Every non-environment test root fails init. | Read-only mode for environment roots only; `default` elsewhere (§5.3). |
| P9 | `-verbose` embeds full provider schemas per run block (megabytes for large providers). | Log, artifact and every downstream buffer explode; ARG_MAX territory. | Never default; document `TF_CLI_ARGS_test`. |
| P10 | An environment's own `init` and `validate` load test files in its root; a parse error in any test file of a root fails init for that root. | A broken test file blocks plan and apply for that environment; a broken sibling breaks every job of its root. | Documented (§4.9); `allow-failing-terraform-tests` cannot cover it. |
| P11 | A concurrency group allows one running and one pending job; a newer arrival cancels the pending one, and cancelled reddens the conclusion. | A per-lane group cancels this run's own matrix rows. | Group per test file (§5.1). |
| P12 | `terraform test` state is in memory; a job killed by timeout or cancellation leaves objects nothing can destroy. | Leaked test objects in a real tenant. | Short per-lane timeouts; the calling repository runs a janitor keyed on a naming prefix. |
| P13 | The plugin cache serves a provider only when the lock records its checksum, and the copied lock records none for test-only providers. | Floating providers download from the registry on every job. | `default` mode exports the may-break variable for non-environment roots; the throwaway lock's single-platform hashes cost nothing (§5.3). |
| P14 | OIDC needs `id-token: write` even when `azure/login` is skipped. | A directory-only lane fails to mint a token. | Permission on the job (§5.1). |
| P15 | Under `set -o allexport` any large shell variable ends up in envp; JSON logs and API responses are large. | Exit 126 "Argument list too long" in production, never in tests. | Files and paths only (CLAUDE.md rule); the summary appends to a file. |
| P16 | A `-filter` that matches nothing warns, reports zero files and exits 0. | A renamed file or a mis-derived root is a green job. | Status `not-discovered` unless `rel` is in `test_abstract` (§5.5). |
| P17 | Ten error annotations per step, fifty per job. | Extra diagnostics are dropped silently. | Cap at ten, say how many more (§5.7). |
| P18 | The Jobs API can fail or paginate; job names carry the caller's prefix; step numbers shift when steps are added. | Broken or wrong links. | Temp file, `--paginate`, `endswith`, step by name, `#logs` fallback (§6.2). |
| P19 | Two callers on one pull request both run tests and share a marker. | The head flips between runs. | Marker scoped per caller (§6.3); guide says disable in one. |
| P20 | The old `terraform-test` action logged in unconditionally and wrote into `$GITHUB_WORKSPACE`. | Fails without ARM variables; pollutes self-hosted workspaces. | Login in the workflow, conditional; files under `$RUNNER_TEMP`. |
| P21 | Comment bodies over 65 536 characters are rejected. | No comment at all. | The budget order in §6.4. |
| P22 | `hashicorp/setup-terraform`'s wrapper rewrites stdout and exit codes. | The `-json` stream is unparseable. | `terraform_wrapper: false`. |
| P23 | The seed placeholder's title must equal the final title. | The head renames itself mid-run and reads as a different comment. | One title constant, tested. |
| P24 | `secrets: inherit` is what makes lane secrets resolvable; a caller without it gets empty values. | Credentialed lanes fail with an unhelpful error. | `export-env-vars` already fails on a missing secret; the guide repeats the requirement. |
| P25 | A test file that references `var.x` needs a `variable "x" {}` block from Terraform 1.13; `TF_VAR_x` alone reaches only a variable the root module declares. | "Variables not allowed", "Reference to unavailable variable" or "Required variable not set". | Authoring note (§3.2); P45 for 1.12. |
| P26 | GitHub documents that a called job which declares `environment:` uses that environment's secrets; in practice they resolve empty unless the caller also passes `secrets: inherit`. | A caller without `inherit` gets an environment lane with empty credentials. | `secrets: inherit` is already mandatory (P24); the credential check turns the symptom into a named error. Reproduced on the test bed: with `inherit` the called job's environment secret resolved, without it the secret was empty although the job's token subject named the environment. |
| P27 | `deployment: false` cannot be combined with a custom deployment protection rule on the environment; without the key every job records a deployment. | Either a job that cannot start, or ten timeline entries per run. | No protection rules on `tftest-*` environments (§3.6). |
| P28 | The prefix export takes `ARM_*` and `TF_VAR_*` from the whole secret bag; a job cannot tell which level a secret came from. | An organisation- or repository-level secret with such a name would reach every environment lane. | Precondition: organisation and repository secrets follow the `ORG_*` / `REPO_*` naming rule, stated in the guide. Lanes without an environment get no prefix export. |
| P29 | Required reviewers or a branch policy on a `tftest-*` environment. | Every pull request's test jobs wait 30 days and fail, or are refused before a step runs. | Never add protection rules to `tftest-*` environments; the summary renders refused jobs from the Jobs API (P33). |
| P30 | The builder sees only this run's Terraform environments; another workflow in the repository may reference a `tftest-*` environment, and anyone who can edit workflows can create one. | The wildcard credential trusts every `tftest-*` environment in the repository. | Acceptable for a sandbox identity; documented. Use exact-subject credentials where it is not. |
| P31 | Repositories created, renamed or transferred after 15 July 2026 emit the immutable subject; opting an existing repository in is repository-wide. | A name-based classic credential stops matching; opting in also changes the plan and apply jobs' subjects. | Read a real token before writing a credential; prefer the flexible form of §3.6; migrate every credential of the repository together. |
| P32 | A plan or apply identity that still trusts `pull_request` or a branch subject. | A no-environment test job on the same event can mint its token; client IDs are not secret. | Isolation precondition 2 (§3.6): apply identities carry `environment:` credentials only. |
| P33 | A job refused by a protection rule, cancelled before its first step, or waiting for approval produces no metadata artifact. | The summary would lose the file while the conclusion counts it. | The summary reconciles matrix rows against metadata and renders the rest from the Jobs API (§6.2). |
| P34 | A collaborator with write access can set environment secrets through the REST API and `gh`, but not through the settings UI, and cannot create, configure or delete an environment; the environment must exist first. | A collaborator who goes through the UI is refused; one who runs `gh secret set --env` before the first run gets `failed to fetch public key: HTTP 404`. | Bring-up order in §3.6: the first run creates the environment, then `gh secret set --env`. Verified with a write-role account. |
| P35 | GitHub compares environment names case-insensitively but puts the stored name, case and all, into the token subject, and a flexible credential's `matches` compares case-sensitively (verified in Entra; undocumented). | A mixed-case environment name matches the environment but not the credential: `AADSTS7002131`. | The `tftest-` pattern is lowercase only; the builder lowercases and rejects an explicit name with upper case. |
| P36 | Environments whose lock files differ produce one test job per file per distinct set. | The test matrix doubles while two environments disagree. | By design: the disagreement is what the extra run verifies. `providers-from` narrows a lane; re-aligning the environments returns to one set. |
| P37 | The module-cache classifier reads `module` blocks in `.tf` files; a test file's `run { module { source } }` is invisible to it. | Verified: a registry run-block source with a version range was keyed from the `.tf` files alone and judged safe to save, and a restored cache kept its old version after the range moved; a local run-block source reaching a registry module was not cached at all. | The resolve phase takes the run-block declarations of every test file in the root: a range keeps the root uncached, local sources are walked (§5.3, §9.9). |
| P39 | With `TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE` on, a cached package whose checksum the lock does not record for the runner's platform fails init instead of being downloaded again; read-only init on such a lock leaves a package `terraform test` refuses. | A copied environment lock without the runner's platform fails every warm-cache init of that set with a checksum error. | Every lock a test job uses must record the runner's platform: step 7 checks it and fails with `lock-platform`, naming the fix (§5.2, §5.3). |
| P40 | `hashFiles()` returns `''` when nothing matches. | Every environment root without a lock file shares one plugin-cache key. | The key carries a fallback, or the cache step is skipped without a lock (§5.2). |
| P41 | `actions/cache` saves only the first entry for a key. With the environment job's key, the environment job saves first. | Test-only providers never reach the cache, and every test job downloads them. | The test job's key has its own `-tftest` suffix and falls back to the environment job's key through `restore-keys` (§5.2 step 7). |
| P38 | Thirty init runs per pull request multiply exposure to transient registry and network failures. | Red jobs unrelated to the code. | Provider and module caches, authenticated module downloads; re-running failed jobs re-runs only the failed files. |
| P42 | `verify-terraform-lock` in its default mode runs `terraform providers lock` against the directory's initialised configuration. | Before init it refuses to run ("Expected '.terraform/' to exist"), and a copied lock does not describe the test root's configuration anyway: every test job reported `lock-platform`. | Lock-only mode checks the lock against a configuration built from the lock itself, in the directory where the lock is committed, after the plugin cache is restored (§5.2 step 7). |
| P43 | The summary finds each job by its display name, and the engine suffixes a name with its provider set only for a file that runs in more than one set. | Rebuilding the name with a suffix whenever the run has several sets missed every job of a narrowed lane or an environment root: no job links, and an environment root's empty set counted as a set. | The summary matches on the row's own `name` and counts only non-empty sets. |
| P44 | GitHub stores secret names upper-cased; Terraform variable names are case-sensitive. | An environment secret `TF_VAR_x` arrives as `TF_VAR_X` and sets only `X`; a test declaring `x` fails with "Required variable not set". | The export adds a lower-cased copy of every `TF_VAR_*` secret (`export-env-vars`' `lower-case-copies-for-prefixes-json`); a mixed-case name needs an explicit mapping (§3.6). |
| P45 | Terraform 1.12 refuses a `variable` block in a test file, which 1.13 requires for `var.x` in the file. | Init fails for every test file of the root under 1.12, which read as `init` and hid the version. | The floor is 1.13 (§3.5), and a failed init defers to it (§5.5 row 1). |

## 11. Test coverage

**Must**

- The engine's `tests.py`, under the coverage and mutation gates: every layout row of §4.2 yields the stated root and rel; every case of
  §4.3 is misplaced; the glob grammar cases of §4.4; first-match-wins and the fallback lane;
  unmatched files land in `default` with empty maps; credentialed rows dropped on fork and on
  Dependabot with the right reason; `tests-active` false for `schedule`, `workflow_dispatch`,
  disabled, and zero files; a collision gets a deterministic suffix; unknown lane keys, two fallback
  lanes, a bad glob and 257 files fail with the documented messages; the matrix JSON has `slug` at
  top level and a JSON boolean for `allow-failing-terraform-tests`; `github-environment: auto`
  resolves to `tftest-<lane>`, an explicit name without the prefix or with upper case is rejected,
  a name equal to a Terraform environment's `github-environment` is rejected case-insensitively,
  rows carry their environment name and the rest an empty one, and an environment lane is
  `fork-safe: false` even with an empty mapping; identical environment locks collapse to one
  provider set, differing locks yield one row per file per set with `--<set-id>` slugs and the
  bracketed job name, `providers-from` narrows a lane to the named environments' sets, an
  environment root gets `root-kind: environment` and no lock to copy, and an environment without a
  lock file is reported and contributes no set.
- `terraform-test`: each classification of §5.5 from its fixture; the version gate; `-junit-xml`
  passed only from 1.11; outputs match the fixture's counts; `elapsed-ms` from timestamps; diagnostic
  files prefixed with the root; at most ten annotations plus the warning; report capped at 65 000;
  nothing large in `$GITHUB_OUTPUT`; resolved provider versions parsed from the written lock and
  classified as from-environments or floating against the copied lock.
- Workflow structural tests: the test jobs' module-cache step sequence and gates equal the
  environment job's, and the provider cache key hashes the test root's lock.
- `create-test-summary`: goldens of §9.3 byte-for-byte; the budget trim order; headline counts;
  sort order; missing links omitted; zero rows renders the "no test files" body; a metadata file
  with an unknown schema version is skipped with a warning.
- `capture-matrix-job-meta`: `artifact-name` sets artifact and basename; default unchanged (golden).
- `export-env-vars`: goldens of the current behaviour before the conversion; the prefix export
  selects exactly the names with a listed prefix, is case-sensitive, is overridden by the explicit
  mapping and by plain variables, and does nothing for an empty list.
- The lock check of §5.2 step 7: a lock without the runner's platform fails with `lock-platform` and skips init; the runner's platform is derived from `runner.os` and `runner.arch` for both architectures.
- `terraform-init`: `backend: false` adds the flag; `readonly-if-present` adds `-lockfile=readonly`
  with a lock and the may-break variable without; default unchanged.
- `terraform-module-cache`: a registry run-block declaration with a range keeps the root uncached;
  a local one reaching a remote module is walked; the declarations change the digest; no input, no
  change (§9.9).
- Workflow structural tests: §9.6.

**Should**

- The module CI workflow's test job still passes with the modernised `terraform-test`, and
  `create-tftest-matrix`'s `all-tests` output is unchanged.
- The seed manifest places the tests head last and only when `tests-count > 0`.
- The summary's Jobs-API resolver handles a caller-prefixed name and two pages.

**Could**

- A property-style test feeding random paths through the root rule and asserting Terraform's
  discovery agrees (needs a Terraform binary in CI).
- A rendered-size test that a 256-row summary fits the budget after trimming.

**What tests cannot cover**: real OIDC token minting per lane and the subject it carries, environment
secrets reaching a called job, `deployment: false`, a collaborator with write access setting
environment secrets, `azure/login` skipping, artifact URL validity, the `#step:N:1` anchor, the
256-job cap, the exact behaviour of an environment root with a real backend. These are verified
through a preview ref on a test-bed calling repository and recorded in §15.

## 12. Open questions

What probes on the test bed, in Entra and a sandbox subscription, with a local Terraform 1.16 and in
the documentation could answer is answered in the text above. What remains:

1. **Dependabot runs and OIDC**: whether `id-token: write` is honoured on a Dependabot-triggered pull
   request run, and what `github.actor` and `github.triggering_actor` read on it and on a human
   re-run. The docs contradict each other on raising a Dependabot run's token permissions. The
   design drops credentialed rows on Dependabot runs either way (§4.7), so this is for the pitfalls
   table; it needs a real Dependabot pull request.
2. **Fork runs and environment creation**: whether a fork pull request's run that references a
   missing environment creates it. The docs are silent on forks; the design never references one
   from a fork (§4.7). The test bed cannot answer it: the organisation's policy refuses a fork of
   its private repositories into a personal account. Needs a public repository to fork.

## 13. Implementation order

One commit each, in this order, each green on its own:

1. `docs:` this spec.
2. `feat(terraform-init):` `backend` and `lockfile-mode` inputs, tests.
3. `feat(capture-matrix-job-meta):` `entity-name` and `artifact-name` inputs, tests.
4. `test(export-env-vars):` pin the current behaviour as goldens.
5. `refactor(export-env-vars):` modernise to the layout guide; goldens green.
6. `feat(export-env-vars):` `export-secrets-with-prefixes-json`, tests.
7. `test(terraform-test):` pin the current outputs as goldens before touching the action.
8. `refactor(terraform-test):` modernise to the layout guide; behaviour unchanged, goldens green.
9. `feat(terraform-test):` working directory, version gate, classification, annotations, outputs;
   JSON fixtures per classification.
10. `feat(terraform-module-cache):` the run-block declarations input of §9.9, tests.
11. `feat(engine):` `tests.py`: roots, lanes, environments, provider sets, exclusions, rows and
    their validation, test first, under both gates.
12. `feat(engine):` the adapter's test facts and the published tests outputs; fixtures.
13. `feat(create-test-summary):` the new action with goldens.
14. `feat(workflow):` `create-matrix` outputs, seed manifest, the test job, the summary job,
    conclusion `needs`; structural tests.
15. `docs:` user guide including the bring-up procedure and the isolation preconditions, PR comments
    spec, README index, CLAUDE.md overview.
16. Validation through a preview ref on the test-bed calling repository, with fixtures for every
    classification, a mapped lane and an environment lane; findings into §15 and the pitfalls table.

AI-assistant configuration files are never in these commits.

## 14. Documentation to update

- [Workflow-terraform-ci-default.md](Workflow-terraform-ci-default.md): the new inputs, the lane
  example, the layout guidance of §4.2 and §4.9, the two-caller rule, the `secrets: inherit`
  reminder, the environment bring-up procedure, the two isolation preconditions and the
  federated-credential forms of §3.6.
- [Workflow-pr-comments.md](Workflow-pr-comments.md): the `tf:head:tests:<caller>` marker in the
  namespace table, its seed position in §3.1, the delete rule in §4, §8.1's two-caller note.
- [Testing-in-ci.md](Testing-in-ci.md): nothing; the new actions enrol in CI like every other.
- `README.md`: action index entries; `CLAUDE.md`: one line in the overview and the docs list.

## 15. What implementation taught the spec

- **Discovery moved into the engine** (D20). The create-matrix adapter lists the committed files
  and the locks in the step that builds the environment matrix, and `tests.py` decides under both
  gates; `create-tftest-matrix` stays for module CI. The row gained `name`, the job's display name
  with the provider-set suffix, because a job's `name:` expression cannot count the sets.
- **One test job** (D21): an empty environment name means no environment, verified in a called
  workflow.
- **The earlier steps report through the test step.** The credential check, the lock check and init
  are `continue-on-error`, the test step runs whatever happened and reports `no-credentials`,
  `lock-platform` or `init` from their outcomes, and the summary falls back to those outcomes when
  the test step left no status. The capture action uploads the metadata itself, so there is no
  separate upload step.
- **Init's may-break export is an explicit opt-in** (`plugin-cache-may-break-lock-file`), because
  deriving it from a writable lock would have changed the environment job, which inits a committed
  lock with the plugin cache set.
- **The lock check needed its own mode** (P42). The first validation run reported `lock-platform`
  for every job: the default mode needs an initialised directory and checks the directory's
  configuration, not the lock. `verify-terraform-lock` gained `lock-only` and
  `plugin-cache-directory`; the check moved after the plugin cache restore and reads the lock where
  it is committed, so its own fix command names the environment.
- **Job names come from the row** (P43), and an environment root's empty provider set is not a set.
- **Validation on the test bed** covered pass, assertion failure, run error with a skipped
  follower, file errors (a required variable, an unknown provider), init failing for a whole root
  from one file's parse error, `no-credentials` in a lane environment the run itself created,
  `lock-platform` on one of two provider sets, a tolerated failure, a secret mapping with a plain
  variable, an environment's `TF_VAR_*` secret, an environment root's own tests, an empty
  repository-root `tests/`, misplaced and excluded files, and job links and artifacts for every
  row. It found P42 to P45.
- **The module cache reads the test files itself** (`test-directory`) rather than being handed
  JSON: no second reader to drift from what init installs. It showed that the environment job had
  the same exposure for an environment with a `tests/` directory, and it now passes
  `test-directory: tests` too.
- **`export-env-vars` keeps its order**: the secret mapping is applied after the plain variables, as
  it always was, so §3.2's order became prefix export, plain variables, mapping.
- **Terraform 1.16 classifies differently from the draft** in three places (§5.5): an uninitialised
  root reports a `test_abstract` with a run error, a single missing package says "there is no
  package for", and a file-level error still emits skipped runs. `test_summary`'s text counts an
  errored run as failed; the counts come from its numeric fields.
- **Module CI sees three changes** through the shared `terraform-test`: a file Terraform cannot find
  now fails instead of passing silently, the summary line loses its quotes, and the report has the
  new format (§9.7).
