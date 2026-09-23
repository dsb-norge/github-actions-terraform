"""Value handling that reproduces what the bash builder's jq pipelines produced.

The port promises byte-identical rows, so every conversion the bash builder did through
`jq -r` and command substitution is spelled out here once, instead of being approximated at
each call site.
"""

import json

# The goal keys valid in the per-goal environment-variable maps: the goals-yml vocabulary
# without 'all', which is shorthand expanded by the workflow's step conditions and so has
# nothing to attach per-goal values to. docs/Per-goal-environment-variables.md §2.2.
GOAL_KEYS = ("init", "format", "validate", "lint", "plan", "apply", "destroy-plan", "destroy")


class MergeError(Exception):
    """A global and a per-environment value whose shapes cannot be merged."""


def render(value):
    """What `jq -r` prints for a value, after command substitution strips trailing newlines.

    Used where the bash builder compared or stored text: the not-empty check, the directory
    check. A null renders as the four characters `null`, exactly as jq prints it.
    """
    # json.dumps gives jq's spelling of null, the booleans and numbers; the indent only shapes
    # containers, which jq prints indented by two.
    text = value if isinstance(value, str) else json.dumps(value, indent=2, ensure_ascii=False)
    return text.rstrip("\n")


def get_val(value):
    """`render`, except that null is the empty string.

    The bash builder read fields through `jq -r '.[$name] | select( . != null )'`, which
    prints nothing for null. Forwarded inputs, the environment name and the
    allow-failing flag all went through that filter.
    """
    return "" if value is None else render(value)


def merge(global_value, env_value):
    """Merge a global '*-yml' value with an environment's, the environment winning.

    Null on either side yields the other. Arrays concatenate, duplicates kept. Objects merge
    deeply, and a null leaf on the environment's side survives, which is what lets an
    environment unset a variable. docs/Per-goal-environment-variables.md §9.5.
    """
    if global_value is None:
        return env_value
    if env_value is None:
        return global_value
    if isinstance(global_value, list) and isinstance(env_value, list):
        return global_value + env_value
    if isinstance(global_value, dict) and isinstance(env_value, dict):
        return _deep_merge(global_value, env_value)
    # jq multiplied two numbers and repeated a string by a number here; neither is a merge
    # anyone meant, so every other pairing is refused.
    raise MergeError()


def _deep_merge(left, right):
    merged = dict(left)
    for key, value in right.items():
        if isinstance(merged.get(key), dict) and isinstance(value, dict):
            merged[key] = _deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def normalize_goal_keys(value):
    """Give a per-goal map every goal key, defaulting to an empty object.

    Without this the workflow renders `toJSON(matrix.vars.extra-envs-per-goal.plan)` as the
    string 'null' for an absent key, which the resolver's jq rejects. Null and false become
    the full key set (jq's `//` treats both as absent). Unknown keys and non-objects pass
    through untouched: rejecting them is resolve-goal-envs' job, so the caller gets one
    error from one place.
    """
    if value is None or value is False:
        value = {}
    if not isinstance(value, dict):
        return value
    normalized = dict(value)
    for key in GOAL_KEYS:
        normalized.setdefault(key, {})
    return normalized
