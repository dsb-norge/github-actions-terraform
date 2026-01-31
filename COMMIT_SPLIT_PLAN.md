# Commit Split Plan: 'wip: auto pr merge'

This document outlines how to split the monolithic commit `1152c43` into logical, atomic commits that can be reviewed and merged independently.

## Overview

The commit introduces three major features:
1. **New actions**: `capture-matrix-job-meta`, `evaluate-automerge-eligibility`, and `auto-merge-pr`
2. **Infrastructure changes**: New workflow inputs for auto-merge configuration
3. **Integration changes**: Workflow modifications to support auto-merge functionality

## Analysis of Dependencies

### Key Insights

1. **create-tf-vars-matrix/action.yml** has changes that belong to different features:
   - **runs-on removal** (lines 125-131): Related to global runs-on setting - should be grouped with runs-on changes
   - **Auto-merge inputs** (pr-auto-merge-*): Related to auto-merge feature
   - **Input field reordering/cleanup**: Can be introduced before other changes as preparatory refactoring
   - **Comment/typo fixes**: Can be part of preparatory refactoring

2. **.github/workflows/terraform-ci-cd-default.yml** has multiple independent changes:
   - Typo fixes ("passe" → "passed", "triggerd" → "triggered", "woraround" → "workaround")
   - Documentation improvements (reordering environment settings alphabetically, fixing descriptions)
   - New global `runs-on` input
   - PR auto-merge inputs (`pr-auto-merge-enabled`, `pr-auto-merge-from-actors-yml`, `pr-auto-merge-limits-yml`)
   - Conditional logic improvements (skip when PR closed/converted to draft)
   - Integration of new actions (capture-matrix-job-meta, automerge job)

## Proposed Commit Sequence

### Commit 1: Preparatory refactoring - typo fixes and documentation improvements
**Purpose**: Non-functional cleanup that improves readability and correctness

**Files changed**:
- `.github/workflows/terraform-ci-cd-default.yml`:
  - Line 10: "passe" → "passed"
  - Line 232: "woraround" → "workaround"
  - Line 260: "triggerd" → "triggered"
  - Line 53: Fix description "goals-yml" → "terraform-init-additional-dirs-yml"
  - Line 56: Fix description "goals-yml" → "extra-envs-yml"
  - Line 59: Fix description "goals-yml" → "extra-envs-from-secrets-yml"

**Benefits**:
- No functional changes
- Improves code quality
- Easy to review
- Won't conflict with subsequent changes

---

### Commit 2: Preparatory refactoring - reorder environment settings alphabetically
**Purpose**: Improve consistency and readability in documentation

**Files changed**:
- `.github/workflows/terraform-ci-cd-default.yml`:
  - Reorder environment settings in documentation (lines 41-61):
    - `allow-failing-terraform-operations`
    - `runs-on` → move to after `allow-failing-terraform-operations`
    - `terraform-version` → add to documentation
    - `tflint-version` → add to documentation
    - `format-check-in-root-dir` → add to documentation
    - `add-pr-comment` → add to documentation
    - `goals-yml`
    - `terraform-init-additional-dirs-yml`
    - `extra-envs-yml`
    - `extra-envs-from-secrets-yml`

**Benefits**:
- Alphabetical ordering improves discoverability
- Documents previously undocumented per-environment settings
- No functional changes
- Prepares for new settings to be added

---

### Commit 3: Preparatory refactoring - reorder and cleanup input fields in create-tf-vars-matrix
**Purpose**: Organize input fields alphabetically and add documentation comments

**Files changed**:
- `create-tf-vars-matrix/action.yml`:
  - Add comment about deliberately excluded fields (line 31-32)
  - Reorder YML_INPUTS alphabetically (lines 33-39)
  - Reorder DEFAULT_INPUT_YML_FIELDS section comment (line 125)
  - Reorder MERGE_INPUT_YML_FIELDS alphabetically (lines 162-165)
  - Update comment "extra-envs-*" → "yml fields that needs merge" (line 167)
  - Reorder REQ_FIELDS alphabetically (lines 221-235)
  - Reorder NOT_EMPTY_FIELDS alphabetically (lines 242-255)

