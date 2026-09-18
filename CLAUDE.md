# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository overview

A collection of composite GitHub Actions and reusable workflows for terraform projects used by other DSB repositories. The two main consumption points are:

- **`.github/workflows/terraform-ci-cd-default.yml`** — the reusable CI/CD workflow that orchestrates init → fmt → validate → lint → plan → apply (→ destroy-plan → destroy) with a `📊` PR comment summary, per-operation tag comments, a per-env `$GITHUB_STEP_SUMMARY` block plus a run-level rollup, and optional `🔒` lock file verification and PR auto-merge. The PR-comment model is `docs/Workflow-pr-comments.md`; apply/destroy reporting and its 29 indexed pitfalls are `docs/Apply-and-destroy-reporting.md`.
- **Composite actions** in top-level directories (e.g. `terraform-init/`, `terraform-plan/`, `verify-terraform-lock/`, `create-validation-summary/`, …).

Calling repos pin against either the rolling major tag (`@v0`) or a specific minor (`@v0.21`). The major tag is force-moved on every minor release, so changes shipped on `@v0` are immediately picked up by all calling repos — be mindful when touching anything in here.

## Architecture

### The matrix builder is the center of gravity

`create-tf-vars-matrix/action.yml` is the spine of the default workflow. It takes the workflow's full `inputs` JSON plus the user's `environments-yml` and produces a job matrix where each row is one fully-resolved environment configuration.

Two patterns to know:

- **Generic input-forwarding loop** (around `create-tf-vars-matrix/action.yml:93-99`): every top-level workflow input is automatically propagated into each env's `matrix.vars`, with per-env override available for free if the user sets the same key inside `environments-yml`. **Adding a new boolean/string workflow input does NOT require matrix-builder changes** — just add it to the `REQ_FIELDS` and `NOT_EMPTY_FIELDS` validators near the end of the action and to the JSON test fixtures.
- **YAML fields** (`extra-envs-yml`, `goals-yml`, `terraform-init-additional-dirs-yml`, `pr-auto-merge-*-yml`) get explicit handling — some default to global, others merge global with per-env.

Boolean inputs end up as strings in the matrix (e.g. `matrix.vars.add-pr-comment == 'true'`). The exception is `allow-failing-terraform-operations`, which is explicitly normalized to a JSON boolean so the workflow can `fromJSON()` it. Follow this pattern only if the value needs `fromJSON()`; otherwise plain string comparison is fine.

### Validation-step + outcome-step pattern

Validation steps (init, fmt, validate, lint, plan, verify-lock) all use the same pattern in the workflow:

1. The step itself runs with `continue-on-error: true` so the job continues regardless.
2. Its outcome is forwarded to `create-validation-summary` which posts a 📊 PR comment row.
3. A separate `🧐 Validation outcome: <step>` step later in the job hard-fails on non-success, respecting `matrix.vars.allow-failing-terraform-operations` via `continue-on-error: ${{ fromJSON(...) }}`.

When adding a new validation step, follow all three pieces. The six original `status-*` inputs of `create-validation-summary` are `required: true`; the operation-block inputs added for apply / destroy-plan / destroy (`status-apply`, `apply-count-*`, …) are optional, default to an "absent" sentinel, and **gate their rows on being non-empty** — an environment that runs no mutating stage must render byte-identical to before (test C1). Follow that second pattern for anything not every environment produces.

The three mutating steps have their own gates, placed **after** the phase-2 comment steps, not before: a gate exits 1 and would otherwise skip the render for exactly the failed apply the phase exists to report. Full ordering and rationale: `docs/Apply-and-destroy-reporting.md` §7.5 (P1); a structural test in `evaluate-automerge-eligibility/run_all_tests.sh` asserts it.

### Two flavors of action layout

Modern actions follow `docs/Action-implementation-guide.md` strictly — see `verify-terraform-lock/`, `create-validation-summary/`, `capture-matrix-job-meta/`, `parse-terraform-plan/`, `parse-terraform-apply/`, `annotate-terraform-outcome/`, `create-run-summary/` as reference implementations. `create-test-report/` is the worked example of converting a legacy action safely: pin the legacy output as golden fixtures in one commit, convert in the next, goldens untouched. Layout:

