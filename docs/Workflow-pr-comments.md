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
| `<!-- tf:tag:plan:<env>:run-id-<run-id> -->` | Tag | One per env per run | Matrix job for that env |

Marker name conventions:

- Heads: `tf:head:<scope>:<name>` where `<scope>` is one of `group` / `env`.
- Tags: `tf:tag:<kind>:<scope-key>:run-id-<run-id>` — the run-id token is what the GC sweep matches on to keep current-run tags.

Markers are treated as opaque substrings by the underlying actions: matching is `body.contains(marker)`. The exact format is enforced by convention in this doc, not by the actions themselves — any unique-enough string works.

## 3. Lifecycle of a single workflow run

```text
                          ┌──────────────────────────────────────────────┐
                          │  Seed phase (top of workflow, before matrix) │
                          │                                              │
   create-matrix ───────► │  seed-pr-comments job:                       │
                          │   - reconcile heads (POST/PATCH per marker)  │
                          │   - GC stale plan tags (run-id != current)   │
                          └─────────────────┬────────────────────────────┘
                                            │
                          ┌─────────────────▼────────────────────────────┐
                          │  Matrix jobs (parallel, one per env)         │
                          │                                              │
                          │   - PATCH `tf:head:env:<env>` with results   │
                          │   - POST `tf:tag:plan:<env>:run-id-<id>`     │
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

Heads are processed in declared order — group heads first, env heads after. On a fresh PR, this means group heads get earlier `created_at` than env heads, so the conversation order is group summaries above per-env. On re-runs the existing heads are PATCHed in place to a `⏳ Running…` placeholder body.

In the same call, a GC sweep deletes every comment matching marker-prefix `<!-- tf:tag:plan:` whose body does not also contain `run-id-<current-run-id>` — i.e. plan tags from prior runs. The seed job is added to `terraform-ci-cd`'s `needs:` chain so matrix jobs can't race ahead and POST their head updates before the seed manifest lands.

### 3.2 Matrix phase

Each env's matrix job runs the validation pipeline, calls [`create-validation-summary`](../create-validation-summary/) to render two bodies, then posts both:

- **Head** — `pr-comment` upsert with marker `<!-- tf:head:env:<env> -->`. Since the seed job already POSTed this marker, this resolves to a PATCH that replaces the `⏳ Running…` placeholder with the validation table + footer.
- **Plan tag** — `pr-comment` upsert with marker `<!-- tf:tag:plan:<env>:run-id-<run-id> -->`. The marker is run-scoped so it never matches anything from the seed phase or prior runs; effectively a POST-fresh.

Both calls are guarded by `always()` so the head refreshes even when an earlier step (init, tflint, etc.) failed.

### 3.3 Aggregator phase

[`aggregate-validation-summaries`](../aggregate-validation-summaries/) downloads all `matrix-job-meta-*.json` artifacts, builds the per-group rolled-up table, and upserts each `tf:head:group:<group>` head with the final rendered body. Seed job has already pre-allocated these heads, so the upsert resolves to a PATCH (preserving `created_at`).

## 4. Re-run behavior

### Heads

1. Seed phase PATCHes each head body to `⏳ Running (run #N)…` (existing comment, content-hash differs → PATCH lands).
2. Matrix / aggregator phase PATCHes each head body to its final state.
3. If the final body's content-hash matches the existing comment's embedded hash (no-op run), the PATCH is skipped — subscribers are not re-pinged. See §5.

### Tags

1. Seed phase GC sweep deletes plan tags from prior runs.
2. Matrix phase POSTs fresh plan tags (their markers carry the current run id).
3. Next run repeats: GC deletes these, POSTs new ones.

The net visual effect on a re-run: heads stay in place but their content briefly shows "Running" then updates to final; plan tags disappear, then new ones appear at the bottom of the conversation.

## 5. Content-hash short-circuit

Every body the action writes carries an inline marker `<!-- comment-hash:<sha256> -->` on line 2, computed from the body content with a single trailing newline normalized away. On upsert, if the existing comment's embedded hash matches the hash of the new body, the PATCH call is skipped entirely.

Effect: when nothing has changed (e.g. CI re-run on the same commit), no `updated_at` churn, no notification emails to PR subscribers. Subscribers only get pinged when a comment's content actually changed.

## 6. Comment body shapes

### 6.1 Per-env head

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

The Links row sits at the bottom of the table — same shape as the per-group head's Links column (§6.3) so reviewers learn one navigation pattern. `[log extract]` anchors at this env's plan tag (§6.2) for the current run; `[job log]` anchors at this matrix job's `#logs`. The Links row replaces the standalone `[Job log]` footer that older versions emitted below the table.

The Links row is rendered by `create-validation-summary` when its `plan-tag-comment-id` input is supplied. The matrix calls `create-validation-summary` twice for ungrouped envs: once initially to get `plan-extract` (used to POST the plan tag), then again with the resulting comment id supplied to re-render `head-summary` with the Links row. Grouped envs only call it once (their `head-summary` output is unused — see §6.1 grouped mode below).

Status cells: `` `success` `` for successful steps, `<kbd>failure</kbd>` / `<kbd>cancelled</kbd>` / `<kbd>skipped</kbd>` / `<kbd></kbd>` (empty outcome) for everything else.

Plan time row is always emitted in ungrouped mode. Renders the upstream `terraform-plan@v0` `plan-time` output as `` `mm:ss` `` inside `<span title="mm:ss (minutes:seconds)">`; the tooltip surfaces the unit on desktop hover. Defaults to `N/A` when the upstream action didn't supply a value.

Plan Details row is rendered only when `include-plan-details=true`. Shape:

```markdown
| 📊 | Plan Details | <span title="Resources to be added">`💫 1` add</span><br><span title="Resources to be changed">`🛠️ 0` change</span><br><span title="Resources to be destroyed">`💥 0` destroy</span> |
```

Optional badges (move / import / remove) are appended `<br>`-separated when the count is non-zero.

#### Grouped mode

When `pr-comment-group` is non-empty, the env has **no per-env head at all** — its row in the per-group head's table is the env's summary surface, and its plan output still gets its own per-env plan tag (§6.2). The seed manifest excludes grouped envs from per-env head seeding, and the matrix-job step that PATCHes the per-env head is skipped via an `if:` guard on `matrix.vars.pr-comment-group`. Reviewers reach the grouped env's plan output via the per-group head's Links column.

### 6.2 Per-env plan tag

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

### 6.3 Per-group head

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

Links cells contain up to two `<br>`-separated lines: `[log extract](#issuecomment-<id>)` (anchors to the env's plan tag for the current run, located by the `tf:tag:plan:<env>:run-id-<run-id>` marker substring) and `[job log](<url>#logs)` (resolved via the Jobs API). When neither resolves, the cell is empty rather than emitting stray pipes.

The footer of the per-group head is a single `[Workflow log](<run-url>)` line pointing at the workflow run page. Per-env heads (§6.1) instead use `[Job log]` because their URL targets the specific job's `#logs` anchor — different scope, different label.

## 7. Configuration

Workflow inputs:

| Input | Effect |
|---|---|
| `add-pr-comment` (global default `true`) | When `false`, suppresses both the env's head + plan tag for that environment. The env does not appear in the seed manifest either. |
| `pr-comment-group` (per env, optional) | When non-empty, the env is included in that group's per-group head. The env's own head still exists but omits the validation table (it lives on the group head). When empty (default), the env is "ungrouped" and its head carries the full table. |

Triggering rules: comments are only posted when the workflow runs against a `pull_request` event whose action is not `closed` or `converted_to_draft`. Forks cannot post (the workflow guards against `github.event.pull_request.head.repo.fork == true` at the seed-job level).

Required token permission: `pull-requests: write` (and `issues: write` if the comment thread is a plain issue). Declared at the top of `terraform-ci-cd-default.yml`.

## 8. Ordering guarantees

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
│  tf:tag:plan:<env-a>:run-id-N (plan extract tag)         │
│  tf:tag:plan:<env-b>:run-id-N (plan extract tag)         │
│  …                                                       │
│  <human reviewer comments interleaved chronologically>   │
└──────────────────────────────────────────────────────────┘
```

On subsequent runs, heads stay at their original `created_at` positions (PATCH preserves it). Plan tags from prior runs are GC'd and new ones POSTed at the bottom of the conversation. Order between heads never changes.

## 9. Concurrency caveat

When two workflow runs against the same PR overlap (e.g. retrigger before the first finishes), the second run's seed-job GC pass will delete the first run's plan tags (their run-id is no longer "current"). The first run's later POST may then land at an unexpected position, or — if the first run's matrix job has already completed and POSTed — its plan tag is deleted before being read.

Mitigation: set `concurrency: { group: pr-${{ github.event.pull_request.number }}-tf, cancel-in-progress: true }` on the caller workflow so a new run cancels any in-flight previous run. Without this, the noise is tolerable but not zero.

## 10. Degraded mode

If listing PR comments fails (network blip, rate limit, etc.), both [`pr-comment`](../pr-comment/) and [`pr-comments-reconcile`](../pr-comments-reconcile/) enter degraded mode:

- `upsert` → POST a fresh comment best-effort, even though it may duplicate an existing one.
- `delete` → no-op (we can't safely identify victims).
- GC pass → skipped entirely.

Duplicates from degraded runs self-heal on the next clean run: the upsert path always sorts marker matches by `created_at` ASC, keeps the oldest, and deletes the rest in the same call.

## 11. Action references

| Spec section | Implementing action / step |
|---|---|
| §3.1 Seed phase | `seed-pr-comments` job in [`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml) calling [`pr-comments-reconcile`](../pr-comments-reconcile/) |
| §3.2 Matrix phase per-env head | matrix step "Upsert per-env head comment" calling [`pr-comment`](../pr-comment/) (mode `upsert`) |
| §3.2 Matrix phase plan tag | matrix step "Post per-env plan-extract tag" calling [`pr-comment`](../pr-comment/) (mode `upsert`, run-id-scoped marker) |
| §3.3 Aggregator phase | `pr-comment-aggregator` job in the workflow, calling [`aggregate-validation-summaries`](../aggregate-validation-summaries/) |
| §5 Content-hash | implemented inside [`pr-comment`](../pr-comment/) and [`pr-comments-reconcile`](../pr-comments-reconcile/) (`_compute_body_hash` + `<!-- comment-hash:<sha> -->` marker on line 2 of every written body) |
| §6.1, §6.2 body rendering | [`create-validation-summary`](../create-validation-summary/) outputs `head-summary` + `plan-extract` |
| §6.3 grouped body rendering | [`aggregate-validation-summaries`](../aggregate-validation-summaries/) `render_group_body` |
