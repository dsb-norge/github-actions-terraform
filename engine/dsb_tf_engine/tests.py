"""The test stage: which test files run, where, with what, and why not. docs/Terraform-tests.md §3-§4.

The adapter reports the committed test files, the directories that hold `.tf` files and each
environment's lock reduced to provider versions. From those and the lanes this decides one row per
test file and provider set, lists the files that do not run with the reason, and validates every
lane. Nothing from the workflow's own `extra-envs-*` reaches a test row: those carry the apply
identity (D6).
"""

import hashlib
import re

from . import globs, values
from .environments import ConfigError, shown

LANE_KEYS = ("name", "match", "extra-envs-yml", "extra-envs-from-secrets-yml", "runs-on", "terraform-version",
             "timeout-minutes", "allow-failing-terraform-tests", "providers-from", "cache-terraform-modules",
             "github-environment")
LANE_NAME = re.compile(r"[a-z0-9-]{1,40}")
LANE_NAME_RULE = "1 to 40 of the characters a-z 0-9 -"
# Lowercase only: GitHub compares environment names without case, but puts the stored name into the
# token subject, and the lanes' federated credential matches case-sensitively.
LANE_ENVIRONMENT = re.compile(r"tftest-[a-z0-9-]{1,40}")
DEFAULT_LANE = "default"
MATRIX_CAP = 256
SLUG_CAP = 100
TEST_FILE_SUFFIXES = (".tftest.hcl", ".tftest.json")
# Unattended runs must not create or destroy test objects, and a dispatch is often a recovery (D7).
TEST_EVENTS = ("pull_request", "push")
UNTESTED_ACTIONS = ("closed", "converted_to_draft")
DEPENDABOT = "dependabot[bot]"


def normalise_dir(path):
    """A directory as the facts and the rows compare it: no leading `./`, no trailing `/`, the root `.`."""
    path = path.rstrip("/")
    while path.startswith("./"):
        path = path[2:]
    return path or "."


def _flag(value):
    """True or false as a boolean or its string, else None."""
    if value is True or value == "true":
        return True
    if value is False or value == "false":
        return False
    return None


