# Automerge Refactor Plan

## Overview

This plan outlines the steps to refactor the automerge functionality by leveraging the new `capture-matrix-job-meta` action. The goal is to simplify the workflow by removing redundant steps from the `terraform-ci-cd` job and consolidating automerge evaluation into the `automerge` job.

## Current State

### terraform-ci-cd job
1. **evaluate-automerge** step: Runs per-environment to evaluate automerge eligibility
2. **upload-automerge-evaluation** step: Uploads individual evaluation result JSON files as artifacts
3. **capture-metadata** step: Captures comprehensive metadata from all steps (including evaluate-automerge outputs)

### automerge job
1. **download-automerge-evaluations** step: Downloads `auto-merge-evaluation-result-*` artifacts
2. **evaluate-automerge** step: Inline bash that aggregates eligibility across environments
3. **app-token** step: Creates GitHub App token for merge operation
4. **automerge** step: Performs the actual merge

## Target State

### terraform-ci-cd job
- Remove **evaluate-automerge** step
- Remove **upload-automerge-evaluation** step
- Keep **capture-metadata** step (already captures all needed data)

### automerge job
- Download `matrix-job-meta-*` artifacts (from capture-matrix-job-meta action)
- Use updated **evaluate-automerge-eligibility** action to process all metadata files and produce aggregated eligibility
- Keep app-token and automerge steps

---

## Implementation Steps

### Step 1: Update the evaluate-automerge-eligibility action

The action currently operates on a single environment with explicit inputs. It needs to be refactored to:

#### 1.1 Change input model
- **Remove** all current inputs except those that can't be derived from metadata
- **Add** new input: `metadata-files-pattern` - glob pattern to find matrix-job-meta files (e.g., `matrix-job-meta-*.json`)

Note: we do not need unput for `github-actor` this will continue to be available from the environment as `$GITHUB_ACTOR` when the action script runs.

#### 1.2 Update data extraction logic
The action must extract the following from each `matrix-job-meta-*.json` file:

| Current Input | Source in metadata JSON |
|---------------|------------------------|
| `environment-name` | `.metadata.environment` |
| `pr-auto-merge-enabled` | `.matrix_context.vars.pr-auto-merge-enabled` |
| `pr-auto-merge-limits-json` | `.matrix_context.vars.pr-auto-merge-limits` |
| `pr-auto-merge-from-actors-json` | `.matrix_context.vars.pr-auto-merge-from-actors` |
| `plan-shouldve-been-created` | Derive from `.matrix_context.vars.goals` (contains 'all' or 'plan') |
| `plan-was-created` | `.steps.plan.outcome == 'success'` |
| `performing-apply-on-pr` | Derive from `.matrix_context.vars.goals` (contains 'apply-on-pr') |
| `apply-on-pr-succeeded` | `.steps.apply.outcome == 'success'` |
| `plan-count-add` | `.steps.parse-plan.outputs.count-add` |
| `plan-count-change` | `.steps.parse-plan.outputs.count-change` |
| `plan-count-destroy` | `.steps.parse-plan.outputs.count-destroy` |
| `plan-count-import` | `.steps.parse-plan.outputs.count-import` |
| `plan-count-move` | `.steps.parse-plan.outputs.count-move` |
| `plan-count-remove` | `.steps.parse-plan.outputs.count-remove` |
| `destroy-plan-shouldve-been-created` | Derive from `.matrix_context.vars.goals` (contains 'destroy-plan') |
| `destroy-plan-was-created` | `.steps.destroy-plan.outcome == 'success'` |
| `performing-destroy-on-pr` | Derive from `.matrix_context.vars.goals` (contains 'destroy-on-pr') |
| `destroy-on-pr-succeeded` | `.steps.destroy.outcome == 'success'` |
| `destroy-plan-count-add` | `.steps.parse-destroy-plan.outputs.count-add` |
| `destroy-plan-count-change` | `.steps.parse-destroy-plan.outputs.count-change` |
| `destroy-plan-count-destroy` | `.steps.parse-destroy-plan.outputs.count-destroy` |
| `destroy-plan-count-import` | `.steps.parse-destroy-plan.outputs.count-import` |
| `destroy-plan-count-move` | `.steps.parse-destroy-plan.outputs.count-move` |
| `destroy-plan-count-remove` | `.steps.parse-destroy-plan.outputs.count-remove` |

#### 1.3 Process multiple files
- Find all files matching the pattern
- Process each file and evaluate eligibility per environment
- Aggregate results: all environments must be eligible for final `should-auto-merge=true`

