# Auto-merge

Authoritative spec for the pull-request auto-merge of
[`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml): when a pull
request is merged without review, from what evidence, and how the merge is tied to that evidence.
Its settings are validated as [Configuration-validation.md](Configuration-validation.md) §3.6
specifies; this spec is what happens with them.

Status: **specification, not yet implemented.** It describes the current pipeline where that is
kept (§3) and the changes (§4). §13 is reserved for what implementation teaches the spec.

## 1. Why

Auto-merge merges with `gh pr merge --admin`, past the branch protection's required reviews. That
is its purpose, for a named bot's routine pull requests whose plans stay within limits, and it is
also why every piece of evidence it trusts must be exactly what it appears to be. Reading the
pipeline end to end found these places where it was not:

1. The evidence was the plan's **console text**. An unanchored search for `No changes.` and the
   first line holding `Plan: ` let text inside the plan zero the add, change, destroy and import
   counts. Verified with Terraform 1.16: a plan that imports 1, adds 3, changes 2 and destroys 3,
   one of whose values reads `No changes allowed; Plan: 0 to add, 0 to change, 0 to destroy.`,
   parsed as zero of each. The comment then said "no changes" and hid the plan, and every limit
   passed.
2. The merge was not tied to what was planned. The plans of a pull-request run are computed on
   the event's merge commit, the head merged with the base as it was then; a rebase merge of the
   pull request number lands the pull request's head as it is now onto the base as it is now.
3. An environment whose `trigger-events` lack `pull_request` is skipped on the pull request without
   its relevance being evaluated, and the evaluator took every skip for "not affected": a change
   to that environment was never planned, auto-merged, and applied unplanned on the push.
4. The evaluator read the **raw** goals, not the goals the run was granted.
5. The actor list failed open: empty meant everyone, and `~`, `{}`, `0` or `true` did too.
6. The JSON plan was uploaded as an artifact on every run; unlike the console plan it holds
   sensitive values in plain text.
7. Auto-merge ran for any base branch, and for pull requests from forks.
8. The merger's retry waited for a mergeable state GitHub never reports.

## 2. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Plan counts come from the **JSON plan** (`terraform show -json`), computed in the environment's job; the console text is for people only. | The JSON plan is Terraform's own structure; nothing in a resource's values can change the counts. |
| D2 | The merge is pinned to the evaluated **head**: `gh pr merge --match-head-commit <github.event.pull_request.head.sha>`. | Every plan of the run was computed from that head. |
| D3 | The merge is pinned to the evaluated **base**: the job compares the base the plans saw (the first parent of `github.sha`, the event's merge commit) with the base branch's tip now, and refuses when they differ. | Decided by the maintainer: plan what you merge. In a burst of bot pull requests only the first merges; the others merge on their next run, after a rebase. |
| D4 | The evaluator reads **`goals-granted`**, the goals the run actually gated on. | "A plan should have been created" must mean the same to the evaluator as to the plan step. |
| D5 | Eligibility needs **every environment of the run**, affected or not, to allow the pull request's actor and to be enabled for auto-merge, as today; an affected environment's plan evidence must also pass. | Relevance decides what is planned, not what may merge unseen; an environment can refuse auto-merge for the whole repository. |
| D6 | An environment skipped because its `trigger-events` lack `pull_request` is not eligible when the change is relevant to it; the engine evaluates relevance for it anyway and publishes the result. | It was never planned; without this it merged unplanned. |
| D7 | The actor list names who may auto-merge; the one in effect for an enabled environment is never empty (Configuration-validation.md D5). A per-environment list replaces the global one (D6 there). Logins compare without case. | Decided by the maintainer. |
| D8 | The actor is the run's `github.actor`, the account whose push or action started the event, as today. A re-run keeps it; the pinned merge (D2, D3) keeps a re-run from merging anything but what was planned. | A re-run by a person of a bot's run merges the evaluated commit or nothing. |
| D9 | Auto-merge runs only for a pull request against the **default branch**, from the same repository (`head.repo.full_name == github.repository`). | Decided by the maintainer for the base branch: only the default branch is production to the gates. A fork's run has no secrets and its code is never merged unreviewed; the full-name comparison also holds for a calling repository that is itself a fork, and for a deleted fork's null `head.repo`. |
| D10 | The JSON plan is no longer uploaded as an artifact; it stays on the runner, where the parse step reads it. | Decided by the maintainer: it holds sensitive values in plain text, and nothing used the artifact. |
| D11 | The merger's retry reads GitHub's `mergeable` values as GitHub reports them (`MERGEABLE`, `CONFLICTING`, `UNKNOWN`), stops on `CONFLICTING`, and never retries a refusal for a moved head or base. | The old comparison with `NOT_MERGEABLE` never matched. |
| D13 | A tolerated failure of a Terraform operation blocks auto-merge; a tolerated test does not. An affected environment is not eligible when any of its operation steps (`init`, `verify-lock`, `fmt`, `validate`, `lint`, `plan`, `apply`, `destroy-plan`, `destroy`) ended `failure` or `cancelled`, whether or not `allow-failing-terraform-operations` kept the job green. A test job tolerated by `allow-failing-terraform-tests` does not block eligibility, and the evaluator names each such test in its log and in a notice. | Decided by the maintainer: `allow-failing-terraform-operations` means "do not fail the check", never "merge without review", and the old evaluator enforced it for the plan but not for format, validate, lint or the lock check; `allow-failing-terraform-tests` is meant as the lever that lets a pull request auto-merge although a tolerated lane fails, and it stays visible. |
| D12 | One set of `plan-max-count-*` limits applies to the sum of an environment's plan and destroy-plan counts, as today; the workflow's comment that promised separate destroy-plan limits is corrected. | The comment described limits that never existed. |

## 3. The pipeline as kept

The `automerge` job runs after the conclusion succeeded, on a `pull_request` that is not closing
and not a draft, when the input `pr-auto-merge-enabled` is `true`, and now (D9) only against the
default branch from the same repository. It:

1. checks the App settings (`pr-auto-merge-app-id`, the key secret's name);
2. downloads every environment job's metadata and `relevance.json`;
3. evaluates every environment of the run (§5);
4. when every one is eligible, mints an App token (contents and pull requests: write) and merges
   (§6).

On a Dependabot-triggered run only Dependabot's own secrets exist, so the App key must also be a
Dependabot secret, as it is today.

## 4. Changes

| Area | Today | Then |
|---|---|---|
| Counts | parsed from the console text | from the JSON plan, in the environment's job (§5.2) |
| Merge | `gh pr merge <n> --admin --rebase --delete-branch` | the same with `--match-head-commit`, after the base check (§6) |
| Goals read | raw `goals` | `goals-granted` (§5.1) |
| Environments out of pull requests | "not affected" | not eligible when relevant (D6) |
| Actors | empty = everyone; exact, case-sensitive; per-environment list added to the global | explicit, validated, case-insensitive; per-environment list replaces |
| Base branch, forks | any base; forks ran and failed | default branch, same repository |
| JSON plan | uploaded as an artifact, stderr in the same file | kept on the runner, stderr apart |
| Retry | waited for `NOT_MERGEABLE` | stops on `CONFLICTING`, never retries a refused pin |

## 5. Evaluation

### 5.1 Per environment

For an affected environment, from its metadata:

| Check | Reads | Fails when |
|---|---|---|
| enabled | the row's `pr-auto-merge-enabled` | not `true` |
| actor | the row's `pr-auto-merge-from-actors`, without case | the run's actor is not listed |
| plan created | `plan` in `goals-granted`; the plan step's outcome | granted and not `success` |
| destroy plan created | `destroy-plan` in `goals-granted`; its outcome | granted and not `success` |
| apply on pull request | `apply` in `goals-granted` (granted on a pull request only through `apply-on-pr`); the apply step's outcome | granted and not `success` |
| destroy on pull request | `destroy` in `goals-granted`; the destroy step's outcome | granted and not `success` |
| limits | the counts of §5.2 against the row's `pr-auto-merge-limits` | a count over its limit, or a count unknown |
| operations | the outcomes of `init`, `verify-lock`, `fmt`, `validate`, `lint`, `plan`, `apply`, `destroy-plan`, `destroy` | any is `failure` or `cancelled`, a tolerated one included (D13) |

As today, a plan whose apply ran on the pull request is not judged by the plan limits (the apply
already happened); likewise the destroy plan and a destroy on the pull request. The limits apply to
the sum of the plan and the destroy plan (D12).

An environment skipped by relevance is judged on enabled and actor, and its limits are still
validated, as defence in depth. An environment skipped because its `trigger-events` lack
`pull_request` is judged the same way when the change is not relevant to it, and is not eligible
when it is (D6): `relevance.json` carries, for every environment, whether a changed file is relevant
to it, whatever its verdict.

Test jobs are judged by the conclusion, as today: one that fails untolerated turns it red and the
auto-merge job does not run. The auto-merge job also downloads the test jobs' metadata
(`terraform-test-meta-*`) to name every tolerated failing or erroring test in its log and in a
notice, `auto-merge eligible despite the tolerated failing test tests/int-x.tftest.hcl (lane integration)`;
they never make the pull request ineligible (D13).

### 5.2 The counts

The JSON step writes `terraform show -json` to a file on the runner and its stderr apart.
`parse-terraform-plan` gains an input for that file and computes the six counts from it with `jq`,
reading from disk and never through a shell variable (the ARG_MAX rule of CLAUDE.md):

| Count | From each `resource_changes[]` entry with `mode: managed` |
|---|---|
| add | `change.actions` holds `create` (a replacement counts here and under destroy) |
| change | `change.actions` is `["update"]` |
| destroy | `change.actions` holds `delete` |
| import | `change.importing` is present |
| move | `previous_address` is present and differs from `address` |
| remove | `change.actions` holds `forget` (a `removed` block) |

Data sources (`mode: data`, action `read`) and `no-op` count nowhere. Output-only changes are an
`output_changes` entry whose actions are not `["no-op"]`, with no resource change. Action
invocations (Terraform 1.14 and later) are not counted: they ride on a counted create or update.
When the plan says it is not complete (`complete: false`, deferred changes) or errored, or the file
is absent or unreadable, every count is unknown (`?`) and the environment is not eligible, as a
count the text parser could not read is today. A failed `terraform show` therefore degrades to
not eligible, which is safe.

Terraform's `Plan:` summary line has no segment for moves or removals, so the oracle is the
repository's contract-test harness: `contract-tests/scenarios/*/expected.json` records all six
counts per scenario under the supported Terraform minors, and `contract-tests/run.sh` gains the
JSON capture and the comparison. Verified by hand with Terraform 1.16 before this spec: a
replacement counted under add and destroy, an import that is also a replacement counted as an
import, a moved and updated resource counted as a change and a move, a `removed` block as a
`forget` action, a deferred data-source read as `read`.

The console text keeps feeding the comment's plan extract; the comment's "no changes" comes from
the counts.

## 6. The merge

`auto-merge-pr` gains two inputs, `head-sha` (`github.event.pull_request.head.sha`) and
`base-sha` (the first parent of `github.sha`), and before merging reads the base branch's tip
(`gh api repos/<repo>/branches/<base>`):

- base tip differs from `base-sha`: not merged, `The base branch 'main' moved after this run planned the pull request (planned on <sha7>, now <sha7>), so the merged result was never planned. The next run, after the pull request is brought up to date, decides.`
- otherwise `gh pr merge --admin --rebase --delete-branch --match-head-commit <head-sha>`; GitHub
  refuses a moved head: `The pull request's head moved after this run planned it (planned <sha7>, now <sha7>), so it was not merged; the run for the new head decides.` (the current head read with `gh pr view --json headRefOid`).

A small window remains between the base check and the merge; a merge landing inside it is the
same race any merge queue closes, and is accepted.

## 7. What the run shows

The evaluator's log lists every environment's checks and why it is not eligible, as today. A
refused merge (base or head moved, a conflict) is an error annotation on the auto-merge job, and
the pull request stays open for a person.

## 8. Examples

**A bot's dependency bump**: `pr-auto-merge-from-actors-yml` naming `"dependabot[bot]"`, limits at
their defaults (nothing added, changed, destroyed or removed; imports and moves unlimited).
Dependabot's pull request plans `dev` and `prod` with no changes: eligible, merged, pinned.

**A person's pull request**: the same configuration, a pull request by `octocat`: not eligible
(actor), nothing merged.

**Text in a plan that looks like a summary**: a tag value `"No changes allowed without CAB
approval"` in a plan that destroys one resource: the JSON plan counts one destroy; not eligible.

**A commit after the plan**: dependabot's run is planned and eligible; a person pushes a commit
before the merge step runs: the merge is refused (head moved); the new commit's run decides, and
its actor is the person.

**A burst**: two dependabot pull requests are planned against the same base; the first merges; the
second's base moved, so it is not merged; after Dependabot rebases it, its new run plans the real
result and merges it.

**Production refuses auto-merge**: `prod` sets `pr-auto-merge-enabled: false`. No pull request of
the repository auto-merges, because every environment of the run must be enabled (D5).

**An environment out of pull requests**: `nightly` has `trigger-events: [push, schedule]`. A
dependabot bump touching only `dev` merges; one touching `nightly`'s directory is not eligible,
because `nightly` was never planned on the pull request.

## 9. Pitfalls

| # | Pitfall | Consequence | Rule |
|---|---|---|---|
| P1 | The console text holds resource values. | Values could forge the summary. | Counts from the JSON plan (D1). |
| P2 | `gh pr merge <n>` merges the head at the time of the call. | Unevaluated commits merged. | `--match-head-commit` (D2). |
| P3 | A pull-request run plans the event's merge commit; `--rebase --admin` lands on today's base. | A result nobody planned merged. | The base check (D3). |
| P4 | A re-run keeps `github.actor` and the event's head and base. | A re-run of an old attempt judged an old state. | The pins refuse a moved head or base (D2, D3, D8). |
| P5 | The actor is the account that triggered the event, not the author of every commit on the head. | A bot's pull request with a person's commit is judged by who pushed last. | The person's push is an event of its own, with the person as actor. |
| P6 | `terraform show -json` wrote stderr into the same file. | A warning line made the JSON unreadable. | Stderr apart (§5.2). |
| P7 | The JSON plan holds sensitive values. | Readable by anyone with access to the run's artifacts. | Not uploaded (D10). |
| P8 | GitHub's `mergeable` values are GraphQL enum values. | A comparison with another spelling never matches. | D11. |
| P9 | The JSON plan's shape changes between Terraform versions. | A count silently missed. | The contract-test harness over the supported minors (§5.2). |
| P10 | An environment skipped by trigger events has no plan evidence. | A change to it merged unplanned. | D6. |

## 10. Tests

- `parse-terraform-plan`: the Terraform 1.16 captures of §5.2 as fixtures, the injected-summary
  plan among them, each with its expected six counts; `complete: false`, an unreadable file, output
  changes only, a data-source read.
- `contract-tests`: the JSON capture and the comparison with every scenario's `expected.json`
  under every supported minor.
- `evaluate-automerge-eligibility`: `goals-granted` against raw goals that differ; the actor list
  without case; a per-environment list replacing the global one; an environment out of pull
  requests, relevant and not; each operation step failed under tolerance; a tolerated failing test
  named and not blocking; the existing suites unchanged elsewhere.
- `auto-merge-pr`: `--match-head-commit` passed; a moved base refused before merging; a moved
  head's message; the retry stopping on `CONFLICTING` and not retrying a refused pin.
- Engine: relevance published for every environment, whatever its verdict.
- Structural: the auto-merge job's base-branch and same-repository conditions, the head and base
  SHA wiring, the JSON file wiring from the plan step to the parse step, no JSON plan artifact.
- Live, once: `gh pr merge --match-head-commit` with a stale SHA against a test-bed pull request is
  refused by GitHub (the test bed has no merge App; a maintainer's token merges there), recorded in
  §13.

## 11. Open questions

None; the decisions are the maintainer's (D3, D9, D10, D13).

## 12. Implementation order

1. `docs:` this spec (with Configuration-validation.md).
2. `test(parse-terraform-plan):` the JSON fixtures, the text parser's current results pinned beside
   them.
3. `feat(terraform-plan):` stderr apart from the JSON plan; the JSON artifact no longer uploaded.
4. `feat(parse-terraform-plan):` counts from the JSON plan; `test(contract-tests):` the JSON
   comparison.
5. `feat(engine):` relevance published for every environment.
6. `feat(evaluate-automerge-eligibility):` `goals-granted`, actors without case, environments out
   of pull requests, the operation outcomes, the tolerated tests named.
7. `fix(auto-merge-pr):` the base check, `--match-head-commit`, the retry's values.
8. `feat(workflow):` the JSON file to the parse steps, the head and base SHAs to the merger, the
   base-branch and same-repository conditions, the corrected comment; structural tests.
9. Test-bed run: the examples of §8 the test bed can reach, and the live `--match-head-commit`
   refusal.

## 13. What implementation taught the spec

Reserved.
