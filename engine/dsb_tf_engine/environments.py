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
    "notifications-yml",
    "pr-auto-merge-from-actors-yml",
    "pr-auto-merge-limits-yml",
    "terraform-init-additional-dirs-yml",
    "trigger-events-yml",
)

# The test stage's inputs: read by tests.py for the test rows, never forwarded into an environment's.
TEST_INPUTS = (
    "allow-failing-terraform-tests",
    "terraform-test-enabled",
    "terraform-test-exclude-paths-yml",
    "terraform-test-lanes-yml",
    "terraform-test-runs-on",
    "terraform-test-timeout-minutes",
)

# The Dependabot admission's inputs: read by admission.py, never forwarded (docs/Dependabot-admission.md §6).
ADMISSION_INPUTS = ("dependabot-admission-enabled", "dependabot-admission-yml")
# The list settings, replaced per environment: the environment's value, else the global one, a plain
# string written alone being its one item and none an empty list.
REPLACE_FIELDS = ("goals-yml", "pr-auto-merge-from-actors-yml", "terraform-init-additional-dirs-yml")

# Merged per environment: the environment's value merged into the global one.
MERGE_FIELDS = (
    "extra-envs-from-secrets-per-goal-yml",
    "extra-envs-from-secrets-yml",
    "extra-envs-per-goal-yml",
    "extra-envs-yml",
    "notifications-yml",
    "pr-auto-merge-limits-yml",
)

# The workflow's boolean inputs. Forwarded, they arrive as "true"/"false", the strings the
# workflow's gates compare (`== 'true'`); a per-environment value is normalised to the same, since
# a JSON boolean would compare false against 'true' and the setting would be silently dropped.
BOOLEAN_INPUTS = (
    "add-pr-comment", "apply-extract-include-outputs", "cache-terraform-modules",
    "format-check-in-root-dir", "path-relevance-enabled", "pr-auto-merge-enabled", "verify-lock-file",
)

# Relevance rules, trigger events, the schedule's cap and ordering: resolved by relevance.py, triggers.py
# and ordering.py, never row variables.
RULE_FIELDS = ("paths", "paths-ignore", "trigger-events", "schedule-goal", "depends-on")

# An environment name, and a github-environment, reach comment markers (':'-separated, ended by
# '-->'), artifact names, concurrency groups and shell; this is what is safe in all of them.
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,254}")
NAME_RULE = "1 to 255 of the characters A-Z a-z 0-9 . _ - starting with a letter or a digit"

# Maps from goal name to variables, which must hold every goal key.
PER_GOAL_FIELDS = ("extra-envs-from-secrets-per-goal", "extra-envs-per-goal")

# The keys an environments-yml entry may hold (docs/Configuration-validation.md §3.1), besides the
# per-environment inputs and the per-environment YAML settings below.
ENTRY_KEYS = ("environment", "project-dir", "github-environment", "url", "paths", "paths-ignore", "trigger-events",
              "schedule-goal", "depends-on", "allow-failing-terraform-operations")
# Workflow inputs an environment may override. A new input is in exactly one of this list, the YAML
# settings (REPLACE_FIELDS, MERGE_FIELDS) or WORKFLOW_ONLY_INPUTS; a test holds the workflow to it.
PER_ENVIRONMENT_INPUTS = ("add-pr-comment", "apply-extract-include-outputs", "cache-terraform-modules",
                          "format-check-in-root-dir", "pr-auto-merge-enabled", "pr-comment-group", "runs-on",
                          "terraform-version", "tflint-version", "verify-lock-file")
# path-relevance-enabled is refused per environment by relevance.py, with its own advice.
WORKFLOW_ONLY_INPUTS = ("environments-yml", "trigger-events-yml", "path-relevance-enabled", *TEST_INPUTS,
                        *ADMISSION_INPUTS, "pr-auto-merge-app-id", "pr-auto-merge-app-private-key-secret")
# What the engine writes into a row itself.
ENGINE_SET_FIELDS = ("goals-granted", "caller-repo-default-branch", "caller-repo-calling-branch",
                     "caller-repo-is-on-default-branch")
