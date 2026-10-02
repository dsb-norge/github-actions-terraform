# What changed in v1

Every change a caller of
[`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml) meets when it
moves from `@v0` (frozen at v0.33) to `@v1`. How to move a repository, with the checks to make and
a way back, is [Migration-v0-to-v1.md](Migration-v0-to-v1.md). How to use the workflow is the user
guide, [Workflow-terraform-ci-default.md](Workflow-terraform-ci-default.md).

The module workflows (`terraform-module-ci`, `terraform-module-release`) are §11.

## 1. In short

- **The workflow decides what runs.** A Python decision engine in the `create-matrix` job validates
  the configuration and decides, per environment, whether it takes part in the run and with which
  goals, and writes down why ([Decision-engine.md](Decision-engine.md)).
- **Only the environments a change touches run** on pull requests and pushes. A documentation-only
  pull request runs no environment and still gets a green `Terraform conclusion`
  ([Path-relevance.md](Path-relevance.md)).
- **Committed `terraform test` files run**, one job per file, and a failing one blocks the merge
  ([Terraform-tests.md](Terraform-tests.md)).
- **A schedule runs only the environments that opt in, and plans them** unless an environment's
  `schedule-goal` says otherwise; a dispatch can run one environment with a chosen goal
  ([Dispatch-and-triggers.md](Dispatch-and-triggers.md)).
- **Environments can be ordered** with `depends-on` ([Environment-ordering.md](Environment-ordering.md)).
- **A configuration mistake is an error**, never a different configuration that silently runs
  ([Configuration-validation.md](Configuration-validation.md)).
- **Auto-merge trusts only exact evidence**: counts from the JSON plan, a merge pinned to what was
  planned, an actor list that must name someone ([Auto-merge.md](Auto-merge.md)).

No input is removed or renamed, and no input's default changes. Eight inputs are new (§3). The
required check keeps its name, `<job id> / Terraform conclusion`.

## 2. Breaking changes

"Breaking" means a default or a rule changed: a caller that changes nothing but the ref gets the
new behaviour.

### 2.1 What runs

| Change | v0.33 | v1 | Why | What a caller sees |
|---|---|---|---|---|
| Path relevance | every environment ran on every pull request and push | on `pull_request` and `push`, an environment runs only when a changed file matches its `paths`; absent `paths` means `auto`: `<project-dir>/**`, `main/**`, `modules/**`, the environment's additional init directories and the root's `/.tflint.hcl`, with `**/*.md` ignored | a docs-only pull request left a required check pending when the caller filtered with `on.paths`; one configuration and one check instead of a second workflow file | unaffected environments get no job; their PR comment says "➖ Not affected by this pull request"; a notice such as `relevance diff (diff): 1 of 3 environments affected`. A change under `.github/workflows/`, a force push and every other uncertainty run every environment ([Path-relevance.md §3, §4.2](Path-relevance.md)) |
| Terraform tests | not run by this workflow | every committed `*.tftest.hcl` and `*.tftest.json` runs on pull requests and pushes, one job per file, with no credentials unless a lane gives them; a failing test turns the conclusion red | tests were wired up by hand, if at all | new `Terraform test (<file>)` jobs and one `Terraform tests summary` comment. A test root needs Terraform 1.13 or later, and every lock file a test uses must record the runner's platform ([Terraform-tests.md §3.5, §5.3](Terraform-tests.md)) |
| Schedule | a `schedule` on the calling workflow planned and applied every environment on the default branch | an environment takes part in a scheduled run only when its own `trigger-events` holds `schedule`, and plans without applying unless its `schedule-goal` says otherwise (`default` for a reconcile) | a schedule meant for one environment applied production unattended, and a drift check could not be had without an apply | a schedule nobody opted into runs nothing, green, with the notice `schedule: no environment takes part in scheduled runs; add 'schedule' to the trigger-events of the environment the schedule is for`; a scheduled run says what each environment was capped to |
| Dispatch inputs | ignored; a dispatch ran every environment with its goals | the calling workflow's `workflow_dispatch` inputs `environment`, `goal` and `reason` are read by name from the event | recovering one environment needed its own workflow file | a caller whose own dispatch block uses `environment` or `goal` for something else now selects or caps environments with it. Without the inputs a dispatch runs as before, and a notice says where the standard block is ([Dispatch-and-triggers.md §3.1](Dispatch-and-triggers.md)) |
| Unsupported events | ran with whatever the gates allowed | only `pull_request`, `push`, `workflow_dispatch` and `schedule`; any other event is a validation error | a gate written for four events decided the others by accident | `event 'merge_group' is not supported by this workflow; supported: pull_request, push, workflow_dispatch, schedule` |
| Default branch | the short ref name was compared, so a tag named like the default branch counted as it | only a branch of that name | a dispatch from such a tag could apply | `dispatch: apply is only allowed from the default branch 'main'; this run is on the tag 'main'`; a push to such a tag grants no apply ([Configuration-validation.md §3.8](Configuration-validation.md)) |

### 2.2 Configuration

Every rule below is checked in `create-matrix` before any environment job starts. A refused
configuration fails that job with one `::error` annotation per problem, titled
`create-tf-vars-matrix`, and the conclusion reads `conclusion: red — the matrix could not be built (failure)`.
The messages are listed in [Configuration-validation.md §3](Configuration-validation.md) and in the
user guide's [mistakes the workflow refuses](Workflow-terraform-ci-default.md#mistakes-the-workflow-refuses).

| Change | v0.33 | v1 | Why |
|---|---|---|---|
| Keys of an `environments-yml` entry | any key was forwarded; a misspelt one (`goals:` for `goals-yml:`, `github_environment`) was ignored and the setting kept its global value | every key must be a known setting; an unsuffixed YAML setting, a suffixed plain one, a workflow-only input and an unknown key each have their own message, with the nearest known key | `goals:` kept the global `[all]` and applied; a misspelt `github-environment` ran in a new, unprotected GitHub Environment |
| Goals | read by substring: a list written without its dashes (`init plan destroy-plan` on separate lines) held `destroy`, a misspelt goal held nothing, case did not matter | a list of known goal names in lower case; a single goal written alone is that goal; anything else is an error naming the valid goals | a caller who asked for a destroy preview got a destroy |
| Goal prerequisites | `apply` without `plan`, `destroy` without `destroy-plan`, `plan` without `init` were granted and never ran | an error naming the missing goal | a goal that can never run was recorded and believed |
| Per-environment booleans | an unquoted `true` (`verify-lock-file: true`) reached the gates as a JSON boolean and compared as false | `true` and `false`, quoted or not, take effect; any other value (`yes`, `null`) is an error, for `allow-failing-terraform-operations` too | the setting did the opposite of what it said |
| Per-environment strings | an unquoted number passed: `terraform-version: 1.10` became `1.1` | a setting that overrides a string input must be a string: `The environment 'prod' sets 'terraform-version' to 1.1, which is not a string; quote it!` | the version was silently different |
| Per-environment `runs-on` as a list | not checked by the builder | refused as not a string: `The environment 'prod' sets 'runs-on' to ["self-hosted", "linux"], which is not a string; quote it!` | the input is a string; write the runner group or label as one string |
| Environment names | any value | `environment` and `github-environment` are 1 to 255 of `A-Z a-z 0-9 . _ -`, starting with a letter or a digit | names reach comment markers, artifact names, concurrency groups and shell |
| One environment per github-environment | two environments could share one | an error: `The environments 'a' and 'b' share the github-environment 'x'; …` (compared without case) | they overwrote each other's comments and metadata |
| Duplicate environment names | passed | `Duplicate environment 'prod' in environments-yml specification!` | |
| Variable values (`extra-envs-yml`, `extra-envs-from-secrets-yml`, their per-goal forms) | YAML-typed: `1.10` reached the job as `1.1`, a leading zero was dropped, `~` was exported as the text `null`, a mapping as its JSON | text as written; a null means not set, so an environment's null removes a global variable; a mapping or a list is an error | the job received a value nobody wrote |
| Variable names | not checked | letters, digits and underscores, not starting with a digit | |
| Additional init directories | a single directory written as a string initialised nothing; the init loop split on spaces | a single directory written alone is that directory; each directory is quoted, so one holding a space is one directory; an empty entry is an error | |

### 2.3 Auto-merge

Only for callers with `pr-auto-merge-enabled: true`. The full design is [Auto-merge.md](Auto-merge.md).

| Change | v0.33 | v1 | Why |
|---|---|---|---|
| Actor list | empty, `~`, `{}`, `0` or `true` allowed every actor; exact case | with auto-merge on, the list in effect for every enabled environment must name at least one login; logins compare without case | the default empty list let any author's pull request merge past review |
| Per-environment actor list | added to the global list | replaces the global list for that environment | a list could only ever widen |
| Limits | an unknown key was ignored, a quoted number accepted | after the per-environment merge, exactly the six `plan-max-count-*` keys, each an unquoted whole number of -1 or more | a misspelt per-environment key was ignored over a permissive global value |
| Counts | read from the plan's console text | from Terraform's JSON plan; a `-target` plan is counted but not eligible | text inside a plan could zero every count |
| Scope | any base branch; forks ran and failed | pull requests against the default branch from the same repository | only the default branch is production to the gates |
| The merge | took the pull request as it was when merged | pinned to the head the run planned (`--match-head-commit`) and refused when the base branch moved since the plan | plan what you merge; in a burst of bot pull requests one merges per base, the rest on their next run after a rebase |
| Tolerated failures | a failed plan made an environment ineligible; a failure of `fmt`, `validate`, `lint` or the lock check tolerated by `allow-failing-terraform-operations` did not | any failed or cancelled operation step (`init`, lock check, `fmt`, `validate`, `lint`, `plan`, `apply`, `destroy-plan`, `destroy`) makes it ineligible, tolerated by `allow-failing-terraform-operations` or not; a tolerated failing test does not, and is named in a notice | tolerating a failure means "do not fail the check", never "merge without review" |

### 2.4 Artifacts, permissions and runners

| Change | v0.33 | v1 | What a caller does |
|---|---|---|---|
| JSON plan artifact | `<env>-terraform-plan-json` uploaded on every run | not uploaded: it holds sensitive values in plain text, and the parse step reads it on the runner | use `<env>-terraform-plan-console-output`, which is unchanged |
| `id-token: write` | used only by callers that log in with OIDC | the `terraform-test` job declares `id-token: write`, whether or not the repository has test files | the calling job grants it (§7) |
| `create-matrix` runtime | bash, `jq`, `yq` | Python 3.12 or later and `yq` (the Go implementation, v4) on the workflow's `runs-on`; `gh` and `git` as before | nothing on GitHub-hosted runners; a self-hosted pool named in `runs-on` carries them (§8) |
| Configuration errors | log lines, one of them lost in a command substitution | `::error` annotations; the step exits 2 | nothing |
| Default branch lookup | a failed API lookup gave the string `null` and the run went on | read from the event payload; a failed API fallback stops the run | nothing |

## 3. New inputs

All optional. Every other input of v0.33 keeps its name, type and default.

| Input | Type | Default | What it does | Spec |
|---|---|---|---|---|
| `path-relevance-enabled` | boolean | `true` | `false` runs every environment that takes part in the event, whatever changed | [Path-relevance.md §3.4](Path-relevance.md) |
| `trigger-events-yml` | string (YAML list) | `[pull_request, push, workflow_dispatch]` | the events an environment takes part in unless it sets `trigger-events`; `schedule` is not allowed here | [Dispatch-and-triggers.md §3.2](Dispatch-and-triggers.md) |
| `terraform-test-enabled` | boolean | `true` | `false` removes every test job, the test summary job and its comment | [Terraform-tests.md §3.1](Terraform-tests.md) |
| `allow-failing-terraform-tests` | boolean | `false` | a failing or erroring test does not fail the check; per lane too | [Terraform-tests.md §3.1](Terraform-tests.md) |
| `terraform-test-runs-on` | string | `ubuntu-latest` | the runner for test jobs, separate from `runs-on`; per lane `runs-on` | [Terraform-tests.md §3.1](Terraform-tests.md) |
| `terraform-test-timeout-minutes` | number | `30` | each test job's timeout; per lane `timeout-minutes` | [Terraform-tests.md §3.1](Terraform-tests.md) |
| `terraform-test-lanes-yml` | string (YAML list) | empty | lanes: which files run with which credentials, runner, version and GitHub Environment | [Terraform-tests.md §3.2](Terraform-tests.md) |
| `terraform-test-exclude-paths-yml` | string (YAML list) | empty | glob patterns of test files discovery ignores | [Terraform-tests.md §3.1](Terraform-tests.md) |

The five `terraform-test-*` inputs, `allow-failing-terraform-tests`, `trigger-events-yml` and
`path-relevance-enabled` are workflow-only: setting one inside an environment is a validation error.

## 4. New and changed per-environment keys

| Key | What it does | Spec |
|---|---|---|
| `paths`, `paths-ignore` | the files that make the environment relevant, and those that never do; `auto` in `paths` is the standard set | [Path-relevance.md §3.1](Path-relevance.md) |
| `trigger-events` | the events the environment takes part in, replacing `trigger-events-yml`; the only place `schedule` may appear | [Dispatch-and-triggers.md §3.2](Dispatch-and-triggers.md) |
| `schedule-goal` | what a scheduled run may do: `plan` (the default), `default` (a reconcile, as a push to the default branch), `apply` or `destroy-plan` | [Dispatch-and-triggers.md §4.4](Dispatch-and-triggers.md) |
| `depends-on` | the environments this one runs after, when the run applies or destroys | [Environment-ordering.md §3](Environment-ordering.md) |
| `pr-auto-merge-enabled` | now documented per environment; `false` keeps every pull request of the repository from auto-merging; `true` while the input is `false` is a warning | [Configuration-validation.md §3.6](Configuration-validation.md) |
| `pr-auto-merge-from-actors-yml` | replaces the global list for the environment (v0 added it) | [Configuration-validation.md §3.6](Configuration-validation.md) |
| `pr-auto-merge-limits-yml` | merged into the global limits, so one limit can be overridden alone | [Configuration-validation.md §3.6](Configuration-validation.md) |

The full list of keys an entry may hold is [Configuration-validation.md §3.1](Configuration-validation.md).
A test lane has keys of its own ([Terraform-tests.md §3.2](Terraform-tests.md)).

## 5. New features

Each is off, or at a safe default, until a caller configures it; whether to adopt each is weighed
in [Migration-v0-to-v1.md §4](Migration-v0-to-v1.md).

| Feature | In one line | Spec |
|---|---|---|
| Path relevance | per-environment `paths` and `paths-ignore` with a small glob grammar (`*`, `**`, `?`, a leading `/` anchors at the root) | [Path-relevance.md §3](Path-relevance.md) |
| Conclusion from named results | green when everything that should have run ran and passed, including when nothing needed to run; the verdict is one line in the log, the step summary and an annotation | [Path-relevance.md §7](Path-relevance.md) |
| Terraform test stage | one job per committed test file, provider versions taken from the environments' lock files, one summary comment | [Terraform-tests.md §4, §5, §6](Terraform-tests.md) |
| Test lanes | files grouped by glob into lanes with their own credentials, runner, Terraform version, timeout and tolerance | [Terraform-tests.md §3.2](Terraform-tests.md) |
| GitHub Environment per lane | `github-environment: auto` runs a lane in `tftest-<lane>`: secrets scoped to the lane, an OIDC subject naming it, no deployment record | [Terraform-tests.md §3.6](Terraform-tests.md) |
| Standard dispatch block | `environment`, `goal` and `reason` read from the caller's dispatch; `goal` can only cap what `goals-yml` grants and never adds `destroy` | [Dispatch-and-triggers.md §3.1, §4.2](Dispatch-and-triggers.md) |
| Trigger events | per-environment participation in `pull_request`, `push`, `workflow_dispatch` and `schedule` | [Dispatch-and-triggers.md §3.2, §4.1](Dispatch-and-triggers.md) |
| Environment ordering | `depends-on`, compiled into up to three stages that run one after the other; a single-environment dispatch bypasses it | [Environment-ordering.md §3, §4, §6](Environment-ordering.md) |
| Configuration validation | every setting means one thing; every mistake is reported in one run, in sentences that say how to write it | [Configuration-validation.md](Configuration-validation.md) |
| Auto-merge of docs-only pull requests | a pull request that affects no environment is eligible under the same enabled and actor checks | [Path-relevance.md §8](Path-relevance.md) |
| Decision record | per environment and test file, run or skip and why, with the granted goals, in the `create-matrix` log | [Decision-engine.md §5](Decision-engine.md) |
| Module cache for test jobs | test jobs use the module cache the environment jobs use, under `cache-terraform-modules` and a per-lane override | [Terraform-tests.md §5.3](Terraform-tests.md), [Terraform-module-cache.md §4.7](Terraform-module-cache.md) |

## 6. Behaviour changes that are not breaking

### 6.1 Jobs and checks

| Job (check name) | New or changed |
|---|---|
| `create-matrix` (Create job matrix) | runs the decision engine; logs the decision record; uploads the `relevance` artifact; emits the relevance notice, and on a dispatch the dispatch line as the first notice |
| `terraform-ci-cd`, `terraform-ci-cd-2`, `terraform-ci-cd-3` (Terraform) | the environments run in up to three stage jobs sharing one step list. Without `depends-on` every environment is in stage 1, and every run shows **two more `Terraform` checks, skipped**. A skipped check satisfies branch protection; they change nothing but the list |
| `terraform-test` (`Terraform test (<file>)`) | new; one job per test file, in parallel with the environments. When the stage does not run, the skipped job shows its name unevaluated, `matrix.test.name`, because GitHub does not evaluate a skipped job's matrix name |
| `terraform-test-summary` (Terraform tests summary) | new; runs on pull requests, and on pushes with test files |
| `conclusion` (Terraform conclusion) | judges named results and the engine's counts instead of "nothing failed": a stage job skipped while it had environments, or a test job skipped while tests were active, is red. Writes its verdict to the log, the step summary and a `::notice` or `::error`, for example `conclusion: green — nothing to verify for this change; environments: 0 affected, 3 not affected (diff: diff); tests: 0` |
| `automerge` (PR auto merger) | runs only against the default branch, from the same repository; also after a run with no affected environment |

Job ids of v0.33 are kept; the check names every caller requires are unchanged.

### 6.2 Pull-request comments

- An ungrouped environment the change does not touch gets its head written as its final body:
  `➖ Not affected by this pull request: no changed file matches this environment's paths`, with a
  collapsed "Path rules" section; its earlier plan and operation comments are removed.
- In a group's table an unaffected environment keeps its column, filled with dashes, and a line
  under the table names it. Columns follow `environments-yml` order instead of the alphabet. A
  group whose members are all unaffected is rendered all dashes, never deleted.
- An environment whose `trigger-events` lack `pull_request` gets a head saying
  `➖ Does not take part in pull requests`, naming its events.
- An environment held back by a failed stage gets `⏭️ Held back: this environment is in stage 2 and stage 1 failed`,
  and a ⏭️ column in its group.
- One `Terraform tests summary` comment per calling workflow, after the environment heads, when
  the repository has test files; it is removed when the last test file is.
- The Mode row and the "Terraform summary" title read the goals the run was granted: a pull request
  against a branch other than the default branch no longer says "applies on PR".
- The plan comment's counts come from the JSON plan, so text inside a plan can no longer hide it.

The comment model is [Workflow-pr-comments.md](Workflow-pr-comments.md).

### 6.3 Run page

- The run summary's headline is `N environments · A affected · U not affected · X applied · Y failed`
  (with `destroyed`, `held back` and `not reported` when non-zero). Every environment has a row, an
  unaffected one of dashes, a held-back one of ⏭️; a line states the relevance mode, a dispatch's
  line is quoted, and with `depends-on` the stages are listed under the table
  ([Path-relevance.md §6.5](Path-relevance.md), [Environment-ordering.md §7.2](Environment-ordering.md)).
- Notices: the relevance count on every run; `nothing to verify for this change` when a pull
  request or push touches nothing, `nothing to run` on a schedule or dispatch with nothing to do;
  who dispatched what, with which goal and reason; an ordering bypass, or an environment that
  applied without its dependency in the run; a tolerated failing test on an auto-merged pull
  request.
- New artifacts: `relevance` (every environment's verdict, no file lists), and per test file
  `terraform-test-log-<slug>` and `terraform-test-meta-<slug>`.

### 6.4 GitHub Environments, concurrency and deployments

- A lane with `github-environment` creates its `tftest-<lane>` environment on its first run, with
  no protection rules. Test jobs record no deployment.
- An unaffected environment's job does not run, so it takes no concurrency lock: a docs-only pull
  request no longer queues behind production's apply. The repository's Environments view shows
  each environment's last deployment, which may be older than the latest run.
- Test jobs queue per test file (`<repository>-terraform-test-<slug>`), with `queue: max` as the
  environment jobs have.
- The advice on the calling workflow's concurrency changes: v0's comment spec suggested
  `cancel-in-progress: true` for pull requests; v1 advises against it on any workflow that applies,
  since it cancels the whole run, an in-progress apply included
  ([Workflow-terraform-ci-default.md, `environments-yml`](Workflow-terraform-ci-default.md#environments-yml)).

### 6.5 Recovery

An apply that failed on one push is not retried by a later push that does not touch that
environment. A dispatch is never filtered by relevance and, with the standard inputs block, can
name the one environment.

## 7. Permissions

The calling job grants:

```yaml
    permissions:
      id-token: write      # OIDC login, for the environments and the test jobs
      contents: read       # checkout, and the files a push changed
      pull-requests: write # PR comments, and the files a pull request changed
      actions: read        # job links in the grouped PR comments
```

The set is the one v0.33's workflow header named. What is new is who asks for it:
`create-matrix` declares `contents: read` and `pull-requests: read` to list the changed files, and
`terraform-test` declares `contents: read` and `id-token: write`. GitHub does not let a called
workflow's job hold a permission the calling job did not grant, so a calling job without
`id-token: write` does not run at all on v1, even in a repository without tests or OIDC.
`secrets: inherit` is needed as before, and is also how environment and lane secrets reach the
test jobs.

## 8. Runner requirements

| Where | Requirement | On GitHub-hosted runners |
|---|---|---|
| `create-matrix` and the reporting jobs, on `runs-on` | Python 3.12 or later (`run.py` exits naming the floor), `yq` v4 (the Go implementation), `jq`, `gh`, `git`, bash and coreutils | present on `ubuntu-latest` |
| Every job | an Actions runner that runs Node 24 actions, v2.327.1 or later: v1 uses `actions/checkout@v7`, `actions/cache@v6`, `actions/upload-artifact@v7`, `actions/download-artifact@v8` and `actions/create-github-app-token@v3`. v0.33 already needed it for checkout, cache and upload | always current |
| The auto-merge job behind a proxy | not supported: `create-github-app-token@v3` has no proxy handling of its own, and the workflow sets nothing to add it | no proxy |
| Test jobs, on `terraform-test-runs-on` | Terraform 1.13 or later for the test roots; the same tools as the environment job | present |

`ubuntu-latest` moving to a newer image brings a newer Python; the engine is standard library only
and its suite runs on 3.12 and on the newest 3.x.

## 9. Internal changes callers may notice

- The matrix is built by the decision engine (`engine/`), run as `python3 -I -B engine/run.py
  create-matrix`, instead of bash and `jq`. For the same configuration and event it produces the
  rows v0.33 produced, apart from the deliberate changes above and the new row variable
  `goals-granted`, which the operation gates now read ([Decision-engine.md §9](Decision-engine.md)).
- The logs of `create-matrix` hold new collapsed groups: the inputs, the changed files, the engine's
  input document and the decision record.
- Values reach `run:` blocks through `env:` instead of being pasted into the script; step names and
  outcomes are unchanged.
- The JSON plan is still written on the runner, with Terraform's stderr kept apart, and read by
  the parse step.
- Every internal `uses:` of the workflow names `@v1`, so the workflow and its actions always come
  from one ref.

## 10. What stays the same

- The required check, `<job id> / Terraform conclusion`, and every v0.33 job id and check name.
- Every v0.33 input, with its type and default; no secrets or outputs are declared, as before.
- The per-environment concurrency group (the `github-environment`), `queue: max`, and the
  environment job running in its GitHub Environment.
- Goals, `apply` on a push or dispatch to the default branch, `apply-on-pr` and `destroy-on-pr`,
  the per-goal variables, module download authentication and the module cache.
- `v0` stays frozen at v0.33 and takes fixes only, so a repository can move back
  ([Migration-v0-to-v1.md §7](Migration-v0-to-v1.md)).

## 11. The module workflows

For a module repository calling `terraform-module-ci.yaml` and `terraform-module-release.yaml`.
The design is [Module-ci.md](Module-ci.md), and moving a repository is
[Migration-v0-to-v1-modules.md](Migration-v0-to-v1-modules.md).

| Change | v0.33 | v1 |
|---|---|---|
| Test discovery | `find` over the working tree, one job per file name | the project workflow's test stage, in the engine's module mode: committed files, the root rule, lanes, misplaced files listed |
| Credentials | every test file got the repository's Azure principal, through the called workflow's `env:` | only from lanes: none by default, one fallback lane for the usual single credential, a GitHub Environment with OIDC per lane |
| No test file | green | red: a module needs at least one test file; `terraform-test-required: false` opts out |
| Terraform version | any | 1.13 or later for the tests |
| Events that test | every event the calling workflow runs on | `pull_request`, `push`, `workflow_dispatch` and `schedule`; any other event is a validation error |
| Test jobs | per file, legacy call shape, embedded login | the project workflow's test job and summary job, held equal by a structural test |
| PR comments | the validation head, and one comment per test file | the validation head for the module (no lock and no plan rows), and one tests summary; v0's per-file comments are deleted |
| Run page | nothing on a dispatch | the validation block, each test job's block, the tests block and the conclusion line on every event |
| Docs | terraform-docs pushed on every event, a dispatch included | a docs commit only on a pull request from the repository; elsewhere a README that needs regenerating fails the check |
| App token | the organisation's token action, with the installation ID | `actions/create-github-app-token@v3`; the installation ID is not read |
| release-please | v4.2.0 | v5.0.0 |
| Conclusion | red on any failed, cancelled or skipped job | named results: the matrix, the docs, validation, the tests, and a missing test file |
| New inputs | — | `runs-on`, `add-pr-comment`, `cache-terraform-modules`, `terraform-test-enabled`, `terraform-test-required`, `allow-failing-terraform-tests`, `terraform-test-runs-on`, `terraform-test-timeout-minutes`, `terraform-test-lanes-yml`, `terraform-test-exclude-paths-yml` |
| Retired actions | `create-tftest-matrix`, `create-test-report` | gone from the v1 line; v0 keeps them |
