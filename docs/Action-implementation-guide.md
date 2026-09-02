# GitHub Action Implementation Guide

Guidelines for implementing new composite GitHub Actions and converting existing ones that have inline bash in `action.yml`.

## Goals

- All non-trivial bash logic lives in **dedicated `.sh` files**, not in YAML strings
- Every action step that contains logic has a **local runner** for manual testing/debugging
- Every action has **automated tests** in a `run_all_tests.sh` script
- A shared `helpers.sh` provides consistent logging, output, and grouping primitives

---

## Directory Structure

Each action lives in its own directory under the repository root. The file layout depends on how many steps the action has.

### Single-step action

```
my-action/
├── action.yml                      # Action metadata + thin YAML shim per step
├── helpers.sh                      # Shared helpers (identical across all actions)
├── helpers_additional.sh           # Optional: action-specific helper functions
├── step_<name>.sh                  # Logic for the single step
├── run_local_step_<name>.sh        # Local runner for manual test/debug
└── run_all_tests.sh                # Automated tests
```

### Multi-step action

```
my-action/
├── action.yml
├── helpers.sh
├── helpers_additional.sh           # Optional: shared helpers across steps
├── step_<name_a>.sh
├── step_<name_b>.sh
├── run_local_step_<name_a>.sh
├── run_local_step_<name_b>.sh
├── run_tests_step_<name_a>.sh      # Optional: tests specific to step a
├── run_tests_step_<name_b>.sh      # Optional: tests specific to step b
└── run_all_tests.sh                # Orchestrates all step test scripts
```

### File naming conventions

| File | Purpose |
|---|---|
| `action.yml` | GitHub Actions composite action definition. Contains only input/output declarations and thin step shims that source the corresponding `step_*.sh`. |
| `helpers.sh` | **Shared, identical across all actions.** Provides logging, output, grouping, and masking primitives. Automatically loads `helpers_additional.sh` if present. |
| `helpers_additional.sh` | **Optional.** Action-specific helper functions — **production code only**. Must only contain code that is used by `step_<name>.sh` scripts (either by a single step or shared across multiple steps). Must not contain code that exists solely for tests or local runners. Loaded automatically by `helpers.sh`. |
| `step_<name>.sh` | All bash logic for one step. Sources `helpers.sh`, defines step-local helper functions and a `main` function, then calls `main`. |
| `run_local_step_<name>.sh` | Sets up a simulated GitHub Actions environment (exports `GITHUB_OUTPUT`, `GITHUB_ACTION_PATH`, etc.) and sources the corresponding `step_<name>.sh`. Used for manual testing. |
| `run_tests_step_<name>.sh` | **Optional.** Tests specific to one step. Used when an action has multiple steps and tests are organized per-step. Called by `run_all_tests.sh`. |
| `run_all_tests.sh` | Automated test suite. For single-step actions, contains the tests directly. For multi-step actions, orchestrates the per-step `run_tests_step_<name>.sh` scripts. |

---

## `helpers.sh` — Shared Helpers

This file is **identical** in every action directory. It provides:

```bash
#!/bin/env bash

# Derives the action name from the directory name
_action_name="$(basename "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)")"

# Logging
function log-info  { ... }   # Plain info message, prefixed with action name
function log-debug { ... }   # Prefixed with "DEBUG: "
function log-warn  { ... }   # Prefixed with "WARN: "
function log-error { ... }   # Prefixed with "ERROR: "

# GitHub Actions log groups
function start-group { echo "::group::${_action_name}: ${*}"; }
function end-group   { echo "::endgroup::"; }
function log-multiline { ... }  # Wraps content in a group

# GitHub Actions outputs
function set-output           { ... }  # Single-line output
function set-multiline-output { ... }  # Multi-line output with heredoc delimiter
function mask-value           { ... }  # ::add-mask::

# Path utility
function ws-path { ... }  # Path relative to $GITHUB_WORKSPACE

# Auto-load action-specific helpers
if [ -f "${GITHUB_ACTION_PATH}/helpers_additional.sh" ]; then
  source "${GITHUB_ACTION_PATH}/helpers_additional.sh"
fi
```