**Benefits**:
- Alphabetical ordering improves maintainability
- Comment clarifies intent of excluded fields
- Easier to spot missing or duplicate fields
- No functional changes (preparation for adding auto-merge fields)

---

### Commit 4: Add global runs-on input to workflow
**Purpose**: Centralize runner configuration with global default

**Files changed**:
- `.github/workflows/terraform-ci-cd-default.yml`:
  - Add new input `runs-on` (lines 155-164)
  - Update `create-matrix` job to use `${{ inputs.runs-on }}` (line 269)
  - Update `conclusion` job to use `${{ inputs.runs-on }}` (line 577)

- `create-tf-vars-matrix/action.yml`:
  - Remove default 'ubuntu-latest' assignment logic (lines 125-131 removed)
  - This logic is now handled by the workflow's global `runs-on` input default

**Benefits**:
- Single source of truth for runner configuration
- Per-environment override still possible via environments-yml
- Simplifies create-tf-vars-matrix action
- All runner-related changes grouped together

**Rationale**: The removal of the `runs-on` default in `create-tf-vars-matrix/action.yml` is directly related to the addition of the global `runs-on` input in the workflow. Previously, the action set a default; now the workflow provides a global default that can still be overridden per-environment.

---

### Commit 5: Add skip logic for closed/draft PR events
**Purpose**: Prevent unnecessary operations when PR is being closed or converted to draft

**Files changed**:
- `.github/workflows/terraform-ci-cd-default.yml`:
  - Update validation summary step condition (lines 401-408):
    - Add `&& github.event.action != 'closed'`
    - Add `&& github.event.action != 'converted_to_draft'`
  - Update apply step condition (lines 507-508):
    - Add `&& github.event.action != 'closed'`
    - Add `&& github.event.action != 'converted_to_draft'`
  - Update destroy-apply step condition (lines 549-550):
    - Add `&& github.event.action != 'closed'`
    - Add `&& github.event.action != 'converted_to_draft'`

**Benefits**:
- Independent improvement to workflow logic
- Prevents wasted resources on PRs being closed
- No dependencies on auto-merge feature
- Clear, focused change

---

### Commit 6: Add capture-matrix-job-meta action
**Purpose**: Introduce new reusable action for capturing matrix job metadata

**Files created**:
- `capture-matrix-job-meta/action.yml`
- `capture-matrix-job-meta/helpers.sh`
- `capture-matrix-job-meta/run_all_tests.sh`
- `capture-matrix-job-meta/run_local_step_capture.sh`
- `capture-matrix-job-meta/step_capture.sh`

**Benefits**:
- Standalone action, no dependencies
- Can be tested independently
- Enables future metadata collection use cases
- Does not modify existing workflow

---

### Commit 7: Add evaluate-automerge-eligibility action
**Purpose**: Introduce new reusable action for evaluating PR auto-merge eligibility

**Files created**:
- `evaluate-automerge-eligibility/action.yml`
- `evaluate-automerge-eligibility/helpers.sh`
- `evaluate-automerge-eligibility/helpers_additional.sh`
- `evaluate-automerge-eligibility/run_all_tests.sh`
- `evaluate-automerge-eligibility/run_local_step_evaluate.sh`
- `evaluate-automerge-eligibility/step_evaluate.sh`

**Benefits**:
- Standalone action, no dependencies (other than expecting capture-matrix-job-meta output format)
- Can be tested independently
- Encapsulates complex eligibility logic
- Does not modify existing workflow

---

### Commit 8: Add auto-merge-pr action
**Purpose**: Introduce new reusable action for performing PR auto-merge

**Files created**:
- `auto-merge-pr/action.yml`
- `auto-merge-pr/helpers.sh`
- `auto-merge-pr/run_all_tests.sh`
- `auto-merge-pr/run_local_step_auto_merge_pr.sh`
- `auto-merge-pr/step_auto_merge_pr.sh`