# Plain settings whose -yml spelling is a mistake per environment: lists, and one single value.
PLAIN_WITH_YML = ("paths", "paths-ignore", "trigger-events", "depends-on")
SCALAR_WITH_YML = ("schedule-goal",)
KEYS_DOC = "docs/Configuration-validation.md §3.1"

# Every goal a caller may name: the eight the operation gates read, 'all' for the five standard goals
# and apply, and the two that let apply and destroy run on a pull request.
GOALS = values.GOAL_KEYS + ("all", "apply-on-pr", "destroy-on-pr")

# Fields the workflow reads from every row.
REQUIRED_FIELDS = (
    "add-pr-comment", "allow-failing-terraform-operations", "apply-extract-include-outputs",
    "cache-terraform-modules", "caller-repo-calling-branch", "caller-repo-default-branch",
    "caller-repo-is-on-default-branch", "environment", "extra-envs", "extra-envs-from-secrets",
    "extra-envs-from-secrets-per-goal", "extra-envs-per-goal", "format-check-in-root-dir", "github-environment",
    "goals", "path-relevance-enabled", "pr-auto-merge-enabled", "pr-auto-merge-from-actors", "pr-auto-merge-limits",
    "pr-comment-group", "project-dir", "runs-on", "terraform-init-additional-dirs", "terraform-version",
    "tflint-version", "url", "verify-lock-file",
)

# Required fields that must not be the empty string. '[]', '{}' and null are not empty.
NOT_EMPTY_FIELDS = (
    "add-pr-comment", "allow-failing-terraform-operations", "apply-extract-include-outputs",
    "cache-terraform-modules", "caller-repo-calling-branch", "caller-repo-default-branch",
    "caller-repo-is-on-default-branch", "environment", "extra-envs", "extra-envs-from-secrets",
    "format-check-in-root-dir", "github-environment", "goals", "path-relevance-enabled", "pr-auto-merge-enabled",
    "pr-auto-merge-from-actors", "pr-auto-merge-limits", "project-dir", "runs-on", "terraform-version",
    "tflint-version", "verify-lock-file",
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


def _distance(left, right):
    """The Levenshtein distance between two names."""
    previous = range(len(right) + 1)
    for i, char in enumerate(left, 1):
        current = [i]
        for j, other in enumerate(right, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (char != other)))
        previous = current
    return previous[-1]


def near_miss(written, known):
    """The one known name within two edits of `written`, both lower cased, or None when there is none
    or two are equally near."""
    scored = sorted((_distance(written.lower(), name.lower()), name) for name in known)
    close = [(score, name) for score, name in scored if score <= 2]
    if not close or (len(close) > 1 and close[0][0] == close[1][0]):
        return None
    return close[0][1]


def _key_problem(name, key):
    """The message for an entry key the environment may not hold, or None."""
    yml = REPLACE_FIELDS + MERGE_FIELDS
    if key in ENTRY_KEYS or key in yml or key in PER_ENVIRONMENT_INPUTS or key == "path-relevance-enabled":
        return None
    if isinstance(key, str) and f"{key}-yml" in yml:
        return (f"The environment '{name}' sets '{key}', which is not a setting: per environment it is '{key}-yml'. "
                "Written like this it would have been ignored, and the environment would have run with the global "
                "value.")
    if isinstance(key, str) and key.endswith("-yml") and key[:-4] in PLAIN_WITH_YML + SCALAR_WITH_YML:
        written = "a list" if key[:-4] in PLAIN_WITH_YML else "a value"
        return (f"The environment '{name}' sets '{key}', which is not a setting: per environment it is "
                f"'{key[:-4]}', {written} written directly in the entry.")
    if key in WORKFLOW_ONLY_INPUTS:
        return (f"The environment '{name}' sets '{key}', which is a workflow input only: it applies to every "
                "environment at once. Set it in the calling workflow's 'with:'.")
    if key in ENGINE_SET_FIELDS:
        return f"The environment '{name}' sets '{key}', which the workflow works out itself; remove it."
    guess = near_miss(key, ENTRY_KEYS + yml + PER_ENVIRONMENT_INPUTS) if isinstance(key, str) else None
    hint = f"; did you mean '{guess}'?" if guess else "."
    return f"The environment '{name}' sets {shown(key)}, which is not a setting{hint} The settings an environment may hold are listed in {KEYS_DOC}."