> **Never modify this file per-action.** Put action-specific helpers in `helpers_additional.sh`.

---

## `step_<name>.sh` — Step Script

This is where all the actual logic for a step lives.

### Template

```bash
#!/bin/env bash
#
# Source for the <name> step
#
# <Brief description of what this step does.>
#
# Required environment variables:
#   input_foo  - Description
#   input_bar  - Description
#

# Choose one based on needs:
set -o nounset   # fail on unset variables (strict)
# set +o nounset # allow unset variables (best-effort / graceful handling)

# Load helpers
source "${GITHUB_ACTION_PATH}/helpers.sh"

# ============================================================================
# Helper Functions (step-local)
# ============================================================================
# For multi-step actions: put functions here that are local to THIS step only.
# For single-step actions: prefer putting helpers in helpers_additional.sh
# instead, keeping this section minimal or empty.
# Shared helpers used by multiple steps belong in helpers_additional.sh.

function some_helper {
  # ...
}

# ============================================================================
# Main Logic
# ============================================================================

function main {
  log-info "Starting <name>..."

  # ... step logic ...

  # Set outputs
  set-output "my-output" "${some_value}"

  log-info "<name> completed."
  return 0
}

# Run main function
main
_main_exit_code=$?
exit ${_main_exit_code}
```

> **Why only `exit` (no `return`)?** In GitHub Actions, `shell: bash` runs with `bash --noprofile --norc -eo pipefail {0}`, meaning the runner automatically fails the step on any non-zero exit code. Because the script is `source`d (not subshelled), `exit` terminates the entire bash process — lines after `source` in the YAML shim are never reached. This is why the shim does not need to capture the exit code. When run locally (via `run_local_step_*.sh` or `run_all_tests.sh`), the scripts run in a **subshell** `( source ... )`, so `exit` terminates only the subshell.

### Key conventions

1. **Source `helpers.sh` first** — always via `source "${GITHUB_ACTION_PATH}/helpers.sh"`.
2. **Use `input_*` variables** — the action.yml shim exports these before sourcing the script (see next section).
3. **Wrap logic in a `main` function** — keeps the global scope clean.
4. **End with `exit`** — call `main`, capture its exit code, and `exit` with it. The shim does not need to capture exit codes because `exit` terminates the sourced shell process directly.
5. **Use `start-group` / `end-group`** — wrap logical sections in log groups for clean output in the Actions UI.
6. **Document required environment variables** in the file header comment.
7. **Step-local vs shared helpers** — in multi-step actions, put functions used only by this step in the "Helper Functions (step-local)" section. Put functions shared across steps in `helpers_additional.sh`. In single-step actions, prefer `helpers_additional.sh` for all helpers.

---

## `action.yml` — Thin YAML Shim

The `action.yml` should contain **no logic**, only:
- Action metadata (`name`, `description`, `author`)
- Input and output declarations
- Steps that prepare environment variables and source `step_*.sh`

### Every `run:` block opens with a description comment

**Rule:** the first line of every `run:` block is a `#` comment saying what the
step does. No exceptions — not for one-liners, not for steps that only source a
`step_*.sh`.

GitHub ignores a composite action's step `name:` in the log. Each inner step is
rendered as a collapsible group titled `Run <first line of the run block>`, and
a `uses:` step gets `Run <owner>/<action>@<ref>`. With the shim pattern that
first line is `set -o allexport` for nearly every step, so a job that calls a
handful of actions collapses into a wall of identical group titles:

```
▾ Terraform Plan
  ▸ Run dsb-norge/github-actions-terraform/terraform-plan@v0
  ▸ Run # Make sure terraform is available
  ▸ Run set -o allexport                    ← which step is this?
  ▸ Run actions/upload-artifact@v7
  ▸ Run set -o allexport                    ← …and this?
  ▸ Run actions/upload-artifact@v7
```

