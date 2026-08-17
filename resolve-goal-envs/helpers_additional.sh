#!/bin/env bash
#
# Action-specific helpers for resolve-goal-envs.
# Auto-loaded by helpers.sh.
#
# Everything here reads JSON from files rather than from shell variables. The
# secrets bag is the one genuinely large payload in this action — a bag holding
# a PEM private key is enough on its own — and under 'set -o allexport' any
# variable holding it, 'local' included, lands in envp for the next fork.
# Ref. docs/Per-goal-environment-variables.md §8.
#

# The goals per-goal environment variables can be attached to. Same vocabulary
# a caller writes in 'goals-yml', with two deliberate differences:
#
#   - 'format', not 'fmt': the caller-facing name follows goals-yml, even
#     though the workflow step id is 'fmt'.
#   - no 'all': it is not a stage but shorthand expanded inside each workflow
#     step's 'if:', so there is nothing to attach values to. The every-goal
#     layer is the plain 'extra-envs-yml'. Rejecting it as an unknown key is
#     what makes 'all:' fail loudly instead of silently doing nothing.
#
# 'destroy-plan' / 'destroy' are separate from 'plan' / 'apply' even though
# they reuse the same two actions — that is what lets a destroy plan be tuned
# independently. Kept in sync with create-tf-vars-matrix and
# docs/Per-goal-environment-variables.md §2.2.
GOAL_KEYS=(
  init
  format
  validate
  lint
  plan
  apply
  destroy-plan
  destroy
)

# Make sure the file $1 holds a JSON object, using $2 as the input's name in
# error messages.
#
# An empty file, a whitespace-only file, or a literal JSON 'null' all mean
# "nothing configured" and become '{}'. 'null' in particular is what
# 'toJSON(...)' renders for a matrix key that does not exist.
function normalize-json-object-file {
  local file="${1}" label="${2}" json_type

  if ! grep -q '[^[:space:]]' "${file}" 2>/dev/null; then
    printf '{}' >"${file}"
    return 0
  fi

  if ! json_type=$(jq -r 'type' "${file}" 2>/dev/null); then
    log-error "input '${label}' is not valid JSON!"
    return 1
  fi

  if [ "${json_type}" == 'null' ]; then
    printf '{}' >"${file}"
    return 0
  fi

  if [ "${json_type}" != 'object' ]; then
    log-error "input '${label}' must be a JSON object, got '${json_type}'!"
    return 1
  fi

  return 0
}