```
my-action/
├── action.yml                  # thin shim: env: input_* + `set -o allexport; source step_<name>.sh`
├── helpers.sh                  # identical across all actions; auto-loads helpers_additional.sh
├── helpers_additional.sh       # optional, action-specific helpers used by step_*.sh
├── step_<name>.sh              # all logic; sources helpers.sh; main(); exits with main's code
├── run_local_step_<name>.sh    # simulates GitHub Actions env for manual testing
└── run_all_tests.sh            # automated tests using subshells + GITHUB_OUTPUT capture
```

Legacy actions (e.g. `terraform-validate/`, `terraform-init/`, `setup-tflint/`) still embed bash in `action.yml`. **When touching one of these for non-trivial work, convert it to the modern layout** following the guide. Cherry-pick `helpers.sh` from a reference action without modifying it.

For step scripts: end with `main; _main_exit_code=$?; exit ${_main_exit_code}` — never `return`. GitHub Actions sources the script in a `bash -eo pipefail` shell, so `exit` terminates the sourced process cleanly and the runner fails the step on non-zero. Tests run the script in a `( subshell )`, so `exit` terminates only the subshell.

Every `run:` block in an `action.yml` **opens with a one-line `#` comment describing what the step does**. GitHub ignores a composite step's `name:` and titles the log group `Run <first line of the run block>` — without the comment every shim renders as an indistinguishable `Run set -o allexport`. Rationale and wording rules: `docs/Action-implementation-guide.md` → "Every `run:` block opens with a description comment".

For JSON inputs in `action.yml` shims, use heredocs:
```yaml
run: |
  # <What this step does>
  input_json_data=$(cat <<'EOF'
  ${{ inputs.json-data }}
  EOF
  )
  export input_json_data
  set -o allexport
  source "${{ github.action_path }}/step_<name>.sh"
```

### Watch for ARG_MAX in step scripts

Under `set -o allexport`, any shell variable holding large data (file contents, `gh api` responses, plan extracts) gets exported to envp; once envp crosses Linux's `ARG_MAX` (~2 MB total) or `MAX_ARG_STRLEN` (128 KB per string), the next `fork+execve` — typically `jq`, `bash -c`, or another helper — fails with exit 126 "Argument list too long". The bug correlates with PR/data size so it stays silent in tests and only surfaces in production on a calling repo with a big-enough plan or comment thread.

**Rule:** never assign large captured data to a shell variable while allexport is in scope. Route through `mktemp` files (or read straight from disk) and pass via stdin / `-f` / `-F body=@file` / `jq --slurpfile`. Four in-tree reference patterns to copy from when authoring or reviewing a step script:

- File tails — `tail -c 65000 "<path>"` directly into the capture, never via an intermediate var (`create-validation-summary/step_create_validation_summary.sh`).
- `gh api` responses — write the response to `mktemp`, then `jq` reads it (`aggregate-validation-summaries/step_aggregate.sh`, both `_resolve_per_env_job_urls` and `list_pr_state`).
- Large JSON merge — `jq --slurpfile` (not `--argjson`, which puts the JSON on argv) and dereference with `[0]` (`capture-matrix-job-meta/step_capture.sh`).
- Large gh CLI inputs — heredoc the body into a tempfile, post via `gh api -F body=@<tempfile>` (`pr-comment/action.yml`).
- Comment bodies — never a step output. `create-validation-summary` publishes every body as a **file path** (`head-summary-file`, `plan-extract-file`, …) and `pr-comment` takes `body-file`. A string output enters the steps context, from there the metadata artifact, and from there envp via `toJSON(steps)`. `capture-matrix-job-meta` additionally caps every captured output at 4 KiB so the next unexpectedly large one degrades the artifact instead of killing the job.

Two related traps in step scripts, hit three times in one change: `$(…)` runs in a subshell, so a function that sets a global for its caller loses it, and the substitution strips trailing newlines. Redirect to a file instead when you need both. `docs/Action-implementation-guide.md` → "Command substitution traps".

Test harnesses must mirror their shim: a suite that `export`s a large input the production shim keeps shell-local will E2BIG the step's own `jq` on a big fixture and test the harness, not the step.

### PRs are gated by per-action test suites

`.github/workflows/action-tests.yml` runs every action's `run_all_tests.sh` in parallel on each PR and exposes a single `tests-conclusion` check (intended to be required by branch protection). Result is reported as a PR comment, run-page annotations, and a `$GITHUB_STEP_SUMMARY` block — all three driven by the result-JSON artifacts each matrix job uploads.

