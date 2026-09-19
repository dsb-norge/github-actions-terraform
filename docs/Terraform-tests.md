# Terraform tests in the default workflow

Authoritative spec for the `terraform test` stage of
[`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml): how test files are
discovered, how each one becomes a job, how credentials reach a test, how results reach the pull
request and the run page, and how a failing test blocks a merge.

Status: **specification, not yet implemented.** The decisions in §2 are settled; §12 lists what
still needs testing before or during implementation. §15 is reserved for what implementation
teaches the spec.

Out of scope: [`terraform-module-ci.yaml`](../.github/workflows/terraform-module-ci.yaml) keeps its
own test job and per-file comments for now (§9.7); per-environment path relevance, single-file
dispatch and test-root lock verification are separate specs that hook into this one (§8).

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
| D11 | Terraform **1.12.0 is the floor**, enforced at runtime; 1.14.1 recommended where a test root commits a lock file. | The empty-root layout needs 1.12 (§4.2); `providers lock` only sees test-only providers from 1.14.1 (§5.3). |

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
    extra-envs-yml:
      ARM_USE_OIDC: true
    extra-envs-from-secrets-yml:
      ARM_TENANT_ID: TESTS_DIRECTORY_TENANT_ID
      ARM_CLIENT_ID: TESTS_DIRECTORY_CLIENT_ID
      TF_VAR_test_client_id: TESTS_DIRECTORY_CLIENT_ID
  - name: subscription
    match:
      - "**/integration-subscription-*.tftest.hcl"
    runs-on: "some-runner-group"
    timeout-minutes: 60
    allow-failing-terraform-tests: true
    extra-envs-yml:
      ARM_USE_OIDC: true
    extra-envs-from-secrets-yml:
      ARM_TENANT_ID: TESTS_SUBSCRIPTION_TENANT_ID
      ARM_SUBSCRIPTION_ID: TESTS_SUBSCRIPTION_ID
      ARM_CLIENT_ID: TESTS_SUBSCRIPTION_CLIENT_ID
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
| `github-environment` | reserved | Rejected with "not implemented" for now. A later spec lets a lane take a GitHub Environment for environment-scoped secrets and an `environment:<name>` OIDC subject; the key is reserved so the schema does not move. |

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
- A lane with a non-empty `extra-envs-from-secrets-yml` is a **credentialed lane**; its files are
  not runnable where secrets are unavailable (§4.7).

Authoring note for lane variables: from Terraform 1.13 a test file must declare a
`variable "x" {}` block for every `var.x` it references, so a lane that sets `TF_VAR_x` only helps
a test file that declares `x`. The block is harmless on older versions.

### 3.3 Login

`azure/login` runs in a test job only when `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID` and
`ARM_CLIENT_ID` are all set after the lane's variables are exported: the same rule the environment
job uses. A directory-only lane omits the subscription and never logs in; the `azuread` and
`azurerm` providers mint their own OIDC tokens from `ARM_USE_OIDC` plus client and tenant ID. The
job therefore always carries `permissions: id-token: write` (P14).

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
`error`, reason `terraform-version`, when the version is below **1.12.0**. Below that version the
empty-root layout does not initialise ("Module not installed"), `-parallelism` is unknown and run
blocks cannot declare `parallel`. The message names the floor and points here.

Recommended: **1.14.1** or later wherever a test root commits a `.terraform.lock.hcl`, because
`terraform providers lock` ignores providers required only by tests before that version and a
readonly init then rejects the lock (P8).

## 4. Discovery and the matrix

Discovery runs once per workflow run, in the existing `create-matrix` job, through the modernised
[`create-tftest-matrix`](../create-tftest-matrix/) action. It produces the test matrix, the count,
and the lists of files that are not run and why.

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
those modules and the test file's `provider` / `mock_provider` blocks require (§5.3). Every run block
in such a file must name its module.

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
- A pattern containing no `/` is matched against the basename alone.
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
    "root": "modules/net",
    "rel": "tests/unit-net.tftest.hcl",
    "lane": "unit",
    "runs-on": "ubuntu-latest",
    "terraform-version": "1.15.x",
    "timeout-minutes": 30,
    "allow-failing-terraform-tests": false,
    "fork-safe": true,
    "extra-envs": {},
    "extra-envs-from-secrets": {}
  }
}
```

- `extra-envs` holds the lane's verbatim variables; `extra-envs-from-secrets` holds env-name to
  secret-name pairs. **Names only, never values.** The matrix JSON is printed in every job's setup
  log, as the environment matrix already is.
- `fork-safe` is `false` for credentialed lanes. It is named for what it is, not
  `requires-credentials`: [`capture-matrix-job-meta`](../capture-matrix-job-meta/) strips any key
  whose name contains `secret`, `credential`, `token`, `auth` or `password`, and the summary needs
  this field from the metadata (P7). The same filter drops `extra-envs-from-secrets` from the
  artifact, which is fine.
- `allow-failing-terraform-tests` is a JSON boolean because the workflow passes it to `fromJSON()`
  in `continue-on-error`; `fromJSON('')` is a hard error, so the builder always emits one.

Outputs of the builder: `tests-matrix-json`, `tests-count` (rows that will run), `tests-active`
(`'true'` when enabled and count > 0 and the event qualifies), `tests-not-run-json` (a list of
`{file, lane, reason}` for misplaced and secrets-unavailable files, consumed by the summary).

### 4.6 Slugs and names

`slug` = `<root with '/' replaced by '-', or 'root' for '.'>--<basename without extension>`, reduced
to `[A-Za-z0-9._-]` and at most 100 characters. Discovery is sorted, so on a collision the later
file appends `-<first 6 hex of sha256 of its path>`; the suffix is deterministic across runs.

The slug names the job's artifacts (`terraform-test-log-<slug>`, `terraform-test-meta-<slug>`),
which is why `/` cannot appear in it (artifact names forbid it, P3), and it is the metadata file's
entity name.

The job's display name is `Terraform test (<file>)` with the repository-relative path, unique by
construction and the key the summary uses to find the job in the Jobs API (§6.2).

### 4.7 Fork and Dependabot pull requests

Secrets are not available to a pull request from a fork, and the token is read-only; Dependabot
pull requests likewise run without repository secrets. Rows whose lane is credentialed are dropped
by the builder when `github.event.pull_request.head.repo.fork == true` or `github.actor ==
'dependabot[bot]'`, and listed with reason `secrets unavailable` (§6.4). Fork-safe rows run. On a
fork the PR comment is not posted at all (the seed job already skips forks); the step summary is.

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

Recommended layouts are the repository-root `tests/` with mocks and `module { source = "./main" }`,
or `tests/` beside a module. Callers who want a guard rail add `envs/**` to
`terraform-test-exclude-paths-yml`; it is not a built-in exclusion.

## 5. The test job

### 5.1 Job definition

```yaml
terraform-test:
  name: "Terraform test (${{ matrix.test.file }})"
  needs: [create-matrix, seed-pr-comments]
  if: |
    !cancelled()
    && needs.create-matrix.result == 'success'
    && needs.create-matrix.outputs.tests-active == 'true'
    && (needs.seed-pr-comments.result == 'success' || needs.seed-pr-comments.result == 'skipped')
  runs-on: ${{ matrix.test.runs-on }}
  timeout-minutes: ${{ matrix.test.timeout-minutes }}
  permissions:
    contents: read
    id-token: write
  strategy:
    fail-fast: false
    matrix: ${{ fromJSON(needs.create-matrix.outputs.tests-matrix-json) }}
  concurrency:
    group: ${{ github.repository }}-terraform-test-${{ matrix.slug }}
    cancel-in-progress: false
```

- `tests-active` folds enabled, count and event into one output because a job-level `if:` cannot
  parse YAML and must never receive an empty matrix (P1, P2).
- Concurrency is **per test file**, not per lane: a per-lane group would leave one row running, one
  pending and cancel the rest of this run's own matrix, and cancelled reddens the conclusion (P11).
  Per-file groups serialise the same file across overlapping runs, which is what protects
  integration tests that create fixed-name objects, and leave sibling files parallel. The
  one-pending caveat of GitHub's default queue applies exactly as it does to the environment job; if
  the workflow later adopts `queue: max` there, it adopts it here too.
- `timeout-minutes` is per lane because a job killed mid-apply leaves objects that no state file
  knows about (P12).
- There is no `environment:` on the job. That is the reserved `github-environment` lane key (§3.2).

### 5.2 Steps, in order

Every step has a `name:`; the summary finds the test step by name in the Jobs API, and the log
groups need readable titles.

| # | Step | Notes |
|---|---|---|
| 1 | `🧹 Clean workspace` | `dsb-norge/directory-recreate@v1`. `runs-on` is caller-overridable to self-hosted groups where a stale `.terraform/` survives checkout. |
| 2 | `⬇ Checkout` | `actions/checkout@v6`. |
| 3 | `🔧 Export lane environment variables` | `export-env-vars@v0` with `extra-envs: toJSON(matrix.test.extra-envs)`, `extra-envs-from-secrets: toJSON(matrix.test.extra-envs-from-secrets)`, `secrets-json: toJSON(secrets)`. |
| 4 | `🔑 Login to Azure` | `azure/login@v3`, `if:` the three ARM variables are set (§3.3). |
| 5 | `📥 Setup Terraform` | `hashicorp/setup-terraform@v4`, `terraform_version: matrix.test.terraform-version`, **`terraform_wrapper: false`** (the wrapper mangles the `-json` stream and the exit code). |
| 6 | `🗄️ Setup Terraform provider plugin cache` | `setup-terraform-plugin-cache@v0`, then `actions/cache` keyed on `<root>/.terraform.lock.hcl` when it exists, else the monthly rolling key the module CI uses (P13). |
| 7 | `⚙️ Terraform init` | `terraform-init@v0`, `working-directory: matrix.test.root`, `additional-dirs-json: "[]"`, `github-token: github.token`, `backend: false`, `lockfile-mode: readonly-if-present` (§5.3). `continue-on-error: true`. |
| 8 | `🧪 Terraform test` | `terraform-test@v0`, `if: steps.init.outcome == 'success'`, `working-directory: matrix.test.root`, `test-file: matrix.test.rel`. `continue-on-error: true`. Writes its own per-job step summary block (§5.8). |
| 9 | `📤 Upload test output` | `actions/upload-artifact`, name `terraform-test-log-<slug>`, paths: the JSON log, the text report, the JUnit file when present. `if: always()`, `continue-on-error: true`. Its `artifact-url` output is what the summary links as "output". |
| 10 | `📦 Capture test job metadata` | `capture-matrix-job-meta@v0` with `entity-name: matrix.slug`, `artifact-name: terraform-test-meta-<slug>` (§9.4). `if: always()`. |
| 11 | `📤 Upload test job metadata` | `if: always()`, `continue-on-error: true`. |
| 12 | `🧐 Validation outcome: ⚙️ Init` | `exit 1` unless init succeeded. `continue-on-error: ${{ fromJSON(matrix.test.allow-failing-terraform-tests) }}`. |
| 13 | `🧐 Validation outcome: 🧪 Test` | `exit 1` unless the test status is `pass`. Same `continue-on-error`. |

The gates come **after** every reporting step, as in the environment job: a gate exits 1 and would
otherwise skip the very upload that explains the failure. Nothing needs shredding here; there is no
per-goal env file.

### 5.3 Init in the test root

`terraform-init` gains two inputs (§9.5):

- `backend: false` adds `-backend=false`. `terraform test` keeps all state in memory and never
  touches a backend; an environment root's `backend` block would otherwise make init reach for real
  storage with whatever identity the lane has, or none.
- `lockfile-mode: readonly-if-present` adds `-lockfile=readonly` when `<root>/.terraform.lock.hcl`
  exists, and otherwise exports `TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=true` for this init
  so the plugin cache is actually used. Terraform only serves a provider from the cache when the lock
  file already records its checksum; a lock-less root would download every provider on every job
  (P13). `readonly` on a lock-less root always fails ("lock file is read-only"), which is why the
  mode is conditional.

`init` installs what the tests need, including in an empty root: the modules each `run` block names
(under keys like `test.tests.unit-net.basic`) and the providers those modules require. A
`mock_provider` still needs the real provider package for its schema; a mocked provider nothing
requires is not installed and the run errors with "unknown provider". Two consequences worth
knowing: a test file added after a local init needs a re-init, and a parse error in **any** test
file of the root fails init for the whole root (P10).

Provider version reproducibility at a test root, i.e. committing that lock file and verifying it, is
the test-root lock spec (§8). This spec only guarantees that a committed lock is honoured.

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
| 1 | init step did not succeed (the test step is skipped) | `error` | `init` |
| 2 | Terraform below the floor (§3.5) | `error` | `terraform-version` |
| 3 | no `test_abstract` message; diagnostics match "Module not installed", "there is no package for", "Inconsistent dependency lock file" | `error` | `not-initialised` |
| 4 | no `test_abstract`; any other diagnostic (parse or configuration error, possibly in a **sibling** test file; the diagnostic's `range.filename` says which) | `error` | `invalid` |
| 5 | `test_abstract` does not contain `rel` (Terraform warned "Unknown test file") | `error` | `not-discovered` |
| 6 | `test_file.status == "error"` with no `test_run` messages (unknown provider, provider configuration, required variable at file level) | `error` | `file` |
| 7 | any `test_run.status == "error"` (provider or API error, evaluation error, postcondition); the file's later runs report `skip` | `error` | `run` |
| 8 | any `test_run.status == "fail"` (assertion) | `fail` | `assertion` |
| 9 | otherwise | `pass` | `` |

`skip` as a run status is a consequence of an earlier error in the same file and is counted, never
a top-level status. A tolerated job (`allow-failing-terraform-tests`) keeps its real `status`; the
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
2. Read `tests-not-run-json` from `create-matrix` for the misplaced and secrets-unavailable rows,
   which have no metadata.
3. Resolve links from the Jobs API, once, paginated, through a temp file: match `jobs[].name` with
   `endswith("Terraform test (<file>)")` so the caller's `<job> / ` prefix does not matter, take
   `html_url`, and find the step named `🧪 Terraform test` in `steps[]` for the `#step:<number>:1`
   anchor. When the step is not found, link `html_url#logs`. When the API call fails, the Links
   column drops the job link and the body says so in one line; the job never fails (P18).
4. The output link is the `artifact-url` recorded in the metadata; absent when the upload failed.

### 6.3 The head comment

Marker: `<!-- tf:head:tests:<caller> -->`, where `<caller>` is `github.workflow` (the calling
workflow's name) reduced to `[A-Za-z0-9_-]`. The marker is scoped per caller because a repository
may call this workflow from two workflows on one pull request (Workflow-pr-comments.md §8.1);
with tests enabled by default both would otherwise discover the same files and fight over one head
(P19). The user guide tells such callers to set `terraform-test-enabled: false` in all but one.
Segment terminators keep it distinct from the module CI's `tf:head:test:<file>` (P8 in the apply
reporting spec).

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
on every event. This is the only reporting surface on `push` runs and on fork pull requests, and it
is what a notification spec (§8) will read from.

### 6.6 Headline annotation

The summary job emits one annotation so the checks pane says something without opening a job:
`::notice title=Terraform tests::12 passed` when everything passed, `::error title=Terraform
tests::1 failed, 12 passed` otherwise (tolerated failures produce a `::warning`).

## 7. Conclusion and gating

`conclusion.needs` becomes `[create-matrix, terraform-ci-cd, terraform-test]`. The existing rule
fails the check on `failure` or `cancelled` and treats `skipped` as success, which is right here:
the test job is skipped when the stage is disabled, when there are no test files, or on an event
that does not run tests. A non-tolerated failing test is a `failure` and blocks the merge; auto-merge
already requires the conclusion, so nothing else changes.

`terraform-test-summary` stays out of `needs`. A later spec makes the conclusion explicit about
which skips are benign; until then the structural test in
[`evaluate-automerge-eligibility`](../evaluate-automerge-eligibility/) asserts that `terraform-test`
is in the list.

## 8. Interplay with the rest of the workflow and with other specs

| Concern | Relationship |
|---|---|
| Environment jobs | Independent. Same `create-matrix` and `seed-pr-comments` dependencies, no `needs` between them (D8). The environment matrix's 256-job cap and the test matrix's are separate. |
| Environment init | Loads test files in the environment root (§4.9). Not something this spec can change; documented. |
| Per-goal environment variables | Do not reach test jobs (D6). |
| Explicit conclusion (separate spec) | Adds "skipped for a benign reason" precision and the fork guard; this spec only adds the `needs` entry. |
| Test-root lock files (separate spec) | This spec honours a committed lock read-only and uses the cache when one exists; verification of test-root locks, and the CLI's part, live there. `lockfile-mode: readonly-if-present` is the hook. |
| Single-file dispatch (separate spec) | Will add `workflow_dispatch` to the event rule together with a `tests-filter` input; the lane and slug vocabulary is what it filters on. |
| Per-environment path relevance (separate spec) | May later skip test roots no changed file touches; the `root` field is what it keys on. |
| Notifications (separate spec) | A failed test job on `push` is a trigger; the metadata artifacts and §6.5 are the data. |
| Module CI | Unchanged (§9.7). |

## 9. Actions: new and changed

All follow [Action-implementation-guide.md](Action-implementation-guide.md): thin `action.yml`
shim, logic in `step_*.sh`, `run_all_tests.sh` with the canonical summary lines, a `#` description
line opening every `run:` block, bodies and large data as files.

### 9.1 `create-tftest-matrix` (modernised, renamed `action.yaml` → `action.yml`)

Inputs: `lanes-yml`, `exclude-paths-yml`, `enabled`, `event-name`, `is-fork`, `actor`, and the global
defaults (`runs-on`, `terraform-version`, `timeout-minutes`, `allow-failing-terraform-tests`).
Outputs: §4.5. Validation (P4): lane schema, unique names, at most one fallback lane, glob grammar,
the 256 cap. Fixtures: the layouts of §4.2, every misplaced case of §4.3, glob cases of §4.4
including the root-level `**/` case, a collision, a fork run, a Dependabot run, a disabled run, a
`push` and a `schedule` event.

The action keeps working for the module CI workflow through its existing `all-tests` output until
that workflow migrates.

### 9.2 `terraform-test` (modernised)

Inputs: `working-directory`, `test-file` (relative to it), `junit` (boolean, default true; only
takes effect from 1.11). The embedded `azure/login` and the embedded artifact upload are removed;
the workflow owns both. Files go under `$RUNNER_TEMP/<slug>/`, never `$GITHUB_WORKSPACE`. Outputs:
§5.6. Behaviour: §3.5, §5.4, §5.5, §5.7, §5.8. Fixtures: JSON logs for each classification of §5.5
(pass; assertion fail; run error with skipped followers; file-level error; parse error; filter miss;
not initialised), captured from a real Terraform and stored with the version noted.

### 9.3 `create-test-summary` (new)

Inputs: `metadata-files-pattern` (default `terraform-test-meta-*.json`), `not-run-json`,
`run-url`, `job-links-json-file` (resolved by a helper in the same action from the Jobs API, or
passed in by tests), `output-file-suffix`. Outputs: `body-file`, `step-summary-file`, `failed-count`,
`tolerated-count`, `passed-count`, `not-run-count`. Golden files for: all green; one failure; a
tolerated error; an init error; misplaced and secrets-unavailable rows; a body over budget at each
trim step; a run with zero rows; missing job links. ARG_MAX: the Jobs API response and every
metadata file are read from disk with `jq --slurpfile` or `-f`; the body is assembled by appending to
a file, never in a shell variable.

### 9.4 `capture-matrix-job-meta`

Two optional inputs: `entity-name` (what `environment-name` really is; the old name stays as an
alias) and `artifact-name` (default `matrix-job-meta-<entity>`), which sets **both** the artifact
name and the JSON file's basename (P7). Existing callers see no change.

### 9.5 `terraform-init`

Inputs `backend` (boolean, default `true`) and `lockfile-mode` (`default` | `readonly` |
`readonly-if-present`, default `default`) as §5.3. Existing callers see no change. The
`TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE` export applies only when `lockfile-mode` resolves
to a writable lock and a plugin cache directory is set.

### 9.6 Workflow changes

- `create-matrix`: a second step calling `create-tftest-matrix`; new job outputs
  `tests-matrix-json`, `tests-count`, `tests-active`, `tests-not-run-json`.
- `seed-pr-comments`: the tests head in the manifest after the environment heads (§6.3).
- `terraform-test` job (§5) and `terraform-test-summary` job (§6).
- `conclusion.needs` (§7).
- Structural tests: the two new jobs' `with:` keys against their actions' inputs; gates after
  reporting steps; `terraform-test` in the conclusion's needs; `terraform-test-summary` not.

### 9.7 Module CI

Untouched by this spec. `terraform-module-ci.yaml` keeps `create-tftest-matrix`'s `all-tests`
output, the old `terraform-test` behaviour behind the modernised action's compatibility (the
workflow passes `working-directory: ${{ github.workspace }}` and `test-file: tests/<file>` after
migration), and `create-test-report`. Migrating it to the summary job is a follow-up once this has
run for a while.

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
| P8 | `terraform providers lock` ignored test-only providers before 1.14.1. | A developer on an older version commits a lock the readonly init rejects. | Recommend 1.14.1 with committed test-root locks; the lock spec verifies. |
| P9 | `-verbose` embeds full provider schemas per run block (megabytes for large providers). | Log, artifact and every downstream buffer explode; ARG_MAX territory. | Never default; document `TF_CLI_ARGS_test`. |
| P10 | An environment's own `init` and `validate` load test files in its root; a parse error in any test file of a root fails init for that root. | A broken test file blocks plan and apply for that environment; a broken sibling breaks every job of its root. | Documented (§4.9); `allow-failing-terraform-tests` cannot cover it. |
| P11 | A concurrency group allows one running and one pending job; a newer arrival cancels the pending one, and cancelled reddens the conclusion. | A per-lane group cancels this run's own matrix rows. | Group per test file (§5.1). |
| P12 | `terraform test` state is in memory; a job killed by timeout or cancellation leaves objects nothing can destroy. | Leaked test objects in a real tenant. | Short per-lane timeouts; the calling repository runs a janitor keyed on a naming prefix. |
| P13 | The plugin cache serves a provider only when the lock file records its checksum. | Every lock-less test root downloads every provider on every job. | `readonly-if-present` exports the may-break variable for lock-less roots. |
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
| P25 | `TF_VAR_*` from a lane needs a `variable` block in the test file from Terraform 1.13. | "Variables not allowed" or undefined-variable errors. | Authoring note (§3.2). |

## 11. Test coverage

**Must**

- `create-tftest-matrix`: every layout row of §4.2 yields the stated root and rel; every case of
  §4.3 is misplaced; the glob grammar cases of §4.4; first-match-wins and the fallback lane;
  unmatched files land in `default` with empty maps; credentialed rows dropped on fork and on
  Dependabot with the right reason; `tests-active` false for `schedule`, `workflow_dispatch`,
  disabled, and zero files; a collision gets a deterministic suffix; unknown lane keys, two fallback
  lanes, a bad glob and 257 files fail with the documented messages; the matrix JSON has `slug` at
  top level and a JSON boolean for `allow-failing-terraform-tests`.
- `terraform-test`: each classification of §5.5 from its fixture; the version gate; `-junit-xml`
  passed only from 1.11; outputs match the fixture's counts; `elapsed-ms` from timestamps; diagnostic
  files prefixed with the root; at most ten annotations plus the warning; report capped at 65 000;
  nothing large in `$GITHUB_OUTPUT`.
- `create-test-summary`: goldens of §9.3 byte-for-byte; the budget trim order; headline counts;
  sort order; missing links omitted; zero rows renders the "no test files" body; a metadata file
  with an unknown schema version is skipped with a warning.
- `capture-matrix-job-meta`: `artifact-name` sets artifact and basename; default unchanged (golden).
- `terraform-init`: `backend: false` adds the flag; `readonly-if-present` adds `-lockfile=readonly`
  with a lock and the may-break variable without; default unchanged.
- Workflow structural tests: §9.6.

**Should**

- The module CI workflow's test job still passes with the modernised `terraform-test` and
  `create-tftest-matrix` (its `all-tests` output unchanged).
- The seed manifest places the tests head last and only when `tests-count > 0`.
- The summary's Jobs-API resolver handles a caller-prefixed name and two pages.

**Could**

- A property-style test feeding random paths through the root rule and asserting Terraform's
  discovery agrees (needs a Terraform binary in CI).
- A rendered-size test that a 256-row summary fits the budget after trimming.

**What tests cannot cover**: real OIDC token minting per lane, `azure/login` skipping, artifact URL
validity, the `#step:N:1` anchor, the 256-job cap, the exact behaviour of an environment root with
a real backend. These are verified through a preview ref on a test-bed calling repository and
recorded in §15.

## 12. Open questions

Things that need testing or exploration, not decisions:

1. **Step anchor**: confirm that the Jobs API `steps[].number` is the `N` in `html_url#step:N:1`
   for a reusable-workflow job, and that the anchor survives re-runs.
2. **`artifact-url` in the steps context**: confirm `steps.<id>.outputs.artifact-url` is populated
   inside a reusable workflow and reaches the metadata artifact intact.
3. **Dependabot**: confirm on a real Dependabot pull request that repository secrets resolve empty,
   and whether `github.actor` or `github.triggering_actor` is the right key.
4. **`hashFiles` on a matrix-derived path** in a step-level expression, used for the cache key of
   §5.2 step 6; fall back to computing the key in a step if it does not resolve.
5. **`pr-comment` delete** for the zero-count case (§6.3): confirm the delete mode's marker
   matching treats the caller-scoped marker as a prefix-safe substring.
6. **Environment root with a real `azurerm` backend**: `init -backend=false -reconfigure` then
   `terraform test` with `command = plan` against mocks, on the test-bed repository.
7. **`TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE` value**: confirm `true` is what Terraform
   expects (the CLI helper scripts use `true`; the docs example uses `1`).
8. **Job name length**: GitHub truncates long job names in the UI; confirm the Jobs API returns the
   full name for a 120-character path so `endswith` still matches.
9. **Reserved `github-environment`**: whether a job-level `environment:` may be empty. Not needed
   here; noted so the later spec starts with the answer.

## 13. Implementation order

One commit each, in this order, each green on its own:

1. `docs:` this spec.
2. `feat(terraform-init):` `backend` and `lockfile-mode` inputs, tests.
3. `feat(capture-matrix-job-meta):` `entity-name` and `artifact-name` inputs, tests.
4. `test(terraform-test):` pin the current outputs as goldens before touching the action.
5. `refactor(terraform-test):` modernise to the layout guide; behaviour unchanged, goldens green.
6. `feat(terraform-test):` working directory, version gate, classification, annotations, outputs;
   JSON fixtures per classification.
7. `refactor(create-tftest-matrix):` modernise and rename `action.yaml` → `action.yml`; `all-tests`
   unchanged.
8. `feat(create-tftest-matrix):` discovery, roots, lanes, exclusions, outputs; fixtures.
9. `feat(create-test-summary):` the new action with goldens.
10. `feat(workflow):` `create-matrix` outputs, seed manifest, `terraform-test` job,
    `terraform-test-summary` job, conclusion `needs`; structural tests.
11. `docs:` user guide, PR comments spec, README index, CLAUDE.md overview.
12. Validation through a preview ref on the test-bed calling repository, with fixtures for every
    classification and a credentialed lane; findings into §15 and the pitfalls table.

AI-assistant configuration files are never in these commits.

## 14. Documentation to update

- [Workflow-terraform-ci-default.md](Workflow-terraform-ci-default.md): the new inputs, the lane
  example, the layout guidance of §4.2 and §4.9, the two-caller rule, the `secrets: inherit`
  reminder.
- [Workflow-pr-comments.md](Workflow-pr-comments.md): the `tf:head:tests:<caller>` marker in the
  namespace table, its seed position in §3.1, the delete rule in §4, §8.1's two-caller note.
- [Testing-in-ci.md](Testing-in-ci.md): nothing; the new actions enrol in CI like every other.
- `README.md`: action index entries; `CLAUDE.md`: one line in the overview and the docs list.

## 15. What implementation taught the spec

Reserved.