**Benefits**:
- Standalone action, no dependencies
- Can be tested independently
- Encapsulates merge logic
- Does not modify existing workflow

---

### Commit 9: Add PR auto-merge configuration inputs
**Purpose**: Add workflow inputs for configuring auto-merge behavior

**Files changed**:
- `.github/workflows/terraform-ci-cd-default.yml`:
  - Add `pr-auto-merge-enabled` input (lines 155-161)
  - Add `pr-auto-merge-from-actors-yml` input (lines 162-175)
  - Add `pr-auto-merge-limits-yml` input (lines 176-208)

- `create-tf-vars-matrix/action.yml`:
  - Add `pr-auto-merge-enabled` to YML_INPUTS (line 36)
  - Add `pr-auto-merge-from-actors-yml` to YML_INPUTS (line 37)
  - Add `pr-auto-merge-limits-yml` to YML_INPUTS (line 38)
  - Add `pr-auto-merge-from-actors-yml` to MERGE_INPUT_YML_FIELDS (line 165)
  - Add `pr-auto-merge-limits-yml` to MERGE_INPUT_YML_FIELDS (line 166)
  - Add `pr-auto-merge-enabled` to REQ_FIELDS (line 230)
  - Add `pr-auto-merge-from-actors` to REQ_FIELDS (line 231)
  - Add `pr-auto-merge-limits` to REQ_FIELDS (line 232)
  - Add `pr-auto-merge-enabled` to NOT_EMPTY_FIELDS (line 252)
  - Add `pr-auto-merge-from-actors` to NOT_EMPTY_FIELDS (line 253)
  - Add `pr-auto-merge-limits` to NOT_EMPTY_FIELDS (line 254)

**Benefits**:
- Adds configuration infrastructure
- No functional behavior change (feature not activated yet)
- Can be tested by passing inputs
- Prepares for final integration

---

### Commit 10: Integrate auto-merge feature into workflow
**Purpose**: Activate auto-merge functionality by integrating all new actions

**Files changed**:
- `.github/workflows/terraform-ci-cd-default.yml`:
  - Add capture-matrix-job-meta step to terraform-ci-cd job (lines 560-570)
  - Add entire automerge job (lines 590-637):
    - Job dependencies and conditional logic
    - Download metadata artifacts
    - Evaluate eligibility
    - Create GitHub App token
    - Perform auto-merge

**Benefits**:
- Final integration of all previous commits
- All dependencies in place (actions exist, inputs configured)
- Feature can be enabled/disabled via `pr-auto-merge-enabled` input
- Clear activation point

---

## Summary

**Total commits**: 10

**Dependency chain**:
1. Commits 1-3: Independent preparatory refactoring (can be merged immediately)
2. Commit 4: Independent infrastructure improvement (depends on commit 3 for clean diffs)
3. Commit 5: Independent workflow improvement
4. Commits 6-8: Independent new actions (can be developed/tested in parallel)
5. Commit 9: Depends on commit 3 (clean insertion into alphabetically ordered fields)
6. Commit 10: Depends on commits 6-9 (integrates everything)

**Merge strategy**:
- Commits 1-5 can be merged to main independently
- Commits 6-8 can be developed on separate branches if desired
- Commit 9 can be merged after commit 3
- Commit 10 should be merged last, after all dependencies

## Benefits of This Approach

1. **Reviewability**: Each commit has a clear, focused purpose
2. **Testability**: New actions can be tested before integration
3. **Rollback**: Individual commits can be reverted without affecting others
4. **Bisectability**: Git bisect will identify which specific change caused issues
5. **Documentation**: Commit messages tell the story of feature development
6. **Incrementality**: Early commits provide value even before final integration
7. **Reduced risk**: Feature can be enabled incrementally across repos

## Notes

- The alphabetical reordering in commit 3 makes commit 9 much cleaner
- The runs-on changes are logically grouped in commit 4
- Each new action (commits 6-8) can have comprehensive tests before integration
- The workflow remains functional after each commit (no breaking changes)
