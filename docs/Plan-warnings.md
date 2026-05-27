# Plan warnings on PRs

Authoritative spec for how `terraform` `Warning:` diagnostics flow from `init` / `validate` / `plan` to the PR conversation and the GitHub run-page UI.

Out of scope: errors (the existing `🧐 Validation outcome` steps already surface them), `tflint` warnings (separate tool, separate shape), force-unlock remediation hints (attached to `Error:` blocks, not `Warning:`).

## 1. Why

Terraform's `Warning:` diagnostics — deprecation notices, soft state-drift warnings, provider-level advisories — appear today only in the raw job log. Reviewers reading the PR conversation never see them, and nothing draws the eye in the GitHub UI. Deprecations harden into errors months later when the provider does a major release; the moment to act was when the warning first fired.

Goal: warnings are first-class on the PR. They're counted in the summary table, listed in a collapsible block under the plan extract, and emitted as `::warning` annotations so they appear inline in the Files-changed view next to the offending source line where context is available.

## 2. Data flow

```text
                         ┌─────────────────────────────────────┐
                         │  terraform-init                     │
                         │   tees stdout/stderr →              │
   each step             │   tf-init-console-output-<env>.txt  │
   captures its          └────────────┬────────────────────────┘
   own console                        │
                         ┌─────────────────────────────────────┐
                         │  terraform-validate                 │
                         │   tees → tf-validate-console-…txt   │
                         └────────────┬────────────────────────┘
                                      │
                         ┌─────────────────────────────────────┐
                         │  terraform-plan                     │
                         │   tees → tf-plan-console-output…txt │
                         └────────────┬────────────────────────┘
                                      │
                  ┌───────────────────▼─────────────────────────┐
                  │  parse-terraform-warnings (×3 per env)      │
   one call per   │   inputs: console-output-file, step-label   │
   step gets its  │   outputs: warning-count                    │
   own annotation │            warnings-markdown-file           │
   budget         │   side effect: emit ::warning::…            │
                  └───────────────────┬─────────────────────────┘
                                      │
                  ┌───────────────────▼──────────┐
                  │  concat-warnings-md          │
                  │   inline step concatenates   │
                  │   the three .md files in     │
                  │   init→validate→plan order   │
                  └───────────────────┬──────────┘
                                      │
            ┌─────────────────────────┴──────────────────┐
            ▼                                            ▼
┌──────────────────────────┐               ┌────────────────────────────┐
│ create-validation-summary│               │  capture-matrix-job-meta   │
│  inputs: warning-count,  │               │   (no code change — picks  │
│   warnings-markdown-file │               │   up new step outputs via  │
│  renders ⚠️ Warnings row │               │   toJSON(steps) automatically) │
│  + warnings collapser    │               └─────────────┬──────────────┘
└──────────────────────────┘                             │
                                                         ▼
                                       ┌─────────────────────────────────┐
                                       │  aggregate-validation-summaries │
                                       │   sums per-env warning counts   │
                                       │   across three step ids,        │
                                       │   renders grouped-table ⚠️ row  │
                                       └─────────────────────────────────┘
```

## 3. Warning-block grammar

What `parse-terraform-warnings` recognises as a warning:

```
^Warning: <title>\n
\n
  on <file> line <N>, in <resource>:\n            ← optional context block
   <line>: <code-excerpt>\n
\n
<message body — one or more wrapped lines>\n
\n
(and N more similar warnings elsewhere)\n         ← optional aggregator suffix
```

The parser uses a state machine:

- **Outside-block** → **Inside-block** on a line matching `^Warning: ` (note trailing space; `Warning:Foo` is not a diagnostic header in terraform's output).
- **Inside-block** → **Outside-block** on EOF, on the next `^Warning: ` / `^Error: ` / `^Plan: ` line, or on a blank line followed by a non-indented non-empty line that isn't itself a `(and N more …)` suffix.

For each block extract:

| Field | Source |
|---|---|
| `title` | text after `Warning: ` on the header line |
| `source_file`, `source_line` | first `^\s*on (?P<file>.+) line (?P<line>\d+)` line in the block; absent when terraform's warning isn't anchored to a file (e.g. provider-level deprecation) |
| `message` | remaining non-context body lines, leading/trailing whitespace trimmed, internal blank lines collapsed |
| `suppressed_count` | `N` from `(and (?P<n>\d+) more similar warnings elsewhere)` if present |

**`warning-count`** is the sum of `(1 + suppressed_count)` across all blocks — so when terraform shows one block with `(and 2 more)`, the count is `3`. This matches what reviewers expect ("there are N warnings in this plan").

Annotations are emitted once per block (terraform only prints file/line for the shown example; the suppressed N have no available context).

## 4. Annotation format

GitHub workflow-command shape:

```
::warning file=<rel-path>,line=<n>,title=<title>::<message>
```

With fallback when source context is missing:

```
::warning title=<title>::<message>
```

Escaping rules ([GitHub docs — workflow commands](https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions#setting-an-error-message)):

- `%` → `%25`
- `\r` → `%0D`
- `\n` → `%0A`
- `:` → `%3A` (in title/file attribute values only)
- `,` → `%2C` (in title/file attribute values only)

Paths are kept as-printed by terraform (relative to the terraform working directory). GitHub resolves them against the repo root for inline-annotation placement; when the working directory isn't the repo root the annotation still appears in the right-side run panel but doesn't anchor inline. Acceptable — anchoring is a bonus, not the contract.

GitHub silently dedupes identical annotations and caps each step at 10 warning annotations. Per-step extraction (one call after init, validate, plan) gives each its own 10 budget, so a noisy init no longer crowds out plan warnings.

## 5. 65k budgeting algorithm

The PR-comment body limit is 65536 chars. Warnings have priority over plan output: if the budget is tight, the plan extract gets trimmed first.

```
OVERHEAD     = 500          # H3 headers + <details> wrappers + blank lines
HARD_LIMIT   = 65000        # leave 536 chars headroom under 65536
WARN_CAP     = 60000        # warnings get most-but-not-all of the budget

warnings_md  = read warnings file (empty string if missing or 0 warnings)

if size(warnings_md) > WARN_CAP:
  # Drop trailing complete '---'-separated blocks until size <= WARN_CAP.
  # Block-level truncation keeps the visible warnings readable; we never
  # show a half-rendered diagnostic.
  warnings_md = drop_trailing_blocks(warnings_md, until=WARN_CAP)
  warnings_md += "\n\n_(truncated, N more warnings — see job log)_"

plan_budget  = max(0, HARD_LIMIT - OVERHEAD - size(warnings_md))
plan_extract = line_anchored_tail(plan_file, plan_budget)
```

`line_anchored_tail` is **not** `tail -c <budget>` — that cut can land mid-UTF-8 and corrupt the comment. Implementation: read the file, accumulate lines from the end while `size(buf) + size(next_line) + 1 ≤ budget`, then emit in order. This also fixes a latent UTF-8 truncation in `create-validation-summary/step_create_validation_summary.sh:162` that pre-dates this feature.

Edge cases:

- **`warnings_md` empty**: warnings collapser not rendered at all. The combined body is plan-block-only, identical to today's output.
- **`plan_budget` floors to 0**: plan-extract renders as an empty code fence inside the existing collapser; the warnings collapser carries the full diagnostic.
- **Both empty**: existing `Plan not available 🤷‍♀️` fallback in `render_plan_extract`.

## 6. Comment-shape integration

This feature extends [Workflow-pr-comments.md §5.1 and §5.2](Workflow-pr-comments.md#51-per-env-head) — it does not replace any existing shape.

### Per-env head (§5.1)

A new `⚠️ Warnings` row is inserted **between** the `📖 Plan` row and the `📊 Plan Details` row, rendered only when `warning-count > 0`:

```markdown
| ⚠️ | Warnings | <span title="Warnings from init+validate+plan">⚠️ 3</span> |
```

The row is absent when count is 0, missing, or `?` — consistent with the existing "absent when not interesting" convention for the Plan Details row.

### Per-env plan tag (§5.2)

A new `<details>` collapser is appended **after** the existing plan-block. It is not a sixth `<plan-block>` shape — the plan-block and warnings-block are siblings:

```markdown
### Terraform plan for environment: `<env>`

<plan-block>             ← existing five shapes, unchanged

<details><summary>⚠️ 3 warnings</summary>

### From terraform init
**Warning: Deprecated attribute**
- source: `.terraform/modules/foo/main.tf:176`

> The attribute "vm_agent_platform_updates_enabled" is deprecated. Refer to the
> provider documentation for details.

---

### From terraform plan
**Warning: Argument is deprecated**
- (and 2 more similar warnings elsewhere)

> This property has been renamed to `rbac_authorization_enabled`...

</details>
```

The collapser is absent when warning-count is 0 — no empty `<details>`.

### Per-group head (§5.3)

A `⚠️ Warnings` row is added to the grouped table, positioned between the step rows and the `📊 Plan details` row:

```markdown
| <span title="Warnings">⚠️</span> | Warnings | ⚠️ 3 | — | ⚠️ 1 |
```

The whole row is **omitted** when no env in the group has warnings — keeping ⚠️ a signal rather than a permanent fixture, and matching the per-env head which also suppresses the row at zero. When the row *is* shown (at least one env has warnings), each cell is `⚠️ N` for envs with warnings and em-dash `—` for the clean envs. Both warning surfaces (per-env head row + per-env plan-tag collapser) were already conditional; this aligns the grouped table with them.

## 7. Test scenarios

Per-action test suites (under `<action>/run_all_tests.sh`) cover:

`parse-terraform-warnings/`:

| Fixture | Expectation |
|---|---|
| `t01_no_warnings.log` | clean plan output; `warning-count=0`; markdown file empty (or absent) |
| `t02_single_warning_with_context.log` | one block with `on <file> line <N>`; 1 annotation with `file=`/`line=`; count=1 |
| `t03_single_warning_no_context.log` | one block without source context; 1 fallback annotation (no `file=`/`line=`); count=1 |
| `t04_aggregator_suppression.log` | block with `(and 2 more similar warnings elsewhere)`; count=3; 1 annotation |
| `t05_multiple_blocks.log` | three distinct categories; 3 annotations; correct sum |
| `t06_warning_then_error.log` | `Warning:` followed by `Error:`; error doesn't bleed into warning body |
| `t07_non_ascii_message.log` | UTF-8 in body; markdown is valid UTF-8; annotation message round-trips |
| `t08_empty_file.log` | empty file; count=0; no crash |
| `t09_init_provider_deprecation.log` | real-shape init log with provider warning at top level |

`create-validation-summary/` test additions:

- Warnings row appears with count > 0; absent with count = 0 / unset / `?`.
- Warnings collapser appended after plan-block; absent when warnings markdown file empty.
- Combined body stays under 65000 bytes for: small warnings + huge plan; huge warnings + small plan; both huge (warnings preserved, plan trimmed).
- UTF-8 boundary preserved (warning body with multi-byte char near the cut point).
- Legacy `summary` output includes warnings collapser.

`aggregate-validation-summaries/` test additions:

- Per-env meta files with varying warning counts render grouped table cells correctly.
- Mixed envs (some with warnings, some without) — row shown, clean envs render `—`.
- All-zero group → whole Warnings row omitted (and likewise when no parse-warnings step entries are present at all).
- Plan details row omitted when no env in the group has plan data.
- Sum across init/validate/plan step ids when some are missing/zero in meta.

## 8. ARG_MAX caveat

`capture-matrix-job-meta` captures every step's outputs via `toJSON(steps)` ([capture-matrix-job-meta/action.yml:64-71](../capture-matrix-job-meta/action.yml)). A prior incident documented in that file: when `plan-extract` (~65k) was exported into the environment, the next fork's envp blew past `ARG_MAX` and the metadata-capture step died with `E2BIG`.

Constraint for this feature: **never expose warnings-markdown *content* as a step output.** Only paths and small integers go through step outputs. The warnings markdown lives in `${GITHUB_WORKSPACE}/tf-warnings-<env>-<step>.md` and is referenced by path; `create-validation-summary` reads the file from disk, never from env.

## 9. Out of scope / follow-ups

- Force-unlock remediation hints. They attach to `Error:` blocks (and look like multi-line shell snippets, not `Warning:` diagnostics) — would need a separate parser.
- Warnings from `tflint` and other non-terraform-CLI tools. Their output formats differ; if surfacing them is wanted later, add per-tool parsers and one more `parse-*-warnings` invocation per env.
- Audit the rest of the codebase for `tail -c` cuts that could land mid-UTF-8. This feature fixes only the one site it touches.
