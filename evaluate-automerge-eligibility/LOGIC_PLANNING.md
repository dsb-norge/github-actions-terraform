# Automerge Eligibility Evaluation Logic Planning

## Overview

This document describes the detailed logic for evaluating whether a pull request is eligible for automatic merging based on Terraform plan changes, configured limits, and actor restrictions. The evaluation runs per-environment within a matrix job context.

## Inputs

### Environment Context

- `environment-name`: The name of the current deployment environment being evaluated (e.g., "sandbox")

### Actor Configuration

- `pr-auto-merge-from-actors-json`: JSON array of GitHub usernames allowed to trigger automerge
  - Empty array `[]` means PRs from all actors are evaluated
  - Non-empty array means current actor (from `${{ github.actor }}`) must be in the list
  - Examples: `["dependabot[bot]", "Laffs2k5"]` or `[]`

### Limits Configuration

- `pr-auto-merge-limits-json`: JSON object containing count limits for each operation type
  - Structure:

    ```json
    {
      "plan-max-count-add": <number or -1>,
      "plan-max-count-change": <number or -1>,
      "plan-max-count-destroy": <number or -1>,
      "plan-max-count-import": <number or -1>,
      "plan-max-count-move": <number or -1>,
      "plan-max-count-remove": <number or -1>
    }
    ```

  - Value of `-1` means any count is acceptable
  - Value of `0` or higher sets a specific limit
  - Missing/null/empty values are configuration errors

### Plan Creation Context

- `plan-shouldve-been-created`: Boolean indicating if a plan should have been created (based on goals)
- `plan-was-created`: Boolean indicating if a plan was successfully created
- `performing-apply-on-pr`: Boolean indicating if apply is being performed on the PR (goal: apply-on-pr)
- `apply-on-pr-succeeded`: Boolean indicating if apply-on-pr succeeded

### Plan Counts

- `plan-count-add`: Number of resources to add
- `plan-count-change`: Number of resources to change
- `plan-count-destroy`: Number of resources to destroy
- `plan-count-import`: Number of resources to import
- `plan-count-move`: Number of resources to move
- `plan-count-remove`: Number of resources to remove

**Note**: Empty/null counts indicate the plan parsing step did not run correctly. This may be acceptable depending on whether limits need to be evaluated (see "Ignoring Limits" section).

### Destroy Plan Creation Context

- `destroy-plan-shouldve-been-created`: Boolean indicating if a destroy plan should have been created
- `destroy-plan-was-created`: Boolean indicating if a destroy plan was successfully created
- `performing-destroy-on-pr`: Boolean indicating if destroy is being performed on the PR (goal: destroy-on-pr)
- `destroy-on-pr-succeeded`: Boolean indicating if destroy-on-pr succeeded

### Destroy Plan Counts

- `destroy-plan-count-add`: Number of resources to add in destroy plan
- `destroy-plan-count-change`: Number of resources to change in destroy plan
- `destroy-plan-count-destroy`: Number of resources to destroy in destroy plan
- `destroy-plan-count-import`: Number of resources to import in destroy plan
- `destroy-plan-count-move`: Number of resources to move in destroy plan
- `destroy-plan-count-remove`: Number of resources to remove in destroy plan

**Note**: Empty/null counts indicate the plan parsing step did not run correctly. This may be acceptable depending on whether limits need to be evaluated (see "Ignoring Limits" section).

## Outputs

- `is-eligible`: Boolean string ("true" or "false") indicating eligibility for automerge
- `result-txt-file`: Path to a text file containing detailed evaluation results for this environment

## Evaluation Logic

### Order of Evaluation

The evaluation should follow this order to fail fast and provide meaningful feedback:

1. **Configuration Validation**
   - Validate limits configuration (no empty/null values)
   - Parse actor list

2. **Actor Authorization Check**
   - Verify current actor is authorized (if actor list is not empty)

3. **Plan Creation Validation**
   - Verify expected plans were created
   - Check for plan creation failures

4. **Limit Applicability Determination**
   - Determine which limits should be evaluated
   - Determine which limits should be ignored

5. **Count Validation**
   - Validate counts are available when needed for evaluation

6. **Count Aggregation**
   - Combine plan and destroy-plan counts if both are being evaluated

7. **Limit Evaluation**
   - Compare aggregated counts against limits