The leading comment is the only lever we have over that title, so it doubles as
the step's log label:

```yaml
- id: plan
  shell: bash
  env:
    input_environment_name: ${{ inputs.environment-name }}
  run: |
    # Run 'terraform plan' and save the plan file
    set -o allexport
    source "${{ github.action_path }}/step_plan.sh"
```

Writing the label:

- **One line, ≤ 72 characters.** It is a title in a narrow log gutter, not a
  sentence. Sentence case, no trailing period.
- **Describe what the step does for the caller, not how the shim works.**
  "Resolve which TFLint config file to use" — not "Source the step script",
  "run step and exit with its exit code", or "Heredoc capture".
- **Distinguish it from its siblings.** Two steps in the same action must not
  share a label; telling them apart in the log is the whole point.
- **Keep rationale out of it.** ARG_MAX notes, heredoc explanations and other
  why-comments still belong in the shim — but below the label, separated by a
  blank line. Only the first line reaches the log.
- **One-liner `run:` steps become blocks.** `run: exit 1` is written as a
  `run: |` block whose first line is the label.

```yaml
- id: plan-status
  if: steps.plan.outcome == 'failure'
  shell: bash
  run: |
    # Fail the action because 'terraform plan' failed
    exit 1
```

`uses:` steps have no `run:` block and therefore no lever — their log title is
the action reference. Give them a `name:` anyway; it documents intent in the
source even though the runner drops it.

> In **reusable workflows** (`.github/workflows/*.yml`) the opposite holds:
> job-level steps *do* honor `name:`, and the name wins over the run block. Give
> every workflow step a `name:` there; the leading comment is optional.

### Never write an Actions expression in an input `description`

Actions parses `${{ ... }}` inside an `action.yml` input description, not just in
`run:` blocks and `with:` values — and the `github` context does **not** exist in
that position. A description that mentions, say, `${{ github.token }}` as an
example value fails the **entire job** at `Set up job` with

```text
Unrecognized named-value: 'github'. Located at position 1 within expression: github.token
##[error]Failed to load <owner>/<repo>/<ref>/<action>/action.yml
```

before a single step runs — and every job that uses the action, not only the one
that passes that input.

Nothing local catches this: the file is valid YAML, so `yaml.safe_load` passes,
`actionlint` does not check `action.yml` descriptions, and no test suite loads
the shim. It surfaces only when a calling repo runs the action.

Describe the value in prose instead — "the caller's own workflow token is
enough" — or name the context without the expression braces.

### Step shim pattern — simple inputs (strings, booleans)

For inputs that are simple strings, pass them as environment variables. Use `set -o allexport` so that any variables set by the step script are automatically exported:

```yaml
- id: my-step
  shell: bash
  env:
    input_foo: ${{ inputs.foo }}
    input_bar: ${{ inputs.bar }}
  run: |
    # <What this step does>
    set -o allexport
    source "${{ github.action_path }}/step_my_step.sh"
```

> The sourced script always calls `exit`, which terminates the bash process. No exit code capture is needed — the runner fails the step automatically on non-zero exit.

### Step shim pattern — JSON inputs