def check_keys(environments):
    """Every key problem of every entry, in order, for the entries that name themselves."""
    return [problem for entry in environments
            if isinstance(entry, dict) and _is_name(entry.get("environment"))
            for problem in (_key_problem(entry["environment"], key) for key in sorted(entry, key=shown)) if problem]


# What each goal needs to have been granted too, or its step could never run (the gate of an apply
# needs a successful plan, of a plan an initialised directory, of a destroy a destroy plan).
PREREQUISITES = {
    "plan": (("init", "all"), "a plan needs an initialised directory", "Add 'init', or use 'all'."),
    "destroy-plan": (("init", "all"), "a destroy plan needs an initialised directory", "Add 'init', or use 'all'."),
    "apply": (("plan", "all"), "an apply deploys the plan", "Add 'plan', or use 'all'."),
    "apply-on-pr": (("plan", "all"), "an apply on a pull request deploys the plan", "Add 'plan', or use 'all'."),
    "destroy": (("destroy-plan",), "a destroy deploys the destroy plan", "Add 'destroy-plan'."),
    "destroy-on-pr": (("destroy-plan",), "a destroy on a pull request deploys the destroy plan", "Add 'destroy-plan'."),
}
GOAL_LIST = ", ".join(GOALS)


def as_list(value):
    """A list setting as a list: a plain string written alone is its one item, never split, and none
    is an empty list."""
    if value is None:
        return []
    return [value] if isinstance(value, str) else value


def _goal_name_problem(owner, goal):
    if isinstance(goal, str) and len(parts := [part for part in re.split(r"[\s,]+", goal) if part]) > 1 \
            and all(part in GOALS for part in parts):
        return (f"{owner} has the goal {shown(goal)}, which is not a goal. It looks like a list written without its "
                "dashes: YAML reads the lines as one piece of text. Write one goal per line starting with '- ', or "
                f"[{', '.join(parts)}].")
    if isinstance(goal, str) and goal.lower() in GOALS:
        return f"{owner} has the goal {shown(goal)}; goals are written in lower case: '{goal.lower()}'."
    guess = near_miss(goal, GOALS) if isinstance(goal, str) else None
    hint = f"; did you mean '{guess}'?" if guess else "."
    return f"{owner} has the goal {shown(goal)}, which is not a goal{hint} A goal is one of {GOAL_LIST}."


def goal_problems(owner, value):
    """Every problem of one goals value (docs/Configuration-validation.md §3.2); `owner` begins each message."""
    goals = as_list(value)
    if not isinstance(goals, list):
        return [f"{owner} has the goals {shown(value)}; they must be a list of goal names."]
    problems = [_goal_name_problem(owner, goal) for goal in goals if goal not in GOALS]
    if problems:
        return problems
    return [f"{owner} has the goal '{goal}' without '{needed[0]}': {why}, so it could never run. {fix}"
            for goal, (needed, why, fix) in PREREQUISITES.items()
            if goal in goals and not any(each in goals for each in needed)]


VARIABLE_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
# The job-wide variable maps, merged global then per environment (docs/Configuration-validation.md §3.5).
JOB_VARIABLES = ("extra-envs", "extra-envs-from-secrets")
JOB_VARIABLE_SETTINGS = tuple(f"{field}-yml" for field in JOB_VARIABLES)