8. **Final Eligibility Determination**
   - All checks must pass for eligibility

### 1. Configuration Validation

**Purpose**: Ensure the action has valid configuration before proceeding.

**Logic**:

- Parse `pr-auto-merge-limits-json` as JSON object
- For each limit field (`plan-max-count-add`, `plan-max-count-change`, etc.):
  - If value is null, undefined, or empty string: **ERROR - Invalid configuration**
  - If value is not a number: **ERROR - Invalid configuration**
  - Valid values are: `-1` (unlimited) or `0` or any positive integer

**Error Handling**: Configuration errors should fail the evaluation with clear error messages indicating which field is invalid.

### 2. Actor Authorization Check

**Purpose**: Ensure the PR author is authorized to trigger automerge.

**Logic**:

- Parse `pr-auto-merge-from-actors-json` as JSON array
- Get current actor from `${{ github.actor }}`
- If array is empty (`[]`):
  - **PASS** - All actors are allowed
- If array is not empty:
  - Check if current actor exists in the array (case-sensitive match)
  - If actor found: **PASS**
  - If actor not found: **FAIL** - Actor not authorized for automerge

**Failure Message**: "Actor '\<actor-name\>' is not authorized for PR automerge"

### 3. Plan Creation Validation

**Purpose**: Verify that expected plans were successfully created. **FAIL** means final conclusion is ineligible. Do not return error from the action.

**Logic for Regular Plan**:

- If `plan-shouldve-been-created` is `true`:
  - If `plan-was-created` is `false`: **FAIL** - Plan creation expected but failed
  - If `plan-was-created` is `true`: **PASS**
- If `plan-shouldve-been-created` is `false`:
  - Plan creation validation is **SKIPPED** (not applicable)

**Logic for Destroy Plan**:

- If `destroy-plan-shouldve-been-created` is `true`:
  - If `destroy-plan-was-created` is `false`: **FAIL** - Destroy plan creation expected but failed
  - If `destroy-plan-was-created` is `true`: **PASS**
- If `destroy-plan-shouldve-been-created` is `false`:
  - Destroy plan creation validation is **SKIPPED** (not applicable)

**Failure Messages**:

- "Plan was expected to have been created but was not, environment is ineligible for PR auto merge"
- "Destroy plan was expected to have been created but was not, environment is ineligible for PR auto merge"

### 4. Apply/Destroy Operation Success Check

**Purpose**: If operations are not being performed on the PR itself, ignore the limits. **FAIL** means final conclusion is ineligible. Do not return error from the action.

**Logic for Apply on PR**:

- If `performing-apply-on-pr` is `true`:
  - If `apply-on-pr-succeeded` is `false`: **FAIL** - Apply operation failed
  - If `apply-on-pr-succeeded` is `true`: **PASS**
- If `performing-apply-on-pr` is `false`:
  - Apply success check is **SKIPPED** (not applicable)

**Logic for Destroy on PR**:

- If `performing-destroy-on-pr` is `true`:
  - If `destroy-on-pr-succeeded` is `false`: **FAIL** - Destroy operation failed
  - If `destroy-on-pr-succeeded` is `true`: **PASS**
- If `performing-destroy-on-pr` is `false`:
  - Destroy success check is **SKIPPED** (not applicable)

**Failure Messages**:

- "Apply operation on PR was not expected to fail, environment is ineligible for PR auto merge"
- "Destroy operation on PR was not expected to fail, environment is ineligible for PR auto merge"

### 5. Limit Applicability Determination

**Purpose**: Determine which plan limits should be evaluated based on the workflow context.

**Ignore Plan Limits When**:

1. `plan-shouldve-been-created` is `false` - Plan wasn't supposed to be created
2. `performing-apply-on-pr` is `true` - Already applying changes on PR, plan is just preview

**Ignore Destroy Plan Limits When**:

1. `destroy-plan-shouldve-been-created` is `false` - Destroy plan wasn't supposed to be created
2. `performing-destroy-on-pr` is `true` - Already destroying on PR, plan is just preview

**Include Plan Limits When**:

- `plan-shouldve-been-created` is `true` AND
- `performing-apply-on-pr` is `false`

**Include Destroy Plan Limits When**:

- `destroy-plan-shouldve-been-created` is `true` AND
- `performing-destroy-on-pr` is `false`

