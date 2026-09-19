# Dispatch and trigger events

Authoritative spec for two related controls of
[`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml): running one
environment on demand with a chosen goal, and letting each environment say which events it takes
part in. Together they let a calling repository trigger its one workflow on every event and keep
the decisions inside.

Status: **specification, not yet implemented.** Both controls are rules of the
[decision engine](Decision-engine.md) and land after its port. §12 is reserved for what
implementation teaches the spec.

## 1. Why

Two needs from the developers of a calling repository.

**Recovering a single environment on demand.** Twice they have had to put a tenant back after a
bad apply. Manual dispatch is the right tool, but it runs every environment in the workflow, so
today the only way to reconcile one environment is a separate workflow file, and the only way to
choose a goal is to edit it.

**A schedule that means one environment, not all.** The shared workflow's apply stage accepts
`schedule`, so a nightly reconcile on the main workflow would apply production unattended. The
nightly therefore lives in its own file, a third copy of the inputs to keep in sync.

Both are the same gap: the caller cannot tell the workflow which environments an event or a
dispatch is for. Once it can, the extra workflow files go away, and the calling workflow can
trigger on everything and let the engine decide.

## 2. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Dispatch inputs are read from `github.event.inputs` inside the reusable workflow. The caller forwards nothing through `with:`. | The `github` context is the caller's event; the caller's only job is to declare the inputs. |
| D2 | One standard `workflow_dispatch.inputs` block, identical in every repository, shipped in the project template: `environment` (string), `goal` (choice), `reason` (string). | Copy-paste, never drifts when environments are added, validated against reality by the engine. |
| D3 | `environment` is a `string`, an exact environment name, or empty for every environment. | A `choice` would hold repository-specific names and drift. GitHub's `environment` input type was assessed and rejected: it lists GitHub Environments, which are `github-environment` names rather than `environment` names, includes the `tftest-*` lanes, is empty until a first run creates them, and cannot express "every environment". A caller may switch to either locally. |
| D4 | `goal` offers `default`, `plan`, `apply`, `destroy-plan`. The input can never add `destroy`. An environment whose own `goals-yml` holds `destroy` still destroys on a default-branch dispatch with `goal: default`, as it does today. | Destroying stays a `goals-yml` decision made in a reviewed commit; the dispatch button cannot introduce it. |
| D5 | The `goal` input is a **cap**: it only removes goals from what the environment's own `goals` would grant on a push to the same ref. `plan` and `destroy-plan` cap; `apply` requires the environment to hold `apply` or `all`. Asking for more is an error, not a silent downgrade. | A validate-only repository must not become an apply target through a dropdown, and a `plan` request must never be silently widened into a plan the environment does not have. |
| D6 | `apply` by dispatch runs on the default branch only, as apply always has. Asking for it elsewhere is an error, not a silent plan. | A person who asked for an apply and got a plan would not notice until the outage. |
| D7 | Per-environment `trigger-events`, with a global default input `trigger-events-yml` = `[pull_request, push, workflow_dispatch]`. **`schedule` is opt-in.** A run event outside the vocabulary is a validation error. | A survey of every calling repository found two that schedule the workflow, both deliberately, both on a dedicated environment. This is a default change and therefore part of the **v1** major release; the two callers opt in during their migration ([Migration-v1.md](Migration-v1.md)). |
| D8 | A dispatched environment is always relevant and always runs regardless of `paths`; relevance mode is `all` on dispatch, as the relevance spec says. | A dispatch is a person asking. |
| D9 | Tests do not run on `workflow_dispatch` (Terraform-tests.md D7). | A recovery must not start integration tests against the tenant being recovered. A later addition may add a `test-file` dispatch input. |
| D10 | The run records who dispatched what, with which goal and reason, in the run summary and a notice: both `github.actor` and `github.triggering_actor`, since a re-run keeps the original actor. | A dispatch that bypasses ordering (a later spec) must be visible. |
| D11 | Granted goals reach the workflow's operation gates through the engine's `goals-granted` row variable (Decision-engine.md D10); the gates keep their event and branch clauses as defence in depth. | Without it a `plan` cap could not stop an apply that `goals-yml` grants. |

## 3. Caller-facing API

### 3.1 The dispatch block

```yaml
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
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

The block is the same in every repository; nothing in it names an environment. A caller that
prefers a dropdown changes `environment` to `type: choice` with its own names and accepts the
upkeep. From the command line:

```bash
gh workflow run terraform-ci-cd.yml --ref main -f environment=staging -f goal=apply -f reason="rebuild after incident 42"
```

### 3.2 Trigger events

| Input or key | Type | Default | Meaning |
|---|---|---|---|
| `trigger-events-yml` (workflow input) | YAML list | `[pull_request, push, workflow_dispatch]` | Events on which an environment takes part unless it says otherwise. |
| `trigger-events` (per environment in `environments-yml`) | list | the global default | Replaces the global list for this environment. |

Valid values: `pull_request`, `push`, `workflow_dispatch`, `schedule`. Anything else is a
validation error.

```yaml
trigger-events-yml: |
  - pull_request
  - push
  - workflow_dispatch
environments-yml: |
  - environment: prod
  - environment: staging
    trigger-events: [pull_request, push, workflow_dispatch, schedule]   # nightly reconcile
```

with the calling workflow carrying `schedule: [{ cron: "0 2 * * *" }]` beside the other triggers.
The nightly file goes away; the schedule reconciles `staging` and touches nothing else.

### 3.3 What a caller does not do

The caller does not add `on.paths` (the relevance spec), does not split environments over files,
and does not forward dispatch inputs. Its trigger block is the four events it wants, with the
default pull-request types; the workflow's existing guards on `closed` and `converted_to_draft`
stay.

## 4. Semantics

### 4.1 Participation

An environment takes part in a run when every line holds:

1. the event is in its resolved `trigger-events`, and the event itself is one of the four the
   workflow supports (any other run event is a validation error);
2. on `workflow_dispatch` with a non-empty `environment` input, its name equals that input; a
   dispatch whose named environment then takes no part, because it matches nothing or because line
   1 dropped it, is an error, never a green empty run;
3. it is relevant to the change (the relevance spec), which on dispatch and schedule is always.

Secrets availability is not a participation rule for environments: a fork pull request's
environments run and fail on authentication, as today; the fork and Dependabot rules apply to test
rows (Terraform-tests.md §4.7). Each line is a rule of the decision engine with its own reason
(Decision-engine.md §6).

### 4.2 Goal resolution on dispatch

The engine first expands the environment's `goals` for the event, ref and branch exactly as the
workflow's gates do today, then applies the `goal` input as a cap:

| `goal` input | Granted goals |
|---|---|
| `default` or empty | Push semantics for the ref: apply on the default branch when the goals hold `apply` or `all`, **destroy on the default branch when the goals hold `destroy`** (as today), plan and destroy-plan elsewhere. |
| `plan` | The expansion intersected with `init, format, validate, lint, plan`. Never adds `plan` to an environment without it; removes `apply`, `destroy-plan` and `destroy`. |
| `apply` | As `default`, and an error unless the goals hold `apply` or `all` (`apply-on-pr` alone does not count) and the ref is the default branch (D5, D6). |
| `destroy-plan` | `init` and `destroy-plan`; never `destroy`. An error unless the goals hold `destroy-plan` or `destroy`; `all` is the standard goals only and does not include it. |

The `goal` input never grants `destroy`, `destroy-on-pr` or `apply-on-pr`. The engine's invariants
I1, I3, I15, I16 and I17 assert these rules on every generated case, and the operation gates read
`goals-granted` (D11).

### 4.3 Errors

A validation error stops the run in `create-matrix`, red conclusion, with one message:

| Situation | Message |
|---|---|
| `environment` names nothing in `environments-yml` | `dispatch: no environment named 'stagin'. Environments: prod, staging, sandbox` |
| `goal: apply` off the default branch | `dispatch: apply is only allowed from the default branch 'main'; this run is on 'feature/x'` |
| `goal: apply` for an environment without the goal | `dispatch: environment 'sandbox' does not hold the goal 'apply' (goals: init, format, validate, lint, plan)` |
| an unknown value in `trigger-events` | `environments-yml: environment 'prod': unknown trigger event 'merge'` |
| the named environment takes no part in dispatches | `dispatch: environment 'staging' does not take part in workflow_dispatch (trigger-events: pull_request, push)` |
| the run's event is outside the vocabulary | `event 'merge_group' is not supported by this workflow; supported: pull_request, push, workflow_dispatch, schedule` |
| a dispatch with no inputs block at all | not an error: every environment runs with `goals-yml`, and the run summary says the block is missing and where to copy it from |

### 4.4 Schedule

On `schedule` the engine keeps only environments whose `trigger-events` contain `schedule`. When
none does, the run does nothing, the conclusion is green, and a notice says so; the run summary
names the input that would change it. A scheduled run is always on the default branch, so a kept
environment gets push-on-default-branch semantics with one existing asymmetry the engine mirrors:
`apply` is granted on `schedule`, `destroy` is not (the workflow's destroy gate has never accepted
`schedule`); a scheduled environment holding `destroy` runs its destroy plan and stops there. The
two calling repositories that schedule the workflow today add the one line of §3.2 to the
environment their schedule was for as part of their move to v1 ([Migration-v1.md](Migration-v1.md)).

## 5. What the run shows

A dispatch or schedule has no pull request, so the surfaces are the run summary and annotations:

- `create-matrix` writes the decision record (Decision-engine.md §5): per environment, run or
  skip and why, and for a dispatch a first line `dispatched by <actor> (re-run by
  <triggering_actor>): environment <name>, goal <goal>, reason "<reason>"`, the parenthesis only
  when the two differ.
- A `::notice title=Terraform CI::` carries the same first line, so it shows in the checks pane.
- The environment jobs and the conclusion are unchanged; the conclusion's own summary line already
  counts what ran.

Concurrency is unchanged: a dispatched environment takes its usual per-environment group, so a
manual reconcile queues behind a merge apply of the same environment rather than racing it.

## 6. Examples

Configuration for all rows: `prod` with `goals-yml: [all, destroy-plan]`, `staging` with
`goals-yml: [all]` and `trigger-events: [pull_request, push, workflow_dispatch, schedule]`,
`sandbox` with `goals-yml: [init, format, validate, lint]`, `scratch` with
`goals-yml: [init, plan, apply, destroy-plan, destroy]`.

| Trigger | Inputs | Runs | Goals granted | Notes |
|---|---|---|---|---|
| dispatch on `main` | `environment: staging`, `goal: apply`, reason given | `staging` | init … plan, apply | the recovery case; prod untouched |
| dispatch on `main` | `environment: staging`, `goal: default` | `staging` | init … plan, apply | same as a push, one environment |
| dispatch on `main` | `environment: ""`, `goal: plan` | all four | prod, staging, scratch: init … plan; sandbox: its own four | a fleet-wide plan; the cap removes apply and destroy, never adds plan |
| dispatch on `feature/x` | `environment: staging`, `goal: apply` | none | error | D6 |
| dispatch on `main` | `environment: sandbox`, `goal: apply` | none | error | D5 |
| dispatch on `main` | `environment: prod`, `goal: destroy-plan` | `prod` | init, destroy-plan | read-only; `prod` holds `destroy-plan` explicitly, `all` alone would be an error |
| dispatch on `main` | `environment: scratch`, `goal: default` | `scratch` | init, plan, apply, destroy-plan, destroy | as today: `goals-yml` holds `destroy`, the input did not add it |
| dispatch on `main` | `environment: scratch`, `goal: destroy-plan` | `scratch` | init, destroy-plan | the cap removed apply and destroy |
| dispatch on `main` | `environment: prod`, but prod's `trigger-events` lack `workflow_dispatch` | none | error | §4.3, never a green empty run |
| dispatch, caller has no inputs block | none available | all four | `goals-yml` | as today, plus the summary note |
| schedule | none | `staging` | init … plan, apply | prod, sandbox and scratch do not opt in |
| schedule, `scratch` opted in | none | `staging`, `scratch` | scratch: init, plan, apply, destroy-plan | destroy is never granted on schedule (§4.4) |
| schedule, no environment opts in | none | none | none | green, notice |
| push to `main` | none | all four, subject to relevance | `goals-yml` | unchanged |

## 7. Interplay with other specs

| Concern | Relationship |
|---|---|
| Decision engine | Rules 2, 3 and 5 of its procedure and invariants I1, I2, I3, I15, I16 and I17 are this spec; `goals-granted` is how they reach the workflow. |
| Path relevance | Dispatch and schedule are relevance mode `all`; a dispatched environment is affected by definition. |
| Tests | Not run on dispatch (D9). `tests-active` is false; the conclusion treats that as benign. |
| Ordering between environments (later) | A dispatch naming one environment carries no dependencies and is that spec's bypass; D10's record is what makes the bypass visible. |
| Notifications (later) | A failed dispatched apply is a push-like failure; the record names the actor and reason. |

## 8. Pitfalls

| # | Pitfall | Consequence | Rule |
|---|---|---|---|
| P1 | Dispatch inputs arrive as strings; an absent block leaves `github.event.inputs` empty. | `"default"` versus empty, missing keys. | The shim normalises; the engine treats empty and `default` alike and an absent block as "no inputs". |
| P2 | A `choice` for `environment` would carry names per repository. | Drift when environments are added; a stale dropdown. | `string` by default (D3). |
| P3 | Silent downgrade of an impossible dispatch goal. | The operator believes an apply happened. | Errors, never downgrades (D5, D6). |
| P4 | `schedule` used to mean every environment. | The two scheduling callers' nightly runs would apply nothing after moving to v1 without the opt-in. | A v1 migration step ([Migration-v1.md](Migration-v1.md)); the empty-schedule notice says which key to set. Never shipped on a rolling major tag. |
| P8 | With no `inputs:` block the payload's `inputs` key is `null`; `github.event.inputs.environment` evaluates to the empty string. | A shim that expects an object fails, or reads `"null"`. | The shim normalises `null` to an empty object; the engine treats absent, empty and `default` alike. |
| P9 | A cap that silently adds. | `goal: plan` on a validate-only environment planning something nobody reviewed. | The cap intersects, never unions (D5); invariant I3. |
| P10 | A named dispatch that selects nothing. | A green run that did nothing while the operator believes the environment was reconciled. | An error (§4.3); invariant I17. |
| P5 | A dispatch from the CLI on a non-default `--ref` with `goal: apply`. | Refused. | The error names the branch; run it on `main`. |
| P6 | Two dispatches of the same environment overlap. | Queued, not raced, by the per-environment concurrency group; a third overlapping run cancels the pending one until `queue: max` lands. | Documented; the queue spec removes the cancel. |
| P7 | The `reason` input is free text and lands in the summary and a notice. | Anything typed there is on the run page. | Documented; nothing else is done with it. |

## 9. Tests

All in the decision engine's suite (Decision-engine.md §8):

- Table cases for every row of §6 and every error of §4.3.
- Generated cases across events × `trigger-events` × dispatch inputs × branch × goals, with
  invariants I1, I2, I3 and I5 asserted.
- The shim: dispatch inputs read from the `github` context and normalised; a run without the
  inputs block produces the informational summary line.

**What tests cannot cover**: that `github.event.inputs` is populated inside the reusable workflow
for a dispatch of the caller, and that `gh workflow run` on a non-default ref reaches the engine
with the right `ref_name`. Both verified on the test-bed and recorded in §12.

## 10. Open questions

1. **`github.event.inputs` inside a reusable workflow**: expected to be the caller's dispatch
   inputs; confirm on the test-bed, including the absent-block case.
2. **A later `test-file` dispatch input** for running one test file: not in this spec; the
   dispatch block gains a fourth input then, with the same copy-paste property.
3. **Whether the global `trigger-events-yml` should be able to include `schedule`**: allowed by
   this spec; a repository whose every environment reconciles nightly sets it once. Confirm this is
   wanted rather than forcing the opt-in per environment.
4. **`github.actor` on `schedule`** is undocumented; the record line prints what the context
   gives. Confirm on the test-bed.
5. **Callers whose existing dispatch block already has an input named `environment` or `goal`**
   for another purpose would start being filtered; the migration guide asks each caller to check.

## 11. Implementation order

1. `docs:` this spec.
2. After the engine's port: `feat(engine):` trigger-events and dispatch rules, cases, invariants.
3. `feat(create-tf-vars-matrix):` the shim reads dispatch inputs and event facts; the workflow's
   `create-matrix` job writes the record and notice.
4. `docs:` user guide (the dispatch block, `trigger-events`, the examples of §6, the schedule
   migration), the project template's `validate.yml` gains the dispatch block, release note.
5. Test-bed run: the dispatch rows of §6 and the schedule rows; findings into §12.

AI-assistant configuration files are never in these commits.

## 12. What implementation taught the spec

Reserved.