#### 1.4 Update outputs
- Keep `is-eligible` output (now represents aggregated result across all environments)
- Remove `result-json-file` output since we no longer create files

Note: the action creates files today, this is no longer needed since we only need the final aggregated result. We keep the console output for logging and debugging purposes.

#### 1.5 Update action.yml
- Update description to reflect new behavior
- Update inputs section with new inputs
- Update outputs section

#### 1.6 Update step_evaluate.sh
- Add file discovery logic (glob pattern matching)
- Add metadata parsing logic (jq to extract values from JSON structure)
- Wrap existing evaluation logic to process each environment
- Add aggregation logic to combine results

#### 1.7 Update/create helper functions
- Add function to extract values from metadata JSON
- Add function to derive boolean values from goals array
- Add function for aggregating multi-environment results

Note that the file `helpers.sh` already exists and contains some helper functions that can be reused. And that this file SHOULD NOT BE MODIFIED.

---

### Step 2: Update the terraform-ci-cd-default.yml workflow

#### 2.1 Remove evaluate-automerge step from terraform-ci-cd job
- Delete the entire `evaluate-automerge` step (lines ~568-601)

#### 2.2 Remove upload-automerge-evaluation step from terraform-ci-cd job
- Delete the entire `upload-automerge-evaluation` step (lines ~603-612)

#### 2.3 Update automerge job - download step
- Change artifact pattern from `auto-merge-evaluation-result-*` to `matrix-job-meta-*`

#### 2.4 Update automerge job - evaluate step
- Replace inline bash with call to updated `evaluate-automerge-eligibility` action
- Add checkout step to get action code (needed since action is used from same repo)
- Pass required inputs:
  - `metadata-files-pattern: matrix-job-meta-*.json`
  - `github-actor: ${{ github.actor }}`

---

### Step 3: Testing

#### 3.1 Unit tests for evaluate-automerge-eligibility action
- Test with single metadata file
- Test with multiple metadata files (all eligible)
- Test with multiple metadata files (some not eligible)
- Test with no metadata files found
- Test with malformed metadata files

Note that all tests should be contained in the file `run_all_tests.sh` in the action directory. This file already exists and should be adapted for the new logic, also the above list of tests should be included (if not already present).

As part of testing the file `run_local_step_evaluate.sh` should be updated to reflect the new input model. This file already exists and should be adapted accordingly.

#### 3.2 Integration testing

Out of scope for this plan but will be done after implementation.

---

### Step 4: Cleanup

#### 4.1 Remove legacy artifacts
- Update any documentation referencing the old artifact pattern
- Check if any other workflows depend on `auto-merge-evaluation-result-*` artifacts

#### 4.2 Update action documentation
- Update README or inline documentation for evaluate-automerge-eligibility action

---

## Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        terraform-ci-cd job (per env)                    │
│                                                                         │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌───────────────────────┐ │
│  │   init   │──▶│   plan   │──▶│  apply   │──▶│  capture-matrix-job-  │ │
│  │          │   │          │   │          │   │  meta (uploads        │ │
│  │          │   │          │   │          │   │  matrix-job-meta-     │ │
│  │          │   │          │   │          │   │  {env}.json)          │ │
│  └──────────┘   └──────────┘   └──────────┘   └───────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                            automerge job                                │
│                                                                         │
│  ┌───────────────────┐   ┌────────────────────────┐   ┌──────────────┐  │
│  │ download-artifact │──▶│ evaluate-automerge-    │──▶│   automerge  │  │
│  │ (matrix-job-meta- │   │ eligibility            │   │   action     │  │
│  │  *.json)          │   │ (processes all files,  │   │              │  │
│  │                   │   │  returns aggregated    │   │              │  │
│  │                   │   │  should-auto-merge)    │   │              │  │
│  └───────────────────┘   └────────────────────────┘   └──────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Risk Considerations

1. **Metadata file format stability**: The `capture-matrix-job-meta` action output format must remain stable or versioning must be considered
2. **Missing step data**: If a step is skipped, its data may be incomplete in metadata - handle gracefully
3. **Backwards compatibility**: Older workflow versions does not need to be supported
4. **Error handling**: Ensure robust error handling when metadata files are malformed or missing expected fields

---

## Success Criteria

- [ ] `evaluate-automerge` and `upload-automerge-evaluation` steps removed from `terraform-ci-cd` job
- [ ] `evaluate-automerge-eligibility` action successfully processes `matrix-job-meta-*.json` files
- [ ] Automerge job produces same eligibility decisions as before refactor
- [ ] All existing tests pass
- [ ] New tests for multi-file processing pass
- [ ] Script for running locally works with new input model with expected results