def variable_problems(where, value):
    """Every problem of one job-wide variable map as written (docs/Configuration-validation.md §3.5); `where(key)`
    begins a message about one variable. A value that is not a mapping is left to the rules of its own."""
    if not isinstance(value, dict):
        return []
    problems = []
    for key, each in value.items():
        if not (isinstance(key, str) and VARIABLE_NAME.fullmatch(key)):
            problems.append(f"{where(key)} is not a variable name: a name is letters, digits and underscores, not "
                            "starting with a digit.")
        elif isinstance(each, (dict, list)):
            kind = "a mapping" if isinstance(each, dict) else "a list"
            marks = "braces" if isinstance(each, dict) else "brackets"
            problems.append(f"{where(key)} is {kind}; a variable's value is text. Quote it if the {marks} are part of "
                            "the value.")
        elif each is not None and not isinstance(each, str):
            problems.append(f"{where(key)} is {shown(each)}, which is not text; quote it.")
    return problems


def _without_nulls(value):
    """A job-wide variable map after the merge, its nulls dropped. A null means "not set", so a
    per-environment null removes a global variable; $GITHUB_ENV cannot unset one, and exporting it would
    give the job the text 'null'."""
    if not isinstance(value, dict):
        return value
    return {key: each for key, each in value.items() if each is not None}


INIT_DIRS = "terraform-init-additional-dirs-yml"


def init_dir_problems(owner, subject, value):
    """Every problem of one additional-init-directories value (docs/Configuration-validation.md §3.4).
    `owner` begins a message about one directory, `subject` one about the value as a whole."""
    directories = as_list(value)
    if not isinstance(directories, list):
        return [f"{subject} {shown(value)}; it must be a list of directories."]
    return [f"{owner} has the additional init directory '', which is empty." if directory == "" else
            f"{owner} has the additional init directory {shown(directory)}, which is not text; quote it."
            for directory in directories if directory == "" or not isinstance(directory, str)]


# Who may auto-merge, and within which plan counts (docs/Configuration-validation.md §3.6).
ACTORS = "pr-auto-merge-from-actors-yml"
LIMITS = "pr-auto-merge-limits-yml"
ENABLED = "pr-auto-merge-enabled"
# GitHub's login form; an App's bot account ends in [bot].
LOGIN = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}(\[bot\])?")
LIMIT_KEYS = ("plan-max-count-add", "plan-max-count-change", "plan-max-count-destroy", "plan-max-count-import",
              "plan-max-count-move", "plan-max-count-remove")
LIMIT_RULE = "the six limits are plan-max-count-add, -change, -destroy, -import, -move and -remove"
NAME_THE_ACTORS = ('so there is no one whose pull requests may merge without review. Name the accounts{where}, for '
                   'example ["dependabot[bot]"].')


def default_limits():
    """The input's documented default, which an absent or empty global value means; a new mapping each
    time, so no row shares one with the engine."""
    return {"plan-max-count-add": 0, "plan-max-count-change": 0, "plan-max-count-destroy": 0,
            "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": 0}


def _actor_problem(owner, actor):
    parts = [part for part in re.split(r"[\s,]+", actor) if part] if isinstance(actor, str) else []
    if len(parts) > 1 and all(LOGIN.fullmatch(part) for part in parts):
        return (f"{owner} holds {shown(actor)}, which is not a login. It looks like a list written without its "
                "dashes: write one account per line starting with '- ', or "
                f"[{', '.join(json.dumps(part) for part in parts)}].")
    if isinstance(actor, int) and not isinstance(actor, bool):
        return f"{owner} holds {shown(actor)}, which is not a login; quote it if it is one."
    return (f"{owner} holds {shown(actor)}, which is not a login: a login is letters, digits and hyphens, up to 39, "
            "not starting with a hyphen, and a bot's ends in [bot].")


def actor_problems(owner, subject, value):
    """Every problem of one actor list; `owner` begins a message about one actor, `subject` one about the
    value as a whole."""
    actors = as_list(value)
    if not isinstance(actors, list):
        return [f"{subject} {shown(value)}; it must be a list of logins."]
    return [_actor_problem(owner, actor) for actor in actors if not (isinstance(actor, str) and LOGIN.fullmatch(actor))]


