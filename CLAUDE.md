# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository overview

A collection of composite GitHub Actions and reusable workflows for terraform projects used by other DSB repositories. The two main consumption points are:

- **`.github/workflows/terraform-ci-cd-default.yml`** — the reusable CI/CD workflow that orchestrates init → fmt → validate → lint → plan → apply with a `📊` PR comment summary and optional `🔒` lock file verification and PR auto-merge.
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

When adding a new validation step, follow all three pieces. The validation-summary action's status inputs are all `required: true` — add a new one alongside `status-init`, `status-fmt`, etc.

### Two flavors of action layout

Modern actions follow `docs/Action-implementation-guide.md` strictly — see `verify-terraform-lock/`, `create-validation-summary/`, `capture-matrix-job-meta/`, `parse-terraform-plan/` as reference implementations. Layout:

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

For JSON inputs in `action.yml` shims, use heredocs:
```yaml
run: |
  input_json_data=$(cat <<'EOF'
  ${{ inputs.json-data }}
  EOF
  )
  export input_json_data
  set -o allexport
  source "${{ github.action_path }}/step_<name>.sh"
```

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

The matrix-builder test harness (`create-tf-vars-matrix/test_action_source.sh`) is a known-flaky direct-invocation harness that requires a real tty and may fail on pristine main; rely on the modern per-action `run_all_tests.sh` suites where they exist.

## Development workflow (see `docs/Development-and-release.md` for full procedure)

To test changes from a calling repo, the documented "dev-tag swap" flow is mandatory:

1. **Rewrite `@v0` refs** in all `dsb-norge/github-actions-terraform/...@v0` lines in this repo to `@<your-feature-tag>`, with a `# TODO revert to @v0` marker above each — there's a documented vscode regex pattern for both the swap and the revert.
2. **Commit on a feature branch**, push, then `git tag -f -a '<tag>' && git push -f origin 'refs/tags/<tag>'`. Re-tag and force-push each time you push more commits.
3. **Calling repo** uses `uses: dsb-norge/github-actions-terraform/.github/workflows/terraform-ci-cd-default.yml@<tag>`.
4. **Before merge**: delete the dev tag locally and on origin, and revert all `@<tag>` refs back to `@v0` using the second documented regex.

Branch + tag may share a name. To disambiguate locally, use `refs/heads/<name>` and `refs/tags/<name>` explicitly with `git push`.

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