Suites must emit the canonical `Tests run: N` / `Tests passed: N` / `Tests failed: N` summary lines verbatim — CI parses them and fails the suite on drift. Full design and verification procedures: [docs/Testing-in-ci.md](docs/Testing-in-ci.md).

## Common commands

```bash
# Run an action's full test suite
bash <action-name>/run_all_tests.sh

# Manually run an action's main step against simulated GitHub env
bash <action-name>/run_local_step_<name>.sh

# Validate workflow / action YAML parses
python3 -c "import yaml; yaml.safe_load(open('<path-to>.yml'))"

# Validate a test-data JSON fixture parses
python3 -c "import json; json.load(open('<path-to>.json'))"
```

`create-tf-vars-matrix` has a modern `run_all_tests.sh` (helper unit tests + fixture-driven runs of the step source extracted from `action.yml` by `extract_step_source.py`) and is enrolled in CI like every other action. The older `test_action_source.sh` harness is a known-flaky direct-invocation harness that requires a real tty and may fail on pristine main — it is kept for manual debugging only and CI does not run it.

## Development workflow (see `docs/Development-and-release.md` and `docs/Preview-refs.md`)

To test changes from a calling repo, use the PR's **preview ref**. There is no dev-tag swap any more:

1. Open a (draft) PR. `.github/workflows/pr-preview.yml` publishes two tags on every push — `preview/pr-<N>` (moving) and `preview/pr-<N>-<sha7>` (immutable) — pointing at a generated, detached commit whose internal `uses: dsb-norge/github-actions-terraform/...@v0` refs are rewritten to the immutable tag. A sticky `🧪 Preview refs for this PR` comment carries the copy-paste line.
2. **Calling repo** uses `uses: dsb-norge/github-actions-terraform/.github/workflows/terraform-ci-cd-default.yml@preview/pr-<N>`, with `# TODO revert to '@v0'` above it. The same ref serves every composite action.
3. **Never commit a ref rewrite to the PR branch** — it keeps saying `@v0`. A branch that still carries an old-style swap commit (`@<tag>` refs with `# TODO revert to @v0` markers) should drop that commit; the preview publishes correctly either way.
4. Closing or merging the PR deletes the tags and the comment.

If the comment says *unavailable (bootstrap)*, the repository variable `PREVIEW_APP_ID` / secret `PREVIEW_APP_PRIVATE_KEY` are missing — `docs/Preview-refs.md` §5 has the one-time App setup. Fallback for fork PRs: `bash .github/scripts/rewrite-internal-refs.sh <ref>`, commit, tag and push by hand (Development-and-release.md → "Fallback: publishing by hand"), and revert with the same script and `v0` before merge.

## Release process (see `docs/Development-and-release.md`)

Minor and major releases both use annotated tags. Critical points beyond the doc:

- **The `v0` major tag's annotation is an append-only changelog.** Every prior `v0.X:` block must be preserved when force-recreating `v0`. The doc shows interactive `git tag -f -a 'v0'` which prompts for fresh annotation — that overwrites. To **amend** properly:
  ```bash
  old=$(git for-each-ref --format='%(contents)' refs/tags/v0)
  new_block="v0.X:
    - <commit subject>
    - <commit subject>"
  combined="${old}
  ${new_block}"
  git tag -a v0.X -m "${new_block}"
  git tag -f -a v0 -m "${combined}"
  git push origin refs/tags/v0.X
  git push -f origin refs/tags/v0
  ```
- The new minor's annotation block follows the format `vX.Y:\n  - <commit subject>\n  ...`. Mirror commit subjects since `vX.(Y-1)`, lightly rephrasing if a literal subject would be confusing as a release note.
- Force-pushing `v0` is intentional and is the supported mechanism — every calling repo on `@v0` moves to the new commit immediately.

## Conventions

- **Commit messages:** lowercase semantic prefix (`feat:`, `fix:`, `chore:`, `refactor:`, `docs:`, `test:`), subject ≤70 chars, body separated by blank line, body lines not wrapped.
- **PR descriptions:** focus on motivation/context and a summary of changes. Don't include QA checklists or testing instructions.
- **Comments in step scripts:** explain *why* (non-obvious constraints, intentional side-effects, references to past incidents); never *what* a well-named identifier already says. Don't reference current PR/task numbers since those rot.
