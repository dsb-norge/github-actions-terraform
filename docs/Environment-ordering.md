# Ordering between environments

Authoritative spec for making one environment apply before another in
[`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml): a test tenant
before production, a shared landing zone before what sits on it. An environment declares what it
follows, the [decision engine](Decision-engine.md) compiles those declarations into stages, and the
workflow runs the stages in sequence.

Status: **specification, not yet implemented.** Decisions in §2 are settled; the mechanics in §4
were verified on a test-bed repository during design and are marked as observed where GitHub does
not document them. §14 is reserved for what implementation teaches the spec.

Related: [Decision-engine.md](Decision-engine.md) assigns the stages;
[Path-relevance.md](Path-relevance.md) decides which environments are in the run at all;
[Dispatch-and-triggers.md](Dispatch-and-triggers.md) provides the bypass; [Road-to-v1.md](Road-to-v1.md)
places this in the release.

## 1. Why

A calling repository manages two tenants: a test tenant and production. A change to shared code
should reach the test tenant first, and production should wait for it to succeed. Today every
environment is a leg of one flat matrix, so they apply in parallel and nothing can express that.

Three things make the requirement narrower than "always deploy in order", and the design follows
all three:

- **Conditional.** Gating every production change on a test tenant is wrong. Most production
  changes are configuration the test tenant says nothing about; the gate is worth having for
  changes to shared code. Path relevance already decides that: a change to production's own
  directory leaves the test tenant out of the run entirely, and a dependency that is not in the
  run is satisfied trivially.
- **Bypassable.** A disposable sandbox must never hold production hostage. Dispatching a single
  environment carries no dependencies, and the run records that ordering was bypassed.
- **Not a health gate.** `depends-on` orders environments *within one run*. It cannot know whether
  the dependency's last apply, in some earlier run, succeeded. §8 states that as an anti-goal
  because the name invites the opposite reading.

## 2. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | An environment declares `depends-on: [<environment>]`; the engine compiles the declarations into stages and validates names, cycles and depth. | Natural to author and checkable. The delivered guarantee is coarser than the declaration reads (D2, §4.4), so the spec, the user guide and the run summary all state what a stage actually waits for, and the run summary prints the computed stages. |
| D2 | A stage waits for **every** environment in the stage before it, not only for the ones a member declared. | A matrix job has one result and GitHub has no per-leg `needs`. This is inherent to the design, not an artefact of this implementation. |
| D3 | An environment with no dependencies and no dependents joins the **last stage in use**. | Its failure can then hold nothing back, which matters because free-standing environments are usually the experimental ones. It waits behind the chain, which costs time on a mutating run and never correctness. |
| D4 | Stages apply on any run where some environment is granted `apply` or `destroy`; otherwise every environment is stage 1. | Keying on the event would exempt callers who apply on pull requests through `apply-on-pr`, which is exactly the throwaway-environment pattern that wants ordering. For a plan-only pull request the two rules are identical. |
| D5 | A **tolerated** failure releases the next stage. | `allow-failing-terraform-operations` makes the job green, and every other consumer already reads it that way. At job level the difference is invisible, so holding back would need a metadata-inspecting gate job between every pair of stages. An environment others depend on should not carry the flag, and the run summary says when one did. |
| D6 | The stage cap is **3**, enforced against the **declared** graph. A deeper chain is a validation error naming it. | Hub-and-spoke is depth 2 and three tiers is depth 3; deeper coupling in practice crosses repositories, which this workflow cannot sequence anyway. Validating the declared graph keeps a configuration's validity independent of which files a change touched. Raising the cap later is one job block and a constant, and moves no existing configuration. |
| D7 | Every stage job keeps `name: "Terraform"`. | Any other name breaks or silently corrupts the aggregator's job-link lookup, and would change the check-run names every caller sees. With identical names, callers observe no change at all. |
| D8 | `depends-on` is **opt-in**. Absent, every environment is stage 1 and the workflow behaves as before. | Nothing breaks for a caller that does nothing, so v1 gains no breaking-change row for this feature. |
| D9 | Ordering is **intra-run only** and never inspects a dependency's earlier runs. | Stated as an anti-goal (§8) because `depends-on` reads like a health gate. |

## 3. Caller-facing API

### 3.1 The key

| Key | Type | Default | Meaning |
|---|---|---|---|
| `depends-on` | list of environment names, per environment in `environments-yml` | `[]` | This environment runs in a later stage than every environment named here. |

```yaml
environments-yml: |
  - environment: shared
  - environment: prod
    depends-on: [shared]
  - environment: sandbox
```

Compiled: stage 1 holds `shared`; stage 2 holds `prod` and, by D3, `sandbox`. The run summary
prints exactly that, so nobody has to derive it from the configuration.

There is no workflow-level input. Ordering is a property of the environments, and a caller that
wants none writes none.

### 3.2 What a caller should and should not use it for

Declare `depends-on` where an apply genuinely must follow another apply: shared code validated in a
test tenant before production, a landing zone before what sits on it. Do not use it to express
reading order or preference; every dependency costs wall-clock time on mutating runs and widens
the blast radius of a failure.

An environment that others depend on should not carry `allow-failing-terraform-operations: true`
(D5). The user guide says so next to both keys.

## 4. Semantics

### 4.1 Stage assignment

The engine validates the **declared** graph first: every name in a `depends-on` must be a declared
environment, the graph must be acyclic, no environment may name itself, and the longest path must
fit the cap (D6). Any failure is a validation error that stops the run before anything else is
decided.

It then assigns stages over the environments that survived relevance, triggers and the dispatch
filter, in this order:

1. Every environment whose `depends-on`, restricted to the run, is empty gets stage 1.
2. Every other environment gets one more than the highest stage among its dependencies in the run.
3. The last stage in use is the highest stage assigned by steps 1 and 2. Every environment with
   neither dependencies nor dependents among the declared environments is moved to that stage (D3).
4. When no environment in the run is granted `apply` or `destroy`, every environment is stage 1
   (D4). The same applies to a dispatch naming a single environment (§6).

Because the assignment is over the run set, a dependency that relevance dropped simply is not
there: a change touching only production's directory leaves the test tenant out, production's
dependency list restricted to the run is empty, and production applies immediately in stage 1. That
is the conditionality the need asked for, and it costs no extra machinery.

### 4.2 Running the stages

Three stage jobs, chained. They share one step list through a YAML anchor, which GitHub supports in
workflow files and which was verified to work for a whole step list across matrix jobs in a
remotely-referenced reusable workflow. The anchor carries only the step list: `runs-on`,
`environment`, `concurrency`, `permissions`, `strategy` and `outputs` are written per stage job.

```yaml
terraform-ci-cd:            # stage 1, keeps today's job id
  name: "Terraform"
  needs: [create-matrix, seed-pr-comments]
  if: |
    !cancelled()
    && needs.create-matrix.result == 'success'
    && (needs.seed-pr-comments.result == 'success' || needs.seed-pr-comments.result == 'skipped')
    && needs.create-matrix.outputs.stage-1-count != '0'
  strategy:
    fail-fast: false
    matrix: ${{ fromJSON(needs.create-matrix.outputs.matrix-stage-1-json) }}
  steps: &environment-steps
    # the ~50 steps, unchanged

terraform-ci-cd-2:          # stage 2
  name: "Terraform"
  needs: [create-matrix, seed-pr-comments, terraform-ci-cd]
  if: |
    !cancelled()
    && needs.create-matrix.result == 'success'
    && (needs.seed-pr-comments.result == 'success' || needs.seed-pr-comments.result == 'skipped')
    && (needs.terraform-ci-cd.result == 'success' || needs.terraform-ci-cd.result == 'skipped')
    && needs.create-matrix.outputs.stage-2-count != '0'
  strategy:
    fail-fast: false
    matrix: ${{ fromJSON(needs.create-matrix.outputs.matrix-stage-2-json) }}
  steps: *environment-steps

terraform-ci-cd-3:          # stage 3, same shape, needs both predecessors
```

Four properties of that guard, each load-bearing:

- **`!cancelled()` must be present.** A condition built only from `needs.*.result` comparisons
  contains no status-check function, so GitHub prepends an implicit success check and the job is
  skipped even when the comparisons are true.
- **`!failure()` must not be used.** It is transitive over every ancestor, so a failed
  `seed-pr-comments`, which the environment job deliberately tolerates today, would hold back every
  stage.
- **A predecessor that was `skipped` releases the next stage; one that `failed` or was `cancelled`
  holds it back.** That is the whole mechanism, and it is why an empty stage in the middle is
  harmless.
- **The row count keeps the empty matrix away.** GitHub evaluates a job-level condition before the
  matrix is applied, so a false condition prevents the "matrix vector does not contain any values"
  error that an empty matrix would otherwise cause. That error is silent: no annotation, no job
  record, only a red run. The workflow carries a comment saying so.

Stage 1 keeps the job id `terraform-ci-cd`, so the structural tests that reach for it by id keep
working, and all three keep the display name `Terraform` (D7).

### 4.3 What holds back what

A stage runs when every earlier stage succeeded or was skipped. A failed environment therefore
holds back every later stage, whether or not anything declared a dependency on it (D2). The
converse is also true and useful: an empty stage never holds anything back.

### 4.4 The gap between the declaration and the guarantee

`prod depends-on shared` compiles to "stage 2 runs after stage 1 succeeded", and stage 1 may hold
environments nobody mentioned. D3 removes the common case by moving free-standing environments to
the last stage, but two environments that are each depended upon still share a stage, and either
one's failure holds back both dependents.

This is not a defect to be fixed later. GitHub has no per-leg `needs`, and the only alternative,
one job per environment, cannot be generated because a workflow's jobs are static. The spec states
the guarantee in the terms the workflow can keep, the user guide repeats it, and the run summary
prints the computed stages so the effective ordering is visible rather than inferred.

### 4.5 Ordering is per run

Environments serialise across runs through their per-environment concurrency group, whose queue is
first-in, first-out by the time a job **started waiting**. A stage-2 job only starts waiting after
its own stage 1 finishes, so a newer run that queued on an environment early can take it before an
older run's later stage reaches it. Deadlock is impossible, since a job holds exactly one group and
waits on nothing while holding it, but interleaving between overlapping runs is real.

`depends-on` therefore orders environments within one run. It does not serialise a repository's
runs against each other; the concurrency groups do that, per environment.

## 5. Validation errors

Each stops the run in `create-matrix` with a red conclusion and one message.

| Situation | Message |
|---|---|
| unknown name | `environments-yml: environment 'prod': depends-on names 'stagng', which is not a declared environment` |
| self-reference | `environments-yml: environment 'prod': depends-on names itself` |
| cycle | `environments-yml: depends-on forms a cycle: shared → prod → shared` |
| deeper than the cap | `environments-yml: depends-on needs 4 stages but this workflow supports 3. Longest chain: shared → platform → regional → app. Flatten the chain or split the repository.` |

## 6. Bypass and recovery

Dispatching a single environment carries no dependencies: it is stage 1 whatever it declares, and
`ordering.bypass` records `single-environment-dispatch`. That is both the escape hatch the need
asked for, so a sandbox can never hold production hostage, and the recovery path for an environment
that a failed stage held back.

The run's record and its notice say so, and only when the dispatched environment actually declares
dependencies:

```
dispatched by <actor>: environment prod, goal apply, reason "recover after failed nightly"
  — ordering bypassed: `prod` depends on `shared`, which is not in this run
```

A dispatch that names no environment is staged normally. A dispatch capped to `goal: plan` grants
no mutating goal, so by D4 it collapses to one stage and runs fully parallel. A scheduled run is
staged like a push; a schedule that keeps one environment is stage 1 by construction, not by
bypass, and the difference matters because a bypass is recorded and this is not.

## 7. What the run shows

### 7.1 Held back is not a benign skip

A stage job that was skipped for having no environments and one that was skipped because a
predecessor failed both report `skipped`. The conclusion does not care: whatever held the stage
back is itself a failure in the same list, so the existing rule already turns the run red. Every
human-facing surface does care, and distinguishes the two by joining the stage's result with its row
count from the builder.

The vocabulary follows the tests spec's "not run" family rather than the relevance spec's "not
affected": `➖` means the run correctly did nothing, and a held-back environment is the opposite of
that.

### 7.2 Run summary

The only surface on push, dispatch and schedule runs.

```markdown
**3 environments · 1 applied · 2 held back · 1 failed**

| Environment | Worst outcome | Plan | Apply | Destroy | Time | Job |
|---|:---:|---|---|---|---|---|
| `shared`  | ❌ | 💫 2 | ❌ | — | 1:14 | [run](…) |
| `prod`    | <span title="held back: stage 2; stage 1 failed">⏭️</span> | — | — | — | — | — |
| `sandbox` | <span title="held back: stage 2; stage 1 failed">⏭️</span> | — | — | — | — | — |

_Ordering: 2 stages. Stage 1 failed, so stage 2 did not run. Held back: `prod`, `sandbox`._
```

The dash cells are the relevance spec's unaffected rows exactly; only the outcome cell and the
footer line are new. The footer also carries the two cases worth naming when they occur: a
dependency that was not in the run at all, and a tolerated failure that released a later stage.

```
_Ordering: 2 stages. `prod` applied; its dependency `shared` was not in this run (not affected)._
_Ordering: 2 stages. Stage 1 released stage 2; `shared` failed but allows failing operations._
```

### 7.3 Conclusion

Red, through the rule the relevance spec already states: a stage whose result is `skipped` while
its row count is greater than zero is a failure. The run is red anyway from the environment that
failed; the value here is the sentence.

```
conclusion: red — stage 1 failed (shared); 2 environment(s) held back: prod, sandbox
```

### 7.4 Pull request comments

Reachable because ordering applies whenever a mutating goal is granted (D4), so a pull request
using `apply-on-pr` can hold an environment back.

A held-back environment's head cannot be written at seed time, because the hold-back does not exist
until a stage has failed, and its own matrix job never runs. The aggregator finalises it: it runs
after every stage with `always()`, already downloads every metadata artifact, and can see that an
environment is in the run with comments enabled, has no metadata, and belongs to a skipped stage
whose row count is non-zero. This is new responsibility for that action, which today reconciles
group heads only.

```markdown
### Terraform summary for environment: `prod`

⏭️ Held back: this environment is in stage 2 and stage 1 failed (run #4711 attempt #1).

<details><summary>Ordering</summary>

Depends on: `shared`
Stage: 2 of 2 · stage 1 result: failure

</details>
```

In a group head the member keeps its column, every cell
`<span title="held back: stage 2; stage 1 failed">⏭️</span>`, and the head gains a footer line
`⏭️ Held back: \`prod\`, \`sandbox\`` above the workflow-log line, structurally identical to the
relevance spec's not-affected footer.

### 7.5 Auto-merge

A held-back environment produces no metadata, which the completeness rule already treats as not
eligible. Only the reason changes, so the operator is not told "cancelled or crashed" when the
truth is "held back because stage 1 failed".

## 8. Anti-goal: not a health gate

`depends-on` orders environments inside one run. It never inspects whether the dependency's last
apply succeeded, and no cross-run state is kept.

The case that will be reported as a bug: an apply fails for the test tenant on one push; the next
push touches only production's directory, so relevance leaves the test tenant out; the dependency is
satisfied trivially; production applies on top of a dependency whose last apply failed. Everything
behaves as specified and nothing is wrong, but a reader of `depends-on` expects otherwise.

Two mitigations, both cheap and both in this spec: the anti-goal is stated in the user guide next to
the key, and whenever a mutating goal is granted and a declared dependency was not in the run, the
run summary and the notice say so (§7.2). That line is the only warning an operator will get, which
is why it is not optional.

## 9. Interplay with other specs

| Concern | Relationship |
|---|---|
| Decision engine | Stage assignment is a rule of its procedure and a set of its invariants; the per-stage matrices and counts are its outputs. Held-back is **not** an engine concept: the engine assigns stages, and whether a stage ran is a fact of the run graph it never sees. |
| Path relevance | Relevance decides membership, ordering decides sequence within it. A dropped dependency is satisfied trivially and recorded. The conclusion rule for "skipped while the count is non-zero" is shared. |
| Dispatch and triggers | Single-environment dispatch is the bypass and the recovery path; a plan-capped dispatch collapses to one stage. |
| Terraform tests | Unchanged: tests do not gate environments, and ordering does not change that argument (the first reason for it, that gating would delay every plan on every pull request, is untouched). What does change is the statement that environment jobs have no `needs` between them, which becomes false for stages while remaining true between tests and environments. |
| Concurrency | Unchanged; an environment appears in exactly one stage, so its group is taken once per run. Stages add a small hand-off latency per contended environment. |
| GitHub Environments | A required reviewer on a deployment environment now blocks every later stage while it waits, which is arguably correct and is documented. |

## 10. Actions and workflow changes

- **Decision engine**: the ordering rule, the stage fields and per-stage matrices in its output, the
  invariants of its §7, and `depends-on` as a dimension of its generated cases.
- **`create-tf-vars-matrix` shim**: emits `matrix-stage-<n>-json` and `stage-<n>-count` per stage.
- **Workflow**: three stage jobs sharing one anchored step list; every consumer's `needs` extended
  (`conclusion`, `pr-comment-aggregator`, `run-summary`, `automerge`); the auto-merge condition
  rewritten so an implicit success check cannot skip it when a stage is skipped, which with three
  stage jobs would otherwise happen on every run of every repository that declares no dependencies.
- **`aggregate-validation-summaries`**: held-back columns, the footer line, and finalising a
  held-back environment's own head (§7.4).
- **`create-run-summary`**: held-back rows, the headline term, the ordering footer.
- **`evaluate-automerge-eligibility`**: the held-back reason string.
- **Structural tests**: the three stage jobs differ only in `if:`, `needs:` and matrix source; all
  three carry the name `Terraform`; every stage job is in the conclusion's `needs`.

## 11. Pitfalls

| # | Pitfall | Consequence | Rule |
|---|---|---|---|
| P1 | A stage waits for its whole predecessor stage, not only for declared dependencies. | An unrelated failure holds back a chain. | Inherent (D2); free-standing environments go last (D3); the computed stages are printed. |
| P2 | A condition built only from `needs.*.result` gets an implicit success check. | The stage never runs. | `!cancelled()` in every stage guard (§4.2). |
| P3 | `!failure()` is transitive over all ancestors. | A failed seed job holds back every stage, which the environment job deliberately tolerates today. | Explicit result checks, never `!failure()`. |
| P4 | An empty matrix fails the run with no annotation and no job record. | A red run nobody can explain. | The per-stage row count gates the job, and a job-level condition is evaluated before the matrix is applied. A comment in the workflow says so. |
| P5 | A stage skipped for being empty and one skipped for being held back both report `skipped`. | A held-back production environment reads as benign. | Join the result with the row count in every human-facing surface (§7.1). |
| P6 | Auto-merge's condition has no status function. | With three stage jobs it is skipped on every run of every unordered repository. | Rewritten in the same change (§10). |
| P7 | A stage job named anything but `Terraform`. | The aggregator's job-link lookup silently produces a garbage key and every job link disappears; check names change for callers. | D7, with a structural test. |
| P8 | Ordering is per run, not global. | A newer run can take an environment before an older run's later stage reaches it. | Documented (§4.5). |
| P9 | `depends-on` reads as a health gate. | Production applies on top of a dependency whose last apply failed. | Anti-goal plus the run-summary line (§8). |
| P10 | A tolerated failure releases the next stage. | Dependents apply after a failed apply. | D5, the guide's advice, and a named line in the run summary. |
| P11 | A required reviewer on a deployment environment. | Every later stage waits for the approval. | Documented; the run-level 35-day limit is the only ceiling. |
| P12 | A held-back environment's head has no matrix job to finalise it. | The head stays at "Awaiting results" forever. | The aggregator finalises it (§7.4). |
| P13 | The anchor carries only the step list. | A stage job silently loses `environment`, `concurrency`, `permissions` or `outputs`. | Written per stage job; a structural test compares the three. |
| P14 | YAML merge keys are not supported, and anchors are unavailable on GitHub Enterprise Server. | A parse failure with no jobs and a misleading run title. | Aliases only; the caveat is recorded. |
| P15 | Matrix job outputs keep only the last leg's value, and `strategy.job-index` restarts per stage. | Anything keyed on either collides across stages. | Cross-stage data travels as per-environment artifacts, as it already does. |

## 12. Test coverage

**Must**

- Engine: linear chains of two and three; a diamond, proving the tail is stage 3 and not stage 2;
  two independent chains sharing stage numbers; a free-standing environment landing in the last
  stage and in stage 1 when there is no chain; a dependency dropped by relevance, by trigger events
  and by the dispatch filter; every validation error of §5 with its message; a plan-only run and a
  plan-capped dispatch collapsing to one stage; a single-environment dispatch bypassing a declared
  dependency; every invariant asserted on every generated case, with `depends-on` graphs as a
  generated dimension.
- Workflow structural tests: §10's last bullet.
- Rendering: run summary with held-back rows and each footer variant; a group head with a held-back
  column; a held-back per-environment head; the auto-merge reason.

**Should**

- The conclusion's message for a held-back run; the notice text for a bypass.

**Could**

- A property test that stage assignment is a pure function of the restricted graph, by permuting
  the declaration order.

**What tests cannot cover**: that a skipped stage releases the next one and a failed stage does
not, that an empty matrix behind a false condition does not fail the run, that the anchor resolves
across a remote reusable-workflow reference, and the queue interleaving of §4.5. All four were
observed on a test-bed repository during design and are re-verified through a preview ref before
release.

## 13. Open questions

1. **The aggregator finalising a held-back head** is the one genuinely new mechanism. Verify on the
   test-bed that it can distinguish held-back from not-affected from crashed-before-capture using
   only the relevance artifact, the metadata set and the stage results.
2. **Whether a strict opt-in is ever wanted**: a per-environment key that makes a tolerated failure
   hold back dependents after all, implemented as a metadata-inspecting gate job between stages. Not
   in v1; recorded so the decision is not rediscovered.
3. **Hand-off latency** between stages on a contended environment was about forty seconds in one
   observation. Confirm it is not materially worse with a real apply in front of it.

## 14. What implementation taught the spec

Reserved.