# Echo one line per problem found in the input files under $1. No output means
# the inputs are valid.
#
# Every check happens here, at the single site that resolves per-goal values,
# so a typo is caught once and early rather than surfacing as a terraform
# failure far from its cause. Messages name keys, goals and secret *names* —
# never values, see log hygiene in
# docs/Per-goal-environment-variables.md §5.5.
function find-input-errors {
  local work_dir="${1}"

  jq -n -r \
    --slurpfile plain "${work_dir}/global-plain.json" \
    --slurpfile secret_map "${work_dir}/global-secrets.json" \
    --slurpfile goal_plain "${work_dir}/per-goal-plain.json" \
    --slurpfile goal_secret_map "${work_dir}/per-goal-secrets.json" \
    --slurpfile bag "${work_dir}/secrets.json" \
    '
      def NAME_RE: "^[A-Za-z_][A-Za-z0-9_]*$";

      def bad_names($ctx):
        to_entries[]
        | select(.key | test(NAME_RE) | not)
        | "\($ctx): \"\(.key)\" is not a valid environment variable name, it must match \(NAME_RE)";

      def bad_values($ctx):
        to_entries[]
        | select(.value != null)
        | select((.value | type) as $t | $t != "string" and $t != "number" and $t != "boolean")
        | "\($ctx): the value of \"\(.key)\" is of type \(.value | type), only string, number, boolean or null are allowed";

      def bad_secret_names($ctx):
        to_entries[]
        | select(((.value | type) != "string") or ((.value | length) == 0))
        | "\($ctx): the secret name for \"\(.key)\" must be a non-empty string";

      # The entry is bound before the has() test: jq evaluates the argument of
      # has() against the input of has(), so a bare .value in there would
      # resolve against the secrets bag rather than against the entry.
      def missing_secrets($ctx; $secrets):
        to_entries[]
        | select(((.value | type) == "string") and ((.value | length) > 0))
        | . as $entry
        | select($secrets | has($entry.value) | not)
        | "\($ctx): secret \"\($entry.value)\", mapped to environment variable \"\($entry.key)\", is not available to the workflow";

      def bad_goal_keys($ctx; $goals):
        keys[]
        | select(IN($goals[]) | not)
        | "\($ctx): \"\(.)\" is not a valid goal, valid goals are: \($goals | join(", "))";

      # A null goal value is accepted, not rejected: writing
      #   extra-envs-per-goal-yml: |
      #     plan:
      # is natural YAML for "nothing here yet", and yq renders it as null. It
      # resolves the same as an absent key.
      def bad_goal_values($ctx):
        to_entries[]
        | select((.value != null) and ((.value | type) != "object"))
        | "\($ctx): the value of goal \"\(.key)\" must be a mapping of environment variables, got \(.value | type)";

      def goal_maps: to_entries[] | select((.value | type) == "object");

      $ARGS.positional as $goals
      | (($plain[0]) // {}) as $p
      | (($secret_map[0]) // {}) as $s
      | (($goal_plain[0]) // {}) as $gp
      | (($goal_secret_map[0]) // {}) as $gs
      | (($bag[0]) // {}) as $secrets
      | [
          ($p  | bad_names("extra-envs")),
          ($p  | bad_values("extra-envs")),
          ($s  | bad_names("extra-envs-from-secrets")),
          ($s  | bad_secret_names("extra-envs-from-secrets")),
          ($s  | missing_secrets("extra-envs-from-secrets"; $secrets)),
          ($gp | bad_goal_keys("extra-envs-per-goal"; $goals)),
          ($gp | bad_goal_values("extra-envs-per-goal")),
          ($gp | goal_maps | .key as $g | .value | bad_names("extra-envs-per-goal.\($g)")),
          ($gp | goal_maps | .key as $g | .value | bad_values("extra-envs-per-goal.\($g)")),
          ($gs | bad_goal_keys("extra-envs-from-secrets-per-goal"; $goals)),
          ($gs | bad_goal_values("extra-envs-from-secrets-per-goal")),
          ($gs | goal_maps | .key as $g | .value | bad_names("extra-envs-from-secrets-per-goal.\($g)")),
          ($gs | goal_maps | .key as $g | .value | bad_secret_names("extra-envs-from-secrets-per-goal.\($g)")),
          ($gs | goal_maps | .key as $g | .value | missing_secrets("extra-envs-from-secrets-per-goal.\($g)"; $secrets))
        ]
      | .[]
    ' \
    --args "${GOAL_KEYS[@]}"
}

# Resolve the effective environment for one goal ($2) from the input files
# under $1, writing the result to $3.
#
# Overlay order, last wins (docs/Per-goal-environment-variables.md §2.3):
#
#   1. extra-envs
#   2. extra-envs-from-secrets, values replaced by the secret's value
#   3. extra-envs-per-goal[goal]
#   4. extra-envs-from-secrets-per-goal[goal], resolved as in 2
#
# Specificity beats source (3 beats 2) while secrets win within one
# specificity level (2 beats 1, 4 beats 3) — the latter preserves what
# export-env-vars already does today by running its plain loop before its
# secrets loop.
#
# jq's '+' on objects is a shallow right-wins merge that keeps null values,
# which is what makes "a null unsets the variable" survive every overlay.
function resolve-goal-envs-file {
  local work_dir="${1}" goal="${2}" out_file="${3}"

  jq -n \
    --slurpfile plain "${work_dir}/global-plain.json" \
    --slurpfile secret_map "${work_dir}/global-secrets.json" \
    --slurpfile goal_plain "${work_dir}/per-goal-plain.json" \
    --slurpfile goal_secret_map "${work_dir}/per-goal-secrets.json" \
    --slurpfile bag "${work_dir}/secrets.json" \
    --arg goal "${goal}" \
    '
      def resolve_from($secrets): with_entries(.value = $secrets[.value]);

      (($bag[0]) // {}) as $secrets
      | (($plain[0]) // {})
        + ((($secret_map[0]) // {}) | resolve_from($secrets))
        + (((($goal_plain[0]) // {})[$goal]) // {})
        + (((((($goal_secret_map[0]) // {})[$goal]) // {})) | resolve_from($secrets))
    ' >"${out_file}"
}

# ==========================================================
log-info "'$(basename ${BASH_SOURCE[0]})' loaded."
