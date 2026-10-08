# Drift detection

Authoritative spec for drift detection with
[`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml): a scheduled plan
of each environment that tells infrastructure changed outside Terraform apart from a default branch
that is not applied, marks either on the run, and, through [Notifications.md](Notifications.md),
reaches the environment's Teams channel once per change rather than once per night.

Status: **the scheduled plan** ([Dispatch-and-triggers.md](Dispatch-and-triggers.md) §4.4), **the
stopgap (§3) and the classification (§4) are built; the kinds and transitions (§4, §5) are specified,
not built.** The open questions are in §9; §11 records what building changed.

## 1. Why

Drift is found late. Changes made by hand in a portal or a CLI surface when an unrelated change
plans them away, sometimes years later and in the middle of something else. A plan with changes and
no code change has been seen running for months before anyone looked at it.

A failed apply on the default branch is the other case: an unrelated push does not retry it
([Path-relevance.md](Path-relevance.md) P16), so the default branch stays unapplied until somebody
notices.

Both show up in a plan of the default branch. Since v1.1.0 a scheduled run plans and stops unless an
environment's `schedule-goal` says otherwise, so a nightly drift check is one `trigger-events` entry.
What is missing is reading the plan: a scheduled plan with changes is green today, and its counts are
only in the run summary.

## 2. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | The check is the scheduled plan that already exists: `schedule` in an environment's `trigger-events`, `schedule-goal` absent or `plan`, and a cron in the caller's `on:`. Nothing new to configure. Everything here applies to scheduled runs whose `goals-granted` hold no `apply`. | The plan runs as the environment, in its GitHub Environment and concurrency group, so it waits for a running apply instead of racing it for the state lock. A scheduled reconcile applies what it finds; its failures are [Notifications.md](Notifications.md) §4's. |
| D2 | **A stopgap first:** a scheduled plan with changes, or one whose changes cannot be read, is marked with a warning annotation and ⚠ in the run summary. The run stays green. | Visible at once, with nothing to configure and nothing to deploy. Red would mean "the pipeline failed", and a check that is red every night teaches people to ignore red. |
| D3 | The plan is classified from the JSON plan, inside the environment job: **drift** when an address in `resource_drift` also has a planned action in `resource_changes` (anything but `no-op` and `read`): something changed outside Terraform that the next apply would revert. Otherwise **pending** when the plan has changes as `parse-terraform-plan` counts them (`count-total` above zero, or output-only changes). Otherwise **clean**. The exit code plays no part. | Drift that changes no planned action (attributes under `ignore_changes`, values a provider normalises) is noise for this purpose; intersecting with the planned actions leaves exactly what Terraform would undo, without heuristics. Exit code 2 also means output-only changes and unapplied `moved` and `import` blocks, and has meant "no changes" in several Terraform releases (P1). |
| D4 | A **fingerprint** of the finding: SHA-256 over the sorted lines `<address> <actions>` for every resource change but `no-op` and `read`, `<address> moved-from <previous_address>` and `<address> importing` for moves and imports, `output <name> <action>` for changed outputs, and `<address> drifted` for the drift of D3. | Equal fingerprints mean the same finding, so the same finding is never sent twice; an unrelated `no-op` resource does not change it. |
| D5 | Notify on **transitions**: a new finding, a changed finding, a resolved finding. Reminders follow [Notifications.md](Notifications.md) §10 and are not transitions. | The approach of the tools that keep state (HCP Terraform, Terramate, tfaction); the ones without post every night and are muted. |
| D6 | A failed scheduled plan-only run (login, init, plan) is `scheduled-failed`, raised on the **second** failed run in a row and resolved by the next successful plan. A plan that ran but whose changes cannot be read is not a finding: three in a row are `drift-check-failing`. | A broken check must not look like "no drift", and one transient error must not page anyone. |
| D7 | **pending** is the `pending-change` kind in the environment's `apply` slot ([Notifications.md](Notifications.md) §4): an apply incident already open there takes the finding as its reminder's evidence; a `pending-change` incident open there becomes `apply-failed` if a later push fails to apply. | It is one fact, the default branch not applied, seen from two runs; one slot keeps it to one thread. |
| D8 | No refresh-only plan. | It also reports attributes `ignore_changes` covers, which the configuration deliberately ignores, and needs a second plan per environment. |
| D9 | Drift runs with the environment's apply identity. | Decided by the maintainer; the engine's schedule cap keeps it a plan ([Dispatch-and-triggers.md](Dispatch-and-triggers.md) §4.4, D12; [Decision-engine.md](Decision-engine.md) I25). |
| D10 | The JSON plan never leaves the environment job. Only the classification, counts, the fingerprint and a capped list of addresses do. | The JSON plan holds sensitive values in plain text ([`terraform-plan`](../terraform-plan/step_plan_json.sh)). |

## 3. The stopgap

On a scheduled run whose `goals-granted` hold no `apply`, when the environment's plan step succeeded
and the plan has changes (`parse-plan`'s `count-total` above zero, or `has-output-only-changes`
true), the run says so in two places and stays green.

[`annotate-terraform-outcome`](../annotate-terraform-outcome/action.yml), which also annotates applies
and destroys, emits one warning per environment, naming the non-zero counts only:

```text
::warning title=Plan has changes::prod — the scheduled plan has 3 changes (2 to add, 1 to change): drift, or a default branch that is not applied
::warning title=Plan has changes::prod — the scheduled plan changes only outputs: drift, or a default branch that is not applied
::warning title=Plan not read::prod — the scheduled plan's changes could not be read; see the plan in the job log
```

The last is for counts that cannot be read (`plan-complete` is `?`); `false`, a targeted or deferred
plan, has valid counts. The workflow hands the action the event, whether `apply` was granted
(`contains(matrix.vars.goals-granted, 'apply')`), the plan's outcome and `parse-plan`'s counts.

[`create-run-summary`](../create-run-summary/action.yml) reads the same facts from each environment's
metadata, puts ⚠️ in front of that environment's plan cell, and names the environments under the
table:

```text
⚠️ **The scheduled plan has changes:** `prod`, `staging`. Drift, or a default branch that is not applied.
⚠️ **The scheduled plan could not be read:** `test`. See the plan in the job log.
```

The "Worst outcome" cell stays as it is: nothing failed. A pull request, a push, a dispatch and a
scheduled reconcile render exactly as before. No workflow input, no workflow output and no
conclusion changes.

With the classification of §4, both say which. The workflow hands the annotation
`parse-terraform-plan`'s `plan-class`, `count-drift` and `has-pending-changes`; the run summary
reads them from the metadata:

```text
::warning title=Drift::prod — the scheduled plan finds 2 resources changed outside Terraform, which the next apply would change back
::warning title=Drift::prod — the scheduled plan finds 1 resource changed outside Terraform, which the next apply would change back, and has changes of its own: the default branch is not applied
::warning title=Default branch not applied::prod — the scheduled plan has 3 changes (2 to add, 1 to change): the default branch is not applied
```

```text
⚠️ **Drift:** `prod`. Changed outside Terraform; the next apply would change it back.
⚠️ **The default branch is not applied:** `staging`. The scheduled plan has changes.
ℹ️ **Drift the plan leaves alone:** `dev` (2). Nothing the next apply would change back, so not a finding.
```

Drift beside changes of its own is in both lines, and its plan cell's marker says both. The last
line names `count-drift-ignored`, which is never a finding. A plan whose counts stand but that
cannot be classified (`plan-class` `unknown` or empty), and a drift count that is not a number, keep
the wording above.

## 4. Classification

[`parse-terraform-plan`](../parse-terraform-plan/action.yml) classifies the JSON plan it counts:

| Output | Meaning |
|---|---|
| `plan-class` | `drift`, `pending` or `clean` (D3); `unknown` when the counts are `?` or the plan cannot be classified (a `resource_drift` that is not a list); empty when the counts come from the console, which cannot tell drift from a change |
| `count-drift` | managed addresses that are drift by D3 |
| `count-drift-ignored` | the other managed entries of `resource_drift`, named in the run summary and never a finding |
| `has-pending-changes` | `true` when the plan has a change of its own besides reverting drift: a change, move or import of an address that did not drift, or, without drift, an output change. Reverting drift changes the outputs that read it, so beside drift an output change does not count. `true` for every `pending` plan, `false` for `clean`; for `drift` it tells drift alone from drift beside an unapplied change (§5) |
| `drift-addresses` | the drifted addresses, sorted, as a compact JSON list of as many as fit in 3000 bytes, under the metadata capture's 4 KiB per output; `count-drift` says how many there are in all |
| `plan-fingerprint` | D4: the SHA-256, in lowercase hex, of the sorted lines, each ending in a newline, the actions joined with `,`; empty for `clean` and `unknown` |

With `unknown`, the counts are `?` and the addresses and fingerprint empty. Nothing the
classification answers is taken on trust: a value of another shape is `unknown`, with a warning.

| Kind | Raised by a scheduled plan-only run when | Severity | Slot |
|---|---|---|---|
| `drift` | `plan-class` is `drift` | medium | `drift` |
| `pending-change` | `plan-class` is `pending` (D7) | medium | `apply` |
| `scheduled-failed` | a step of the environment job failed, the second run in a row | medium | `schedule` |
| `drift-check-failing` | `plan-class` was `unknown` three runs in a row | low | `schedule` |

## 5. Transitions

The decide job of [Notifications.md](Notifications.md) §8 keeps the state of its §9, per environment
and slot, with the last fingerprint and counts of consecutive failed and unreadable runs added.

| Slot | Last state | This scheduled run | Action |
|---|---|---|---|
| `drift` | none or resolved | drift, fingerprint F | a new message |
| `drift` | open with F | drift with F | nothing; reminders weekly, mentioning nobody |
| `drift` | open with F | drift with F′ | update the first message, reply "changed", remember F′ |
| `drift` | open | pending or clean | update the first message to resolved, reply "resolved" |
| `apply` | none or resolved | pending, fingerprint F | a new `pending-change` message |
| `apply` | open (any kind) | pending | nothing new; the reminders of [Notifications.md](Notifications.md) §10 carry it |
| `apply` | open (any kind) | drift or clean, with no changes of its own | resolved, as [Notifications.md](Notifications.md) §4 says for a clean plan |
| `schedule` | none or resolved | failed, the second in a row | a new `scheduled-failed` message |
| `schedule` | none or resolved | unknown, the third in a row | a new `drift-check-failing` message |
| `schedule` | open | a successful, readable plan | resolved |
| any | state lost | the finding again | a new message: a duplicate, never a missed finding |

A drift plan that also has changes of its own (drift and unapplied code together) keeps or opens the
`drift` incident and the `apply` incident. The message lists the class, the counts and up to twenty
drifted addresses, and links the run, whose summary has the plan.

## 6. Configuration

Nothing new. An environment opts into the nightly plan with `schedule` in its `trigger-events`;
the caller adds the cron, off the hour ([Workflow-terraform-ci-default.md](Workflow-terraform-ci-default.md),
example 6). The kinds route like any other ([Notifications.md](Notifications.md) §6.2). An
environment that is never applied from CI is `pending` by design and may set
`kinds: { pending-change: { off: true } }`.

## 7. Pitfalls

| # | Pitfall | Seen as | Answer |
|---|---|---|---|
| P1 | `terraform plan -detailed-exitcode` returns 2 for output-only changes, unapplied `moved` and `import` blocks, and in several releases for no change at all. | "Drift" every night that nobody can find. | D3: the JSON decides. |
| P2 | `resource_drift` lists changes to attributes the configuration ignores, and values a provider normalises. | A permanent drift finding nothing will ever change. | D3 counts only drift a planned action would revert. |
| P3 | GitHub delays scheduled runs at the top of the hour and drops some under load. | A missing night. | Cron off the hour; a missing run is absence, out of scope here ([Notifications.md](Notifications.md) §15). |
| P4 | A provider schema upgrade can show as drift. | A one-time finding after a provider bump. | Accepted: one message, resolved on the next apply. |

## 8. Tests

- **`parse-terraform-plan`:** recorded JSON plans (`plan_json_drift_deleted`,
  `plan_json_drift_with_own_changes`, `plan_json_pending_create`, `plan_json_moved_unapplied`,
  `plan_json_import_unapplied`, planned against a hand-written local state: a resource deleted
  outside Terraform, the same beside a resource of its own, a new resource, an unapplied `moved` and
  an unapplied `import`) and the earlier ones (no changes, output-only, every kind of change, an
  errored plan). Derived from them in one place: drift under `ignore_changes` (the planned action
  made `no-op`), an attribute changed and changed back, output changes beside drift, a data source in
  `resource_drift`, a plan without `resource_drift`, one where it is not a list, and 150 drifted
  addresses for the cap. The fingerprint is stable under reordering and under an unrelated `no-op`
  resource. A stub classification of every malformed shape is `unknown`.
- **`annotate-terraform-outcome` and `create-run-summary`:** the stopgap's annotation and marker on
  plan-only scheduled runs only, unchanged output on every other run (the existing exact-output
  assertions); with a class, drift, drift beside changes of its own, pending, clean, ignored drift,
  and a class that cannot be trusted, byte-exact.
- **Structural:** F30 holds the annotate step's wiring in the three stage jobs to the event, the
  granted goals, the plan's outcome and `parse-terraform-plan`'s outputs, the classification's
  included, each of which must exist.
- **Engine:** the transitions of §5 as table cases.
- **Test bed:** a scheduled plan with a resource changed by hand, then the same finding twice, then
  the change reverted; an attribute under `ignore_changes` changed by hand, which stays clean.
  For the classification, one scheduled run on a test-bed repository, on the pull request's preview
  ref, with three plan-only environments against a local backend: one whose committed, hand-written
  state holds a file the runner does not have warned `Drift` (1 resource) and carried the drift
  marker and line in the run summary; one with a resource to add and one with only an output change
  warned `Default branch not applied` and were named in that line. The transitions' runs wait for
  §10's third step.

## 9. Open questions

- Confirm D3 on attribute drift. The recorded plans confirm it for a resource deleted outside
  Terraform (`resource_drift` says `delete`, the plan says `create`); an attribute changed by hand,
  with and without `ignore_changes`, needs a plan against a provider that reads a real object, and
  the suite derives those two cases from the recorded plan meanwhile.

## 10. Implementation order

1. The stopgap (§3). Built.
2. The classification (§4), which sharpens the stopgap's wording. Built.
3. The kinds and transitions (§4, §5) with the state of [Notifications.md](Notifications.md) §9.

## 11. What implementation taught the spec

- The warning names only the non-zero counts. Six counts of which four are zero buried the one or
  two kinds of change a scheduled plan usually has.
- The warning follows the other annotations' shape, `<environment> — <what happened>`, and counts
  that cannot be read get a title of their own, `Plan not read`, so the two never read alike.
- The run summary needed no new input: the event and the granted goals are already in each
  environment's metadata (`workflow.event_name`, `matrix_context.vars.goals-granted`).
- §5 opens the `apply` incident beside the `drift` one when a drift plan has changes of its own,
  which none of the outputs first specified could tell: `has-pending-changes` says it.
- `drift-addresses` is a JSON list, which the decide job can read, and `count-drift` carries the
  number in all, instead of a capped text with "…and N more".
- The console says nothing about drift that the plan reverts by creating a resource again: Terraform's
  "Objects have changed outside of Terraform" note was absent from the recorded plan of a deleted
  resource. Only the JSON plan's `resource_drift` tells drift from a new resource.
