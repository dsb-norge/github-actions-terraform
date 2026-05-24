# PR comments

Authoritative spec for all pull-request comments produced by [`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml).

Out of scope: deployment-environment UI, status checks, workflow run summaries — this doc is only about the comments posted on the PR conversation timeline.

## 1. Mental model — heads and tags

Two classes of PR comment, identified by an HTML marker on the body:

- **Heads** — long-lived, mutable. PATCHed in place across runs. Never reordered: their `created_at` is fixed at first-ever post, so once seeded they stay at their position in the PR conversation forever.
- **Tags** — run-scoped, immutable per run. Markers embed the workflow run id. Deleted at the start of the next run, re-POSTed by the matrix job that owns them.

Heads are pre-allocated at the top of every workflow run, in a deterministic order. This is what guarantees the relative order of summary comments never flips between runs — the rendering changes, the positions don't. Tags appear below all heads because they're necessarily POSTed mid-run.

All commenting goes through two generic, terraform-agnostic primitives — [`pr-comment`](../pr-comment/) (single op) and [`pr-comments-reconcile`](../pr-comments-reconcile/) (bulk seed + GC). They take `repo`, `issue-number`, `github-token`, and operate purely on HTML markers; they know nothing about terraform, events, or fork PRs (those concerns live in the workflow's `if:` guards).

## 2. Marker namespace

| Marker | Class | Cardinality | Posted/refreshed by |
|---|---|---|---|
| `<!-- tf:head:group:<group> -->` | Head | One per distinct non-empty `pr-comment-group` | Seed job (initial), [`aggregate-validation-summaries`](../aggregate-validation-summaries/) (final) |
| `<!-- tf:head:env:<env> -->` | Head | One per ungrouped env with `add-pr-comment: true` | Seed job (initial), matrix job for that env (final) |
| `<!-- tf:tag:plan:<env>:run-id-<run-id>:attempt-<run-attempt> -->` | Tag | One per env per run-attempt | Matrix job for that env |

Marker name conventions:

- Heads: `tf:head:<scope>:<name>` where `<scope>` is one of `group` / `env`.
- Tags: `tf:tag:<kind>:<scope-key>:run-id-<run-id>:attempt-<run-attempt>`. The run-id distinguishes workflow runs; the attempt token distinguishes re-runs of the same run (`run-id` is stable across attempts, only `run-attempt` increments). Both are needed so re-runs — including "Re-run failed jobs" — get fresh tags without colliding with the prior attempt's.

Markers are treated as opaque substrings by the underlying actions: matching is `body.contains(marker)`. The exact format is enforced by convention in this doc, not by the actions themselves — any unique-enough string works.

## 3. Lifecycle of a single workflow run

```text
                          ┌──────────────────────────────────────────────┐
                          │  Seed phase (top of workflow, before matrix) │
                          │                                              │
   create-matrix ───────► │  seed-pr-comments job:                       │
                          │   - reconcile heads (POST/PATCH per marker)  │
                          │   - (heads only; plan-tag GC lives in the    │
                          │      matrix, see §3.2)                       │
                          └─────────────────┬────────────────────────────┘
                                            │
                          ┌─────────────────▼────────────────────────────┐
                          │  Matrix jobs (parallel, one per env)         │
                          │                                              │
                          │   - DELETE prior `tf:tag:plan:<env>:*`       │
                          │   - PATCH `tf:head:env:<env>` with results   │
                          │   - POST `tf:tag:plan:<env>:run-id-<id>:`    │
                          │     `attempt-<n>` with fresh plan-extract    │
                          └─────────────────┬────────────────────────────┘
                                            │
                          ┌─────────────────▼────────────────────────────┐
                          │  Aggregator job (after matrix)               │
                          │                                              │
                          │   - PATCH each `tf:head:group:<group>` head  │
                          │     with the rolled-up grouped table         │
                          └──────────────────────────────────────────────┘
```

### 3.1 Seed phase

The `seed-pr-comments` job in [`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml) composes a `heads-yml` manifest from `create-matrix` outputs:

1. One `tf:head:group:<group>` head per distinct non-empty `pr-comment-group` value.
2. One `tf:head:env:<env>` head per env with `add-pr-comment: true` **and no `pr-comment-group`**. Grouped envs do not get a standalone per-env head — they are represented in their per-group head's table.

Heads are processed in declared order — group heads first, env heads after. On a fresh PR, this means group heads get earlier `created_at` than env heads, so the conversation order is group summaries above per-env. On re-runs the existing heads are PATCHed in place to a `⏳ Awaiting results…` placeholder body.

