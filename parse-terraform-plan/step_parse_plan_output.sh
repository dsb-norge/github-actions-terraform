#!/bin/env bash
#
# Source for the parse-plan-output step
#
# Parses a Terraform plan's console output file to extract resource change counts.
# Outputs the number of resources to be added, changed, destroyed, imported,
# moved, and removed.
#
# Required environment variables:
#   input_plan_console_file  - Path to the plan console output file
#

set +o nounset # allow unset variables (graceful handling of empty/missing input)

# Load helpers
source "${GITHUB_ACTION_PATH}/helpers.sh"

# ============================================================================
# Main Logic
# ============================================================================

function main {
  log-info "Starting parse-plan-output..."

  # Fallback output values when parsing fails
  local imports='?'
  local adds='?'
  local changes='?'
  local destroys='?'
  local moves='?'
  local removes='?'

  if [ ! -z "${input_plan_console_file:-}" ]; then
    log-info "parsing plan output file: ${input_plan_console_file}"

    if [ -s "${input_plan_console_file}" ]; then

      # Parse the Plan: line or detect "No changes." / output-only changes
      if grep -q "No changes." "${input_plan_console_file}"; then
        imports=0
        adds=0
        changes=0
        destroys=0
      elif grep -q "without changing any real infrastructure" "${input_plan_console_file}"; then
        # Output-only changes: Terraform reports changes to outputs but no resource changes.
        # There is no "Plan:" summary line in this case.
        log-info "detected output-only changes (no resource changes)"
        imports=0
        adds=0
        changes=0
        destroys=0
      else
        imports=0 # not always in the plan string
        local plan_line
        plan_line=$(grep "Plan: " "${input_plan_console_file}")
        if [ -n "$plan_line" ]; then
          if [[ $plan_line =~ ([0-9]+)\ to\ import ]]; then
            imports=${BASH_REMATCH[1]}
          fi
          if [[ $plan_line =~ ([0-9]+)\ to\ add ]]; then
            adds=${BASH_REMATCH[1]}
          else
            log-error "failed to parse, unable to find the number of resources to add in the plan file"
          fi
          if [[ $plan_line =~ ([0-9]+)\ to\ change ]]; then
            changes=${BASH_REMATCH[1]}
          else
            log-error "failed to parse, unable to find the number of resources that will be changed in the plan file"
          fi
          if [[ $plan_line =~ ([0-9]+)\ to\ destroy ]]; then
            destroys=${BASH_REMATCH[1]}
          else
            log-error "failed to parse, unable to find the number of resources to destroy in the plan file"
          fi
        else
          log-error "failed to parse, unable to find plan details in the plan file"
        fi
      fi

      # Count both types of move operations:
      # 1. "has moved to" - simple move without changes
      # 2. "(moved from" - move with in-place update
      # grep -c exits 0 on match, 1 on no match, 2+ on error
      local has_moved_count moved_from_count grep_rc_1 grep_rc_2
      set +e
      has_moved_count=$(grep -c "has moved to" "${input_plan_console_file}")
      grep_rc_1=$?
      moved_from_count=$(grep -c "(moved from" "${input_plan_console_file}")
      grep_rc_2=$?
      set -e
      if [ $grep_rc_1 -le 1 ] && [ $grep_rc_2 -le 1 ]; then
        moves=$((has_moved_count + moved_from_count))
      else
        log-error "failed to parse, unexpected error when counting moved resources in the plan file"
      fi

      # Count resources to be removed from state (no longer managed by Terraform).
      # Each such resource has a comment line like:
      #   # <resource_address> will no longer be managed by Terraform
      # We match lines starting with '#' to avoid counting summary warning lines like:
      #   Warning: Some objects will no longer be managed by Terraform
      # grep -c exits 0 on match, 1 on no match, 2+ on error
      local removed_count grep_rc
      set +e
      removed_count=$(grep -c "# .* will no longer be managed by Terraform" "${input_plan_console_file}")
      grep_rc=$?
      set -e
      if [ $grep_rc -le 1 ]; then
        removes=$removed_count
      else
        log-error "failed to parse, unexpected error when counting resources to be removed from the plan file"
      fi

    else
      log-error "plan console output file '${input_plan_console_file}' is empty!"
    fi
  fi

  set-output 'import-count' "${imports}"
  set-output 'add-count' "${adds}"
  set-output 'change-count' "${changes}"
  set-output 'destroy-count' "${destroys}"
  set-output 'move-count' "${moves}"
  set-output 'remove-count' "${removes}"

  log-info "parse-plan-output completed."
  return 0
}

# Run main function
main
_main_exit_code=$?
exit ${_main_exit_code}