def _is_count(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def _globals(inputs, errors):
    enabled = _flag(inputs.get("terraform-test-enabled", True))
    allow = _flag(inputs.get("allow-failing-terraform-tests", False))
    for name, value in (("terraform-test-enabled", enabled), ("allow-failing-terraform-tests", allow)):
        if value is None:
            errors.append(f"The input '{name}' is {shown(inputs[name])}; it must be true or false!")
    timeout = inputs.get("terraform-test-timeout-minutes", 30)
    if not _is_count(timeout):
        errors.append(f"The input 'terraform-test-timeout-minutes' is {shown(timeout)}; it must be a positive whole "
                      "number!")
    runs_on = inputs.get("terraform-test-runs-on", "ubuntu-latest")
    if runs_on == "":
        errors.append("The input 'terraform-test-runs-on' is empty!")
    return {"enabled": enabled, "allow": allow, "timeout": timeout, "runs_on": runs_on,
            "version": inputs.get("terraform-version", "latest"),
            "cache": _flag(inputs.get("cache-terraform-modules", True)) is not False}


def _yaml_input(document, name, errors, noun):
    result = document["yaml"]["inputs"].get(name, {"ok": True, "value": None})
    if not result["ok"]:
        errors.append(f"The specification for input '{name}' is not valid yaml!")
        return []
    value = [] if result["value"] is None else result["value"]
    if not isinstance(value, list):
        errors.append(f"The input '{name}' must be a list of {noun}!")
        return []
    return value


def _excludes(document, errors):
    patterns = []
    for pattern in _yaml_input(document, "terraform-test-exclude-paths-yml", errors, "patterns"):
        try:
            patterns.append(globs.compile_glob(pattern))
        except globs.GlobError as error:
            errors.append(f"The input 'terraform-test-exclude-paths-yml' has an invalid entry: {error}!")
    return patterns


def _variables(label, value, errors):
    if not isinstance(value, dict):
        errors.append(f"The test lane '{label}' sets 'extra-envs-yml' to {shown(value)}; it must be a mapping of "
                      "variable names to values!")
        return {}
    rendered = {}
    for name, item in value.items():
        if isinstance(item, (dict, list)) or item is None:
            errors.append(f"The test lane '{label}' sets the variable '{name}' in 'extra-envs-yml' to {shown(item)}; "
                          "it must be a string, a number or a boolean!")
        else:
            rendered[name] = values.get_val(item)
    return rendered


def _secrets(label, value, errors):
    if not isinstance(value, dict):
        errors.append(f"The test lane '{label}' sets 'extra-envs-from-secrets-yml' to {shown(value)}; it must be a "
                      "mapping of variable names to secret names!")
        value = {}
    for name, item in value.items():
        if not isinstance(item, str) or item == "":
            errors.append(f"The test lane '{label}' maps '{name}' in 'extra-envs-from-secrets-yml' to {shown(item)}; "
                          "it must be a secret name!")
    return value


def _match(label, value, errors):
    if not isinstance(value, list):
        errors.append(f"The test lane '{label}' sets 'match' to {shown(value)}; it must be a list of patterns!")
        value = []
    elif value == []:
        errors.append(f"The test lane '{label}' sets 'match' to []; leave it out for a fallback lane!")
    patterns = []
    for pattern in value:
        try:
            patterns.append(globs.compile_glob(pattern))
        except globs.GlobError as error:
            errors.append(f"The test lane '{label}' has an invalid entry in 'match': {error}!")
    return patterns


def _lane(index, entry, defaults, environment_names, errors):
    """One lane, resolved against the defaults; None when it is not a mapping."""
    if not isinstance(entry, dict):
        errors.append(f"Test lane {index} is not a mapping!")
        return None
    name = entry.get("name")
    label = name if isinstance(name, str) else str(index)
    if "name" not in entry:
        errors.append(f"Test lane {index} has no 'name'!")
    elif not isinstance(name, str) or LANE_NAME.fullmatch(name) is None:
        errors.append(f"The test lane name {shown(name)} must be {LANE_NAME_RULE}!")
    for key in entry:
        if key not in LANE_KEYS:
            errors.append(f"The test lane '{label}' has the unknown key '{key}'!")
    lane = {"name": label, "patterns": _match(label, entry["match"], errors) if "match" in entry else None,
            "variables": _variables(label, entry.get("extra-envs-yml", {}), errors),
            "secrets": _secrets(label, entry.get("extra-envs-from-secrets-yml", {}), errors)}
    for key, default in (("runs-on", defaults["runs_on"]), ("terraform-version", defaults["version"])):
        lane[key] = entry.get(key, default)
        if not isinstance(lane[key], str):
            errors.append(f"The test lane '{label}' sets '{key}' to {shown(lane[key])}, which is not a string; quote it!")
    lane["timeout"] = entry.get("timeout-minutes", defaults["timeout"])
    if not _is_count(lane["timeout"]):
        errors.append(f"The test lane '{label}' sets 'timeout-minutes' to {shown(lane['timeout'])}; it must be a "
                      "positive whole number!")
    for key, default in (("allow-failing-terraform-tests", defaults["allow"]),
                         ("cache-terraform-modules", defaults["cache"])):
        flag = _flag(entry.get(key, default))
        if flag is None:
            errors.append(f"The test lane '{label}' sets '{key}' to {shown(entry[key])}; it must be true or false!")
        lane[key] = flag
    lane["providers_from"] = entry.get("providers-from")
    if "providers-from" in entry and not isinstance(lane["providers_from"], list):
        errors.append(f"The test lane '{label}' sets 'providers-from' to {shown(lane['providers_from'])}; it must be "
                      "a list of environment names!")
        lane["providers_from"] = []
    for environment in lane["providers_from"] or []:
        if environment not in environment_names:
            errors.append(f"The test lane '{label}' takes providers from {shown(environment)}, which is not an "
                          "environment of this workflow!")
    lane["environment"] = entry.get("github-environment", "")
    if lane["environment"] == "auto":
        lane["environment"] = f"tftest-{label}"
    elif "github-environment" in entry and (not isinstance(lane["environment"], str)
                                            or LANE_ENVIRONMENT.fullmatch(lane["environment"]) is None):
        errors.append(f"The test lane '{label}' sets 'github-environment' to {shown(lane['environment'])}; it must be "
                      "'auto' or match ^tftest-[a-z0-9-]{1,40}$!")
        lane["environment"] = ""
    if lane["environment"]:
        # Federated credentials are the only authentication an environment lane supports (D16).
        lane["variables"] = {"ARM_USE_OIDC": "true", **lane["variables"]}
    return lane


def _lanes(document, defaults, rows, errors):
    entries = _yaml_input(document, "terraform-test-lanes-yml", errors, "lanes")
    environment_names = [row["environment"] for row in rows]
    lanes = [lane for index, entry in enumerate(entries, start=1)
             if (lane := _lane(index, entry, defaults, environment_names, errors)) is not None]
    seen, fallback = set(), None
    for lane in lanes:
        if lane["name"] in seen:
            errors.append(f"The test lane name '{lane['name']}' is used twice!")
        seen.add(lane["name"])
        if lane["patterns"] is None and fallback is not None:
            errors.append(f"The test lanes '{fallback}' and '{lane['name']}' both have no 'match'; only one lane may "
                          "be the fallback!")
        if lane["patterns"] is None:
            fallback = fallback or lane["name"]
        for row in rows:
            if lane["environment"] and lane["environment"].casefold() == row["github-environment"].casefold():
                errors.append(f"The test lane '{lane['name']}' runs in '{lane['environment']}', which is also the "
                              f"github-environment of the environment '{row['environment']}'; a test lane needs an "
                              "environment of its own!")
    # Files no lane matches and no fallback lane takes: global values, no credentials.
    lanes.append({"name": DEFAULT_LANE, "patterns": None, "variables": {}, "secrets": {},
                  "runs-on": defaults["runs_on"], "terraform-version": defaults["version"],
                  "timeout": defaults["timeout"], "allow-failing-terraform-tests": defaults["allow"],
                  "cache-terraform-modules": defaults["cache"], "providers_from": None, "environment": ""})
    return lanes


def _lane_for(lanes, path):
    """The first lane whose patterns match, else the first fallback: a declared one before the default."""
    for lane in lanes:
        if lane["patterns"] and globs.first_match(lane["patterns"], path) is not None:
            return lane
    return next(lane for lane in lanes if lane["patterns"] is None)


def _root(path, directories):
    """(root, rel) by Terraform's own discovery rule inverted (§4.2), or None for a misplaced file."""
    directory, _, name = path.rpartition("/")
    directory = directory or "."
    parent, _, last = directory.rpartition("/")
    if last == "tests":
        root, rel = parent or ".", f"tests/{name}"
    elif directory in directories or directory == ".":
        root, rel = directory, name
    else:
        return None
    return None if "tests" in root.split("/") else (root, rel)


def _digest(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:6]


def _slug(root, path, used):
    name = path.rpartition("/")[2]
    for suffix in TEST_FILE_SUFFIXES:
        name = name.removesuffix(suffix)
    # Artifact names forbid '/', and the slug names the job's artifacts (P3).
    slug = re.sub(r"[^A-Za-z0-9._-]", "-", f"{'root' if root == '.' else root.replace('/', '-')}--{name}")[:SLUG_CAP]
    if slug in used:
        slug = f"{slug[:SLUG_CAP - 7]}-{_digest(path)}"
    used.add(slug)
    return slug


def _provider_sets(document, rows, notices):
    """The distinct provider-version sets of the environments' locks, in environment order."""
    locks = document["tests"]["environment_locks"]
    sets = {}
    for row in rows:
        directory = normalise_dir(values.render(row["project-dir"]))
        lock = locks.get(directory)
        if lock is None:
            notices.append(f"the environment '{row['environment']}' has no .terraform.lock.hcl; its providers take no "
                           "part in the test stage")
            continue
        identity = _digest("\n".join(f"{provider}={version}" for provider, version in sorted(lock.items())))
        entry = sets.setdefault(identity, {"id": identity, "environments": [],
                                           "lock": f"{'' if directory == '.' else directory + '/'}.terraform.lock.hcl"})
        entry["environments"].append(row["environment"])
    return list(sets.values())


def _secrets_unavailable(event):
    return event.get("pull_request", {}).get("is_fork", False) or event.get("actor") == DEPENDABOT


def _row(slug, path, root, rel, kind, lane, provider_set, name):
    return {"slug": slug, "test": {
        "file": path, "root": root, "rel": rel, "name": name, "lane": lane["name"], "runs-on": lane["runs-on"],
        "terraform-version": lane["terraform-version"], "timeout-minutes": lane["timeout"],
        "allow-failing-terraform-tests": lane["allow-failing-terraform-tests"],
        "github-environment": lane["environment"], "root-kind": kind,
        "provider-set": provider_set["id"] if provider_set else "",
        "provider-set-lock": provider_set["lock"] if provider_set else "",
        "provider-set-environments": provider_set["environments"] if provider_set else [],
        "cache-terraform-modules": "true" if lane["cache-terraform-modules"] else "false",
        "fork-safe": not (lane["environment"] or lane["secrets"]),
        "extra-envs": lane["variables"], "extra-envs-from-secrets": lane["secrets"]}}


def decide_tests(document, rows):
    """The tests block and its warnings and notices, or a ConfigError with every error.

    Lanes and inputs are validated whether or not the stage runs, so a configuration never becomes
    valid by being run on a schedule.
    """
    errors = []
    defaults = _globals(document["workflow_inputs"], errors)
    excludes = _excludes(document, errors)
    lanes = _lanes(document, defaults, rows, errors)
    if errors:
        raise ConfigError(errors)

    event = document["event"]
    if (not defaults["enabled"] or "tests" not in document or event["name"] not in TEST_EVENTS
            or event.get("action", "") in UNTESTED_ACTIONS):
        return {"matrix": {"include": []}, "count": 0, "active": False, "not_run": [], "provider_sets": []}, [], []

    warnings, notices = [], []
    sets = _provider_sets(document, rows, notices)
    environment_roots = {normalise_dir(values.render(row["project-dir"])) for row in rows}
    directories = {normalise_dir(path) for path in document["tests"]["directories_with_tf"]}
    unavailable = _secrets_unavailable(event)
    matrix, not_run, used = [], [], set()
    for path in sorted(document["tests"]["files"]):
        if any(segment.startswith(".") for segment in path.split("/")) or globs.first_match(excludes, path):
            continue
        lane = _lane_for(lanes, path)
        located = _root(path, directories)
        if located is None:
            not_run.append({"file": path, "lane": lane["name"], "reason": "misplaced"})
            warnings.append(f"test file '{path}' is misplaced: Terraform finds test files only beside the root "
                            "module's .tf files or in its tests/ directory (docs/Terraform-tests.md §4.2)")
            continue
        if unavailable and (lane["environment"] or lane["secrets"]):
            not_run.append({"file": path, "lane": lane["name"], "reason": "secrets unavailable"})
            continue
        root, rel = located
        slug = _slug(root, path, used)
        name = f"Terraform test ({path})"
        if root in environment_roots:
            # An environment root runs with its own committed lock (§5.3).
            matrix.append(_row(slug, path, root, rel, "environment", lane, None, name))
            continue
        chosen = [entry for entry in sets if lane["providers_from"] is None
                  or set(entry["environments"]) & set(lane["providers_from"])]
        kind = "repo-root" if root == "." else "module"
        for entry in chosen or [None]:
            if len(chosen) > 1:
                matrix.append(_row(f"{slug}--{entry['id']}", path, root, rel, kind, lane, entry,
                                   f"{name} [providers: {', '.join(entry['environments'])}]"))
            else:
                matrix.append(_row(slug, path, root, rel, kind, lane, entry, name))
    if len(matrix) > MATRIX_CAP:
        raise ConfigError([f"{len(matrix)} test jobs exceed GitHub's cap of {MATRIX_CAP} jobs in one matrix; exclude "
                           "files with terraform-test-exclude-paths-yml!"])
    block = {"matrix": {"include": matrix}, "count": len(matrix), "active": bool(matrix), "not_run": not_run,
             "provider_sets": sets}
    return block, warnings, notices
