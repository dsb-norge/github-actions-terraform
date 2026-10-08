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

# Classify a JSON plan (docs/Drift-detection.md §4, D3, D4)
# =========================================================
# For a plan plan-json-counts counted. Prints ONE tab-separated line:
#
#   ok <class> <count-drift> <count-drift-ignored> <has-pending-changes> <drift-addresses>
#   unknown <reason>
#
# drift    an address in resource_drift (managed) also has a planned action,
#          anything but "no-op" and "read": something changed outside Terraform
#          that the next apply would revert
# pending  any other change: a planned action, a move, an import, or an output
#          change
# clean    none
#
# <count-drift> counts those addresses; <count-drift-ignored> the other managed
# entries of resource_drift: drift no planned action reverts (ignore_changes, a
# value a provider normalises), never a finding. <has-pending-changes> is 'true'
# when the plan has a change on an address that did not drift, or, without
# drift, an output change: reverting drift changes the outputs that read it, so
# beside drift an output change is not a change of the plan's own.
# <drift-addresses> is the drifted addresses, sorted, as a compact JSON array of
# as many as fit in 3000 bytes, under the metadata capture's 4 KiB per output.
#
# Exits non-zero, with jq's message on stderr, when jq fails on the file.
_PLAN_JSON_CLASSIFY_DEFS='
  def acting: .change.actions | map(select(. != "no-op" and . != "read"));
  def managed($list): [ ($list // [])[] | select(.mode == "managed") ];
  def drifted($plan):
    managed($plan.resource_changes) as $changes
    | [ $changes[] | select(acting | length > 0) | .address ] as $acting
    | [ managed($plan.resource_drift)[] | .address ] | unique | map(select(IN($acting[])));
'
function plan-json-classify {
  local json_file="${1}"
  jq -r -s "${_PLAN_JSON_CLASSIFY_DEFS}"'
    .[0] as $plan
    | if (($plan.resource_drift // []) | type) != "array" then "unknown\tits resource_drift is not a list"
      else
        managed($plan.resource_changes) as $changes
        | drifted($plan) as $drift
        | (([ managed($plan.resource_drift)[] | .address ] | unique | length) - ($drift | length)) as $ignored
        | [ $changes[] | select((acting | length > 0) or .change.importing != null
                                or (.previous_address != null and .previous_address != .address)) | .address ]
          | unique as $changed
        | any(($plan.output_changes // {})[]; .actions != ["no-op"]) as $outputs
        | (any($changed[]; IN($drift[]) | not) or (($drift | length) == 0 and $outputs)) as $pending
        | (if ($drift | length) > 0 then "drift" elif ($changed | length) > 0 or $outputs then "pending" else "clean" end) as $class
        | (reduce $drift[] as $address ({shown: [], full: false};
             if .full then .
             elif ((.shown + [$address]) | tojson | utf8bytelength) <= 3000 then .shown += [$address]
             else .full = true end) | .shown) as $shown
        | [ "ok", $class, ($drift | length), $ignored, $pending, ($shown | tojson) ] | map(tostring) | join("\t")
      end
  ' "${json_file}"
}

# The fingerprint of a classified JSON plan (docs/Drift-detection.md D4): the
# SHA-256, in lowercase hex, of its sorted lines, each ending in a newline:
#
#   <address> <actions>               every managed change but "no-op" and "read",
#                                     the actions joined with ','
#   <address> moved-from <previous>   a move
#   <address> importing               an import
#   output <name> <actions>           an output change
#   <address> drifted                 drift by D3
#
# Equal fingerprints are the same finding; an unrelated no-op changes nothing.
function plan-json-fingerprint {
  local json_file="${1}" lines_file
  lines_file="$(mktemp)"
  if ! jq -j -s "${_PLAN_JSON_CLASSIFY_DEFS}"'
    .[0] as $plan
    | managed($plan.resource_changes) as $changes
    | [ $changes[] | select(acting | length > 0) | "\(.address) \(.change.actions | join(","))" ]
      + [ $changes[] | select(.previous_address != null and .previous_address != .address)
          | "\(.address) moved-from \(.previous_address)" ]
      + [ $changes[] | select(.change.importing != null) | "\(.address) importing" ]
      + [ ($plan.output_changes // {}) | to_entries[] | select(.value.actions != ["no-op"])
          | "output \(.key) \(.value.actions | join(","))" ]
      + [ drifted($plan)[] | "\(.) drifted" ]
    | sort | map(. + "\n") | add // ""
  ' "${json_file}" >"${lines_file}"; then
    rm -f "${lines_file}"
    return 1
  fi
  sha256sum "${lines_file}" | cut -d' ' -f1
  rm -f "${lines_file}"
}
