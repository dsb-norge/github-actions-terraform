"""Relevance: which environments a change is relevant to, docs/Path-relevance.md §3-§5.

The mode comes from the facts the adapter reported, checked in the order of §4.2, and every
uncertainty fails open to mode `all`: running too much is the safe error. In mode `diff` an
environment runs when a changed file matches one of its `paths` and none of its `paths-ignore`.
"""

from . import globs
from .environments import ConfigError, shown

AUTO = "auto"
# Nothing in the workflow reads Markdown; a configuration that does sets `paths-ignore: []`.
IMPLIED_IGNORE = "**/*.md"
# The standard layout beside the environment's own directories.
AUTO_SHARED = ("main/**", "modules/**", ".tflint.hcl")
SWITCH = "path-relevance-enabled"
DIFF_EVENTS = ("pull_request", "push")
# The calling workflow carries the `uses:` ref and every input, and may route through a local one.
WORKFLOWS = ".github/workflows/"
ON_PR_GOALS = ("apply-on-pr", "destroy-on-pr")
# What the jobs after the matrix read for every environment, affected or not.
ENTRY_FIELDS = ("github-environment", "add-pr-comment", "pr-comment-group", "pr-auto-merge-enabled",
                "pr-auto-merge-from-actors", "pr-auto-merge-limits")
NO_MATCH = "no changed file matches"


def _enabled(document, declared):
    for entry in declared:
        if SWITCH in entry:
            raise ConfigError([f"The environment '{entry['environment']}' sets '{SWITCH}', which is a workflow input "
                               "only; to run it on every change, set its 'paths' to ['**']!"])
    value = document["workflow_inputs"][SWITCH]
    if value is not True and value is not False and value not in ("true", "false"):
        raise ConfigError([f"The input '{SWITCH}' is {shown(value)}; it must be true or false!"])
    return value is True or value == "true"


def fail_open_reason(document, enabled):
    """The reason of §4.2 that makes this run mode `all`, or None for mode `diff`."""
    event = document["event"]
    if not enabled:
        return "disabled"
    if event["name"] not in DIFF_EVENTS:
        return "event"
    push = event.get("push", {})
    if push.get("forced", False):
        return "forced"
    if push.get("deleted", False):
        return "branch-deleted"
    changed = document.get("changed_files")
    if changed is None:
        return "not-computed"
    head = event.get("pull_request", {}).get("head_sha")
    if head is not None and changed["api_head_sha"] is not None and changed["api_head_sha"] != head:
        return "pr-head-moved"
    if changed["truncated"]:
        return "too-many-files"
    if not changed["available"]:
        return "api-error"
    if any(path.startswith(WORKFLOWS) for path in changed["files"]):
        return "workflow-changed"
    return None


def _directory(path):
    """A directory as the rule for everything under it."""
    if isinstance(path, str):
        path = path.rstrip("/") + "/**"
    return globs.compile_glob(path)


def _auto(name, row, errors):
    rules = []
    try:
        rules.append(_directory(row["project-dir"]))
    except globs.GlobError as error:
        errors.append(f"The environment '{name}' uses auto, but its project-dir {shown(row['project-dir'])} cannot "
                      f"be matched: {error}; set its 'paths' explicitly!")
    rules += [globs.compile_glob(pattern) for pattern in AUTO_SHARED]
    directories = row["terraform-init-additional-dirs"]
    for directory in directories if isinstance(directories, list) else [directories]:
        try:
            rules.append(_directory(directory))
        except globs.GlobError as error:
            errors.append(f"The environment '{name}' uses auto, but its terraform-init-additional-dirs entry "
                          f"{shown(directory)} cannot be matched: {error}; set its 'paths' explicitly!")
    return rules


def _patterns(name, field, value, errors, row=None):
    """The compiled patterns of one rule list; `auto` expands only where `row` is given."""
    if not isinstance(value, list):
        errors.append(f"The environment '{name}' sets '{field}' to {shown(value)}; it must be a list of patterns!")
        value = []
    rules = []
    for pattern in value:
        if pattern == AUTO and row is not None:
            rules += _auto(name, row, errors)
        elif pattern == AUTO:
            errors.append(f"The environment '{name}' has an invalid entry in '{field}': 'auto' belongs in 'paths'!")
        else:
            try:
                rules.append(globs.compile_glob(pattern))
            except globs.GlobError as error:
                errors.append(f"The environment '{name}' has an invalid entry in '{field}': {error}!")
    unique = {}
    for rule in rules:
        unique.setdefault(rule.pattern, rule)
    return unique.values()


def _rules(entry, row, errors):
    name = row["environment"]
    paths = entry.get("paths", [AUTO])
    if paths == []:
        errors.append(f"The environment '{name}' sets 'paths' to []; it would never run on a change: remove it for "
                      "auto, or say ['**']!")
    included = _patterns(name, "paths", paths, errors, row=row)
    implied = [IMPLIED_IGNORE] if isinstance(paths, list) and AUTO in paths else []
    ignored = _patterns(name, "paths-ignore", entry.get("paths-ignore", implied), errors)
    return included, ignored


def _first_relevant(files, included, ignored):
    """The `paths` rule of the first changed file that is relevant, or None."""
    for path in files:
        rule = globs.first_match(included, path)
        if rule is not None and globs.first_match(ignored, path) is None:
            return rule
    return None


def _mutates_on_pr(goals):
    # As the workflow's contains() reads them: an element of a list, a substring of a string.
    return [goal for goal in ON_PR_GOALS if isinstance(goals, (list, str)) and goal in goals]


def decide_relevance(document, declared, rows):
    """The relevance block and one entry per row, or a ConfigError with every rule error."""
    enabled = _enabled(document, declared)
    errors = []
    resolved = [_rules(entry, row, errors) for entry, row in zip(declared, rows)]
    if errors:
        raise ConfigError(errors)

    reason = fail_open_reason(document, enabled)
    changed = document.get("changed_files")
    entries = []
    for row, (included, ignored) in zip(rows, resolved):
        if reason is not None:
            verdict, why = "run", f"all:{reason}"
        else:
            rule = _first_relevant(changed["files"], included, ignored)
            verdict, why = ("run", rule) if rule is not None else ("skip", NO_MATCH)
        entry = {"environment": row["environment"], "verdict": verdict, "reasons": [f"relevance: {why}"]}
        entry.update({field: row[field] for field in ENTRY_FIELDS})
        entry["mutates-on-pr"] = _mutates_on_pr(row["goals"])
        entry["paths"] = [rule.pattern for rule in included]
        entry["paths-ignore"] = [rule.pattern for rule in ignored]
        entries.append(entry)

    block = {"mode": "all" if reason is not None else "diff", "reason": reason or "diff",
             "changed_count": changed["count"] if changed is not None else 0}
    return block, entries


def notice(block, entries):
    affected = sum(entry["verdict"] == "run" for entry in entries)
    total = len(entries)
    text = (f"relevance {block['mode']} ({block['reason']}): {affected} of {total} "
            f"environment{'' if total == 1 else 's'} affected")
    return text + ("; nothing to verify for this change" if affected == 0 else "")