JSON values passed from GitHub Actions expressions can contain special characters that break normal variable assignment. Use heredocs. **Do NOT `export` the heredoc-captured variable** — the step script is `source`d in the same shell and reads it as a shell-local, so it never needs to be in envp. Exporting it would push the JSON into envp for every subsequent fork and risk an ARG_MAX crash on big inputs — see [Anti-pattern: exporting heredoc-captured JSON](#anti-pattern-exporting-heredoc-captured-json) below for the full rationale.

```yaml
- id: my-step
  shell: bash
  env:
    input_simple_var: ${{ inputs.simple-var }}
  run: |
    # <What this step does>
    #
    # Heredoc capture (special chars survive verbatim). Intentionally NOT
    # exported — step_my_step.sh reads it as a shell-local via `source`.
    input_json_data=$(cat <<'EOF'
    ${{ inputs.json-data }}
    EOF
    )

    set -o allexport
    source "${{ github.action_path }}/step_my_step.sh"
```

> Note the order: the heredoc capture happens **before** `set -o allexport`. That keeps `input_json_data` from being auto-exported. Variables set later by the step script (under allexport) still get the export attribute, which is what allexport is there for.

### Naming convention for step IDs

The step `id` should match the `<name>` portion of `step_<name>.sh`. For example:
- Step id: `capture` → `step_capture.sh`
- Step id: `evaluate` → `step_evaluate.sh`
- Step id: `auto-merge-pr` → `step_auto_merge_pr.sh` (hyphens become underscores in filename)

---

## `run_local_step_<name>.sh` — Local Runner

Allows running a step locally by simulating the GitHub Actions environment.

### Template

```bash
#!/bin/env bash
#
# Local testing/debugging script for step_<name>.sh
# Simulates GitHub Actions environment for testing locally.
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Set up GITHUB_OUTPUT like GitHub Actions does
export GITHUB_OUTPUT=$(mktemp)
export RUNNER_TEMP=$(mktemp -d)

# Required system variables
export GITHUB_ACTION_PATH="${_this_script_dir}"
export GITHUB_RUN_ID="12345678"
export GITHUB_ACTOR="test-user"
export GITHUB_EVENT_NAME="pull_request"
export GITHUB_REF="refs/pull/123/merge"
export GITHUB_SHA="abc123def456"
# ... add any other GITHUB_* variables the step uses

# Required input variables (match what action.yml would export)
export input_foo="test-value"
export input_bar="another-value"

# For JSON inputs, use multi-line exports
export input_json_data='{
  "key": "value",
  "nested": { "a": 1 }
}'

# Source the main script
source "${_this_script_dir}/step_<name>.sh"

# Display GitHub Actions outputs
echo ""
echo "========================================"
echo "GitHub Actions Outputs (GITHUB_OUTPUT):"
echo "========================================"
cat "${GITHUB_OUTPUT}"
```

### Key points

- Export **all** `GITHUB_*` variables that the step or helpers use.
- Export **all** `input_*` variables that the step expects.
- Use **realistic test data** that exercises the happy path — this is a debugging aid, not a test harness.
- Print the contents of `$GITHUB_OUTPUT` at the end so you can verify outputs.

---

## `run_tests_step_<name>.sh` — Per-Step Tests (Optional)

When an action has **multiple steps**, tests for each step can be organized into separate files. Each `run_tests_step_<name>.sh` contains all test cases for the corresponding `step_<name>.sh`. The `run_all_tests.sh` script then orchestrates them.

For **single-step actions**, this file is not needed — put all tests directly in `run_all_tests.sh`.

The structure of a per-step test file is identical to `run_all_tests.sh` (see below) — same test counters, `run_test`/`run_error_test` functions, and summary output. The only difference is that it tests one specific step.

---

## `run_all_tests.sh` — Automated Tests

For single-step actions, this is a self-contained test suite. For multi-step actions, it orchestrates the per-step test scripts.

### Multi-step orchestrator pattern

```bash
#!/bin/env bash
#
# Run all tests for this action
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

overall_exit=0

echo "Running tests for step_<name_a>..."
bash "${_this_script_dir}/run_tests_step_<name_a>.sh" || overall_exit=1

echo ""
echo "Running tests for step_<name_b>..."
bash "${_this_script_dir}/run_tests_step_<name_b>.sh" || overall_exit=1

exit ${overall_exit}
```

### Single-step / per-step test structure

```bash
#!/bin/env bash
#
# Test runner for step_<name>.sh
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=0

# Generic test runner function
run_test() {
  local test_name="${1}"
  local expected_value="${2}"       # What to assert
  # ... additional params as needed

  TESTS_RUN=$((TESTS_RUN + 1))

  echo -e "${BLUE}TEST ${TESTS_RUN}: ${test_name}${NC}"

  # Set up fresh GITHUB_OUTPUT
  export GITHUB_OUTPUT=$(mktemp)
  export GITHUB_ACTION_PATH="${_this_script_dir}"
  # ... set other GITHUB_* variables

  # Run step in a subshell
  (
    set -o allexport
    source "${_this_script_dir}/step_<name>.sh"
  ) > /tmp/test_output.txt 2>&1
  local exit_code=$?

  # Assert on outputs (read from $GITHUB_OUTPUT) or exit code
  local actual_value
  actual_value=$(grep "^my-output=" "${GITHUB_OUTPUT}" | cut -d= -f2)

  if [[ "${actual_value}" == "${expected_value}" ]]; then
    echo -e "${GREEN}✓ PASSED${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAILED${NC}: expected '${expected_value}', got '${actual_value}'"
    cat /tmp/test_output.txt
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi

  # Cleanup
  rm -f "${GITHUB_OUTPUT}"
}

# For tests that expect an error exit code
run_error_test() {
  local test_name="${1}"
  # ... similar structure, asserts exit_code != 0
}

# --------------------------------------------------
# Test cases
# --------------------------------------------------

# Test 1: Happy path
export input_foo="good-value"
run_test "Happy path produces correct output" "expected-result"

# Test 2: Edge case
export input_foo=""
run_test "Empty input handled gracefully" "default-result"

# ... more tests ...

# --------------------------------------------------
# Summary
# --------------------------------------------------
echo ""
echo "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"

if [[ ${TESTS_FAILED} -gt 0 ]]; then
  exit 1
else
  exit 0
fi
```

### Test design guidelines

- **Each test runs in a subshell** — prevents state leakage between tests.
- **Redirect stdout/stderr to a file** — show output only on failure to keep the summary clean.
- **Assert on `$GITHUB_OUTPUT` contents** or on output files, not on log messages.
- **Provide both `run_test` (assert output) and `run_error_test` (assert failure)** functions.
- **Use a `reset_defaults` or `create_metadata_file` helper** to reduce boilerplate if many tests share structure.
- **Cover edge cases**: empty inputs, null values, invalid JSON, missing fields, boundary values.
- **Exit with code 1 if any test failed** so CI can catch regressions.
- **Emit the canonical summary lines** — three lines, exactly: `Tests run:    <N>`, `Tests passed: <N>`, `Tests failed: <N>`. These are parsed by the [action-tests workflow](../.github/workflows/action-tests.yml) to populate per-action and total test counts in the PR comment summary. ANSI color codes around the numbers are fine; the format of the rest of the line must not drift (no "Total tests:", no "Passed:", etc.). See [Testing-in-ci.md §4](Testing-in-ci.md#4-test-count-parsing-contract) for the full parsing contract.

---

## Converting an Existing Inline-Bash Action

Most existing actions embed their logic directly in `action.yml` YAML strings. Here is the process to convert them.

### Step-by-step

1. **Copy `helpers.sh`** from a reference action (e.g., `capture-matrix-job-meta/helpers.sh`) into the action directory. Do not modify it.

2. **Identify the steps** in `action.yml` that contain logic (anything beyond simple `source` or single-command checks). Each such step becomes a `step_<name>.sh`.

3. **Extract the bash code** from the `run:` block into `step_<name>.sh`:
   - Add the shebang `#!/bin/env bash`
   - Add a file-header comment describing the step
   - Add `source "${GITHUB_ACTION_PATH}/helpers.sh"` at the top
   - Wrap the logic in a `main` function
   - Add the exit stanza at the bottom
   - Replace GitHub Actions expression references (`${{ inputs.* }}`, `${{ github.* }}`) with `input_*` environment variables

4. **Update the `action.yml`** step to the thin shim pattern:
   - Move `${{ inputs.* }}` references into `env:` as `input_*` variables
   - Replace the `run:` block with the `set -o allexport` + `source` shim (no exit code capture needed)
   - Open the `run:` block with the one-line description comment (see [Every `run:` block opens with a description comment](#every-run-block-opens-with-a-description-comment))
   - Use heredocs for JSON inputs

5. **Create `run_local_step_<name>.sh`**:
   - Copy from a reference action (e.g., `capture-matrix-job-meta/run_local_step_capture.sh`)
   - Update the exported `input_*` variables to match the step's needs
   - Provide realistic test data

6. **Create `run_all_tests.sh`**:
   - Write test cases that exercise the converted logic
   - Cover the happy path and important edge cases
   - Existing inline code may not have been tested — this is a good opportunity to add coverage

7. **If action-specific helpers are needed**, create `helpers_additional.sh`. This is auto-loaded by `helpers.sh`.

8. **Test locally**:
   ```bash
   # Quick manual run
   bash my-action/run_local_step_<name>.sh

   # Full test suite
   bash my-action/run_all_tests.sh
   ```

### What stays in `action.yml`

Some steps are fine to keep inline:

- **Pre-requisite checks** (e.g., verifying a binary exists) — these are usually 3–5 lines and don't need their own test suite.
- **Steps that are purely declarative** (e.g., `uses: actions/upload-artifact@v7`).
- **Pass-through steps** that only set a condition (`if:`) and print a message.

Use your judgement — the goal is testability, not blind extraction.

### Before & after example

**Before** (inline bash in `action.yml`):

```yaml
- id: plan
  shell: bash
  run: |
    set -o allexport; source "${{ github.action_path }}/helpers.sh"; set +o allexport;

    PLAN_FILE="${GITHUB_WORKSPACE}/plan-${{ inputs.environment-name }}.plan"
    set-output 'plan-file' "${PLAN_FILE}"

    PLAN_CMD="terraform plan -out=${PLAN_FILE} ${{ inputs.extra-plan-args }}"
    start-group "'terraform plan'"
    set +e
    ${PLAN_CMD} 2>&1 | tee output.txt
    PLAN_EXIT_CODE=${?}
    # ... 40 more lines of exit code handling ...
    end-group
```

**After** — `action.yml` step:

```yaml
- id: plan
  shell: bash
  env:
    input_environment_name: ${{ inputs.environment-name }}
    input_extra_plan_args: ${{ inputs.extra-plan-args }}
  run: |
    # Run 'terraform plan' and save the plan file
    set -o allexport
    source "${{ github.action_path }}/step_plan.sh"
```

**After** — `step_plan.sh`:

```bash
#!/bin/env bash
#
# Source for the plan step
#
# Runs terraform plan and captures the output.
#
# Required environment variables:
#   input_environment_name  - Environment name for file naming
#   input_extra_plan_args   - Additional terraform plan arguments
#

set -o nounset
source "${GITHUB_ACTION_PATH}/helpers.sh"

function main {
  local plan_file="${GITHUB_WORKSPACE}/plan-${input_environment_name}.plan"
  set-output 'plan-file' "${plan_file}"

  local plan_cmd="terraform plan -out=${plan_file} ${input_extra_plan_args}"
  log-info "command: '${plan_cmd}'"
  start-group "'terraform plan'"

  set -o pipefail
  set +e
  ${plan_cmd} 2>&1 | tee output.txt
  local exit_code=${?}

  # ... exit code handling ...

  end-group
  return ${exit_code}
}

main
_main_exit_code=$?
exit ${_main_exit_code}
```

---

## Anti-pattern: exporting heredoc-captured JSON

**Don't do this:**

```yaml
run: |
  input_json_data=$(cat <<'EOF'
  ${{ inputs.json-data }}
  EOF
  )
  export input_json_data           # ← anti-pattern
  source "${{ github.action_path }}/step_my_step.sh"
```

Equally bad — capturing under allexport:

```yaml
run: |
  set -o allexport
  input_json_data=$(cat <<'EOF'    # ← variables created under allexport are auto-exported
  ${{ inputs.json-data }}
  EOF
  )
  source "${{ github.action_path }}/step_my_step.sh"
```

### Why it breaks

Under either form, `input_json_data` is in the shell's exported-variable set. At the next `fork+execve` — any time the step calls `jq`, `gh`, `terraform`, or any other external command — bash builds `envp` from the exported set. Linux enforces two limits on `envp`:

- `ARG_MAX` (~2 MB total across argv + envp), and
- `MAX_ARG_STRLEN` (128 KB per individual string on Ubuntu).

The 128 KB per-string limit is the closer one in practice — a single big JSON input (a long PR body in `github.event`, a 65 KB plan extract, the full `toJSON(steps)` for a busy matrix job) trips it. The fork fails with exit 126 "Argument list too long". The original step looks like it succeeded; whatever it forks dies. The bug is **size-dependent**, so it doesn't appear in tests and only surfaces in production on a calling repo with a big-enough input.

### Why it bites repeatedly

The pattern looks reasonable: the script is sourced from the shim, so why wouldn't you "make sure" the variable is visible by exporting it? But sourcing a script means it runs in the **same shell** — the script already sees the caller's variable table without `export`. The `export` only changes what reaches forked subprocesses, which is exactly where the danger lives. Once you internalize "source sees locals" the temptation to `export` evaporates.

This repo has been bitten by this exact bug multiple times: `capture-matrix-job-meta` (steps context with embedded plan extracts), `aggregate-validation-summaries` (paginated `gh api` responses), `pr-comment` (user-supplied comment body), `auto-merge-pr` (`github.event` JSON on PRs with long descriptions). Each fix was a one-line removal of the `export` (plus, in the more sophisticated cases, an internal switch from `--argjson` to `--slurpfile` for jq). Reference implementations are in the corresponding action directories.

### The safe pattern (recap)

```yaml
run: |
  # <What this step does>
  #
  # Heredoc capture, NOT exported.
  input_json_data=$(cat <<'EOF'
  ${{ inputs.json-data }}
  EOF
  )

  # set -o allexport AFTER the heredoc so this variable isn't auto-exported.
  set -o allexport
  source "${{ github.action_path }}/step_my_step.sh"
```

Inside the step script: read `${input_json_data}` directly, or — if it might be very large and needs to be passed to a forked tool — write it to a tempfile and pass the path (`jq --slurpfile`, `gh api -F body=@<file>`, etc). See [CLAUDE.md → "Watch for ARG_MAX in step scripts"](../CLAUDE.md) for the in-tree reference patterns.

### When to actually export

`export FOO=value` is correct when you need an external command (e.g., `terraform`) to see `FOO` via the environment. In that case the data is bounded (a directory path, a flag, a token) and won't trip ARG_MAX. The anti-pattern is specifically about exporting **large user-supplied content** that the step only reads.

---

## Checklist

Use this checklist when creating or converting an action:

- [ ] `helpers.sh` is present and identical to the shared version
- [ ] `helpers_additional.sh` exists if action-specific helpers are needed
- [ ] Each non-trivial step has a `step_<name>.sh` file
- [ ] Each `step_<name>.sh` sources `helpers.sh`, uses a `main` function, and ends with `exit`
- [ ] `action.yml` steps use the `set -o allexport` + `source` shim (no exit code capture)
- [ ] Every `run:` block starts with a one-line `#` comment describing what the step does
- [ ] JSON inputs are passed via heredocs in the YAML shim
- [ ] Each step has a `run_local_step_<name>.sh` with realistic test data
- [ ] Multi-step actions have `run_tests_step_<name>.sh` per step, orchestrated by `run_all_tests.sh`
- [ ] `run_all_tests.sh` covers happy path, edge cases, and error conditions
- [ ] Tests run in subshells and assert on `$GITHUB_OUTPUT` or exit codes
- [ ] `run_all_tests.sh` exits with code 1 on any failure
- [ ] All scripts have the `#!/bin/env bash` shebang
- [ ] `helpers_additional.sh` only contains production code used by `step_<name>.sh` scripts
- [ ] All scripts have a file-header comment describing their purpose