**Special Case - All Limits Ignored**:

- If both plan limits and destroy plan limits are ignored, skip all limit evaluation
- Evaluation should **PASS** (no limits to check)
- Log: "All limits ignored, no evaluation needed for environment"

### 6. Count Validation

**Purpose**: Ensure count data is available when needed for limit evaluation. **FAIL** means final conclusion is ineligible. Do not return error from the action.

**Logic**:

- For each count type that will be evaluated (based on limit applicability):
  - If the count is empty, null, or not a valid number:
    - **FAIL** - "Plan parsing failed or did not run correctly"
  - If the count is a valid number (including 0):
    - **PASS**

**When to Check**:

- Only check counts for plans whose limits are being evaluated
- If plan limits are ignored, don't check plan counts
- If destroy plan limits are ignored, don't check destroy plan counts

**Failure Message**: "Required plan counts are missing or invalid. Plan parsing may have failed, environment is ineligible for PR auto merge"

### 7. Count Aggregation

**Purpose**: Combine counts from regular plan and destroy plan when both are being evaluated.

**Logic**:

**Scenario A - Only Plan Limits Evaluated**:

- Use plan counts directly:
  - `total-count-add` = `plan-count-add`
  - `total-count-change` = `plan-count-change`
  - `total-count-destroy` = `plan-count-destroy`
  - `total-count-import` = `plan-count-import`
  - `total-count-move` = `plan-count-move`
  - `total-count-remove` = `plan-count-remove`

**Scenario B - Only Destroy Plan Limits Evaluated**:

- Use destroy plan counts directly:
  - `total-count-add` = `destroy-plan-count-add`
  - `total-count-change` = `destroy-plan-count-change`
  - `total-count-destroy` = `destroy-plan-count-destroy`
  - `total-count-import` = `destroy-plan-count-import`
  - `total-count-move` = `destroy-plan-count-move`
  - `total-count-remove` = `destroy-plan-count-remove`

**Scenario C - Both Plan and Destroy Plan Limits Evaluated**:

- Add counts from both plans:
  - `total-count-add` = `plan-count-add` + `destroy-plan-count-add`
  - `total-count-change` = `plan-count-change` + `destroy-plan-count-change`
  - `total-count-destroy` = `plan-count-destroy` + `destroy-plan-count-destroy`
  - `total-count-import` = `plan-count-import` + `destroy-plan-count-import`
  - `total-count-move` = `plan-count-move` + `destroy-plan-count-move`
  - `total-count-remove` = `plan-count-remove` + `destroy-plan-count-remove`

**Example**: If limit is 1 change, plan has 1 change, and destroy plan has 1 change, total is 2 changes, which exceeds the limit.

### 8. Limit Evaluation

**Purpose**: Compare aggregated counts against configured limits.

**Logic for Each Count Type**:

- For each operation type (add, change, destroy, import, move, remove):
  - Get the limit value (e.g., `plan-max-count-add`)
  - Get the aggregated count (e.g., `total-count-add`)
  - If limit is `-1`:
    - **PASS** - Unlimited, any count is acceptable
  - If limit is `0` or higher:
    - If count &lt;= limit: **PASS**
    - If count &gt; limit: **FAIL** - Count exceeds limit

**Evaluation Strategy**:

- Evaluate all limits, not just until first failure
- Collect all limit violations for comprehensive feedback

**Failure Messages**:

- "Add count (\<count\>) exceeds limit (\<limit\>) in environment"
- "Change count (\<count\>) exceeds limit (\<limit\>) in environment"
- "Destroy count (\<count\>) exceeds limit (\<limit\>) in environment"
- "Import count (\<count\>) exceeds limit (\<limit\>) in environment"
- "Move count (\<count\>) exceeds limit (\<limit\>) in environment"
- "Remove count (\<count\>) exceeds limit (\<limit\>) in environment"

### 9. Final Eligibility Determination

**Purpose**: Determine final eligibility based on all checks.

**Logic**:

- Eligibility requires **ALL** of the following:
  1. Configuration validation passed
  2. Actor authorization passed (if applicable)
  3. Plan creation validation passed (if applicable)
  4. Destroy plan creation validation passed (if applicable)
  5. All applicable limits passed

**Log Messages**:

Make sure to log the outcome of each evaluation step for debugging purposes.

**Output**:

- If all checks passed: `is-eligible` = `"true"`
- If any check failed: `is-eligible` = `"false"`

## Additional Scenarios and Edge Cases

### Scenario: No Plans Required

- If `plan-shouldve-been-created` is `false` AND `destroy-plan-shouldve-been-created` is `false`
- All limits are ignored (nothing to evaluate)
- Actor check still applies
- Result: Likely eligible unless actor check fails

### Scenario: Only Destroy Plan Required

- If `plan-shouldve-been-created` is `false` AND `destroy-plan-shouldve-been-created` is `true`
- Only destroy plan limits are evaluated
- Plan counts are not needed
- Actor check still applies

### Scenario: Both Plans Required but Apply/Destroy on PR

- If `performing-apply-on-pr` is `true` AND `performing-destroy-on-pr` is `true`
- All limits are ignored (operations already performed)
- Must verify both operations succeeded
- Actor check still applies

### Scenario: Plan Parsing Failed but Limits Ignored

- Plan counts are empty/invalid
- But limits are ignored (e.g., performing-apply-on-pr is true)
- Validation should **PASS** (counts not needed)

### Scenario: Zero Changes

- All counts are 0
- Should **PASS** against any non-negative limit
- Should **PASS** against `-1` (unlimited)

### Scenario: Mixed Limits

- Some limits are `-1` (unlimited)
- Others have specific values
- Only evaluate limits with specific values
- Unlimited limits always pass

## Output File Format

The `result-txt-file` should contain structured information for debugging and cross-environment aggregation:

```text
Environment: <environment-name>
Actor: <github.actor>
Eligible: <true|false>

Configuration Validation: <PASS|FAIL|SKIPPED>
Actor Authorization: <PASS|FAIL|SKIPPED>
Plan Creation: <PASS|FAIL|SKIPPED>
Destroy Plan Creation: <PASS|FAIL|SKIPPED>
Apply on PR Success: <PASS|FAIL|SKIPPED>
Destroy on PR Success: <PASS|FAIL|SKIPPED>

Limits Evaluation:
  Plan Limits: <INCLUDED|IGNORED>
  Destroy Plan Limits: <INCLUDED|IGNORED>

  Add: <count> / <limit> - <PASS|FAIL>
  Change: <count> / <limit> - <PASS|FAIL>
  Destroy: <count> / <limit> - <PASS|FAIL>
  Import: <count> / <limit> - <PASS|FAIL>
  Move: <count> / <limit> - <PASS|FAIL>
  Remove: <count> / <limit> - <PASS|FAIL>

Failure Reasons:
  - <reason 1>
  - <reason 2>
  ...
```

## Implementation Considerations

### Error Handling

- Configuration errors should fail fast with clear messages
- Missing counts should not error, results in negative conclusion if limits need to be evaluated
- All validation failures should be collected before final determination

### Logging

- Log each evaluation step for debugging
- Do not include environment name in log messages
- Differentiate between PASS, FAIL, and SKIPPED states

### Performance

- Fail fast on configuration errors
- Fail fast on actor authorization (if applicable)
- Continue through limit evaluations to collect all violations

### Testing Scenarios

Implementation should be tested against these scenarios:

1. All limits ignored (apply-on-pr + destroy-on-pr)
2. Only plan limits evaluated
3. Only destroy plan limits evaluated
4. Both plan limits evaluated (aggregated counts)
5. Actor not in allowed list
6. Plan creation failed
7. Count exceeds single limit
8. Counts exceed multiple limits
9. All counts at exactly the limit
10. All counts below limits
11. Mixed limits (some -1, some specific values)
12. Zero changes
13. Missing counts when needed
14. Missing counts when not needed
15. Invalid configuration (empty limits)

## Integration with Matrix Jobs

This action runs once per environment in the matrix. The `terraform-ci-cd` job in the workflow executes this action as a step for each environment configuration.

The action receives environment-specific data from:

- `matrix.vars.pr-auto-merge-limits` → `pr-auto-merge-limits-json`
- `matrix.vars.pr-auto-merge-from-actors` → `pr-auto-merge-from-actors-json`
- `matrix.vars.github-environment` → `environment-name`

The output artifact (`result-txt-file`) is saved per environment and later aggregated by the `automerge` job to determine if the PR should be merged (all environments must be eligible).
