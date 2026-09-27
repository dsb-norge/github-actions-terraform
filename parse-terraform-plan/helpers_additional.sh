#!/bin/env bash
#
# Action-specific helpers for parse-terraform-plan.
# Auto-loaded by helpers.sh.
#

# Count the changes of a JSON plan
# ================================
# Reads the file 'terraform show -json <planfile>' wrote and prints ONE
# tab-separated line on stdout:
#
#   ok <add> <change> <destroy> <import> <move> <remove> <outputs-change> <complete>
#   unknown <reason>
#
# <outputs-change> is 'true' when an output_changes entry's actions are
# anything but ["no-op"]. <complete> is 'true' only when the plan's "complete"
# is literally true, 'false' when it is false or the key is missing. Exits
# non-zero, with jq's message on stderr, when jq fails on the file: not JSON at
# all, or a document of a shape it cannot walk.
#
# jq reads the file itself: a JSON plan can be many megabytes, and nothing here
# may hold it in a shell variable while allexport is in scope (the ARG_MAX rule
# in CLAUDE.md). Only the one-line result comes back.
#
# What counts, from each resource_changes entry with mode "managed" (data
# sources, whose action is "read", count nowhere, and "no-op" counts nowhere):
#
#   add      actions holds "create"   a replacement, ["delete","create"] or
#   destroy  actions holds "delete"   ["create","delete"], counts under both
#   change   actions is ["update"]
#   import   change.importing is present, whatever the actions
#   move     previous_address is present and differs from address, whatever
#            the actions
#   remove   actions holds "forget"   a 'removed' block
#
# These are the categories of Terraform's own 'Plan:' line (imports included),
# plus the move and removal the line has no segment for.
#
# Unknown, rather than a count that might be wrong: a plan that errored, a
# document that is not a Terraform JSON plan of format 1.x, more than one
# document in the file, and a managed change without a list of actions.
#
# An incomplete plan ("complete": false: -target, deferred changes) is counted:
# its counts are what it plans, and a person reading the PR comment should see
# them. That it is not the whole plan is <complete>, reported apart, for a
# consumer that must refuse anything less than a complete plan.
function plan-json-counts {
  local json_file="${1}"
  jq -r -s '
    def unknown($why): "unknown\t\($why)";
    def holds($action): any(.change.actions[]; . == $action);
    if length != 1 then unknown("the file holds \(length) JSON documents, not one plan")
    else .[0]
      | if type != "object" or (.format_version | type) != "string" then
          unknown("it is not a Terraform JSON plan: no format_version")
        elif (.format_version | split(".") | .[0]) != "1" then
          unknown("its format_version \(.format_version) is not a 1.x Terraform JSON plan")
        elif .errored == true then
          unknown("the plan errored (errored: true)")
        elif ((.resource_changes // []) | type) != "array" then
          unknown("its resource_changes is not a list")
        elif ((.output_changes // {}) | type) != "object" then
          unknown("its output_changes is not an object")
        else
          [ (.resource_changes // [])[] | select(.mode == "managed") ] as $managed
          | if any($managed[]; (.change.actions | type) != "array" or any(.change.actions[]; type != "string")) then
              unknown("a managed resource change has no list of actions")
            else
              [ ($managed | map(select(holds("create"))) | length),
                ($managed | map(select(.change.actions == ["update"])) | length),
                ($managed | map(select(holds("delete"))) | length),
                ($managed | map(select(.change.importing != null)) | length),
                ($managed | map(select(.previous_address != null and .previous_address != .address)) | length),
                ($managed | map(select(holds("forget"))) | length),
                any((.output_changes // {})[]; .actions != ["no-op"]),
                (.complete == true)
              ]
              | "ok\t" + (map(tostring) | join("\t"))
            end
        end
    end
  ' "${json_file}"
}
