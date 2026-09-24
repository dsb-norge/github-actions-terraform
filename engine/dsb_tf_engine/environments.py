"""Environment rows: the port of the bash matrix builder, rule 7 of docs/Decision-engine.md §6.

Every row carries the workflow's variables in the types its gates compare (D9): a workflow input,
forwarded or set per environment, is a string ("true"/"false" for a boolean input), a
per-environment key that is not an input keeps its YAML type, and
allow-failing-terraform-operations is the one JSON boolean. The comments name the bash behaviour
each step reproduces where it is not obvious, because the goldens under tests/port pin all of it.
"""

import json
import re

from . import values
from .model import DocumentError


class ConfigError(Exception):
    """The caller's configuration is invalid. Carries the messages, in reporting order."""

    def __init__(self, messages):
        super().__init__("; ".join(messages))
        self.messages = messages


# The workflow inputs holding YAML. They are parsed by the shim, never forwarded, and removed
# from every row. Sorted, which is also the order a parse error is reported in.
YML_INPUTS = (
    "environments-yml",
    "extra-envs-from-secrets-per-goal-yml",
    "extra-envs-from-secrets-yml",
    "extra-envs-per-goal-yml",
    "extra-envs-yml",
    "goals-yml",
    "pr-auto-merge-from-actors-yml",
    "pr-auto-merge-limits-yml",
    "terraform-init-additional-dirs-yml",
)

# Replaced per environment: the environment's value, else the global one, else an empty list.
REPLACE_FIELDS = ("goals-yml", "terraform-init-additional-dirs-yml")

# Merged per environment: the environment's value merged into the global one.
MERGE_FIELDS = (
    "extra-envs-from-secrets-per-goal-yml",
    "extra-envs-from-secrets-yml",
    "extra-envs-per-goal-yml",
    "extra-envs-yml",
    "pr-auto-merge-from-actors-yml",
    "pr-auto-merge-limits-yml",
)

# The workflow's boolean inputs. Forwarded, they arrive as "true"/"false", the strings the
# workflow's gates compare (`== 'true'`); a per-environment value is normalised to the same, since
# a JSON boolean would compare false against 'true' and the setting would be silently dropped.
BOOLEAN_INPUTS = (
    "add-pr-comment", "apply-extract-include-outputs", "cache-terraform-modules",
    "format-check-in-root-dir", "path-relevance-enabled", "pr-auto-merge-enabled", "verify-lock-file",
)

# Relevance rules: resolved by relevance.py, never row variables.
RULE_FIELDS = ("paths", "paths-ignore")

# An environment name, and a github-environment, reach comment markers (':'-separated, ended by
# '-->'), artifact names, concurrency groups and shell; this is what is safe in all of them.
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,254}")
NAME_RULE = "1 to 255 of the characters A-Z a-z 0-9 . _ - starting with a letter or a digit"

# Maps from goal name to variables, which must hold every goal key.
PER_GOAL_FIELDS = ("extra-envs-from-secrets-per-goal", "extra-envs-per-goal")

# Fields the workflow reads from every row. runs-on and format-check-in-root-dir are read too
# but were never listed; the port keeps the list as it was.
REQUIRED_FIELDS = (
    "add-pr-comment", "allow-failing-terraform-operations", "apply-extract-include-outputs",
    "cache-terraform-modules", "caller-repo-calling-branch", "caller-repo-default-branch",
    "caller-repo-is-on-default-branch", "environment", "extra-envs", "extra-envs-from-secrets",
    "extra-envs-from-secrets-per-goal", "extra-envs-per-goal", "github-environment", "goals",
    "path-relevance-enabled", "pr-auto-merge-enabled", "pr-auto-merge-from-actors", "pr-auto-merge-limits", "pr-comment-group",
    "project-dir", "terraform-init-additional-dirs", "terraform-version", "tflint-version", "url",
    "verify-lock-file",
)

# Required fields that must not be the empty string. '[]', '{}' and null are not empty.
NOT_EMPTY_FIELDS = (
    "add-pr-comment", "allow-failing-terraform-operations", "apply-extract-include-outputs",
    "cache-terraform-modules", "caller-repo-calling-branch", "caller-repo-default-branch",
    "caller-repo-is-on-default-branch", "environment", "extra-envs", "extra-envs-from-secrets",
    "github-environment", "goals", "path-relevance-enabled", "pr-auto-merge-enabled", "pr-auto-merge-from-actors",
    "pr-auto-merge-limits", "project-dir", "terraform-version", "tflint-version", "verify-lock-file",
)


def _unsuffixed(field):
    return field[: -len("-yml")]


def shown(value):
    """A caller's value as a message shows it: a string quoted with its escapes, else JSON."""
    return repr(value) if isinstance(value, str) else json.dumps(value, ensure_ascii=False)


def _is_name(value):
    return isinstance(value, str) and NAME.fullmatch(value) is not None


def _boolean(name, field, value):
    """true or false, as a boolean or its string; anything else is an error, never a silent false."""
    if value is True or value == "true":
        return True
    if value is False or value == "false":
        return False
    raise ConfigError([f"The environment '{name}' sets '{field}' to {shown(value)}; it must be true or false!"])


def _typed_overrides(document, name, environment):
    """The environment's own values for workflow inputs, in the types the forwarded ones have."""
    typed = {}
    for field, value in environment.items():
        if field in BOOLEAN_INPUTS:
            typed[field] = "true" if _boolean(name, field, value) else "false"
        elif field in document["workflow_inputs"] and field not in YML_INPUTS and not isinstance(value, str):
            raise ConfigError([f"The environment '{name}' sets '{field}' to {shown(value)}, which is not a string; "
                               "quote it!"])
    return typed


