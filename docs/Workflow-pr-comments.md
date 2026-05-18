# PR comments

Authoritative spec for all pull-request comments produced by [`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml).

Out of scope: deployment-environment UI, status checks, workflow run summaries — this doc is only about the comments posted on the PR conversation timeline.

## 1. When are comments posted

Comments are only posted when the workflow runs against a `pull_request` event whose action is not `closed` or `converted_to_draft`. The mechanism is identical regardless of which job posts the comment: each comment carries a deterministic Markdown heading (the "prefix") and every post does a delete-by-prefix + post — so comments update in place across re-runs, never duplicate.

Comments are suppressed when either:

- the workflow input `add-pr-comment: false` is set (globally), or
- a per-environment `add-pr-comment: false` override is set in `environments-yml` (per env).

Both controls only affect the per-environment comments. The per-group reconcile job runs unconditionally on PR events; see §6 for why and the cost analysis.

## 2. The two comment families

| Family | Identity prefix | Posted by | Cardinality |
|---|---|---|---|
| Per-environment | `` ### Terraform validation summary for environment: `<env>` `` | matrix job for that env, via `comment-on-pr@v2` | one per env per workflow run |
| Per-group | `` ### Terraform validation summary for group: `<group>` `` | `pr-comment-aggregator` job, via `aggregate-validation-summaries` | one per distinct non-empty `pr-comment-group` value |

Both families share the prefix-based identity contract: the family prefix uniquely identifies the comment within a PR, the action lists existing comments via `gh api`, deletes any whose body starts with the matching specific prefix, and posts the freshly-built body. Bodies always start with their full prefix (heading line) so substring matching is unambiguous.

Per-env prefixes use backtick-delimited env names so partial matches can't collide (e.g. `dev` doesn't match `dev-2`).

## 3. Per-environment comments

Each matrix job (one per env in `environments-yml`) runs `create-validation-summary` followed by `comment-on-pr@v2`. The body shape depends on whether the env declares a `pr-comment-group`.

### 3.1 Ungrouped mode (default)

The env has no `pr-comment-group` set (or its value is `""`). This is the historical behavior and the contract that backwards-compat tests pin down.

Raw markdown:

````markdown
### Terraform validation summary for environment: `dev`
|  | Step | Result |
|:---:|---|---|
| ⚙️ | Initialization | `success` |
| 🔒 | Lock file | `success` |
| 🖌 | Format and Style | `success` |
| ✔ | Validate | `success` |
| 🧹 | TFLint | `success` |
| 📖 | Plan | `success` |

<details><summary>Plan: 7 changes ℹ️</summary>

```terraform
…
```

</details>

[Job log](https://github.com/owner/repo/actions/runs/123/job/456#logs)
````

Rendered:

> ### Terraform validation summary for environment: `dev`
>
> |  | Step | Result |
> |:---:|---|---|
> | ⚙️ | Initialization | `success` |
> | 🔒 | Lock file | `success` |
> | 🖌 | Format and Style | `success` |
> | ✔ | Validate | `success` |
> | 🧹 | TFLint | `success` |
> | 📖 | Plan | `success` |
>
> <details><summary>Plan: 7 changes ℹ️</summary>
>
> ```terraform
> …
> ```
>
> </details>
>
> [Job log](#)

Cell formatting in the Result column:

| Step outcome | Cell value |
|---|---|
| `success` | `` `success` `` (Markdown code-span) |
| anything else (`failure`, `cancelled`, `skipped`, `''`) | `<kbd>failure</kbd>` etc. — the raw outcome string inside a `<kbd>` tag |

#### Plan details row (optional)

When `include-plan-details` is true (the workflow wires this as `steps.parse-plan.outcome == 'success'`), an extra row is appended:

```markdown
| 📊 | Plan Details | <span title="Resources to be added">`💫 0` add</span><br><span title="Resources to be changed">`🛠️ 0` change</span><br><span title="Resources to be destroyed">`💥 0` destroy</span> |
```

Rules:

- `add`, `change`, `destroy` lines are always present.
- `move`, `import`, `remove` lines are appended only when their respective count is non-zero, with emojis `🔀`, `📥`, `⛓️‍💥`.
- Lines are separated by `<br>`. Each badge is wrapped in `<span title="…">…</span>` with a human-readable description as the tooltip.

#### Plan extract

The plan-extract block has four rendering modes, selected by the `plan-count-total` and `plan-has-output-only-changes` inputs (typically sourced from `parse-terraform-plan`'s `count-total` and `has-output-only-changes` outputs):

| `plan-count-total` | `plan-has-output-only-changes` | Rendered block |
|---|---|---|
| numeric `0` | `false` | `Plan: no changes ✅` (plain text, no `<details>`) |
| numeric `0` | `true` | `<details><summary>Plan: output-only changes ℹ️</summary>` + code-fenced plan (resource counts are zero but the Changes-to-Outputs section is the actual content) |
| numeric `N>0` | (any) | `<details><summary>Plan: <N> changes ℹ️</summary>` + code-fenced plan, last 65k chars |
| missing / `?` | (any) | `<details><summary>Show Plan (last 65k characters)</summary>` + code-fenced plan (legacy fallback for cases where count parsing failed) |

When no plan output file is available at all (regardless of either input), the literal `Plan not available 🤷‍♀️` is rendered instead.

Source precedence for the plan output itself:

1. `plan-txt-output-file` (the `-no-color` output Terraform writes when the plan succeeds). Read via `tail -c 65000`.
2. `plan-console-file` (captured stdout, used when the plan failed and #1 doesn't exist). Stripped of leading `… Refreshing state…` lines via `sed -n '/Terraform used the selected providers to generate the following execution/,$p'` before being capped at 65k chars.

#### Footer

```markdown
[Job log](<run_url>/job/<check_run_id>#logs)
```

A single bare Markdown link. Pusher / event / workflow data is intentionally omitted — it's already visible in the PR conversation timeline header and on the linked job page, so restating it on every comment was pure noise.

### 3.2 Grouped mode

The env has `pr-comment-group: "<name>"` set. The per-env comment loses its validation table — that data is now in the per-group comment (§4). The plan extract block, the `Plan not available 🤷‍♀️` short-circuit, and the footer behave identically to ungrouped mode. No back-pointer to the group summary is rendered — the grouped summary itself anchor-links to every per-env comment via its Links row (§4.5), so navigation goes the natural top-down direction.

Raw markdown (no-changes example):

````markdown
### Terraform validation summary for environment: `sub-a-dev`

Plan: no changes ✅

[Job log](#)
````

Rendered:

> ### Terraform validation summary for environment: `sub-a-dev`
>
> Plan: no changes ✅
>
> [Job log](#)

For envs with changes, the body becomes `<details><summary>Plan: <N> changes ℹ️</summary>…</details>` (same as §3.1). For envs where the plan has output-only changes, `<details><summary>Plan: output-only changes ℹ️</summary>…</details>`. For envs where no plan output file exists, `Plan not available 🤷‍♀️`.

The prefix is identical to ungrouped mode. This is intentional: callers who toggle grouping on/off get in-place comment updates rather than orphan accumulation.

## 4. Per-group comments

Every PR run triggers the `pr-comment-aggregator` job once. It downloads all `matrix-job-meta-*` artifacts (uploaded by `capture-matrix-job-meta`), partitions envs by `pr-comment-group`, and emits one comment per distinct non-empty group.

### 4.1 Comment shape

Raw markdown:

````markdown
### Terraform validation summary for group: `dev`

|  | Step | sub-a-dev | sub-b-dev | sub-c-dev |
|:---:|---|:---:|:---:|:---:|
| <span title="Initialization">⚙️</span> | Initialization | <span title="success">✅</span> | <span title="success">✅</span> | <span title="failure">❌</span> |
| <span title="Lock file">🔒</span> | Lock file | <span title="success">✅</span> | <span title="success">✅</span> | <span title="skipped">⏭️</span> |
| <span title="Format and Style">🖌</span> | Format and Style | <span title="success">✅</span> | <span title="success">✅</span> | <span title="skipped">⏭️</span> |
| <span title="Validate">✔</span> | Validate | <span title="success">✅</span> | <span title="success">✅</span> | <span title="skipped">⏭️</span> |
| <span title="TFLint">🧹</span> | TFLint | <span title="success">✅</span> | <span title="success">✅</span> | <span title="skipped">⏭️</span> |
| <span title="Plan">📖</span> | Plan | <span title="success">✅</span> | <span title="success">✅</span> | <span title="skipped">⏭️</span> |
| <span title="Plan details">📊</span> | Plan details | <div align="left"><span title="Resources to be added">`💫 0` add</span><br><span title="Resources to be changed">`🛠️ 0` change</span><br><span title="Resources to be destroyed">`💥 0` destroy</span></div> | <div align="left"><span title="Resources to be added">`💫 1` add</span><br><span title="Resources to be changed">`🛠️ 0` change</span><br><span title="Resources to be destroyed">`💥 0` destroy</span><br><span title="Resources to be imported">`📥 2` import</span></div> | N/A |
| <span title="Links">🔗</span> | Links | [log extract](#issuecomment-…)<br>[job log](https://…) | [log extract](#issuecomment-…)<br>[job log](https://…) | [job log](https://…) |

[Job log](https://…)
````

Rendered:

> ### Terraform validation summary for group: `dev`
>
> |  | Step | sub-a-dev | sub-b-dev | sub-c-dev |
> |:---:|---|:---:|:---:|:---:|
> | <span title="Initialization">⚙️</span> | Initialization | <span title="success">✅</span> | <span title="success">✅</span> | <span title="failure">❌</span> |
> | <span title="Lock file">🔒</span> | Lock file | <span title="success">✅</span> | <span title="success">✅</span> | <span title="skipped">⏭️</span> |
> | <span title="Format and Style">🖌</span> | Format and Style | <span title="success">✅</span> | <span title="success">✅</span> | <span title="skipped">⏭️</span> |
> | <span title="Validate">✔</span> | Validate | <span title="success">✅</span> | <span title="success">✅</span> | <span title="skipped">⏭️</span> |
> | <span title="TFLint">🧹</span> | TFLint | <span title="success">✅</span> | <span title="success">✅</span> | <span title="skipped">⏭️</span> |
> | <span title="Plan">📖</span> | Plan | <span title="success">✅</span> | <span title="success">✅</span> | <span title="skipped">⏭️</span> |
> | <span title="Plan details">📊</span> | Plan details | <div align="left"><span title="Resources to be added">`💫 0` add</span><br><span title="Resources to be changed">`🛠️ 0` change</span><br><span title="Resources to be destroyed">`💥 0` destroy</span></div> | <div align="left"><span title="Resources to be added">`💫 1` add</span><br><span title="Resources to be changed">`🛠️ 0` change</span><br><span title="Resources to be destroyed">`💥 0` destroy</span><br><span title="Resources to be imported">`📥 2` import</span></div> | N/A |
> | <span title="Links">🔗</span> | Links | [log extract](#)<br>[job log](#) | [log extract](#)<br>[job log](#) | [job log](#) |
>
> [Job log](#)

### 4.2 Column ordering

Envs are sorted alphabetically by env name within the group. Stable across re-runs.

### 4.3 Status emoji cells

Every status cell wraps an emoji in `<span title="<outcome>">…</span>` so desktop browsers surface a tooltip naming the outcome. Mapping:

| Step outcome | Emoji | `title` attribute |
|---|:---:|---|
| `success` | ✅ | `success` |
| `failure` | ❌ | `failure` |
| `cancelled` | 🚫 | `cancelled` |
| `skipped` | ⏭️ | `skipped` |
| `''` / step not present in env's metadata | — (em dash) | `not applicable` |

The column-1 step emojis (⚙️ 🔒 🖌 ✔ 🧹 📖 📊 🔗) are also wrapped in `<span title="<step-name>">…</span>` for desktop hover discoverability.

Tooltips degrade silently: GitHub's mobile apps don't render `title` attributes, and screen readers don't reliably announce them. The emoji itself carries the user-facing meaning; tooltips are an enhancement.

### 4.4 Plan details row

Same multi-line content as the ungrouped Plan Details row (§3.1) — one `<br>`-separated line per non-zero category, with `add` / `change` / `destroy` always shown. Each cell wraps its badge stack in `<div align="left">…</div>` so the badges anchor to the left edge of the otherwise center-aligned column. `N/A` when the plan didn't run or `parse-terraform-plan` couldn't extract counts for that env.

### 4.5 Links row

Per-env cell, zero to two Markdown links, one per line, separated by `<br>`. Each line is independently optional:

- `log extract` — anchor to the env's per-env comment (§3.2) using GitHub's `#issuecomment-<id>` fragment. Present only when the resolver matched the env's per-env comment in the PR via `gh api repos/<owner>/<repo>/issues/<n>/comments`.
- `job log` — direct URL to the env's matrix job log on the current workflow run, with `#logs` anchor. Present only when the resolver matched the env's matrix job in the current run via `gh api repos/<owner>/<repo>/actions/runs/<run_id>/jobs`. Matching uses the GitHub-rendered job name pattern `^Terraform \(<env>\)$`.

Each line is omitted independently when its source isn't resolvable. When *both* lines would be omitted, the cell is rendered as empty rather than as a stray pipe pair — keeping the table tidy. The grouped table itself always posts; the Links column degrades gracefully.

Per-env-comment lookup edge cases:

- **0 matches** — `log extract` line omitted (common when the per-env `comment-on-pr` step failed or the env's matrix job failed before it ran).
- **1 match** — `log extract` line points at `#issuecomment-<id>`.
- **2+ matches** (race / stale duplicates not yet cleaned by `comment-on-pr@v2`'s delete-by-prefix) — `log extract` points at the comment with the highest numeric `id` (GitHub IDs are monotonic, so highest = newest). A warning naming the env is logged.

If the Jobs API call itself fails (rate limit, transient 5xx), every env's `job log` line is dropped and a single warning is logged; the grouped table still renders.

### 4.6 Reconcile algorithm

The aggregator action runs every PR event. Its job is to make the set of group comments on the PR equal to the desired set computed from the current run's metadata:

1. **Build desired set.** Read every `matrix-job-meta-*.json` artifact downloaded by `actions/download-artifact@v4`. Group entries by `matrix_context.vars.pr-comment-group`, dropping empty-string values. The desired set may be empty (no env declares a group).
2. **List PR + run state.** Two paginated `gh api` calls:
    - `repos/$REPO/issues/$PR/comments` — from the result, build two maps:
      - existing group comments (body starts with `### Terraform validation summary for group: `)
      - existing per-env comments (body starts with the exact backtick-delimited per-env prefix from §2)
    - `repos/$REPO/actions/runs/$RUN_ID/jobs` — used to resolve each env's matrix job URL for the Links row (§4.5). Match by GitHub-rendered job name pattern `^Terraform \(<env>\)$`. Either call may fail independently: a Jobs API failure drops `job log` links from every Links cell; a PR-comments failure triggers degraded mode (skip reconcile delete pass, still post fresh bodies, will re-reconcile on next run).
3. **Render desired.** For each desired group, sort envs alphabetically and build the prefix + body per §4.1. The Links row uses the per-env comment map (step 2) to resolve `log extract` anchors.
4. **Reconcile (delete pass).** Walk the existing group comments:
    - prefix not in desired set → DELETE (orphan from a removed/renamed group)
    - prefix in desired set → DELETE (will be reposted with fresh body in step 5)
5. **Post pass.** For each desired group, POST the rendered body.
6. **Emit `groups-processed-json`** for logs/tests.

Four scenarios collapse into the same path:

| Desired groups | Existing group comments | Outcome |
|---|---|---|
| 0 | 0 | no-op |
| 0 | N | sweep N orphans (caller disabled grouping) |
| M | 0 | post M (first run with grouping enabled) |
| M | N (any overlap) | sweep mismatched, repost matched, post new |

Self-healing: at most one PR run is needed after toggling grouping on/off or renaming groups; no manual cleanup procedure.

#### Degraded mode

If `gh api` fails (rate limit, transient 5xx), the action logs a warning, treats the existing-comments map as empty, renders bodies with Links rows showing `job log` only (no `log extract` anchors), and attempts to post. Subsequent runs reconcile any duplicates left behind. The grouped table itself always renders.

#### Failure isolation

The aggregator job uses `actions/download-artifact@v4` with `continue-on-error: true` because the empty-artifact case (no envs uploaded metadata) is valid input — sweep-only mode still needs to run. The action also tolerates malformed individual metadata files: parse errors are logged, the file is skipped, the env is reported with `not applicable` cells in the table.

## 5. Configuration reference

All flags that influence PR-comment behavior. Boolean inputs are passed through `matrix.vars` as the strings `"true"` / `"false"`.

### Workflow inputs

| Input | Type | Default | Effect |
|---|---|---|---|
| `add-pr-comment` | bool | `true` | When `false`, suppresses the per-env comment for every env. Per-group comments still render (set per-env `add-pr-comment: false` and use the per-env override if you need different behavior). |
| `pr-comment-group` | string | `""` | Global default for the per-env `pr-comment-group` field. Rarely useful (you almost always want per-env values). |

### Per-environment fields (`environments-yml`)

| Field | Type | Default | Effect |
|---|---|---|---|
| `add-pr-comment` | bool | inherits workflow input | Per-env override of the comment suppression. |
| `pr-comment-group` | string | `""` (or workflow input) | When non-empty, the env's per-env comment switches to the §3.2 "grouped" shape and the env contributes a column to the matching per-group comment (§4). Envs sharing the same value are collapsed into one group comment. |

### Comment suppression matrix

| `add-pr-comment` workflow | `add-pr-comment` env | Per-env comment posted? |
|:---:|:---:|:---:|
| `true` | unset | yes |
| `true` | `true` | yes |
| `true` | `false` | no |
| `false` | unset | no |
| `false` | `true` | yes |
| `false` | `false` | no |

The per-group comment is independent of `add-pr-comment`: as long as any env declares a `pr-comment-group`, the aggregator emits the corresponding group comment regardless of whether per-env comments are suppressed. This is intentional — the group comment is the place where a reviewer expects the high-level status to surface, even if individual envs hide their plan extracts.

## 6. Backwards-compatibility contract

These invariants are pinned by test coverage and must hold across any future change to comment-rendering code:

1. **Byte-level shape is pinned by tests.** Both modes' comments have byte-level golden tests in `create-validation-summary/run_all_tests.sh`. Any deliberate change to comment rendering must update both the test golden values AND this spec doc in the same change — the tests exist to catch accidental drift, not to lock the format forever. The v0.23 → v0.24 footer/pointer/plan-block changes are an example of a deliberate, test-and-spec-tracked format update.
2. **Prefix continuity.** The per-env prefix is identical in both ungrouped and grouped modes: `` ### Terraform validation summary for environment: `<env>` ``. Toggling `pr-comment-group` on/off for an env produces an in-place update of its per-env comment, never an orphan.
3. **No new required inputs.** All grouped-mode additions and condensing additions default to empty / off. A caller that touches nothing sees no behavioral change beyond the agreed format updates (which apply uniformly).
4. **Per-env metadata artifact format unchanged.** The aggregator consumes the same `matrix-job-meta-*` artifacts uploaded by `capture-matrix-job-meta` that the existing `automerge` job consumes. No new artifact format, no new permission grants.
5. **`@v0` rolling tag.** New actions and outputs (e.g. `aggregate-validation-summaries`, `parse-terraform-plan`'s `count-total`) ship on `@v0` along with all other actions in this repo; calling repos on `@v0` adopt the feature automatically on release. Adoption of grouping is opt-in via the per-env field; no caller is forced into grouping.

## 7. Action and job references

Quick map from spec section to implementing code:

| Section | Implementing code |
|---|---|
| §3.1 Ungrouped per-env comment body | [`create-validation-summary/step_create_validation_summary.sh`](../create-validation-summary/step_create_validation_summary.sh) |
| §3.2 Grouped per-env comment body | same file, branched on `pr-comment-group` |
| §3 Posting/replacing per-env comments | [`dsb-norge/github-actions/ci-cd/comment-on-pr@v2`](https://github.com/dsb-norge/github-actions/tree/main/ci-cd/comment-on-pr) |
| §4 Per-group comment body + reconcile | [`aggregate-validation-summaries/step_aggregate.sh`](../aggregate-validation-summaries/step_aggregate.sh) |
| §4.6 Source artifacts | [`capture-matrix-job-meta/step_capture.sh`](../capture-matrix-job-meta/step_capture.sh) |
| §5 Input plumbing & per-env defaults | [`create-tf-vars-matrix/action.yml`](../create-tf-vars-matrix/action.yml) |
| Workflow wiring | [`.github/workflows/terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml) |
