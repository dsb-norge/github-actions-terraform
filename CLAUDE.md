# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository overview

A collection of composite GitHub Actions and reusable workflows for terraform projects used by other DSB repositories. The two main consumption points are:

- **`.github/workflows/terraform-ci-cd-default.yml`** — the reusable CI/CD workflow that orchestrates init → fmt → validate → lint → plan → apply (→ destroy-plan → destroy) with a `📊` PR comment summary, per-operation tag comments, a per-env `$GITHUB_STEP_SUMMARY` block plus a run-level rollup, and optional `🔒` lock file verification and PR auto-merge. Each environment takes part only in the events of its `trigger-events` (`schedule` is opt-in per environment, and a scheduled run plans unless the environment's `schedule-goal` says otherwise), a dispatch with the standard inputs block runs one environment with a goal that can only cap its `goals-yml`, and every operation gate reads the engine's `goals-granted`, never the raw goals (`docs/Dispatch-and-triggers.md`). On pull requests and pushes it runs only the environments the change is relevant to, and the `Terraform conclusion` check judges named results and the builder's counts (`docs/Path-relevance.md`); it also runs every committed `terraform test` file as its own job, with one summary comment (`docs/Terraform-tests.md`). The PR-comment model is `docs/Workflow-pr-comments.md`; apply/destroy reporting and its 39 indexed pitfalls are `docs/Apply-and-destroy-reporting.md`.
- **`.github/workflows/terraform-module-ci.yaml`** (and `terraform-module-release.yaml`) — the module repositories' workflow: terraform-docs (a commit only on a pull request), validation, and the project workflow's test stage through the engine's **module mode** (`create-tf-vars-matrix` with `mode: module`, `docs/Module-ci.md`). Its `terraform-test` and `terraform-test-summary` jobs are the project workflow's, **copied**: F20 fails unless the two are equal but for `needs` and `if`, so **a change to either workflow's test jobs is made in both**. A module needs at least one test file by default (`terraform-test-required`).
- **Composite actions** in top-level directories (e.g. `terraform-init/`, `terraform-plan/`, `verify-terraform-lock/`, `create-validation-summary/`, …).

Calling repos pin a rolling major tag (`@v0`, or `@v1` for the v1 line) or a specific release (`@v0.21`, `@v1.2.0`). A major tag is force-moved on release, so what ships on it reaches every caller pinned to it at once — be mindful when touching anything in here.

**`main` is the v1 line.** Its workflows' internal refs say `@v1`, and `v1` is a moving tag that follows every v1 release; callers pin `@v1` or an exact `@v1.X.Y` (`CHANGELOG.md`). `v0` is frozen at v0.33 and takes fixes only, on a `release/v0` branch cut from that commit when the first fix is needed (`docs/Development-and-release.md` → "Release lines").

**`docs/README.md` indexes every document by kind** (user guide, migration, spec, contributor guide); a new document gets its row in the change that adds it, and F22 in `evaluate-automerge-eligibility/run_all_tests.sh` fails otherwise.

## Architecture

### The decision engine is the center of gravity

The spine of the default workflow is the **decision engine** in `engine/` (`docs/Decision-engine.md`): a Python 3.12+ standard-library package, one JSON document in and one out, under a 100 percent line and branch coverage gate and a mutation gate. It has two sides. **The core** (`model`, `values`, `environments`, `triggers`, `ordering`, `globs`, `relevance`, `tests`, `comments`, `decide`, `record`) is pure: it imports only `json`, `re`, `hashlib` and itself, never YAML, the network, the filesystem or the environment (`test_purity.py` enforces it). **The adapter side** (`adapter.py`, `workflow.py`, `__main__.py`) does the rest: `create-tf-vars-matrix`'s whole step is `python3 -I -B engine/run.py create-matrix --inputs-file <file> --mode project|module`, and the adapter probes `yq`, parses every `*-yml` value, reads the default branch, the event facts and a dispatch's inputs from `GITHUB_EVENT_PATH` (and the ref type, the triggering actor and the base ref from the runner), fetches the changed files through `gh` (every failure a fact the core fails open on), lists the committed test files and reads the environments' locks for the test stage, checks directories, decides in-process and publishes the per-stage matrices and counts (`matrix-stage-<n>-json`, `stage-<n>-count`, and `matrix-json` as their union), the counts, the relevance mode and reason, the test matrix (`tests-matrix-json`, `tests-count`, `tests-active`), and `relevance-file`: `relevance.json`, every environment's verdict plus the seed manifest, which the workflow uploads as the `relevance` artifact for the seed, the aggregator, the run summary and the auto-merge evaluator. Every future decision is a rule in the core; its fact-gathering is adapter-side Python, not bash (D13).

**The environments run in up to three stage jobs**, `terraform-ci-cd`, `terraform-ci-cd-2` and `terraform-ci-cd-3` (`docs/Environment-ordering.md`): an environment's `depends-on` puts it in a later stage when the run applies or destroys, and without `depends-on` everything is stage 1. The three share one step list through the YAML anchor `&environment-steps`, so a change to the environment steps is a change to every stage; every other job field is written out per stage job, and F15 in `evaluate-automerge-eligibility/run_all_tests.sh` holds the three to one shape. A job that needs the environments needs all three, and must still run when stages 2 and 3 are skipped, which they are on every run of a repository without `depends-on`.

**Run any Python an action starts as `python3 -I -B <path>/engine/run.py …`.** `-I` keeps the caller's checkout (the working directory) and `PYTHON*` variables off the import path; without it a caller's own `json.py` replaces the standard library. `run.py` adds the engine directory and enforces the 3.12 floor.

Two patterns to know:

- **Generic input forwarding** (`build_row` in `engine/dsb_tf_engine/environments.py`): every top-level workflow input is propagated into each env's `matrix.vars` as a string. **Adding a new boolean/string workflow input needs no forwarding logic, but it must be classified**: an `environments-yml` entry may hold only known keys (`docs/Configuration-validation.md` §3.1), so decide whether an environment may override it and add it to exactly one of `PER_ENVIRONMENT_INPUTS` or `WORKFLOW_ONLY_INPUTS` in `environments.py` (a `*-yml` input goes to `REPLACE_FIELDS` or `MERGE_FIELDS` instead); `test_config.py` fails until you do. Then add it to `REQUIRED_FIELDS` / `NOT_EMPTY_FIELDS`, add it to every port case's `inputs_json` (as GitHub delivers it), and regenerate: `UPDATE_ENGINE_INPUTS=1 bash create-tf-vars-matrix/run_all_tests.sh` and `UPDATE_PORT_GOLDENS=1 bash engine/run_all_tests.sh`, and review the diff.
- **YAML fields** (`extra-envs-yml`, `goals-yml`, `terraform-init-additional-dirs-yml`, `pr-auto-merge-*-yml`) get explicit handling: the list settings (`REPLACE_FIELDS`: goals, init directories, auto-merge actors) are replaced per environment, a single string being one item; the maps (`MERGE_FIELDS`) merge the environment's value over the global one. Each has its validation in `environments.py` (`docs/Configuration-validation.md` §3). The adapter parses every `*-yml` input and per-env key and hands over `{"ok", "value"}` parse results, reading each value exactly as the old bash builder did (`input_text`, `field_text`); the four variable settings are read through `READ_AS`, which keeps every plain scalar as written.
- **The port cases** (`engine/tests/port/cases/`) pin every row the bash builder produced, including real callers' anonymised shapes. They are the regression goldens; a change that alters any row alters a golden, and the diff is the review.

Boolean inputs end up as strings in the matrix (e.g. `matrix.vars.add-pr-comment == 'true'`), whether forwarded or set per environment: the engine normalises a per-environment value of a boolean input (`BOOLEAN_INPUTS` in `environments.py`, held to the workflow's declared booleans by a test) to `"true"`/`"false"`, because a JSON `true` compares false against `'true'` in GitHub expressions. **A new boolean workflow input goes into `BOOLEAN_INPUTS` too.** The exception is `allow-failing-terraform-operations`, which is explicitly normalized to a JSON boolean so the workflow can `fromJSON()` it. Follow this pattern only if the value needs `fromJSON()`; otherwise plain string comparison is fine. Environment and github-environment names follow one rule (`NAME` in `environments.py`) and a github-environment belongs to one environment.

### Validation-step + outcome-step pattern

Validation steps (init, fmt, validate, lint, plan, verify-lock) all use the same pattern in the workflow:

1. The step itself runs with `continue-on-error: true` so the job continues regardless.
2. Its outcome is forwarded to `create-validation-summary` which posts a 📊 PR comment row.
3. A separate `🧐 Validation outcome: <step>` step later in the job hard-fails on non-success, respecting `matrix.vars.allow-failing-terraform-operations` via `continue-on-error: ${{ fromJSON(...) }}`.

When adding a new validation step, follow all three pieces. The six original `status-*` inputs of `create-validation-summary` are `required: true`; the operation-block inputs added for apply / destroy-plan / destroy (`status-apply`, `apply-count-*`, …) are optional, default to an "absent" sentinel, and **gate their rows on being non-empty** — an environment that runs no mutating stage must render byte-identical to before (test C1). Follow that second pattern for anything not every environment produces.

The three mutating steps have their own gates, placed **after** the phase-2 comment steps, not before: a gate exits 1 and would otherwise skip the render for exactly the failed apply the phase exists to report. Full ordering and rationale: `docs/Apply-and-destroy-reporting.md` §7.5 (P1); a structural test in `evaluate-automerge-eligibility/run_all_tests.sh` asserts it.

### Two flavors of action layout

Modern actions follow `docs/Action-implementation-guide.md` **if there are no overweighing reasons not to**; a departure is explained in the action and its spec. The one departure is `create-tf-vars-matrix`, whose logic is the engine's Python adapter so it sits under the engine's coverage and mutation gates. Reference implementations of the layout — see `verify-terraform-lock/`, `create-validation-summary/`, `capture-matrix-job-meta/`, `parse-terraform-plan/`, `parse-terraform-apply/`, `annotate-terraform-outcome/`, `create-run-summary/` as reference implementations. Converting a legacy action safely means pinning its output as golden fixtures in one commit and converting in the next, goldens untouched. Layout:

```
my-action/
├── action.yml                  # thin shim: env: input_* + `set -o allexport; source step_<name>.sh`
├── helpers.sh                  # identical across all actions; auto-loads helpers_additional.sh
├── helpers_additional.sh       # optional, action-specific helpers used by step_*.sh
├── step_<name>.sh              # all logic; sources helpers.sh; main(); exits with main's code
├── run_local_step_<name>.sh    # simulates GitHub Actions env for manual testing
└── run_all_tests.sh            # automated tests using subshells + GITHUB_OUTPUT capture
```

Every action follows the modern layout now (`create-tf-vars-matrix` is the engine departure above), and every one has a suite: the Action tests comment's "Not tested yet" list is empty. **A new action follows the guide from its first commit.** Cherry-pick `helpers.sh` from a reference action without modifying it.

For step scripts: end with `main; _main_exit_code=$?; exit ${_main_exit_code}` — never `return`. GitHub Actions sources the script in a `bash -eo pipefail` shell, so `exit` terminates the sourced process cleanly and the runner fails the step on non-zero. Tests run the script in a `( subshell )`, so `exit` terminates only the subshell. F23 in `evaluate-automerge-eligibility/run_all_tests.sh` enforces the ending.

Every `run:` block in an `action.yml` **opens with a one-line `#` comment describing what the step does**. GitHub ignores a composite step's `name:` and titles the log group `Run <first line of the run block>` — without the comment every shim renders as an indistinguishable `Run set -o allexport`. Rationale and wording rules: `docs/Action-implementation-guide.md` → "Every `run:` block opens with a description comment".

**How a value reaches a step script** (`docs/Action-implementation-guide.md` → "Step shim pattern — JSON inputs"). GitHub pastes an expression's value into the `run:` script before bash parses it, so a heredoc capture of free text ends at a line equal to its delimiter and runs the rest as shell; and a value in envp (`env:`, `export`, `allexport`) reaches every fork, past 128 KiB in bytes with E2BIG. Only **small scalars** go through `env:`. JSON-contract inputs (`*-json`, callers pass `toJSON(...)`) are captured as they are; **free text and anything large is captured as `toJSON(inputs.<name>)`** (one line, so no delimiter line can occur) and decoded in the step, which unexports it at once:
```yaml
run: |
  # <What this step does>
  input_body_json=$(cat <<'MY_ACTION_BODY_JSON'
  ${{ toJSON(inputs.body) }}
  MY_ACTION_BODY_JSON
  )
  set -o allexport
  source "${{ github.action_path }}/step_<name>.sh"   # input_body="$(jq -r '. // ""' <<<"${input_body_json}")"; export -n input_body
```
The delimiter is `<ACTION>_<INPUT>_JSON`, never `EOF`, unique in the repository. The structural test F9 in `evaluate-automerge-eligibility/run_all_tests.sh` enforces it. **Never paste `${{ inputs.* }}`, `${{ matrix.* }}` or a step output into a `run:` block's text** outside such a capture: read it from the step's `env:` (F16). No non-breaking space in a workflow or action file (F19). **Check the history before moving a value into envp**: the May 2026 fixes (`f9594c2`, `07eeddd`, `4fedab9`, `8cd5d63`, `8aafc32`) took large values out of it after production E2BIG failures.

### Watch for ARG_MAX in step scripts

Under `set -o allexport`, any shell variable holding large data (file contents, `gh api` responses, plan extracts) gets exported to envp; once envp crosses Linux's `ARG_MAX` (~2 MB total) or `MAX_ARG_STRLEN` (128 KB per string), the next `fork+execve` — typically `jq`, `bash -c`, or another helper — fails with exit 126 "Argument list too long". The bug correlates with PR/data size so it stays silent in tests and only surfaces in production on a calling repo with a big-enough plan or comment thread.

**Rule:** never assign large captured data to a shell variable while allexport is in scope. Route through `mktemp` files (or read straight from disk) and pass via stdin / `-f` / `-F body=@file` / `jq --slurpfile`. Five in-tree reference patterns to copy from when authoring or reviewing a step script:

- File tails — `tail -c <budget> "<path>"` directly into the capture, never via an intermediate var (`line_anchored_tail` in `create-validation-summary/step_create_validation_summary.sh`, budgeted under a 65000-byte limit).
- `gh api` responses — write the response to `mktemp`, then `jq` reads it (`aggregate-validation-summaries/step_aggregate.sh`, both `_resolve_per_env_job_urls` and `list_pr_state`).
- Large JSON merge — `jq --slurpfile` (not `--argjson`, which puts the JSON on argv) and dereference with `[0]` (`capture-matrix-job-meta/step_capture.sh`).
- Large gh CLI inputs — write the body to a tempfile and post via `gh api -F body=@<tempfile>` (`pr-comment/helpers_additional.sh`); callers hand large bodies over as `body-file`, never inline.
- Comment bodies — never a step output. `create-validation-summary` publishes every body as a **file path** (`head-summary-file`, `plan-extract-file`, …) and `pr-comment` takes `body-file`. A string output enters the steps context, from there the metadata artifact, and from there envp via `toJSON(steps)`. `capture-matrix-job-meta` additionally caps every captured output at 4 KiB so the next unexpectedly large one degrades the artifact instead of killing the job.

Two related traps in step scripts, hit three times in one change: `$(…)` runs in a subshell, so a function that sets a global for its caller loses it, and the substitution strips trailing newlines. Redirect to a file instead when you need both. `docs/Action-implementation-guide.md` → "Command substitution traps".

Test harnesses must mirror their shim: a suite that `export`s a large input the production shim keeps shell-local will E2BIG the step's own `jq` on a big fixture and test the harness, not the step.

### PRs are gated by per-action test suites

`.github/workflows/action-tests.yml` runs every action's `run_all_tests.sh` in parallel on each PR and exposes a single `tests-conclusion` check (required by branch protection). Result is reported as a PR comment, run-page annotations, and a `$GITHUB_STEP_SUMMARY` block — all three driven by the result-JSON artifacts each matrix job uploads.

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

`engine/run_all_tests.sh` runs the engine suite under coverage and fails below 100 percent of lines and branches, then runs the **mutation gate** (`engine/tests/mutation.py`): every small fault injected into the package must fail a test. Each gate counts as one test. When the gate names a surviving mutant, write the test that kills it; list it in `engine/tests/mutation_equivalents.json` only when it provably cannot change behaviour, with the reason — and prefer removing the redundant code that makes it equivalent. Coverage alone is not the bar: at 100 percent coverage the first mutation run found 44 unnoticed faults. `python3 engine/tests/mutation.py --list` shows every mutant. It needs `coverage`: CI uses the preinstalled `pipx`; locally use a venv (`python3 -m venv <dir> && <dir>/bin/pip install coverage`, then put `<dir>/bin` first on `PATH`). Without either, the gate fails on purpose. Note a venv's Python lacks PyYAML, which some older structural tests import — run other suites with the system `python3`. Engine tests must compare against **literal** expected values, never the module's own constants: a test that reads the constant it checks passes whatever the constant says (33 adapter mutants survived that way). CI also runs the engine suite on Python 3.12 and the newest 3.x (`engine-python` in `action-tests.yml`). `action-tests.yml` discovers `engine/` through a second pass for top-level suites without an `action.yml`. **In CI the mutation gate runs once, sharded**: the suite jobs set `ENGINE_MUTATION=shards` and run coverage only, the `engine-mutation` matrix (eight shards) runs `mutation.py --shard K/N`, and `engine-mutation-gate` judges them with `--merge` (`docs/Testing-in-ci.md` §14; F17 holds the wiring, so a shard-count change touches the matrix, the command and the name together). Each mutant runs its own module's tests (`test_<module>`) first and `SLOW_LAST` last; a new test module needs no registration, but a new slow one belongs in `SLOW_LAST`. The full gate takes about four minutes locally.

Suite scripts write the step's output to a file of their own (`_test_output=$(mktemp)`), never a fixed `/tmp` path: suites run side by side, and F18 fails on a redirect into a fixed `/tmp` file.

## Development workflow (see `docs/Development-and-release.md` and `docs/Preview-refs.md`)

To test changes from a calling repo, use the PR's **preview ref**. There is no dev-tag swap any more:

1. Open a (draft) PR. `.github/workflows/pr-preview.yml` publishes two tags on every push — `preview/pr-<N>` (moving) and `preview/pr-<N>-<sha7>` (immutable) — pointing at a generated, detached commit whose internal `uses: dsb-norge/github-actions-terraform/...@v1` refs are rewritten to the immutable tag. A sticky `🧪 Preview refs for this PR` comment carries the copy-paste line.
2. **Calling repo** uses `uses: dsb-norge/github-actions-terraform/.github/workflows/terraform-ci-cd-default.yml@preview/pr-<N>`, with `# TODO revert to '@v1'` above it. The same ref serves every composite action.
3. **Never commit a ref rewrite to the PR branch** — it keeps saying `@v1`. A branch that still carries an old-style swap commit (`@<tag>` refs with `# TODO revert to @v0` markers) should drop that commit; the preview publishes correctly either way.
4. Closing or merging the PR deletes the tags and the comment.

If the comment says *unavailable (bootstrap)*, the repository variable `PREVIEW_APP_ID` / secret `PREVIEW_APP_PRIVATE_KEY` are missing — `docs/Preview-refs.md` §5 has the one-time App setup. Fallback for fork PRs: `bash .github/scripts/rewrite-internal-refs.sh <ref>`, commit, tag and push by hand (Development-and-release.md → "Fallback: publishing by hand"), and revert with the same script and `v1` before merge.

## Release process (see `docs/Development-and-release.md` → "Release")

- **v1 releases are release-please's** (`.github/workflows/release.yml`, `release-please-config.json`, `.release-please-manifest.json`). Every push to `main` updates one release pull request (`chore(main): release 1.X.Y`); merging it tags `v1.X.Y`, publishes the GitHub Release and moves `v1`. Never tag a v1 release or move `v1` by hand, except to un-release (the doc's command). **Commit subjects are the release notes**: `feat:` and `fix:` (and breaking changes) are listed in `CHANGELOG.md` and decide the bump; `docs:`, `test:`, `refactor:`, `chore:`, `ci:` release nothing on their own. Mark a breaking change `feat!:` or with a `BREAKING CHANGE:` footer only when it is one: it proposes v2.
- The release pull request is opened with the releaser App (`vars.RELEASER_APP_ID`, `secrets.RELEASER_APP_PRIVATE_KEY`) so its CI runs; without the variable the job is skipped.
- **v0 fixes are released by hand** from `release/v0`, and **`v0`'s annotation is an append-only changelog**: every prior `v0.X:` block is kept when `v0` is force-recreated. `git tag -f -a v0` without `-m` prompts for a fresh annotation and overwrites it. To **amend**:
  ```bash
  old=$(git for-each-ref --format='%(contents)' refs/tags/v0)
  new_block="v0.X:
    - <commit subject>
    - <commit subject>"
  git tag -a v0.X -m "${new_block}"
  git tag -f -a v0 -m "${old}
  ${new_block}"
  git push origin refs/tags/v0.X
  git push -f origin refs/tags/v0
  ```
  Mirror the commit subjects since the previous minor, lightly rephrased where a literal subject would confuse as a release note, and add the block to `CHANGELOG.md`'s v0 section. Force-pushing `v0` is intentional: every caller on `@v0` moves at once.

## Conventions

- **Commit messages:** lowercase semantic prefix (`feat:`, `fix:`, `chore:`, `refactor:`, `docs:`, `test:`), subject ≤70 chars, body separated by blank line, body lines not wrapped.
- **PR descriptions:** focus on motivation/context and a summary of changes. Don't include QA checklists or testing instructions.
- **Comments in step scripts:** explain *why* (non-obvious constraints, intentional side-effects, references to past incidents); never *what* a well-named identifier already says. Don't reference current PR/task numbers since those rot.
- **Docs:** specs are written as built, with no progress markers, nothing internal (this repository is public), and worked examples produced by running the code; actions stay on their latest major. `docs/Development-and-release.md` → "Documentation", "Validating on a test-bed repository", "Keeping actions current".
