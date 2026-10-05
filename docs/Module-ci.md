# Module CI

The reusable workflow [`terraform-module-ci.yaml`](../.github/workflows/terraform-module-ci.yaml)
validates, documents and tests a Terraform **module** repository: one module at the repository
root, its examples, and its `terraform test` files. The project workflow,
[`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml), does the same
for a repository of environments that are planned and applied. The two are separate workflows,
one per kind of repository, and share every piece that makes sense to share: the decision engine
decides the test stage for both, the test jobs are one job written twice, and the reports come
from the same actions. The user guide is
[Workflow-terraform-module-ci.md](Workflow-terraform-module-ci.md).

## 1. Why

On v0 module CI grew beside the project workflow and kept its own ways: a `find` over the working
tree for the test files, one comment per test file, a login with the repository's Azure principal
for every file, unit tests included, and a conclusion that failed a repository with no test files
the moment the shared `terraform-test` action moved on. The project workflow's test stage
([Terraform-tests.md](Terraform-tests.md)) solved each of these: committed files only, lanes with
their own credentials and GitHub Environments, one summary comment, a conclusion that judges named
results. Module CI takes that stage over instead of keeping a second one.

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | **The decision engine decides a module's test stage**, in a module mode of the `create-matrix` command: the same discovery, root rule, lanes and validation as the project workflow's test stage, with no environments. `create-tftest-matrix` and `create-test-report` leave the v1 line. | One set of rules under the engine's coverage and mutation gates (Decision-engine.md D12, D13). The two actions were used by module CI alone; v0 keeps its own copies. |
| D2 | **The module workflow carries the project workflow's `terraform-test` and `terraform-test-summary` jobs**, written out again and held to the same steps by a structural test (F20). One workflow per kind of repository, never one for both. | A shared reusable workflow would change the project workflow's job graph and its check names, and nest `secrets: inherit`; a copy under a parity test cannot drift. |
| D3 | **Tests run on `pull_request`, `push`, `workflow_dispatch` and `schedule`** in module mode. | Module callers use a dispatch as their manual build, and a nightly schedule catches provider and API drift; a module has no environment to recover, which is why the project mode keeps tests off dispatches. |
| D4 | **Credentials come only from lanes**: none by default; one credential, the normal case, is one fallback lane that maps the repository's secrets; several are several lanes, and a lane may run in its own GitHub Environment with OIDC (§6). | The v0 workflow gave every file the repository's principal through workflow-level `env:`. Every module caller already carries the same three secret names in a calling-workflow `env:` block that never reached the called workflow; the lane replaces that block line for line. An implicit default lane would fail every repository without those secrets and keep unit tests on the principal. |
| D5 | **Terraform 1.13 or later** for the test jobs, as in the project workflow. | One floor, one authoring rule (Terraform-tests.md D11). |
| D6 | **terraform-docs pushes only on a pull request from the repository**, not from a fork, and on Dependabot's only when the admission admitted the run ([Dependabot-admission.md](Dependabot-admission.md) D22); everywhere else a README that needs regenerating fails the docs check. The action is converted to the modern layout and keeps the upstream Docker action. | A dispatch or a push must never commit to the branch it runs on, `main` included. The Docker action's pinned terraform-docs keeps every README's table spacing. |
| D7 | **App tokens come from `actions/create-github-app-token@v3`**, in module CI and module release. | The organisation's own token action needs Deno from v3, which the hosted runners do not carry; the project workflow already uses the upstream action. |
| D8 | **Reporting follows the project workflow**: a validation head and a tests head on a pull request, a step summary from every job, and a conclusion line in the log and an annotation, on the run page in the run summary's headline (§7.1). The per-file test comments of v0 are deleted once. | One reporting model for both kinds of repository ([Workflow-pr-comments.md](Workflow-pr-comments.md)); the actions exist. |
| D9 | **A module needs at least one test file**: with none, the conclusion is red, `terraform-test-required: false` opts out. Everything from a unit suite up is supported: lanes, GitHub Environments, OIDC, several credentials. | A module's tests are its contract with its callers; a unit suite needs no credentials, so every module can have one. |
| D10 | **The test bed is a module-shaped branch of the project test bed**, with the kept test identity; close to release a real module repository is moved by the migration guide. | No new repository to administer; the identity and its environment exist. |
| D11 | **Scope: everything that makes sense to share**, and the module workflow's own gaps with it: the plugin cache, per-job permissions, parsed warnings, the docs. | The two workflows are held together by the structural tests from here on. |
| D12 | **Path relevance for the module**: on a pull request or a push, the module is affected unless every changed file matches `paths-ignore-yml` (default `**/*.md`). Not affected, the run validates nothing and holds every test file back; the docs job runs as always, and the conclusion is green. `path-relevance-enabled: false` runs everything. Unlike the project workflow's relevance, it also holds back the tests (Path-relevance.md D11 keeps them there). | Decided by the maintainer: a README- or docs-only pull request ran validation and every test, credentialed integration lanes included, for nothing a change to Markdown can break. A module is one unit, so its relevance is one verdict; the project workflow keeps its tests because they test environments' code that path rules may not see. |
| D13 | **A run summary job**, `run-summary`, writes one block for the whole run to the run page on every event: the conclusion, the relevance line, the docs, validation and test results, the admission's table when it refused, and auto-merge's verdict and result. It is `create-run-summary` in `mode: module`. | Decided by the maintainer: each job described only itself, so the run page had no single answer, and the admission's table, which the project workflow puts there, appeared nowhere. |

## 3. Caller-facing API

### 3.1 Inputs

| Input | Type | Default | Meaning |
|---|---|---|---|
| `terraform-version` | string | required | Terraform for validation and, unless a lane says otherwise, the tests; 1.13 or later for tests. |
| `tflint-version` | string | required | TFLint for the lint step. |
| `readme-file-path` | string | `.` | Directory of the README terraform-docs maintains. |
| `runs-on` | string | `ubuntu-latest` | Runner of every job but the test jobs. |
| `add-pr-comment` | boolean | `true` | Post the validation and tests heads on pull requests. |
| `cache-terraform-modules` | boolean | `true` | The module cache in the test jobs ([Terraform-module-cache.md](Terraform-module-cache.md)). |
| `terraform-test-enabled` | boolean | `true` | `false` removes the test stage. |
| `terraform-test-required` | boolean | `true` | `false` lets a repository with no test file conclude green (D9). |
| `allow-failing-terraform-tests` | boolean | `false` | A failing test does not fail the check; per lane too. |
| `terraform-test-runs-on` | string | `ubuntu-latest` | Runner of the test jobs; per lane `runs-on`. |
| `terraform-test-timeout-minutes` | number | `30` | Each test job's timeout; per lane `timeout-minutes`. |
| `terraform-test-lanes-yml` | string | `""` | Lanes, exactly as in the project workflow ([Terraform-tests.md §3.2](Terraform-tests.md)). |
| `terraform-test-exclude-paths-yml` | string | `""` | Globs of test files discovery ignores. |
| `dependabot-admission-enabled` | boolean | `false` | The Dependabot admission ([Dependabot-admission.md §11](Dependabot-admission.md)). |
| `dependabot-admission-yml` | string | `""` | The admission's policy, added to its built-in one. |
| `pr-auto-merge-enabled` | boolean | `false` | Merge a listed bot's pull request once its run is green ([Module-auto-merge.md](Module-auto-merge.md)). |
| `pr-auto-merge-from-actors-yml` | string | `"[]"` | The bots whose pull requests may merge, by the pull request's author. |
| `path-relevance-enabled` | boolean | `true` | Skip validation and the tests on a change that touches only ignored files (§5.1); `false` runs everything. |
| `paths-ignore-yml` | string (YAML list) | `""` | Globs of files that never make the module affected; empty means `["**/*.md"]`, `[]` ignores nothing. |

Every input with a project-workflow namesake means the same there; the engine validates them with
the same rules and messages ([Configuration-validation.md](Configuration-validation.md)).

### 3.2 Permissions, secrets and variables

```yaml
    permissions:
      id-token: write      # OIDC, for the test jobs
      contents: read       # checkout; the docs job pushes with the App token, not this one
      pull-requests: write # the heads, the admission head included
      actions: read        # job links in the tests head
    secrets: inherit
```

No job asks for `contents: write`: the docs commit is pushed with the App token, which carries its
own permissions. The App is the organisation's CI App: `vars.ORG_TF_CICD_APP_ID` and
`secrets.ORG_TF_CICD_APP_PRIVATE_KEY`. `vars.ORG_TF_CICD_APP_INSTALLATION_ID` is no longer read.
A Dependabot run reads the variable but Dependabot secrets only, so the docs push on an admitted
Dependabot pull request needs the key as an organisation Dependabot secret of the same name too.
Both are the organisation's, and reach a repository only when it is on each one's repository
access list. The docs job, the auto-merge job and the release job check them before the token
step and fail naming each one missing; the token step may then fail, and the step after it names the two causes left,
the App not installed on the repository or a key that is not the App's (P9). Only the App can ask
GitHub about its installation, and the token step is that question, so the installation is judged
from its outcome rather than checked a second time with the key.

## 4. Jobs

```mermaid
flowchart LR
    matrix["create-matrix: the engine, module mode"] --> tests["terraform-test: one job per test file"]
    matrix --> seed["seed-pr-comments: the admission head, on Dependabot's pull requests"]
    matrix --> docs
    docs["generate-docs: terraform-docs"] --> validate["validate: init, fmt, validate, lint"]
    docs --> tests
    tests --> summary["terraform-test-summary: tests head, step summary"]
    matrix --> summary
    docs --> summary
    validate --> summary
    docs --> conclusion["conclusion: the required check"]
    validate --> conclusion
    tests --> conclusion
    matrix --> conclusion
    conclusion --> automerge["automerge: a listed bot's pull request, merged by the CI App"]
    conclusion --> runsummary["run-summary: one block for the run"]
    automerge --> runsummary
```

| Job | Check name | What it does |
|---|---|---|
| `create-matrix` | `Create test matrix` | Runs `create-tf-vars-matrix` with `mode: module`, which also judges the Dependabot admission and auto-merge; uploads `relevance` (the decision, for the summary). |
| `seed-pr-comments` | `Seed PR comment heads` | The project workflow's seed job, step for step (F20), on a pull request Dependabot opened: posts the admission head of a refused one and deletes it on a later run that is not refused ([Dependabot-admission.md](Dependabot-admission.md) D21). |
| `generate-docs` | `Update documentation` | After `create-matrix`, whatever its result. terraform-docs on the README and the examples; on a pull request it commits a regenerated README with the App token, which starts a new run, on Dependabot's only when the admission admitted the run and only on top of the commit the run evaluated (D22); elsewhere a README that needs regenerating fails it. |
| `validate` | `Validate module` | Init in the module root (a plain `terraform init`, not `-backend=false`; the test jobs' init passes `backend: false`), fmt, validate, TFLint, the init and validate warnings, the validation head and its step summary, then the gates. Skipped when the docs job pushed a commit: the run the push starts validates. On a Dependabot run it also waits for `create-matrix` and is skipped when that failed or the admission refused the pull request ([Dependabot-admission.md](Dependabot-admission.md) D16). |
| `terraform-test` | `Terraform test (<file>)` | The project workflow's test job, step for step (F20); it waits for the docs job and skips when that pushed a commit. |
| `terraform-test-summary` | `Terraform tests summary` | The project workflow's summary job, step for step, while the stage is on: on every event with test files, and on a pull request. It waits for validation, so the validation head is posted first, and skips when the docs job pushed. |
| `conclusion` | `Terraform conclusion` | §8. The only check a caller requires. |
| `run-summary` | `Run summary` | On every run, after everything else: one block for the whole run on the run page (§7.1). Never in the conclusion's needs. |
| `automerge` | `PR auto merger` | After a green conclusion, on a pull request the engine ruled eligible and the docs job pushed nothing to: confirms the run is the CI App's where docs commits are at the head, and merges with the App's token, pinned to the evaluated head and base ([Module-auto-merge.md §6](Module-auto-merge.md)). |

The test jobs do not wait for validation: they install their own providers, and a failing test is
worth seeing next to a failing lint. They do wait for the docs job, as validation does: a docs
commit starts a run of its own, and this run's tree is superseded.

## 5. The engine's module mode

`create-matrix --mode module` (the action input `mode: module`) builds the input document without
`environments-yml`: no environments, no changed files, the test facts only (committed test files,
directories with `.tf` files; no locks, since a module commits none). The document carries
`"mode": "module"`, and `decide` then:

1. validates the test stage's inputs and lanes with the project mode's rules;
2. refuses an event other than the four of D3, as the project mode does;
3. decides the test stage on `pull_request`, `push`, `workflow_dispatch` and `schedule`, with no
   provider sets: every test root floats its providers;
4. with `terraform-test-required` true and the stage run, sets the tests block's `missing` when no
   test file runs or is held back from a fork (a misplaced or excluded file counts as none), with
   a warning naming the fix; the adapter publishes it as `tests-required-missing` (§8);
5. judges the Dependabot admission ([Dependabot-admission.md §11](Dependabot-admission.md)) and
   auto-merge ([Module-auto-merge.md §3](Module-auto-merge.md)), over the facts the adapter
   gathered for them;
6. decides whether the change is relevant to the module (§5.1), and holds every test file back
   when it is not.

The output carries `tests`, `notices`, `warnings`, `trigger`, `admission`, `automerge`,
`comments` and a record of one line per test file (`tests/unit-tests.tftest.hcl: run, lane unit`
or `…: not run, misplaced`). The adapter publishes `tests-matrix-json`, `tests-count`,
`tests-active`, `tests-required-missing`, the admission's `admission-refused`, `admission-reason`
and `admission-admitted`, auto-merge's `automerge-eligible` and `automerge-confirm-app`, and
`relevance-file`; the file holds the output without matrices, as in the project mode, so
`create-test-summary` reads its not-run rows from the same place.

### 5.1 Path relevance

On a `pull_request` or a `push`, with `path-relevance-enabled` on, the adapter fetches the changed
files as the project mode does (the pull request's files; a push's compare), and the engine rules
on one unit, the module:

- **Affected** when a changed file matches none of `paths-ignore-yml`, by default `["**/*.md"]`:
  every run as before.
- **Not affected** when every changed file is ignored: every test file is held back with the
  reason `relevance: not affected`, so no test job runs and none is missing; `affected-count` is
  `0`. The validate job is skipped on it. The docs job runs as always: a README-only pull request
  still gets its README checked, or regenerated and committed.
- **Run everything** (mode `all`) where the project mode fails open (Path-relevance.md §4.2): the
  switch off, a dispatch or a schedule, a forced or deleting push, a pull request whose head moved,
  more files than the API lists, a failed request, or a change under `.github/workflows/`.

The relevance is the pull request's, not the commit's: a pull request that changes a `.tf` file
anywhere is affected on every run. The input `paths-ignore-yml` is validated as an environment's
`paths-ignore` is (a list of globs; `auto` has no meaning here). The adapter publishes
`relevance-mode`, `relevance-reason`, `changed-count`, `affected-count` and `unaffected-count`
(`1` and `0`, or `0` and `1`), and a notice says the verdict, for example `relevance diff (diff):
the module is not affected: every changed file is ignored (**/*.md); nothing to validate or test`.

Auto-merge counts validation skipped this way as passed ([Module-auto-merge.md](Module-auto-merge.md)
M8): a release pull request changes only `CHANGELOG.md`, which nothing validates.

## 6. Credentials

| Case | Configuration |
|---|---|
| None | No lanes. Every file runs without credentials: unit tests with `mock_provider`. |
| One, from repository secrets (the v0 shape) | One fallback lane mapping the secrets the repository already has: |

```yaml
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

| Case | Configuration |
|---|---|
| One, isolated (recommended) | The same lane with `github-environment: auto` instead of the mappings; the environment holds the `ARM_*` secrets and the identity trusts `repo:<owner>/<repo>:environment:tftest-<lane>` only. |
| Unit without, integration with | Two lanes: `unit` matching `**/unit-*.tftest.hcl` with nothing, `integration` with a credential. |
| Several | One lane per identity, each matching its files. |

Lanes are the project workflow's, key for key ([Terraform-tests.md §3.2, §3.6](Terraform-tests.md)).

## 7. Reporting

| Surface | Pull request | Push, dispatch, schedule |
|---|---|---|
| Validation head `<!-- tf:head:module -->` | `create-validation-summary` with `subject: module`: the title "Terraform validation summary for module: `<repository>`", init, fmt, validate, lint and the warnings count; no lock and no plan rows (`absent`) | — |
| Tests head `<!-- tf:head:tests:<caller> -->` | `create-test-summary`, one comment for every file | — |
| Legacy `<!-- tf:head:test:<file> -->` comments | deleted by the validate job | — |
| Step summaries | validation block, each test job's block, the tests block, and the run summary, whose headline is the conclusion (§7.1) | the same |
| Annotations | one per failed gate, the tests headline, the conclusion | the same |

The docs job writes one line to its step summary: regenerated and pushed, up to date, needs
regenerating, or failed.

### 7.1 The run summary

The `run-summary` job runs on every event, after the conclusion and auto-merge, and never fails.
`create-run-summary` with `mode: module` reads `relevance.json` and one JSON object of the run's
results, which the job builds from its `needs`: the conclusion's result and line, the docs job's
result and status, the validate job's result and its four steps' outcomes and warnings count, the
tests summary job's result and counts, and the auto-merge job's result. It writes:

- a headline: the conclusion's verdict and why, for example `❌ Module CI: red — validation's
  result is failure`;
- the relevance line (§5.1);
- a table with one row each for the docs, validation (the steps that failed, or that all passed,
  and the warnings; or why it was skipped) and the tests (passed, failed, tolerated, not run, or
  held back);
- when the admission refused the pull request, the admission's section, as in the project
  workflow (Dependabot-admission.md §7);
- when auto-merge applies, its verdict, and whether the pull request was merged.

The validate job and the tests summary job publish what it reads as job outputs; the tests summary
job's outputs are on both workflows' copy of the job, which F20 holds equal.

## 8. The conclusion

Judges named results and the engine's outputs, like the project workflow's
([Path-relevance.md §7](Path-relevance.md)):

| Condition | Verdict |
|---|---|
| `create-matrix` not successful | red: the matrix could not be built |
| docs job not successful | red |
| docs job pushed a commit (validation skipped on purpose) | green: the run the push started decides |
| the module is not affected (§5.1) | green: nothing to validate or test |
| validation not successful, docs not pushed | red |
| tests required, stage on, no test file | red: a module needs at least one test file |
| tests active and the test jobs not successful | red |
| tests inactive and the test jobs skipped | fine |

One line, for example `conclusion: green — validation succeeded; tests: 4`, to the log and a
`::notice` or `::error`, and as the job output `line`, which the run summary's headline shows. The
conclusion writes no summary block of its own: on the run page the run summary is the answer, and
the jobs' blocks below it are the detail (§7.1).

## 9. Moving a module repository from v0

The user guide, [Workflow-terraform-module-ci.md](Workflow-terraform-module-ci.md), has the calling workflow and the lanes. In short: `@v1`; Terraform 1.13 or later;
`actions: read`; the calling workflow's `env:` block becomes a lane (§6); a repository without
tests adds a unit suite or sets `terraform-test-required: false` for the move.

## 10. Pitfalls

| # | Pitfall | Consequence | Rule |
|---|---|---|---|
| P1 | The calling workflow's `env:` block kept | Nothing: a caller's workflow-level `env` never reaches a called workflow. Tests without a lane have no credentials. | Replace it with a lane (§6). |
| P2 | A unit test without `mock_provider` in a lane without credentials | The provider fails to configure. | Mock the provider, or give the lane the credential. |
| P3 | Two module test jobs of two pull requests on one integration file | They create the same fixed-name objects. | The per-file concurrency group of the test job, `queue: max`. |
| P4 | A docs commit pushed with `GITHUB_TOKEN` | No new run starts, and the required check stays on the old commit. | The App token (D7). |
| P5 | The plugin cache restored where no CLI config points at it | Never read, and a miss fails init. | The test jobs set their cache up themselves, as in the project workflow; validation keeps its own. |
| P6 | A README out of date on a fork's pull request, a push, a dispatch or a schedule | The docs check fails: only a pull request from the repository gets a docs commit. | Regenerate with terraform-docs 0.20 (the pinned action's), or let a pull request regenerate it. |
| P7 | `.tflint.hcl` matched by the template's `.gitignore` (`**/.tflint.hcl`) | A copy that is not force-added is never committed, and lint fails: "could not find a TFLint config file". | The template keeps it force-added; a repository keeps it that way. |
| P8 | The default terraform-docs config injected in check mode | Upstream stages the whole directory and counts every staged file, so the injected file would read as drift. | The injected config is listed in `.git/info/exclude`; with push it is committed as before. |
| P9 | A repository without access to the App's organisation variable or secret | The expression reads empty and the token action fails with "The 'client-id' (or deprecated 'app-id') input must be set to a non-empty string", which names neither the variable nor where to grant it. | A check before the token step names each one missing; a failed token is explained after it as the installation or the key (§3.2, F24). |
| P10 | A pull request that was affected and is no longer (its last non-Markdown change reverted). | Its validation head stays from the earlier run, while the conclusion says not affected. | Accepted: relevance is the pull request's, so this needs a revert inside one pull request; the run summary and the conclusion say the current verdict. |
| P11 | A module that reads a Markdown file through `file()` or `templatefile()`. | A change to that file changes the module, but is ignored by default. | Such a module sets `paths-ignore-yml: "[]"` (Workflow-terraform-module-ci.md). |

## 11. Tests

- Engine: module mode for every event, the required finding, lanes and exclusions without
  environments, the record, the published outputs; the module's relevance (a Markdown-only change,
  one file that is not ignored, the ignore list replaced and empty, every fail-open reason, invalid
  inputs, no test file missed, the admission first); under both gates.
- F20: `terraform-test` and `terraform-test-summary` of the two workflows have the same steps, the
  same name, runner, timeout, permissions, environment, strategy and concurrency; they differ only
  in `needs` and `if`: the module jobs wait for the docs job (the summary for validation too) and
  skip after a docs push, and the module summary runs on every event with test files.
- F21: the module conclusion's needs, named results and lines; F9, F16 and F19 already cover the
  module workflows.
- F24: in both module workflows the App check runs under the token step's condition, the token
  step continues on error and the explaining step follows it; the check's own run block is run for
  every combination of a missing variable and secret.
- F26: the docs job's token on Dependabot's pull request only in an admitted run, and its pin; F27:
  the auto-merge job's inputs, needs, condition, permissions, steps and App confirmation; F28: the
  relevance inputs and outputs, validation skipped when not affected, the conclusion's run block
  for a change that does not affect the module, the tests summary's counts in both workflows, and
  the run summary job.
- `create-run-summary`: module mode byte for byte, not affected, a refused admission, a docs push,
  nothing readable, a project decision, and results larger than one environment string.
- `terraform-docs`: a suite for the converted steps (a push with `push: true` only, fail on a diff
  otherwise, the counts); the workflow passes `push: true` on a pull request from the repository
  alone.
- The test bed: no test file, a unit suite only, the one-credential lane, an environment lane with
  OIDC, a docs change on a pull request, a dispatch.

## 12. Where each piece lives

| Piece | Where |
|---|---|
| Module mode | `engine/dsb_tf_engine/decide.py`, `tests.py`, `adapter.py`, `__main__.py` |
| The action input | `create-tf-vars-matrix/action.yml` (`mode`) |
| The module head | `create-validation-summary/` (`subject`, the `absent` status) |
| Docs | `terraform-docs/` |
| The workflows | `.github/workflows/terraform-module-ci.yaml`, `terraform-module-release.yaml` |
| Auto-merge | `engine/dsb_tf_engine/automerge.py` (the rule), `automerge_facts.py` (the commits) |
| Path relevance | `engine/dsb_tf_engine/relevance.py` (`decide_module_relevance`) |
| The run summary | `create-run-summary/` (`mode: module`) |
| Parity, conclusion and wiring tests | `evaluate-automerge-eligibility/run_all_tests.sh` (F20, F21, F24, F26, F27, F28) |

## 13. Open questions

None. Schedules run a module's tests too (D3), which the engine's tests cover. GitHub runs a
schedule only from the default branch, which the test bed's module branch is not.

## 14. What implementation taught the spec

- **A suite must hand over a large value as the shim does.** The run summary's module-mode test of
  results larger than one environment string first failed with "Argument list too long" in the
  harness's own `dirname`: `MODULE_RESULTS=… run_step` exports the value to every fork of the
  function. The shim captures it as a shell-local, and so does the test now.

- **The test bed ran the rest through the workflow at the preview ref**, on a module-shaped branch
  of the project test bed made from the module template:
  - a push: the unit suite ran without credentials and the integration test as the lane
    identity, through its GitHub Environment and OIDC;
  - a README that needed regenerating failed the docs check with its step-summary line, and the
    conclusion named it;
  - with the README current, every job and the conclusion were green (`conclusion: green —
    validation succeeded; tests: 2`);
  - a dispatch ran the tests;
  - a branch without test files was red with the warning and `a module needs at least one test
    file`, and green with `terraform-test-required: false`;
  - a pull request whose README needed regenerating got the docs commit through the App. The run
    skipped validation and the tests and concluded green ("the run it started decides"), and the
    run the push started was green with three test files, one of them creating a user-assigned
    identity in a sandbox resource group and destroying it again;
  - that run posted the validation head and the tests head, and deleted a planted v0 per-file
    comment;
  - an unused variable failed TFLint, which the head, an annotation and the conclusion named.
- **A missing App variable named nothing.** The first run of a repository made from the module
  template, whose access to the organisation's variable was not yet granted, failed the docs job
  with the token action's "client-id must be set"; hence the check before the token step (P9).
- **The tests summary must not run after a docs push.** On the first pull-request round it did:
  it reported every skipped file as leaving no metadata, in a head created before the validation
  head. The module summary job now waits for validation and skips after a docs push; the second
  round's first run skipped it, and the validation head came first.
- **The first mutation run of the module mode** found the adapter's string defaults and one
  conditional redundant; the adapter takes a boolean, and `--mode` is required.
