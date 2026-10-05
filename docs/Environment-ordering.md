# Ordering between environments

Authoritative spec for making one environment apply before another in
[`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml): a test tenant
before production, a shared landing zone before what sits on it. An environment declares what it
follows, the [decision engine](Decision-engine.md) compiles those declarations into stages, and the
workflow runs the stages in sequence.

The decisions in §2 are settled; the mechanics of §4 were observed on a test-bed repository during
design and again through the implementation (§14). §14 is what implementation taught the spec.

Related: [Decision-engine.md](Decision-engine.md) assigns the stages;
[Path-relevance.md](Path-relevance.md) decides which environments are in the run at all;
[Dispatch-and-triggers.md](Dispatch-and-triggers.md) provides the bypass.

## 1. Why

A calling repository manages two tenants: a test tenant and production. A change to shared code
should reach the test tenant first, and production should wait for it to succeed. Without
`depends-on`, every environment is a leg of one flat matrix, so they apply in parallel.

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
| D6 | The stage cap is **3**, enforced against the **declared** graph. A deeper chain is a validation error naming it. | Hub-and-spoke is depth 2 and three tiers is depth 3; deeper coupling in practice crosses repositories, which this workflow cannot sequence anyway. Validating the declared graph keeps a configuration's validity independent of which files a change touched. Raising the cap later moves no existing configuration; it is one job block, the engine's constant, and one entry in every list of the stage jobs (the four consumers' `needs`, the three `stage-results-json` values, the conclusion's stage loop, the run summary's stage loops (`create-run-summary`), the auto-merge condition, the outputs of create-matrix and `create-tf-vars-matrix`, and F10 and F15). |
| D7 | Every stage job keeps `name: "Terraform"`. | Any other name breaks or silently corrupts the aggregator's job-link lookup, and would change the check-run names every caller sees. With identical names, callers observe no change at all. |
| D8 | `depends-on` is **opt-in**. Absent, every environment is stage 1 and the workflow behaves as before. | Nothing breaks for a caller that does nothing, so v1 gains no breaking-change row for this feature. |
| D9 | Ordering is **intra-run only** and never inspects a dependency's earlier runs. | Stated as an anti-goal (§8) because `depends-on` reads like a health gate. |

## 3. Caller-facing API

### 3.1 The key

| Key | Type | Default | Meaning |
|---|---|---|---|
| `depends-on` | list of environment names, per environment in `environments-yml`; one name written alone is that one name, as for the other list settings (Configuration-validation.md §3) | `[]` | This environment runs in a later stage than every environment named here. |

```yaml
environments-yml: |
  - environment: shared
  - environment: prod
    depends-on: [shared]
  - environment: sandbox
```

Compiled: stage 1 holds `shared`; stage 2 holds `prod` and, by D3, `sandbox`. The run summary
prints exactly that (§7.2), so nobody has to derive it from the configuration.

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
`strategy`, `environment`, `concurrency` and `defaults` are written per stage job, the fields the
environment job has.

```yaml
terraform-ci-cd:            # stage 1, keeps today's job id
  name: "Terraform"
  needs: [create-matrix, seed-pr-comments]
  if: |
    !cancelled()
    && needs.create-matrix.result == 'success'
    && needs.create-matrix.outputs.stage-1-count != '0'
  strategy:
    fail-fast: false
    matrix: ${{ fromJSON(needs.create-matrix.outputs.matrix-stage-1-json) }}
  steps: &environment-steps
    # the ~60 steps, unchanged

terraform-ci-cd-2:          # stage 2
  name: "Terraform"
  needs: [create-matrix, seed-pr-comments, terraform-ci-cd]
  if: |
    !cancelled()
    && needs.create-matrix.result == 'success'
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
  `seed-pr-comments`, which the environment job deliberately tolerates (Path-relevance.md §5.3),
  would hold back every stage. The seed's result is not tested at all, as today: it is in `needs`
  for ordering only.
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

The messages follow Configuration-validation.md's style (its D9): what was written, why it cannot
be used, and how to write what was probably meant.

| Situation | Message |
|---|---|
| unknown name | `The environment 'prod' depends on 'stagng', which is not an environment of environments-yml; did you mean 'staging'?` (with no near miss: `… The environments are shared, staging, prod.`) |
| self-reference | `The environment 'prod' depends on itself, so it could never run; remove 'prod' from its depends-on.` |
| cycle | `depends-on forms a cycle, shared → prod → shared, so none of them could ever run first; remove one of the dependencies.` |
| deeper than the cap | `depends-on needs 4 stages, but the workflow runs at most 3: shared → platform → regional → app. Flatten the chain, or split the repository.` |
| not a list of names | `The environment 'prod' sets 'depends-on' to {"shared": true}; it must be a list of environment names.` |
| a name that is not text | `The environment 'prod' depends on 7, which is not an environment name; quote it if it is one.` (for a number; otherwise `… depends on null, which is not an environment name.`) |

The names are checked first, then the cycle, then the depth, each only when the one before found
nothing. A cycle is named in run order from its member declared first.

## 6. Bypass and recovery

Dispatching a single environment carries no dependencies: it is stage 1 whatever it declares, and
`ordering.bypass` records `single-environment-dispatch`. That is both the escape hatch the need
asked for, so a sandbox can never hold production hostage, and the recovery path for an environment
that a failed stage held back.

The run's record and a notice say so, and only when the dispatched environment actually declares
dependencies. The dispatch line itself is unchanged:

```
prod: run — relevance: all:event; ordering: single-environment dispatch, stage 1; goals: init, format, validate, lint, plan, apply
ordering bypassed: 'prod' depends on 'shared', which a single-environment dispatch does not run
```

A dispatch that names no environment is staged normally. A dispatch capped to `goal: plan` grants
no mutating goal, so by D4 it collapses to one stage and runs fully parallel. A scheduled run is
staged like a push when an environment's `schedule-goal` grants it a mutating goal; capped to
`plan`, the default, it collapses to one stage. A schedule that keeps one environment is stage 1
by construction, not by bypass, and the difference matters because a bypass is recorded and this
is not.

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
**3 environments · 3 affected · 0 not affected · 0 applied · 2 held back · 1 failed**

| Environment | Worst outcome | Plan | Apply | Destroy | Time | Job |
|---|:---:|---|---|---|---|---|
| `shared` | <span title="a step failed or was cancelled">❌</span> | `💫 2` `🛠️ 0` `💥 0` | `💫 ?/2` `🛠️ ?/0` `💥 ?/0` | — | `1:14` | [run](…) |
| `prod` | <span title="held back: stage 2; stage 1 failed">⏭️</span> | — | — | — | — | — |
| `sandbox` | <span title="held back: stage 2; stage 1 failed">⏭️</span> | — | — | — | — | — |

_Ordering: 2 stages. Stage 1: `shared`. Stage 2: `prod`, `sandbox`. Stage 1 failed, so stage 2 did not run. Held back: `prod`, `sandbox`._
```

A held-back row has plain dashes and no job link: the unaffected rows' "not affected" tooltip would
be false. The headline counts `held back` after `destroyed` and before `failed`, and a held-back
environment is counted as neither failed nor not reported. The footer is one line below the table:

- with more than one stage, it lists the stages, each with its environments by github-environment,
  in `environments-yml` order;
- `Stage 1 failed, so stage 2 did not run. Held back: …` (`stages 2 and 3`, `Stage 1 was cancelled,
  so …`), when a stage was held back;
- `Stage 1 released stage 2; `shared` failed but allows failing operations.`, when an earlier
  stage's environment has a failed operation under `allow-failing-terraform-operations` and a later
  stage ran;
- `` `prod` applied; its dependency `shared` was not in this run (relevance: no changed file matches). ``,
  for an environment granted apply or destroy whose declared dependency was not in the run. This
  one shows at one stage too, because it is the §8 warning: `_Ordering: 1 stage. …_`.

Without depends-on, nothing about ordering is shown.

### 7.3 Conclusion

Red, through the rule the relevance spec already states: a stage whose result is `skipped` while
its row count is greater than zero is a failure. The run is red anyway from the environment that
failed; the value here is the sentence. The conclusion job has the stages' results and counts, not
the environments' names, so it names stages:

```
conclusion: red — stage 1 failed; stage 2 held back (2 environment(s)); environments: 3 affected, 0 not affected (…); tests: 0
conclusion: green — stage 1 succeeded; stage 2 succeeded; environments: 3 affected, 0 not affected (…); tests: 0
```

With one stage, as for every repository without depends-on, the line is exactly what it was before
ordering existed, word for word.

### 7.4 Pull request comments

Reachable because ordering applies whenever a mutating goal is granted (D4), so a pull request
using `apply-on-pr` can hold an environment back.

A held-back environment's head cannot be written at seed time, because the hold-back does not exist
until a stage has failed, and its own matrix job never runs. The aggregator finalises it: it runs
after every stage with `always()`, already downloads every metadata artifact, and can see that an
environment is in the run with comments enabled, has no metadata, and belongs to a skipped stage
whose row count is non-zero. It is the only per-environment head that action writes; otherwise it
reconciles group heads only.

```markdown
### Terraform summary for environment: `prod`

⏭️ Held back: this environment is in stage 2 and stage 1 failed (run #4711 attempt #1).

<details><summary>Ordering</summary>

Depends on: `shared`
Stage: 2 of 2 · stage 1 result: failure

</details>
```

The title follows the seed's rule ("Terraform validation summary" for an environment that does not
mutate on pull requests). A free-standing environment's details say `Depends on: none;
free-standing environments run in the last stage`. The aggregator finds the head by its marker,
`<!-- tf:head:env:<github-environment> -->`, and writes it with `pr-comment`'s upsert semantics:
the oldest match is kept and patched, the others deleted, and the head posted when there is none.
A `skip` entry (not affected) and a `run` entry whose stage ran (crashed before capturing metadata)
are left alone.

In a group head the member keeps its column, every cell but the empty Links cell
`<span title="held back: stage 2; stage 1 failed">⏭️</span>`, and the head gains a footer line
`⏭️ Held back: \`prod\`, \`sandbox\`` above the workflow-log line, below the not-affected footer.
A group whose members are all held back is rendered too.

### 7.5 Auto-merge

A held-back environment produces no metadata, which the completeness rule already treats as not
eligible. Only the reason changes, so the operator is not told "cancelled or crashed" when the
truth is "held back because stage 1 failed":
`'prod' was held back: it is in stage 2 and stage 1 failed, so it was never planned, environment is ineligible for PR auto merge`.
In practice the auto-merge job does not run at all when a stage was held back, since the
conclusion is red; the reason is defence in depth.

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
| Terraform tests | Unchanged: tests do not gate environments, and ordering does not change that argument (the first reason for it, that gating would delay every plan on every pull request, is untouched). What does change is the statement that environment jobs have no `needs` between them: it is false for the stages and remains true between tests and environments (Terraform-tests.md §8). |
| Concurrency | Unchanged; an environment appears in exactly one stage, so its group is taken once per run. Stages add a small hand-off latency per contended environment. |
| GitHub Environments | A required reviewer on a deployment environment now blocks every later stage while it waits, which is arguably correct and is documented. |

## 10. Actions and workflow changes

The contract between the pieces:

| Where | What |
|---|---|
| engine output | `matrices` holds `"1"`, `"2"` and `"3"`, each `{"environment": [...], "include": [...]}`, empty when the stage has no environment. `counts.by_stage` is `{"1": n, "2": n, "3": n}`. `ordering` is `{"declared": <whether any environment declares depends-on>, "stages_used": <1 to 3>, "cap": 3, "bypass": null or "single-environment-dispatch"}`. Every entry of `environments[]` carries `depends-on`, the declared list (so a renderer can say what a held-back environment waits for); a `run` entry carries `stage`, 1 to 3. |
| reasons | a `run` entry's reasons gain, after its relevance reason and before its goals, `ordering: stage <n>` when more than one stage is in use, one `ordering: depends-on '<name>' not in this run (<that environment's first reason>)` per declared dependency left out when a mutating goal is granted, and `ordering: single-environment dispatch, stage 1` for the bypass |
| notices | the bypass, when the dispatched environment declares dependencies; and, when a mutating goal is granted, each declared dependency that is not in the run (§8) |
| `create-tf-vars-matrix` outputs | `matrix-stage-1-json`, `matrix-stage-2-json`, `matrix-stage-3-json` and `stage-1-count`, `stage-2-count`, `stage-3-count`; `matrix-json` stays, the union of the three; `affected-count` stays the total |
| `relevance.json` | the entries and `ordering` as above, since it is the output document without its matrices |
| the stage results | the jobs after the stages receive them as `stage-results-json`, `{"1": "<result>", "2": "<result>", "3": "<result>"}`, built in the workflow from `needs.<stage job>.result` |

- **Decision engine**: the ordering rule, the stage fields and per-stage matrices in its output, the
  invariants of its §7, and `depends-on` as a dimension of its generated cases.
- **`create-tf-vars-matrix` shim**: emits `matrix-stage-<n>-json` and `stage-<n>-count` per stage.
- **Workflow**: three stage jobs sharing one anchored step list; every consumer's `needs` extended
  (`conclusion`, `pr-comment-aggregator`, `run-summary`, `automerge`); the auto-merge condition,
  which already carried `!cancelled()`, tests each stage by name: `success`, or `skipped` with no
  environments.
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
| P3 | `!failure()` is transitive over all ancestors. | A failed seed job holds back every stage, which the environment job deliberately tolerates. | Explicit result checks, never `!failure()`. |
| P4 | An empty matrix fails the run with no annotation and no job record. | A red run nobody can explain. | The per-stage row count gates the job, and a job-level condition is evaluated before the matrix is applied. A comment in the workflow says so. |
| P5 | A stage skipped for being empty and one skipped for being held back both report `skipped`. | A held-back production environment reads as benign. | Join the result with the row count in every human-facing surface (§7.1). |
| P6 | A job-level condition built only from `needs.*.result` comparisons gets an implicit `success()`. | With three stage jobs, auto-merge would be skipped on every run of every unordered repository. | Auto-merge keeps `!cancelled()` and tests each stage by name (§10). |
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

As built: the engine's `test_ordering.py` (every case of the Must list, every message of §5) and a
generated dimension of 600 random graphs across events, goals, changed files and dispatches, with
I18 to I24 derived apart from `ordering.py`; F10 (the conclusion's lines) and F15 (the three stage
jobs' shape) in `structural-tests/run_all_tests.sh`; the held-back cases of
`create-run-summary`, `aggregate-validation-summaries` and `evaluate-automerge-eligibility`, each
with the unordered output held byte-identical.

**What tests cannot cover**: that a skipped stage releases the next one and a failed stage does
not, that an empty matrix behind a false condition does not fail the run, that the anchor resolves
across a remote reusable-workflow reference, and the queue interleaving of §4.5. All four were
observed on a test-bed repository during design and again on the implementation (§14).

## 13. Open questions

1. **The aggregator finalising a held-back head**: closed on the test bed. A pull request whose
   stage 1 failed an apply finalised the held-back environment's own head and the group head's
   held-back columns, from the relevance artifact, the metadata set and the stage results; not
   affected and crashed are told apart by the verdict and by whether the stage ran, and tested.
2. **Whether a strict opt-in is ever wanted**: a per-environment key that makes a tolerated failure
   hold back dependents after all, implemented as a metadata-inspecting gate job between stages.
   Deferred: not in v1; recorded so the decision is not rediscovered.
3. **Hand-off latency** between stages: three seconds on the test bed, uncontended, with a real
   apply in stage 1. A contended environment adds its concurrency queue's wait, as today.

## 14. What implementation taught the spec

- **Stage 1 is never held back.** A skipped stage 1 with environments means the run was cancelled
  before it started, not that ordering held it; treating it as held back would also have broken
  the promise that a repository without depends-on sees nothing new. Held back is a stage from 2
  up, skipped, with environments, and without their metadata; metadata always wins.
- **The dependency warning shows at one stage.** Its motivating case, a push touching only
  production's directory, leaves one environment and one stage. The run summary therefore prints
  that sentence whenever a mutating goal was granted, stages or not, and the engine's notice does
  the same.
- **The conclusion names stages, not environments.** It runs with the job results and the counts
  only; the run summary names the environments.
- **The cycle is found by peeling.** Environments whose dependencies are all peeled off are removed
  until none can be; what is left is on a cycle or depends on one, and following dependencies
  within it must repeat. The first build walked the graph depth first with a visited set, which
  the mutation gate showed was an optimisation no test could see; the peeling has none. The
  longest chain is found by relaxation, and the stages by plain recursion, which the validated
  depth keeps short.
- **The structural tests had a blind spot for digits.** F12 matched output names with `[a-z-]+`,
  so the new `stage-1-count` read as undeclared.
- **The test bed confirmed the four things tests cannot** (§12): a skipped stage released the next
  and a failed one held it back, an empty stage job behind its count was skipped without an error,
  and the anchor resolved across the remote reference. The interleaving of §4.5 showed with two
  pushes four seconds apart, the first touching every environment and the second one environment:
  the newer run took that environment in its stage 1 while the older run was still in its stage 1,
  the older run's stage 2 took it after, and both runs were green. A single-environment dispatch
  recovered an environment on its own, and a push touching only a dependent applied it alone, with
  the notice and the footer sentence naming the dependency that was not in the run.