def limit_problems(subject, key_subject, value):
    """Every problem of one limits mapping as written. `subject` begins a message about the value as a
    whole, `key_subject(key)` one about one of its keys. Missing keys are checked after the merge."""
    if value is None:
        return []
    if not isinstance(value, dict):
        return [f"{subject} {shown(value)}; it must be a mapping of the six limits."]
    problems = []
    for key, limit in value.items():
        if key not in LIMIT_KEYS:
            guess = near_miss(key, LIMIT_KEYS)
            problems.append(f"{key_subject(key)}, which is not a limit" + (f"; did you mean '{guess}'?" if guess
                                                                           else f"; {LIMIT_RULE}."))
        elif isinstance(limit, str):
            problems.append(f"{key_subject(key)} to {shown(limit)}, which is text; a limit is a whole number, written "
                            "without quotes, and -1 means no limit.")
        elif isinstance(limit, bool) or not isinstance(limit, int) or limit < -1:
            problems.append(f"{key_subject(key)} to {shown(limit)}; a limit is a whole number of -1 or more, and -1 "
                            "means no limit.")
    return problems


# Teams notifications (docs/Notifications.md §6): how each kind is routed, globally and per environment.
NOTIFICATIONS = "notifications-yml"
NOTIFY_KINDS = ("apply-cancelled", "apply-failed", "held-back")
NOTIFY_KEYS = ("defaults", "deliver-as", "enabled", "kinds", "runs-on")
# The jobs run once for the whole run, so these cannot differ per environment.
NOTIFY_WORKFLOW_WIDE = ("enabled", "runs-on")
ROUTE_KEYS = ("alias", "direct", "mention", "off", "remind")
PEOPLE = ("author", "merger")
# The relay's own rule for an alias, which is a path segment of the URL it is posted to.
ALIAS = re.compile(r"[a-z0-9][a-z0-9-]{0,48}[a-z0-9]")
ALIAS_RULE = "an alias is 2 to 50 of a-z 0-9 -, starting and ending with a letter or a digit"


def is_flag(value):
    """true or false, as a boolean or its text; never 1 or 0, which equal True and False in Python."""
    return value is True or value is False or value in ("true", "false")


def _guess(written, known):
    guess = near_miss(written, known)
    return f" (did you mean '{guess}'?)" if guess else ""


def _route_problems(owner, subject, where, value):
    """Every problem of the routing of the defaults or of one kind; `subject` names the value as a whole,
    `where` is the path its keys hang from."""
    if value is None:
        return []
    if not isinstance(value, dict):
        return [f"{owner}: {subject} is {shown(value)}; it must be a mapping of {', '.join(ROUTE_KEYS)}"]
    problems = []
    for key in sorted(value):
        each = value[key]
        if key not in ROUTE_KEYS:
            problems.append(f"{owner}: {where}: unknown key {shown(key)}{_guess(key, ROUTE_KEYS)}; known keys: "
                            f"{', '.join(ROUTE_KEYS)}")
        elif key == "alias" and not (isinstance(each, str) and ALIAS.fullmatch(each)):
            problems.append(f"{owner}: {where}.alias is {shown(each)}; {ALIAS_RULE}")
        elif key in ("direct", "mention") and not isinstance(as_list(each), list):
            problems.append(f"{owner}: {where}.{key} is {shown(each)}; it must be a list of author and merger")
        elif key in ("direct", "mention"):
            problems += [f"{owner}: {where}.{key} takes author and merger, not {shown(person)}"
                         for person in as_list(each) if person not in PEOPLE]
        elif key in ("off", "remind") and not is_flag(each):
            problems.append(f"{owner}: {where}.{key} is {shown(each)}; it must be true or false")
    return problems


def _kind_problems(owner, value):
    if value is None:
        return []
    if not isinstance(value, dict):
        return [f"{owner}: 'kinds' is {shown(value)}; it must be a mapping from a kind to its settings"]
    problems = []
    for kind in sorted(value):
        if kind in NOTIFY_KINDS:
            problems += _route_problems(owner, f"kinds.{kind}", f"kinds.{kind}", value[kind])
        else:
            problems.append(f"{owner}: kinds: unknown kind {shown(kind)}{_guess(kind, NOTIFY_KINDS)}; kinds: "
                            f"{', '.join(NOTIFY_KINDS)}")
    return problems