The seed job does **not** GC plan tags — that work happens per-env in the matrix (§3.2). This is what makes "Re-run failed jobs" behave correctly: when a previous attempt's seed already succeeded, GitHub skips it on the re-run, so any cleanup hooked into the seed phase wouldn't fire. Each matrix job purges its own env's plan tags as its first commenting step, which works whether the seed re-ran or not. The seed is `terraform-ci-cd`'s `needs:` dependency so matrix jobs still can't race ahead of head seeding.

### 3.2 Matrix phase

Each env's matrix job runs the validation pipeline, calls [`create-validation-summary`](../create-validation-summary/) to render the head + plan-extract bodies, and posts comments in three ordered steps:

1. **Purge prior plan tags** — `pr-comment` delete with marker `<!-- tf:tag:plan:<env>:`. Substring match wipes every existing plan-tag for this env regardless of run-id or attempt token. Idempotent: a fresh first-attempt run finds nothing to delete (records `action=not-found`); a re-run wipes the attempt(s) it's about to supersede. Envs whose matrix job *doesn't* re-run (e.g. on "Re-run failed jobs") are untouched — their plan tags stay, which is correct because their plan output didn't change either.
2. **Plan tag** — `pr-comment` upsert with marker `<!-- tf:tag:plan:<env>:run-id-<run-id>:attempt-<run-attempt> -->`. The prior delete just wiped everything, so the upsert resolves to a fresh POST.
3. **Head** — `pr-comment` upsert with marker `<!-- tf:head:env:<env> -->` (ungrouped envs only). Since the seed job already POSTed this marker, this resolves to a PATCH that replaces the `⏳ Awaiting results…` placeholder with the validation table + Links row.

All three calls are guarded by `always()` so the head and tag refresh even when an earlier step (init, tflint, etc.) failed.

### 3.3 Aggregator phase

[`aggregate-validation-summaries`](../aggregate-validation-summaries/) downloads all `matrix-job-meta-*.json` artifacts, builds the per-group rolled-up table, and upserts each `tf:head:group:<group>` head with the final rendered body. Seed job has already pre-allocated these heads, so the upsert resolves to a PATCH (preserving `created_at`).

## 4. Re-run behavior

### Heads

1. Seed phase PATCHes each head body to `⏳ Awaiting results (run #N)…`.
2. Matrix / aggregator phase PATCHes each head body to its final state.

Heads keep their original `created_at` across runs (PATCH preserves it). Their position at the top of the conversation is fixed from the first POST onwards.

### Tags

1. Each matrix job's **first** commenting step deletes any existing plan tag for its own env (`<!-- tf:tag:plan:<env>:` substring match, regardless of run-id or attempt). This handles cross-run AND cross-attempt cleanup uniformly: prior runs' tags, prior attempts of the current run's tags, all go.
2. Matrix phase then POSTs a fresh plan tag carrying the current `run-id` + `attempt` tokens.
3. Envs whose matrix job *doesn't* re-run (e.g. "Re-run failed jobs" with that env having succeeded in the prior attempt) keep their existing plan tag untouched — their plan output didn't change.

The net visual effect on a re-run: heads briefly show "Awaiting results" while matrix is executing. Each env's matrix job, on entering its commenting phase, wipes its own stale plan tag before posting the new one. Envs that aren't being re-run keep their existing tags showing the right state.