def parsed_inputs(document):
    """The parsed value of every YAML input, raising on the first that did not parse.

    An input absent from the document parses as null, as an empty string did in bash.
    """
    parsed = {}
    for name in YML_INPUTS:
        result = document["yaml"]["inputs"].get(name, {"ok": True, "value": None})
        if not result["ok"]:
            raise ConfigError([f"The specification for input '{name}' is not valid yaml!"])
        parsed[name] = result["value"]
    return parsed


def _env_field(document, index, field):
    """A per-environment YAML field as the shim parsed it."""
    environments = document["yaml"]["environments"]
    result = environments[index].get(field) if index < len(environments) else None
    if result is None:
        raise DocumentError(f"input document: 'yaml.environments[{index}]' lacks '{field}'")
    if not result["ok"]:
        raise ConfigError([f"the environment's '{field}' is not valid yaml!"])
    return result["value"]


def build_row(document, globals_, index, environment):
    """One environment's row, in the order the bash builder assembled it."""
    if not isinstance(environment, dict) or "environment" not in environment:
        raise ConfigError(["Missing property 'environment' in environments-yml specification!"])
    name = environment["environment"]
    if not _is_name(name):
        raise ConfigError([f"The environment name {shown(name)} must be {NAME_RULE}!"])
    if "github-environment" in environment and not _is_name(environment["github-environment"]):
        raise ConfigError([f"The github-environment {shown(environment['github-environment'])} of environment "
                           f"'{name}' must be {NAME_RULE}!"])
    row = {key: value for key, value in environment.items() if key not in RULE_FIELDS}
    row.update(_typed_overrides(document, name, environment))

    row.setdefault("project-dir", f"./envs/{name}")

    # Generic forwarding: an input the environment does not set is copied in as a string.
    for input_name in sorted(document["workflow_inputs"]):
        if input_name not in row and input_name not in YML_INPUTS:
            row[input_name] = values.get_val(document["workflow_inputs"][input_name])

    row.setdefault("github-environment", name)

    # The one field the workflow reads with fromJSON(), so it must be a JSON boolean.
    flag = "allow-failing-terraform-operations"
    row[flag] = flag in row and _boolean(name, flag, row[flag])

    row.setdefault("url", "")

    for field in REPLACE_FIELDS:
        if field in row:
            row[_unsuffixed(field)] = _env_field(document, index, field)
        else:
            global_value = globals_[field]
            row[_unsuffixed(field)] = [] if global_value is None else global_value

    for field in MERGE_FIELDS:
        if field in row:
            try:
                row[_unsuffixed(field)] = values.merge(globals_[field], _env_field(document, index, field))
            except values.MergeError:
                raise ConfigError([
                    f"unable to merge the environment's '{field}' with the global value!",
                    "the two are probably of different shapes, e.g. a mapping globally and a plain value per environment.",
                ]) from None
        else:
            row[_unsuffixed(field)] = globals_[field]

    for field in PER_GOAL_FIELDS:
        if isinstance(row[field], str):
            raise ConfigError([f"the environment's '{field}' must be a mapping of goal names, not a string!"])
        row[field] = values.normalize_goal_keys(row[field])

    for field in YML_INPUTS:
        row.pop(field, None)

    default_branch = document["caller"]["default_branch"]
    ref_name = document["event"]["ref_name"]
    row["caller-repo-default-branch"] = default_branch
    row["caller-repo-calling-branch"] = ref_name
    row["caller-repo-is-on-default-branch"] = "true" if ref_name == default_branch else "false"
    return row


def project_dir_path(environment):
    """The path the directory check reads for an environment, known before its row is built.

    The adapter reports existence for exactly these paths, so the rule lives here once:
    the rendered `project-dir` when the environment names one, else `./envs/<environment>`.
    """
    if "project-dir" in environment:
        return values.render(environment["project-dir"])
    return f"./envs/{values.get_val(environment['environment'])}"


def validate_rows(document, rows):
    """The checks the workflow depends on, every failure of a group reported before stopping."""
    if not rows:
        raise ConfigError(["The specification is an empty array!"])

    messages = []
    for row in rows:
        messages += [f"Missing property '{f}' in environment specification!" for f in REQUIRED_FIELDS if f not in row]
        messages += [f"Property '{f}' is empty in environment specification!"
                     for f in NOT_EMPTY_FIELDS if f in row and values.render(row[f]) == ""]
    if messages:
        raise ConfigError(messages)

    directories = document["directories_exist"]
    messages = [
        f"The directory '{path}' does not exist, make sure 'project-dir' points to an existing directory!"
        for path in (values.render(row["project-dir"]) for row in rows)
        if not directories.get(path, False)
    ]
    if messages:
        raise ConfigError(messages)


def build_rows(document):
    """Every environment's row, in environments-yml order, or a ConfigError."""
    globals_ = parsed_inputs(document)
    environments = globals_["environments-yml"]
    if not isinstance(environments, list):
        raise ConfigError(["The specification for input 'environments-yml' must be a list of environments!"])

    rows = [build_row(document, globals_, index, environment) for index, environment in enumerate(environments)]

    seen = set()
    for row in rows:
        if row["environment"] in seen:
            raise ConfigError([f"Duplicate environment '{row['environment']}' in environments-yml specification!"])
        seen.add(row["environment"])

    # GitHub compares environment names without case, and the markers, the metadata artifact and the
    # concurrency group all key on this one.
    owners = {}
    for row in rows:
        owner = owners.setdefault(row["github-environment"].casefold(), row["environment"])
        if owner != row["environment"]:
            raise ConfigError([f"The environments '{owner}' and '{row['environment']}' share the github-environment "
                               f"'{row['github-environment']}'; it names their comments, metadata and concurrency "
                               "group, so each needs its own!"])

    validate_rows(document, rows)
    return rows