def notification_problems(owner, value, names, per_environment):
    """Every problem of one notifications-yml value (docs/Notifications.md §6.4); `owner` begins each message,
    `names` are the environments deliver-as may name. An environment may not set the workflow-wide keys."""
    if value is None:
        return []
    if not isinstance(value, dict):
        return [f"{owner} is {shown(value)}; it must be a mapping of settings (docs/Notifications.md §6.2)"]
    known = tuple(key for key in NOTIFY_KEYS if not (per_environment and key in NOTIFY_WORKFLOW_WIDE))
    problems = []
    for key in sorted(value):
        each = value[key]
        if per_environment and key in NOTIFY_WORKFLOW_WIDE:
            problems.append(f"{owner}: '{key}' is workflow-wide; set it in the {NOTIFICATIONS} input")
        elif key not in NOTIFY_KEYS:
            problems.append(f"{owner}: unknown key {shown(key)}{_guess(key, known)}; known keys: {', '.join(known)}")
        elif key == "enabled" and not is_flag(each):
            problems.append(f"{owner}: 'enabled' is {shown(each)}; it must be true or false")
        elif key == "runs-on" and not (isinstance(each, str) and each):
            problems.append(f"{owner}: 'runs-on' is {shown(each)}; it must be a runner label")
        elif key == "deliver-as" and each not in names:
            problems.append(f"{owner}: 'deliver-as' names {shown(each)}, which is not an environment of environments-yml")
        elif key == "defaults":
            problems += _route_problems(owner, "'defaults'", "defaults", each)
        elif key == "kinds":
            problems += _kind_problems(owner, each)
    return problems


def _setting_problems(document, globals_, environments):
    """Every problem of the list and limit settings as written, each global value once, naming the input,
    then each environment's own."""
    names = [entry["environment"] for entry in environments
             if isinstance(entry, dict) and _is_name(entry.get("environment"))]
    problems = goal_problems("goals-yml", globals_["goals-yml"])
    problems += init_dir_problems(INIT_DIRS, f"{INIT_DIRS} is", globals_[INIT_DIRS])
    problems += actor_problems(ACTORS, f"{ACTORS} is", globals_[ACTORS])
    problems += limit_problems(f"{LIMITS} is", lambda key: f"{LIMITS} sets {shown(key)}", globals_[LIMITS])
    for setting in JOB_VARIABLE_SETTINGS:
        problems += variable_problems(lambda key, setting=setting: f"The variable {shown(key)} in '{setting}'",
                                      globals_[setting])
    problems += notification_problems(NOTIFICATIONS, globals_[NOTIFICATIONS], names, False)
    for index, entry in enumerate(environments):
        if not (isinstance(entry, dict) and _is_name(entry.get("environment"))):
            continue
        name = entry["environment"]
        if "goals-yml" in entry:
            problems += goal_problems(f"The environment '{name}'", _env_field(document, index, "goals-yml"))
        if INIT_DIRS in entry:
            problems += init_dir_problems(f"The environment '{name}'", f"The environment '{name}' sets '{INIT_DIRS}' to",
                                          _env_field(document, index, INIT_DIRS))
        if ACTORS in entry:
            problems += actor_problems(f"The {ACTORS} of the environment '{name}'",
                                       f"The environment '{name}' sets '{ACTORS}' to", _env_field(document, index, ACTORS))
        if LIMITS in entry:
            problems += limit_problems(f"The environment '{name}' sets '{LIMITS}' to",
                                       lambda key, name=name: f"The environment '{name}' sets {shown(key)} in '{LIMITS}'",
                                       _env_field(document, index, LIMITS))
        for setting in (setting for setting in JOB_VARIABLE_SETTINGS if setting in entry):
            problems += variable_problems(
                lambda key, name=name, setting=setting: f"The variable {shown(key)} of the environment '{name}' in "
                                                        f"'{setting}'",
                _env_field(document, index, setting))
        if NOTIFICATIONS in entry:
            problems += notification_problems(f"environments-yml: environment '{name}': {NOTIFICATIONS}",
                                              _env_field(document, index, NOTIFICATIONS), names, True)
    return problems