A consequence: there's a brief window early in matrix execution where a re-run's heads show "Awaiting results" while the prior attempt's plan tags are still visible underneath. The tags disappear one-by-one as each env's matrix job reaches its purge step — usually within the first 10-30 seconds of matrix runtime. This is the cost of supporting "Re-run failed jobs" cleanly (the seed job can't pre-empt the cleanup because it might not re-run on that path).

## 5. Comment body shapes

### 5.1 Per-env head

```markdown
### Terraform validation summary for environment: `<env>`
|  | Step | Result |
|:---:|---|---|
| ⚙️ | Initialization | `success` |
| 🔒 | Lock file | `success` |
| 🖌 | Format and Style | `success` |
| ✔ | Validate | `success` |
| 🧹 | TFLint | `success` |
| 📖 | Plan | `success` |
| ⏱ | Plan time | <span title="mm:ss (minutes:seconds)">`1:23`</span> |
| 🔗 | Links | [log extract](#issuecomment-<plan-tag-id>)<br>[job log](<job-url>) |
```

The Links row sits at the bottom of the table — same shape as the per-group head's Links column (§5.3) so reviewers learn one navigation pattern. `[log extract]` anchors at this env's plan tag (§5.2) for the current run; `[job log]` anchors at this matrix job's `#logs`. The Links row replaces the standalone `[Job log]` footer that older versions emitted below the table.

The Links row is rendered by `create-validation-summary` when its `plan-tag-comment-id` input is supplied. The matrix calls `create-validation-summary` twice for ungrouped envs: once initially to get `plan-extract` (used to POST the plan tag), then again with the resulting comment id supplied to re-render `head-summary` with the Links row. Grouped envs only call it once (their `head-summary` output is unused — see §5.1 grouped mode below).

Status cells: `` `success` `` for successful steps, `<kbd>failure</kbd>` / `<kbd>cancelled</kbd>` / `<kbd>skipped</kbd>` / `<kbd></kbd>` (empty outcome) for everything else.

Plan time row is always emitted in ungrouped mode. Renders the upstream `terraform-plan@v0` `plan-time` output as `` `mm:ss` `` inside `<span title="mm:ss (minutes:seconds)">`; the tooltip surfaces the unit on desktop hover. Defaults to `N/A` when the upstream action didn't supply a value.

Plan Details row is rendered only when `include-plan-details=true`. Shape:

```markdown
| 📊 | Plan Details | <span title="Resources to be added">`💫 1` add</span><br><span title="Resources to be changed">`🛠️ 0` change</span><br><span title="Resources to be destroyed">`💥 0` destroy</span> |
```

Optional badges (move / import / remove) are appended `<br>`-separated when the count is non-zero.

#### Grouped mode

When `pr-comment-group` is non-empty, the env has **no per-env head at all** — its row in the per-group head's table is the env's summary surface, and its plan output still gets its own per-env plan tag (§5.2). The seed manifest excludes grouped envs from per-env head seeding, and the matrix-job step that PATCHes the per-env head is skipped via an `if:` guard on `matrix.vars.pr-comment-group`. Reviewers reach the grouped env's plan output via the per-group head's Links column.

### 5.2 Per-env plan tag

```markdown
### Terraform plan for environment: `<env>`

<plan-block>
```

`<plan-block>` is one of five shapes:

1. `Plan: no changes ✅` — when `count-total` is numeric 0 and `has-output-only-changes` is not true.
2. `<details><summary>Plan: output-only changes ℹ️</summary>…</details>` — when `count-total` is 0 but `has-output-only-changes=true` (the plan changes outputs but no resources).
3. `<details><summary>Plan: N changes ℹ️</summary>…</details>` — when `count-total` is numeric > 0.
4. `<details><summary>Show Plan (last 65k characters)</summary>…</details>` — fallback when `count-total` is missing or `?` (parse failed).
5. `Plan not available 🤷‍♀️` — when no plan output is available at all.

All `<details>` shapes wrap the plan text in a `` ```terraform `` code fence. The plan text is capped at 65000 characters (tail-trimmed) to stay under GitHub's 65536-char comment limit.

### 5.3 Per-group head

The rolled-up grouped table aggregates every env in the group (alphabetical column order):

```markdown
### Terraform validation summary for group: `<group>`
|  | Step | <env-a> | <env-b> | <env-c> |
|:---:|---|:---:|:---:|:---:|
| <span title="Initialization">⚙️</span> | Initialization | <span title="success">✅</span> | <span title="failure">❌</span> | <span title="skipped">⏭️</span> |
| <span title="Lock file">🔒</span> | Lock file | … | … | … |
| <span title="Format and Style">🖌</span> | Format and Style | … | … | … |
| <span title="Validate">✔</span> | Validate | … | … | … |
| <span title="TFLint">🧹</span> | TFLint | … | … | … |
| <span title="Plan">📖</span> | Plan | … | … | … |
| <span title="Plan details">📊</span> | Plan details | <div align="left">…</div> | … | … |
| <span title="Plan time">⏱</span> | Plan time | <span title="mm:ss (minutes:seconds)">`1:23`</span> | <span title="mm:ss (minutes:seconds)">—</span> | … |
| <span title="Links">🔗</span> | Links | [log extract](#issuecomment-…)<br>[job log](…) | … | … |

[Workflow log](<run-url>)
```

Status cells map outcomes to emoji + tooltip: ✅ / ❌ / 🚫 / ⏭️ / — (empty outcome).

Plan Details cells stack the count badges in a `<div align="left">` so they anchor left in the otherwise center-aligned column. The badges (`💫 N add`, `🛠️ N change`, `💥 N destroy`) always render; `🔀 move`, `📥 import`, `⛓️‍💥 remove` are appended only when non-zero.

Plan time cells: backtick-wrapped `mm:ss` when present, em-dash `—` when missing. Both wrapped in `<span title="mm:ss (minutes:seconds)">` so desktop hover surfaces the unit.

Links cells contain up to two `<br>`-separated lines: `[log extract](#issuecomment-<id>)` (anchors to the env's plan tag, located by the `<!-- tf:tag:plan:<env>:run-id-<run-id>:` marker-prefix substring — matches any attempt of the current run; stale tags from prior runs are ignored) and `[job log](<url>#logs)` (resolved via the Jobs API). When neither resolves, the cell is empty rather than emitting stray pipes.

The footer of the per-group head is a single `[Workflow log](<run-url>)` line pointing at the workflow run page. Per-env heads (§5.1) instead use `[Job log]` because their URL targets the specific job's `#logs` anchor — different scope, different label.

## 6. Configuration

Workflow inputs:

| Input | Effect |
|---|---|
| `add-pr-comment` (global default `true`) | When `false`, suppresses both the env's head + plan tag for that environment. The env does not appear in the seed manifest either. |
| `pr-comment-group` (per env, optional) | When non-empty, the env is represented in that group's per-group head only — no standalone per-env head is created (the env's row in the per-group head's table is its summary surface). The env's own plan tag is still POSTed and is reachable from the per-group head's Links column. When empty (default), the env is "ungrouped" and gets its own per-env head with the full validation table. |

Triggering rules: comments are only posted when the workflow runs against a `pull_request` event whose action is not `closed` or `converted_to_draft`. Forks cannot post (the workflow guards against `github.event.pull_request.head.repo.fork == true` at the seed-job level).

Required token permission: `pull-requests: write` (and `issues: write` if the comment thread is a plain issue). Declared at the top of `terraform-ci-cd-default.yml`.

## 7. Ordering guarantees

On a fresh PR (run #1), the seed job POSTs in declared order, so the conversation timeline becomes:

```text
↑ older                                              ↓ newer
┌──────────────────────────────────────────────────────────┐
│  tf:head:group:<group-1>      (group summary head)       │
│  tf:head:group:<group-2>      (group summary head)       │
│  …                                                       │
│  tf:head:env:<env-a>          (per-env head)             │
│  tf:head:env:<env-b>          (per-env head)             │
│  …                                                       │
│  tf:tag:plan:<env-a>:run-id-N:attempt-1 (plan extract)   │
│  tf:tag:plan:<env-b>:run-id-N:attempt-1 (plan extract)   │
│  …                                                       │
│  <human reviewer comments interleaved chronologically>   │
└──────────────────────────────────────────────────────────┘
```

On subsequent runs, heads stay at their original `created_at` positions (PATCH preserves it). Plan tags are wiped per-env by the matrix delete-first step and re-POSTed at the bottom of the conversation. Order between heads never changes.

## 8. Concurrency caveat

When two workflow runs against the same PR overlap (e.g. retrigger before the first finishes), each run's matrix delete-first step will wipe plan tags from the env it's about to post for — including any in-flight tag the other run just POSTed. The result is some plan tags briefly disappearing and reappearing while both runs are in flight. Each run's aggregator scopes its anchor lookup to its own `run-id`, so the per-group head's Links column resolves to that run's tags rather than the competing run's.

Mitigation: set `concurrency: { group: pr-${{ github.event.pull_request.number }}-tf, cancel-in-progress: true }` on the caller workflow so a new run cancels any in-flight previous run. Without this, the noise is tolerable but not zero.

## 9. Degraded mode

If listing PR comments fails (network blip, rate limit, etc.), both [`pr-comment`](../pr-comment/) and [`pr-comments-reconcile`](../pr-comments-reconcile/) enter degraded mode:

- `upsert` → POST a fresh comment best-effort, even though it may duplicate an existing one.
- `delete` → no-op (we can't safely identify victims).
- Reconcile's GC pass → skipped entirely.

Duplicates from degraded runs self-heal on the next clean run: the matrix's per-env delete-first step wipes all plan tags for that env (any leftover duplicates included) before posting the new one. For heads, the upsert path sorts marker matches by `created_at` ASC, keeps the oldest, and deletes the rest in the same call.

## 10. Action references

| Spec section | Implementing action / step |
|---|---|
| §3.1 Seed phase | `seed-pr-comments` job in [`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml) calling [`pr-comments-reconcile`](../pr-comments-reconcile/) |
| §3.2 Matrix phase per-env head | matrix step "Upsert per-env head comment" calling [`pr-comment`](../pr-comment/) (mode `upsert`) |
| §3.2 Matrix phase plan tag | matrix step "Post per-env plan-extract tag" calling [`pr-comment`](../pr-comment/) (mode `upsert`, run-id-scoped marker) |
| §3.3 Aggregator phase | `pr-comment-aggregator` job in the workflow, calling [`aggregate-validation-summaries`](../aggregate-validation-summaries/) |
| §5.1, §5.2 body rendering | [`create-validation-summary`](../create-validation-summary/) outputs `head-summary` + `plan-extract` |
| §5.3 grouped body rendering | [`aggregate-validation-summaries`](../aggregate-validation-summaries/) `render_group_body` |
