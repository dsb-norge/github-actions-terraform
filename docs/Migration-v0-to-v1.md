# Migrating from v0 to v1

How to move a Terraform project repository that calls
[`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml) from `@v0` to
`@v1`. Every change behind these steps, with the reason for it, is in [V1-changes.md](V1-changes.md);
how to use the workflow is the user guide, [Workflow-terraform-ci-default.md](Workflow-terraform-ci-default.md).

v1 changes defaults: which environments run on a pull request, what a schedule applies, whether
test files run, and which configuration mistakes are refused. A repository moves deliberately, on a
draft pull request, and can move back (§7). `v0` stays frozen at v0.33 and takes fixes only.

The guide has three tiers:

- **Must** (§2): ignoring it breaks the run or changes what the run does.
- **Should** (§3): strongly recommended, and cheap.
- **Could** (§4): the new features, each with its benefit, its cost, when to adopt it and a
  minimal example.

Then the change itself (§5), how to validate it (§6), how to roll back (§7) and the pitfalls (§8).

## 1. Pre-flight checklist

Answer these from the repository before changing anything; each answer points at a section.

- [ ] Which workflow files call the workflow at `@v0`?
  `git grep -n "terraform-ci-cd-default.yml@v0" -- .github/workflows` (§2.1)
- [ ] Does every calling job's `permissions:` grant `id-token: write`, `contents: read`,
  `pull-requests: write` and `actions: read`? (§2.2)
- [ ] Does a calling workflow filter with `on.<event>.paths` or `paths-ignore`, or is there a
  second, path-filtered calling workflow? (§2.3)
- [ ] Does any environment read files outside `<project-dir>/**`, `main/**`, `modules/**`, its
  additional init directories and the root's `.tflint.hcl`: a `-var-file` or `-backend-config`
  passed through `TF_CLI_ARGS_*`, a local module elsewhere, Markdown through `file()`? (§2.3)
- [ ] Does a calling workflow have `on.schedule`, which environments is it meant for, and should a
  scheduled run apply them or only plan? (§2.4)
- [ ] Does a calling workflow declare `workflow_dispatch.inputs` named `environment`, `goal` or
  `reason`? (§2.5)
- [ ] Is any test file committed? `git ls-files '*.tftest.hcl' '*.tftest.json'` (§2.6)
- [ ] Which federated credentials trust this repository's `pull_request` or branch subjects? (§2.7)
- [ ] Is `pr-auto-merge-enabled: true`? (§2.9)
- [ ] Does anything download the `<env>-terraform-plan-json` artifact? (§2.10)
- [ ] Does `runs-on`, globally or per environment, name a self-hosted pool? (§2.11)
- [ ] Does a calling workflow trigger on anything but `pull_request`, `push`, `workflow_dispatch`
  and `schedule`? (§2.12)
- [ ] Does Dependabot open pull requests in the repository, and do the Azure IDs reach the calling
  workflow as secrets? Which providers and modules come from outside `hashicorp`, `microsoft`, `Azure`
  and `dsb-norge`? Do Dependabot's update jobs get a runner at all? (§2.13)
- [ ] Does a calling workflow set `concurrency` with `cancel-in-progress: true`? (§3.2)
- [ ] Is the workflow called from more than one workflow file for the same pull requests? (§3.4)

## 2. Must do / check

### 2.1 Change the ref in every calling workflow

Every `uses: dsb-norge/github-actions-terraform/.github/workflows/terraform-ci-cd-default.yml@v0`
becomes `@v1`, in every calling workflow file and every job. One ref serves the workflow and all
its actions. A repository that pins a minor (`@v0.31`) moves to `@v1` the same way.

### 2.2 Grant the permissions

```yaml
    permissions:
      id-token: write      # OIDC login, for the environments and the test jobs
      contents: read       # checkout, and the files a push changed
      pull-requests: write # PR comments, and the files a pull request changed
      actions: read        # job links in the grouped PR comments
```

The test job declares `id-token: write` whether or not the repository has test files or logs in
with OIDC. GitHub does not let a called workflow's job hold a permission the calling job did not
grant, so without it the run fails at startup, with no job and no check: the conclusion stays
pending. Keep `secrets: inherit`.

Grant these four and nothing more: `permissions: write-all` also raises the token of a run Dependabot
starts from read-only to write, and every job of that run executes the pull request's dependencies
([Dependabot-admission.md](Dependabot-admission.md) §1).

### 2.3 Path relevance: remove `on.paths`, review what each environment reads

On `pull_request` and `push` an environment now runs only when a changed file is relevant to it
([Path-relevance.md](Path-relevance.md)). Without `paths`, an environment's set is `auto`:
`<project-dir>/**`, `main/**`, `modules/**`, every directory of its
`terraform-init-additional-dirs-yml`, and `/.tflint.hcl` (the repository root's only), with
`**/*.md` ignored. A change under `.github/workflows/`, a force push, a pull request whose head moved
and every API failure run every environment.

1. **Remove `paths` and `paths-ignore` from the calling workflow's `on:` block.** A workflow that
   `on.paths` skips reports no check at all, so a required `Terraform conclusion` stays pending and
   blocks the pull request; that is the problem relevance exists to remove. Move what the filter
   expressed into the environments' `paths`, which for the standard layout is nothing.
2. **Give an environment that reads files outside `auto` a `paths` entry for them.** Otherwise a
   change to those files no longer plans it:

   ```yaml
         environments-yml: |
           - environment: staging
             paths: [auto, "config/staging/**"]   # a -var-file under config/
           - environment: docs-site
             paths-ignore: []                      # reads Markdown through file()
   ```

3. **If you are not sure yet**, keep the old behaviour for the move and review later (§3.6):

   ```yaml
         path-relevance-enabled: false
   ```

A repository that used a second calling workflow with complementary `on.paths` filters folds it
into one after the move (§3.3).

### 2.4 Schedules: opt the scheduled environment in, and say whether it applies

On v0 a `schedule` planned and applied every environment on the default branch. On v1 an
environment takes part in a scheduled run only when its own `trigger-events` holds `schedule`; a
schedule nobody opted into runs nothing and is green, with a notice naming the key. `schedule` is
refused in the global `trigger-events-yml`. And a scheduled environment plans without applying
unless its `schedule-goal` says otherwise: a v0 nightly reconcile keeps applying with
`schedule-goal: default`.

```yaml
      environments-yml: |
        - environment: prod
        - environment: staging
          trigger-events: [pull_request, push, workflow_dispatch, schedule]
          schedule-goal: default   # the nightly reconcile; without it the schedule only plans
```

`trigger-events` replaces the default `[pull_request, push, workflow_dispatch]` for that
environment, so list the other events it keeps. A scheduled run never destroys; with
`schedule-goal: default`, an environment holding `destroy` runs its destroy plan and stops there.
For drift detection only, leave `schedule-goal` out: the environment plans every night and applies
only on a push ([user guide, example 6](Workflow-terraform-ci-default.md#6-scheduled-drift-detection)).

### 2.5 Dispatch inputs are read by name

v1 reads the calling workflow's `workflow_dispatch` inputs `environment`, `goal` and `reason`
([Dispatch-and-triggers.md §3.1](Dispatch-and-triggers.md)). A caller whose own dispatch block uses
one of these names for something else renames its input, or it will select an environment or cap
the goals. A dispatch without those inputs runs every environment with its goals, as on v0. The
standard block is recommended in §3.1.

### 2.6 Test files will run

Every committed `*.tftest.hcl` and `*.tftest.json` now runs on pull requests and pushes, one job per
file, and a failing one turns the conclusion red ([Terraform-tests.md](Terraform-tests.md)). Files
that are not committed, and paths with a segment starting with `.`, are skipped.

- **No test files:** nothing to do. A pull request that adds one starts the stage.
- **Test files that are not meant to run here**, or not ready: switch the stage off with
  `terraform-test-enabled: false`, or exclude them with `terraform-test-exclude-paths-yml`.
- **Test files that should run:**
  - Terraform 1.13 or later for the test jobs (`terraform-version`, or a lane's own).
  - A test file runs only where Terraform finds it: beside a root module's `.tf` files, or in the
    `tests/` directory directly under one, or in a repository-root `tests/` when the root holds no
    `.tf`. Anything else is reported as misplaced and does not run.
  - Every environment lock file a test uses must record a checksum for the runner's platform
    (`linux_amd64` on GitHub-hosted runners); a job whose lock does not reports `lock-platform`
    with the `terraform providers lock -platform=…` command that fixes it.
  - Without lanes every file runs with **no credentials**, which suits unit tests with
    `mock_provider`. A test that needs credentials fails until it has a lane (§4.2).
  - A `tests/` directory inside an environment works but is loaded by that environment's own init
    and validate too, so a broken test file blocks its plan; prefer a repository-root `tests/` or
    `tests/` beside a module.

### 2.7 Audit the identities, for a repository with test files

Every test job can request an OIDC token. In a lane without a GitHub Environment its subject is
the pull request's (`repo:<owner>/<repo>:pull_request`), or the branch's on a push, so test code
from a pull request can use any identity that trusts such a subject. Before the move:

1. Plan and apply credentials are **environment secrets** of the Terraform environments, never
   repository or organisation secrets. The identifiers an OIDC login needs (tenant, subscription and
   client IDs) are not credentials: they are plain values in each environment's `extra-envs-yml`,
   which a Dependabot run can read and secrets of no kind can give it (§2.13).
2. No plan or apply identity trusts a `pull_request` or branch subject; remove or narrow every
   federated credential that does. The environment job always runs in its GitHub Environment, so it
   needs only `repo:<owner>/<repo>:environment:<github-environment>`.

With both, a test job can neither read those secrets nor exchange a token for those identities.
Client IDs are not secret; the subject an identity trusts is what protects it. See the user guide,
[Terraform tests](Workflow-terraform-ci-default.md#terraform-tests), and
[Terraform-tests.md §3.6](Terraform-tests.md), "Isolation".

### 2.8 Configuration the workflow now refuses or reads differently

The configuration is validated before any environment job starts; a refused one fails
`create-matrix` with one annotation per problem, and the conclusion is red. Check, in every calling
workflow's `with:`:

| Check | Refused or changed | Fix |
|---|---|---|
| Keys of each `environments-yml` entry | an unknown, misspelt, unsuffixed (`goals:`) or wrongly suffixed (`trigger-events-yml:`) key, or a workflow-only input set per environment, is an error | the key the message names ([Configuration-validation.md §3.1](Configuration-validation.md)) |
| `goals-yml`, global and per environment | a list written without its dashes, a misspelt or upper-case goal, `plan` without `init`, `apply` without `plan`, `destroy` without `destroy-plan` | a YAML list of known goals, or `all` |
| Per-environment booleans (`add-pr-comment`, `verify-lock-file`, `cache-terraform-modules`, …) | an unquoted `true` used to act as false; it now takes effect. `yes`, `null` and other values are errors | check that each one says what you mean: a per-environment `verify-lock-file: true` now runs the lock check |
| Per-environment string settings | an unquoted number (`terraform-version: 1.10`) is an error | quote it: `terraform-version: "1.10"` |
| Per-environment `runs-on` | a list of labels is an error | one string: a runner group name or one label |
| Environment names and `github-environment` | 1 to 255 of `A-Z a-z 0-9 . _ -`, starting with a letter or a digit; no two environments may share a `github-environment` (without case); no duplicate environments | rename |
| Variable values in `extra-envs-yml` and the other variable settings | now text as written (`1.10` stays `1.10`, a leading zero stays); a null means not set instead of the text `null`; a mapping or a list is an error | nothing, unless a value relied on the old conversion; quote a value whose braces are part of it |
| `terraform-init-additional-dirs-yml` | a single directory written as a string is now initialised; an empty entry is an error | check that a directory written alone should run |

The quickest check is the draft pull request of §6: every problem of this kind is reported in its
first run.

### 2.9 Auto-merge, if enabled

Only for `pr-auto-merge-enabled: true` ([Auto-merge.md](Auto-merge.md)).

- `pr-auto-merge-from-actors-yml` must name at least one login for every environment with
  auto-merge enabled. The default, `[]`, is now an error, never "everyone". Quote bot logins in a
  flow list: `'["dependabot[bot]"]'`.
- A per-environment actor list **replaces** the global one; it used to be added to it. Review each.
- `pr-auto-merge-limits-yml`: after the per-environment merge, exactly the six `plan-max-count-*`
  keys, each an unquoted whole number of -1 or more.
- Only pull requests against the default branch, from the same repository, are merged.
- A failed operation step tolerated by `allow-failing-terraform-operations` now makes the pull
  request ineligible; a tolerated failing test does not.
- The merge is refused when the pull request's head or its base branch moved after the plan. In a
  burst of bot pull requests one merges; the others merge on their next run, after a rebase.
- `pr-auto-merge-app-id` accepts the App's ID or its client ID.

### 2.10 The JSON plan artifact is gone

`<env>-terraform-plan-json` is no longer uploaded: it held sensitive values in plain text. A
process that downloaded it uses `<env>-terraform-plan-console-output`, which is unchanged.

### 2.11 Self-hosted runners

Only if `runs-on` or `terraform-test-runs-on` names a self-hosted pool:

- `create-matrix` and the reporting jobs run on the workflow's `runs-on` and need Python 3.12 or
  later, `yq` v4 (the Go implementation), `jq`, `gh`, `git` and bash. Too old a Python stops
  `create-matrix` naming the floor.
- Every job uses Node 24 actions, which need Actions runner v2.327.1 or later.
- An HTTP(S) proxy is not supported: the workflow sets no proxy configuration, so the auto-merge
  job's App token step (`actions/create-github-app-token`) does not honour `HTTP(S)_PROXY`.

### 2.12 Unsupported events

The workflow runs on `pull_request`, `push`, `workflow_dispatch` and `schedule`. A calling workflow
triggered by anything else (`merge_group`, `pull_request_target`, `release`, …) fails in
`create-matrix`; remove that trigger or call the workflow from another file.

### 2.13 Dependabot pull requests are admitted first

A run Dependabot starts executes Terraform only when the admission admits its pull request: every
provider and module it changes comes from an allowed namespace (built in: `dsb-norge`, `hashicorp`,
`microsoft`, `Azure`), was published at least three days before, and a provider is signed as the
version before it was. A pull request that is not admitted runs no Terraform job and fails
`Terraform conclusion`, with a comment saying why and what to do. The whole design is
[Dependabot-admission.md](Dependabot-admission.md).

An admitted run plans as a person's run would, which needs the environment's IDs: a Dependabot run
cannot read Actions or environment secrets. Move them to plain values, per environment:

```yaml
      environments-yml: |
        - environment: prod
          extra-envs-yml:
            ARM_TENANT_ID: "00000000-0000-0000-0000-000000000000"
            ARM_SUBSCRIPTION_ID: "00000000-0000-0000-0000-000000000000"
            ARM_CLIENT_ID: "00000000-0000-0000-0000-000000000000"
```

Do the same for every test lane that needs credentials: an admitted run runs those lanes too, and a
lane whose IDs are still environment secrets fails there. A secret a test needs beyond the IDs becomes
a Dependabot secret. Allow other publishers with `dependabot-admission-yml` (`allow: [elastic]`);
`dependabot-admission-enabled: false` runs Dependabot's pull requests as before.

Check that Dependabot's update jobs run at all, before you count on its pull requests. Each update
appears in the repository's Actions as a run named after its directories, `terraform in /envs/… -
Update #…`. One that stays queued for a day and is then cancelled, every day, never opens a pull
request, and nothing else says so. The cause is the Dependabot **runner type** (repository or
organization settings, Advanced Security, Dependabot): **Labeled runner** sends the update jobs to
self-hosted runners with that label (`dependabot` by default), and none exists, or the repository is
not in the runner group's access. Choose **Standard GitHub runner** unless Dependabot must reach a
private registry: the update job only reads the repository and public registries and opens pull
requests, and the pull requests' CI runs on the calling workflow's own runners either way. A
labeled runner also needs Docker. The setting has no REST API; the organization's applies to every
repository that does not override it.

## 3. Should do / check

### 3.1 Add the standard dispatch block

Even in a repository that never dispatches today: it is the recovery button. An apply that failed
on one push is not retried by a later push that does not touch that environment, and a dispatch is
never filtered by relevance.

```yaml
on:
  workflow_dispatch:
    inputs:
      environment:
        description: "Environment to run, as named in environments-yml. Empty runs every environment."
        type: string
        default: ""
      goal:
        description: "Goal for this run. default follows goals-yml; plan, apply and destroy-plan override it for the selected environments."
        type: choice
        options: [default, plan, apply, destroy-plan]
        default: default
      reason:
        description: "Why this run is dispatched. Recorded in the run summary."
        type: string
        default: ""
```

Nothing goes through `with:`. `goal` only ever removes goals, never adds `destroy`, and `apply`
needs the default branch and an environment that holds `apply` or `all`; asking for more is an
error. Use `reason`: it is recorded in a notice and the run summary.

### 3.2 No `cancel-in-progress: true` on a workflow that applies

A `concurrency` group with `cancel-in-progress: true` on the calling workflow cancels the whole run,
an in-progress or waiting environment job included, so an apply can be cut off; on a push, which
has no pull-request number, every run shares the group. v0's comment spec suggested it; remove it
from any workflow that applies. The per-environment groups already serialise runs, queued rather
than cancelled ([user guide, `environments-yml`](Workflow-terraform-ci-default.md#environments-yml)).

### 3.3 Delete the workflow files the move made redundant

After the move is merged: a second calling workflow that existed only for a path filter, a nightly
workflow whose schedule now lives in the main workflow (§2.4), a dispatch-only workflow that
recovered one environment (§3.1). Fold their triggers into the one calling workflow, and require
only its `tf / Terraform conclusion` (`tf` being the calling job's id).

### 3.4 One caller runs the tests

When two calling workflows run on the same pull request, both would run the same test files and
report them in two comments. Set `terraform-test-enabled: false` in all but one.

### 3.5 Audit identities in every repository

§2.7 is a must for a repository with test files. A pull request can add a test file, so the same
two conditions protect every repository where the test stage is on; check them when the repository
moves, not when its first test arrives.

### 3.6 Remove the relevance switch after the review

`path-relevance-enabled: false` is a bridge for the move. Once the `paths` of §2.3 are reviewed,
remove it; to keep one environment running on every change, give it `paths: ["**"]` instead.

### 3.7 Require only the conclusion

`tf / Terraform conclusion` is the one check to require. It is green when everything that should
have run ran and passed, including when nothing needed to run. Do not require individual
`Terraform` or `Terraform test (…)` checks: which of them exist depends on what the change touched.

## 4. Could do / check

Each feature is off, or at a safe default, until configured. The examples are the part of `with:`
that matters and are valid against the current inputs.

### 4.1 Tune path relevance

- **Benefit:** a pull request plans only the environments it can affect; a documentation-only pull
  request finishes in minutes, green, and is eligible for auto-merge.
- **Cost:** a `paths` list to keep true when an environment starts reading a new directory.
- **When:** at the move, for the environments of §2.3; later whenever one reads outside `auto`.

```yaml
      environments-yml: |
        - environment: prod                      # auto
        - environment: staging
          paths: [auto, "scripts/**"]            # the standard set plus one directory
        - environment: sandbox
          paths: ["**"]                          # every change
```

A list with `auto` adds to the standard set; a list without it replaces the set. `paths-ignore`
defaults to `["**/*.md"]` with `auto` and to `[]` otherwise. The grammar is `*`, `**`, `?` and a
leading `/` for the root; no negation. [Path-relevance.md §3](Path-relevance.md).

### 4.2 Terraform tests: lanes, GitHub Environments and OIDC

- **Benefit:** unit and integration tests run on every pull request and push, in parallel with the
  plans, against the provider versions the environments lock, and block the merge when they fail.
  A lane in its own GitHub Environment gets secrets scoped to it and an OIDC subject naming it, so
  a test identity can be granted to that lane alone.
- **Cost:** test jobs on every pull request and push; for a credentialed lane, an identity with a
  federated credential and environment secrets to set up. Integration tests that apply create real
  objects; keep their timeouts short.
- **When:** unit tests with `mock_provider` as soon as there are any; a credentialed lane when a
  test needs a real tenant, one lane per identity.

```yaml
      terraform-test-lanes-yml: |
        - name: unit
          match: ["**/unit-*.tftest.hcl"]
        - name: integration
          match: ["**/integration-*.tftest.hcl"]
          github-environment: auto          # runs in the GitHub Environment tftest-integration
          timeout-minutes: 45
          allow-failing-terraform-tests: true # while the lane is brought up
```

Bringing up an environment lane: the first run creates `tftest-<lane>` and its jobs fail with
`no-credentials`, printing the commands that set its `ARM_*` secrets; someone with write access
sets them; the identity's owner adds a federated credential for
`repo:<owner>/<repo>:environment:tftest-<lane>`; re-run the failed jobs. Never add protection rules
to a `tftest-*` environment.

An environment lane exports every secret whose name starts with `ARM_` or `TF_VAR_`. That is safe
only when no repository or organisation secret carries those prefixes, so that only the lane's own
environment secrets match; rename any that do before adding an environment lane. The full
procedure, the flexible credential for every lane of a repository and the rules for secrets are
[Terraform-tests.md §3.2, §3.6](Terraform-tests.md).

### 4.3 The standard dispatch block

Recommended for every repository (§3.1).

- **Benefit:** reconcile one environment, preview a destroy, or run a fleet-wide plan, without a
  workflow file of its own; every dispatch says who asked and why.
- **Cost:** twenty lines, the same in every repository.
- **When:** at the move.

```bash
gh workflow run <calling-workflow>.yml --ref main -f environment=prod -f goal=plan -f reason="check drift after the provider upgrade"
```

[Dispatch-and-triggers.md §3.1, §4.2](Dispatch-and-triggers.md).

### 4.4 Trigger events and schedules

- **Benefit:** one calling workflow triggered on every event, with each environment saying which it
  takes part in: a nightly drift plan of an environment that applies on push, a nightly reconcile
  with `schedule-goal: default`, an environment kept out of pull requests.
- **Cost:** an environment out of pull requests is never planned on them, so a pull request that
  touches it is never auto-merged.
- **When:** when a schedule exists (a must, §2.4), or an environment should not plan on pull
  requests.

```yaml
      environments-yml: |
        - environment: dev
          trigger-events: [pull_request, push, workflow_dispatch, schedule]   # plans every night
```

with `schedule: [{ cron: "23 3 * * *" }]` in the calling workflow's `on:`. Leave
`trigger-events-yml` at its default. [Dispatch-and-triggers.md §3.2, §4.4](Dispatch-and-triggers.md).

### 4.5 Environment ordering: `depends-on`

- **Benefit:** an apply that must follow another, such as shared code applied to a test tenant
  before production, runs in a later stage of the same run, and only when the earlier stage
  succeeded.
- **Cost:** stages run one after the other on every run that applies or destroys, and a stage waits
  for the whole stage before it, not only for what an environment names: one failure holds back
  every later stage. It orders environments within one run only and never checks a dependency's
  earlier runs.
- **When:** only where an apply genuinely depends on another. Never on an environment that carries
  `allow-failing-terraform-operations`, whose tolerated failure releases the next stage.

```yaml
      environments-yml: |
        - environment: shared
        - environment: prod
          github-environment: prod-approval
          depends-on: [shared]
        - environment: sandbox
```

`shared` is stage 1; `prod` and, having no dependencies and no dependents, `sandbox` are stage 2.
A run that only plans puts everything in stage 1. A dispatch naming one environment runs it alone,
which is how a held-back environment is recovered. At most three stages.
[Environment-ordering.md §3, §4, §6](Environment-ordering.md).

### 4.6 Auto-merge, now hardened

- **Benefit:** a named bot's routine pull requests merge without review when every plan stays
  within its limits. v1 counts from the JSON plan, pins the merge to what was planned, and requires
  an explicit actor list, which makes adopting it safer than on v0; a documentation-only pull
  request is eligible too.
- **Cost:** a GitHub App with write access to contents and pull requests, its key as an Actions and
  a Dependabot secret, and limits to keep right.
- **When:** for repositories with frequent dependency pull requests whose plans are usually empty.

```yaml
      pr-auto-merge-enabled: true
      pr-auto-merge-app-id: "123456"
      pr-auto-merge-app-private-key-secret: AUTO_MERGE_APP_PRIVATE_KEY # the secret's name
      pr-auto-merge-from-actors-yml: |
        - "dependabot[bot]"
      environments-yml: |
        - environment: dev
        - environment: prod
          github-environment: prod-approval
          pr-auto-merge-limits-yml:   # merged over the global limits
            plan-max-count-add: 0
            plan-max-count-change: 0
```

The global limits default to no adds, changes, destroys or removals. An environment with
`pr-auto-merge-enabled: false` keeps every pull request of the repository from auto-merging.
[Auto-merge.md](Auto-merge.md), [user guide, example 13](Workflow-terraform-ci-default.md#13-auto-merge-for-dependabot).

### 4.7 Configuration validation

Always on; nothing to switch. It reports every problem of a configuration in one run, in sentences
that say what was written and how to write it ([Configuration-validation.md](Configuration-validation.md)).

- **Benefit:** a typo can no longer turn into a different configuration: a misspelt
  `github-environment` into an unprotected environment, `goals:` into an apply.
- **Cost:** none after the first run.
- **When:** use the move to tidy the configuration: quote versions, write goals as lists, drop
  keys that repeat the global value, and name auto-merge actors per environment only where they
  differ.

### 4.8 Module cache

`cache-terraform-modules` exists on v0 and stays on by default. On v1 the test jobs use the same
cache ([Terraform-module-cache.md](Terraform-module-cache.md), [Terraform-tests.md §5.3](Terraform-tests.md)),
with a per-lane override, and a per-environment value now takes effect when written unquoted.

- **Benefit:** fewer module downloads, so fewer transient registry and network failures.
- **Cost:** none for immutably pinned sources; the cache switches itself off for a root whose
  sources it cannot pin.
- **When:** keep it on. Switch it off for one environment or lane only to rule it out while
  debugging.

```yaml
      terraform-test-lanes-yml: |
        - name: unit
          cache-terraform-modules: false   # this lane only
      environments-yml: |
        - environment: prod
          cache-terraform-modules: false   # this environment only
```

### 4.9 Per-environment overrides

The settings an environment may override are listed in
[Configuration-validation.md §3.1](Configuration-validation.md). On v1 each takes the input's type:
booleans are `true` or `false`, strings must be strings.

- **Benefit:** one calling workflow for environments that differ in runner, version, lock check or
  comments.
- **Cost:** every override is one more place a value differs from the global one.
- **When:** when an environment genuinely differs.

```yaml
      terraform-version: "1.13.4"
      environments-yml: |
        - environment: dev
        - environment: prod
          github-environment: prod-approval
          terraform-version: "1.14.0"   # quoted: a string setting
          runs-on: "my-runner-group"    # one string, never a list
          verify-lock-file: true        # takes effect, quoted or not
```

### 4.10 Grouped PR comments

`pr-comment-group` exists on v0. With relevance, an ungrouped environment the change does not
touch still has its own "not affected" comment; in a group it is one column of dashes.

- **Benefit:** a repository with more than three environments keeps its pull requests readable.
- **Cost:** a grouped environment's summary is a column, not a comment of its own.
- **When:** more than three environments.

```yaml
      environments-yml: |
        - environment: prod
        - environment: staging
          pr-comment-group: platform
        - environment: sandbox
          pr-comment-group: platform
```

## 5. Changing the calling workflow, step by step

A typical v0 calling workflow, which filters by path and schedules a nightly run:

```yaml
name: "Terraform CI/CD"

on:
  pull_request:
    branches: [main]
    paths: ["envs/**", "main/**", "modules/**"]
  push:
    branches: [main]
    paths: ["envs/**", "main/**", "modules/**"]
  schedule:
    - cron: "0 3 * * *"
  workflow_dispatch:

jobs:
  tf:
    uses: dsb-norge/github-actions-terraform/.github/workflows/terraform-ci-cd-default.yml@v0
    secrets: inherit
    permissions:
      contents: read
      pull-requests: write
    with:
      extra-envs-yml: |
        ARM_USE_OIDC: true
      extra-envs-from-secrets-yml: |
        ARM_TENANT_ID: AZURE_TENANT_ID
        ARM_CLIENT_ID: AZURE_CLIENT_ID
      environments-yml: |
        - environment: dev
          extra-envs-from-secrets-yml:
            ARM_SUBSCRIPTION_ID: DEV_SUBSCRIPTION_ID
        - environment: prod
          github-environment: prod-approval
          extra-envs-from-secrets-yml:
            ARM_SUBSCRIPTION_ID: PROD_SUBSCRIPTION_ID
        - environment: nightly
          goals-yml: [init, format, validate, lint, plan]
```

On a branch:

1. Change `@v0` to `@v1` (§2.1).
2. Grant the four permissions (§2.2).
3. Remove `paths` from `on.pull_request` and `on.push` (§2.3).
4. Add `schedule` to the `trigger-events` of the environment the schedule is for (§2.4).
5. Add the standard dispatch block (§3.1).
6. Settle the test stage (§2.6) and, with test files, the identities (§2.7).
7. Fix what §2.8 and §2.9 name.

The same workflow on v1:

```yaml
name: "Terraform CI/CD"

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
  schedule:
    - cron: "0 3 * * *"
  workflow_dispatch:
    inputs:
      environment:
        description: "Environment to run, as named in environments-yml. Empty runs every environment."
        type: string
        default: ""
      goal:
        description: "Goal for this run. default follows goals-yml; plan, apply and destroy-plan override it for the selected environments."
        type: choice
        options: [default, plan, apply, destroy-plan]
        default: default
      reason:
        description: "Why this run is dispatched. Recorded in the run summary."
        type: string
        default: ""

jobs:
  tf:
    uses: dsb-norge/github-actions-terraform/.github/workflows/terraform-ci-cd-default.yml@v1
    secrets: inherit
    permissions:
      id-token: write
      contents: read
      pull-requests: write
      actions: read
    with:
      extra-envs-yml: |
        ARM_USE_OIDC: true
      extra-envs-from-secrets-yml: |
        ARM_TENANT_ID: AZURE_TENANT_ID
        ARM_CLIENT_ID: AZURE_CLIENT_ID
      environments-yml: |
        - environment: dev
          extra-envs-from-secrets-yml:
            ARM_SUBSCRIPTION_ID: DEV_SUBSCRIPTION_ID
        - environment: prod
          github-environment: prod-approval
          extra-envs-from-secrets-yml:
            ARM_SUBSCRIPTION_ID: PROD_SUBSCRIPTION_ID
        - environment: nightly
          goals-yml: [init, format, validate, lint, plan]
          trigger-events: [push, schedule]
```

On v0 the schedule planned and applied `dev` and `prod` every night and planned `nightly`; on v1 it
plans `nightly` alone, and `nightly` takes no part in pull requests or dispatches. Give `nightly`
`[pull_request, push, workflow_dispatch, schedule]` to keep it planning on pull requests too.

## 6. Validating the move

Open the change as a **draft pull request** and read its runs. Green is necessary, not sufficient:
compare each run with what the change should have done.

1. **The move's own pull request** changes the calling workflow, so every environment runs
   (`relevance all (workflow-changed)`). Check:
   - `Create job matrix` succeeded. Its annotations list every refused setting; its log's
     "decision record" group gives each environment's verdict and granted goals, for example
     `prod: run — relevance: all:workflow-changed; goals: init, format, validate, lint, plan`.
   - The plans say what they said on v0: a move that changes no Terraform code plans no changes.
   - With test files, one `Terraform test (<file>)` job per file and a `Terraform tests summary`
     comment; a credentialed test without a lane fails here.
   - `Terraform conclusion` is green, and its line reads, for example,
     `conclusion: green — environments: 3 affected, 0 not affected (all: workflow-changed); tests: 2`.
2. **A documentation-only pull request** (a README change): no environment runs, each ungrouped
   environment's comment says "➖ Not affected by this pull request", the notice reads
   `relevance diff (diff): 0 of 3 environments affected; nothing to verify for this change`, and the
   conclusion is green. Test files still run.
3. **A pull request that touches one environment** runs that environment alone; the others are
   "not affected".
4. **With test files, a pull request that breaks a test** turns the conclusion red.
5. **After the merge, the first push** applies only what the merge touched. Its run summary lists
   every environment, applied or not affected, with the relevance line.
6. **A dispatch** with `environment` and `goal: plan` plans that one environment; the run's first
   notice reads `dispatched by <you>: environment <name>, goal plan, reason "…"`.
7. **The first scheduled run** takes only the environments that opted in; the others are skipped
   with `trigger-events: schedule not enabled` in the decision record.

## 7. Rolling back

`v0` stays frozen at v0.33 and takes fixes only, so moving back is changing `@v1` to `@v0`. Undo
the v1-only parts at the same time:

- **Remove the v1-only inputs from `with:`** (`path-relevance-enabled`, `trigger-events-yml` and
  the `terraform-test-*` inputs, `allow-failing-terraform-tests`): GitHub refuses a call with an
  input the called workflow does not declare.
- **Mind the schedule.** v0 does not read `trigger-events`: a schedule applies every environment on the
  default branch again. Remove the schedule, or move it back to its own workflow, before the
  rollback merges.
- **Mind the dispatch block.** v0 ignores its inputs: a dispatch runs every environment with its
  goals, and `goal: plan` no longer stops an apply on the default branch.
- v0 does not read `paths`, `paths-ignore` or `depends-on`: every environment runs on every
  change, all at once. Restore `on.paths` if the repository relied on it.
- Keep the permissions of §2.2 and the identity audit of §2.7; both are right for v0 too.

## 8. Pitfalls

| Pitfall | What happens | What to do |
|---|---|---|
| `on.paths` kept on the calling workflow | a docs-only pull request never runs the workflow, and the required conclusion stays "Expected" | remove it; relevance runs inside (§2.3) |
| An environment reads a file outside `auto` | a change to that file no longer plans it | list the file's directory in `paths` (§2.3) |
| A schedule without an opted-in environment | the nightly run does nothing, green, with a notice | add `schedule` to that environment's `trigger-events` (§2.4) |
| `schedule` in `trigger-events-yml` | refused | per environment only |
| `trigger-events` written without the events the environment keeps | it drops out of pull requests or dispatches | list every event it takes part in |
| A dispatch input of your own named `environment` or `goal` | it selects or caps environments | rename it (§2.5) |
| A calling job without `id-token: write` | the run does not start | grant it, even without tests or OIDC (§2.2) |
| A per-environment `runs-on` written as a list | v0's builder passed it through; v1 refuses it as not a string | one string: a runner group or one label |
| An unquoted per-environment `true` | used to act as false; now takes effect, so a lock check or a comment appears | check each boolean says what you mean |
| `terraform-version: 1.10` per environment | refused | quote it |
| Test files that need credentials, with no lane | they fail on every pull request | add a lane, exclude them or switch the stage off (§2.6, §4.2) |
| An identity trusting `pull_request` or a branch | test code from a pull request can use it | narrow it to environment subjects (§2.7) |
| Repository-level `ARM_*` or `TF_VAR_*` secrets and an environment lane | the lane exports them as if they were its own | rename them before adding the lane (§4.2) |
| Auto-merge with the default actor list | refused | name the accounts (§2.9) |
| A tolerated failure on a Dependabot pull request | no longer auto-merges | fix the failure; tolerate tests, not operations |
| A burst of bot pull requests | one merges per base; the rest wait for their rebase | expected: the merge is pinned to what was planned |
| A failed apply on a push, then an unrelated push | the environment is not retried | dispatch it (§3.1) |
| `cancel-in-progress: true` on the calling workflow | an apply can be cancelled mid-run | remove it (§3.2) |
| Two calling workflows on one pull request | the same tests run twice | `terraform-test-enabled: false` in all but one (§3.4) |
| Two skipped `Terraform` checks and a skipped `matrix.test.name` check on every run | the unused stage jobs and the test job without tests | expected; they satisfy branch protection |
| A pull request with a merge conflict | no run at all; the check stays "Expected" | GitHub's behaviour; resolve the conflict |
| Rolling back with v1-only inputs in `with:` | the call is refused | remove them (§7) |

## 9. Module repositories

A module repository, one that calls `terraform-module-ci.yaml` and `terraform-module-release.yaml`,
moves with its own guide: [Migration-v0-to-v1-modules.md](Migration-v0-to-v1-modules.md).