def _switched_on(document):
    return values.get_val(document["workflow_inputs"].get(ENABLED)) == "true"


def _auto_merge_problems(document, environments, rows):
    """What the environments end up with: an actor list naming someone wherever auto-merge is on, and all
    six limits."""
    problems = []
    unnamed = [row["environment"] for row in rows
               if _switched_on(document) and row[ENABLED] == "true" and not row["pr-auto-merge-from-actors"]]
    if unnamed and not any(ACTORS in entry for entry in environments):
        problems.append(f"Auto-merge is switched on ({ENABLED}), but {ACTORS} names nobody, "
                        + NAME_THE_ACTORS.format(where=""))
    else:
        problems += [f"Auto-merge is switched on ({ENABLED}), but the actor list that applies to the environment "
                     f"'{name}' names nobody, " + NAME_THE_ACTORS.format(where=f" in {ACTORS}") for name in unnamed]
    for entry, row in zip(environments, rows):
        missing = ", ".join(f"'{key}'" for key in LIMIT_KEYS if key not in row["pr-auto-merge-limits"])
        if missing and LIMITS in entry:
            problems.append(f"The limits of the environment '{row['environment']}' lack {missing}; {LIMIT_RULE}.")
        elif missing:
            problems.append(f"{LIMITS} lacks {missing}; {LIMIT_RULE}.")
    # A global value that lacks a limit is reported once, not once per environment inheriting it.
    return list(dict.fromkeys(problems))


def setting_warnings(document, rows):
    """The settings that are valid but change nothing."""
    return [f"The environment '{row['environment']}' sets {ENABLED}: true, but auto-merge is switched off for the "
            f"whole run (the input {ENABLED} is false), so it has no effect."
            for row in rows if not _switched_on(document) and row[ENABLED] == "true"]


def _typed_overrides(document, name, environment):
    """The environment's own values for workflow inputs, in the types the forwarded ones have."""
    typed = {}
    # In key order, so which of two bad values is reported never depends on how the entry was written.
    for field, value in sorted(environment.items(), key=lambda item: shown(item[0])):
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
        if input_name not in row and input_name not in (*YML_INPUTS, *TEST_INPUTS, *ADMISSION_INPUTS):
            row[input_name] = values.get_val(document["workflow_inputs"][input_name])

    row.setdefault("github-environment", name)

    # The one field the workflow reads with fromJSON(), so it must be a JSON boolean.
    flag = "allow-failing-terraform-operations"
    row[flag] = flag in row and _boolean(name, flag, row[flag])

    row.setdefault("url", "")

    for field in REPLACE_FIELDS:
        value = _env_field(document, index, field) if field in row else globals_[field]
        row[_unsuffixed(field)] = as_list(value)

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

    for field in JOB_VARIABLES:
        row[field] = _without_nulls(row[field])

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
    row["caller-repo-is-on-default-branch"] = "true" if on_default_branch(document) else "false"
    return row


def on_default_branch(document):
    """Whether the run's ref is the default branch: a branch of that name, never a tag
    (docs/Configuration-validation.md §3.8)."""
    event = document["event"]
    return event["ref_type"] == "branch" and event["ref_name"] == document["caller"]["default_branch"]


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

    # A global problem is reported once, naming the input, not once per environment that inherits it.
    problems = check_keys(environments) + _setting_problems(document, globals_, environments)
    if problems:
        raise ConfigError(problems)
    if globals_[LIMITS] in (None, {}):
        globals_[LIMITS] = default_limits()
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
    problems = _auto_merge_problems(document, environments, rows)
    if problems:
        raise ConfigError(problems)
    return rows
