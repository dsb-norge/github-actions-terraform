"""The input document: its shape, checked before anything is decided.

A document that does not match is a fault in the shim that built it, not in the caller's
configuration, so it is reported as a DocumentError (exit 1) rather than a validation
error (exit 2). The shape is docs/Decision-engine.md §4.
"""

from . import SCHEMA_VERSION


class DocumentError(Exception):
    """The input document does not match the schema."""


TOP_LEVEL_KEYS = ("schema_version", "caller", "event", "workflow_inputs", "yaml", "directories_exist")
# Present only when the adapter fetched them; absent means "relevance not computed".
# admission: the facts of a Dependabot run the admission judges (docs/Dependabot-admission.md §8).
# automerge: a module pull request's commits, for its auto-merge (docs/Module-auto-merge.md §4).
# notify_target: the notification target the workflow read from its variables (docs/Notifications.md §6.1).
OPTIONAL_KEYS = ("changed_files", "run", "tests", "mode", "admission", "automerge", "notify_target")
NOTIFY_TARGET_KEYS = ("bot_url", "bot_audience", "alias")
# Absent means the project workflow's decision; a module decides its test stage alone (docs/Module-ci.md §5).
MODES = ("project", "module")
TESTS_KEYS = ("files", "directories_with_tf", "environment_locks")
CHANGED_FILES_KEYS = ("available", "truncated", "error", "api_head_sha", "count", "files")
PUSH_KEYS = ("created", "forced", "deleted")
# 'block' says whether the calling workflow declares dispatch inputs at all, 'inputs' names the ones
# this dispatch delivered.
DISPATCH_KEYS = ("block", "environment", "goal", "reason", "inputs")
REF_TYPES = ("branch", "tag")


def _require(condition, message):
    if not condition:
        raise DocumentError(message)


def _is_parsed_map(value):
    """A map from a '*-yml' name to the shim's parse result: {"ok": bool, "value": any}."""
    return isinstance(value, dict) and all(
        isinstance(result, dict) and set(result) == {"ok", "value"} and isinstance(result["ok"], bool)
        for result in value.values()
    )


def _is_count(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def _is_changed_files(value):
    return (isinstance(value, dict) and set(value) == set(CHANGED_FILES_KEYS)
            and isinstance(value["available"], bool) and isinstance(value["truncated"], bool)
            and isinstance(value["error"], (str, type(None))) and isinstance(value["api_head_sha"], (str, type(None)))
            and _is_count(value["count"])
            and isinstance(value["files"], list) and all(isinstance(path, str) for path in value["files"]))


def _is_strings(value):
    return isinstance(value, list) and all(isinstance(item, str) for item in value)


def _is_tests(value):
    locks = value.get("environment_locks") if isinstance(value, dict) else None
    return (isinstance(value, dict) and set(value) == set(TESTS_KEYS) and _is_strings(value["files"])
            and _is_strings(value["directories_with_tf"]) and isinstance(locks, dict)
            and all(lock is None or (isinstance(lock, dict) and all(isinstance(v, str) for v in lock.values()))
                    for lock in locks.values()))


ADMISSION_KEYS = ("now", "files", "dependencies", "locks")
FILE_STATUSES = ("modified", "added", "removed", "renamed", "changed")
PROVIDER_FACTS = ("published", "keys_from", "keys_to", "vouched", "class_from", "class_to", "zh", "shasums")


def _is_lock(value):
    """A parsed lock file: address to its version, constraints and hashes; null when it could not be read."""
    return value is None or (isinstance(value, dict) and all(
        isinstance(block, dict) and set(block) == {"version", "constraints", "hashes"}
        and isinstance(block["version"], str) and isinstance(block["constraints"], (str, type(None)))
        and _is_strings(block["hashes"]) for block in value.values()))


def _is_tf_file(item):
    return (set(item) == {"path", "status", "kind", "lines", "unmapped"} and _is_strings(item["unmapped"])
            and isinstance(item["lines"], list) and all(
                isinstance(line, dict) and set(line) == {"old", "new"}
                and all(isinstance(line[key], (str, type(None))) for key in ("old", "new")) for line in item["lines"]))


def _is_lock_file(item):
    return set(item) == {"path", "status", "kind", "before", "after"} and _is_lock(item["before"]) \
        and _is_lock(item["after"])


def _is_admission_file(item):
    return (isinstance(item, dict) and isinstance(item.get("path"), str) and item.get("status") in FILE_STATUSES
            and isinstance(item.get("kind"), str)
            and (_is_tf_file(item) if item["kind"] == "tf" else _is_lock_file(item) if item["kind"] == "lock"
                 else set(item) == {"path", "status", "kind"}))


def _is_published(value):
    return value is None or _is_count(value)


def _is_module(item):
    return (set(item) == {"kind", "address", "from", "to", "files", "facts", "source_kind", "namespace", "name"}
            and all(isinstance(item[key], str) for key in ("source_kind", "namespace", "name"))
            and set(item["facts"]) == {"published"} and _is_published(item["facts"]["published"]))


def _is_provider(item):
    facts = item["facts"]
    return (set(item) == {"kind", "address", "from", "to", "files", "facts", "locked"} and isinstance(item["locked"], bool)
            and set(facts) == set(PROVIDER_FACTS) and _is_published(facts["published"])
            and isinstance(facts["vouched"], bool)
            and all(_is_strings(facts[key]) for key in ("keys_from", "keys_to", "zh", "shasums"))
            and all(isinstance(facts[key], str) for key in ("class_from", "class_to")))


def _is_dependency(item):
    return (isinstance(item, dict) and item.get("kind") in ("provider", "module")
            and all(isinstance(item.get(key), str) for key in ("address", "from", "to"))
            and _is_strings(item.get("files")) and isinstance(item.get("facts"), dict)
            and (_is_module(item) if item["kind"] == "module" else _is_provider(item)))


def _is_admission(value):
    return (isinstance(value, dict) and set(value) == set(ADMISSION_KEYS) and _is_count(value["now"])
            and isinstance(value["files"], list) and all(_is_admission_file(item) for item in value["files"])
            and isinstance(value["dependencies"], list) and all(_is_dependency(item) for item in value["dependencies"])
            and isinstance(value["locks"], dict) and all(isinstance(v, bool) for v in value["locks"].values()))


AUTOMERGE_KEYS = ("available", "reason", "head_ref", "count", "commits")
COMMIT_KEYS = ("sha", "parents", "author", "committer", "verified", "message", "files", "files_truncated")


def _is_commit_file(item):
    return (isinstance(item, dict) and set(item) == {"name", "status", "previous"} and isinstance(item["name"], str)
            and isinstance(item["status"], str) and isinstance(item["previous"], (str, type(None))))


def _is_commit(item):
    return (isinstance(item, dict) and set(item) == set(COMMIT_KEYS) and isinstance(item["sha"], str)
            and isinstance(item["message"], str)
            and _is_count(item["parents"]) and all(isinstance(item[key], (str, type(None))) for key in ("author", "committer"))
            and isinstance(item["verified"], bool) and isinstance(item["files_truncated"], bool)
            and (item["files"] is None or (isinstance(item["files"], list)
                                           and all(_is_commit_file(entry) for entry in item["files"]))))


def _is_automerge(value):
    return (isinstance(value, dict) and set(value) == set(AUTOMERGE_KEYS) and isinstance(value["available"], bool)
            and isinstance(value["reason"], (str, type(None))) and isinstance(value["head_ref"], str)
            and _is_count(value["count"])
            and isinstance(value["commits"], list) and all(_is_commit(item) for item in value["commits"]))


def check(document):
    """Raise DocumentError unless the document has the shape the engine reads."""
    _require(isinstance(document, dict), "input document: not a JSON object")
    unknown = sorted(set(document) - set(TOP_LEVEL_KEYS) - set(OPTIONAL_KEYS))
    _require(not unknown, f"input document: unknown key(s) {unknown}")
    missing = [key for key in TOP_LEVEL_KEYS if key not in document]
    _require(not missing, f"input document: missing key(s) {missing}")
    _require(document["schema_version"] == SCHEMA_VERSION,
             f"input document: schema_version {document['schema_version']!r}, expected {SCHEMA_VERSION}")

    caller = document["caller"]
    _require(isinstance(caller, dict) and isinstance(caller.get("repository"), str)
             and isinstance(caller.get("default_branch"), str),
             "input document: 'caller' needs the strings 'repository' and 'default_branch'")
    event = document["event"]
    _require(isinstance(event, dict) and isinstance(event.get("name"), str)
             and isinstance(event.get("ref_name"), str) and event.get("ref_type") in REF_TYPES,
             "input document: 'event' needs the strings 'name' and 'ref_name', and 'ref_type' 'branch' or 'tag'")
    if "push" in event:
        push = event["push"]
        _require(isinstance(push, dict) and all(isinstance(push.get(key), bool) for key in PUSH_KEYS),
                 "input document: 'event.push' needs the booleans 'created', 'forced' and 'deleted'")
    if "pull_request" in event:
        pull_request = event["pull_request"]
        _require(isinstance(pull_request, dict) and _is_count(pull_request.get("number"))
                 and isinstance(pull_request.get("head_sha"), str) and isinstance(pull_request.get("is_fork"), bool),
                 "input document: 'event.pull_request' needs the integer 'number', the string 'head_sha' and the "
                 "boolean 'is_fork'")
        _require(isinstance(pull_request.get("author", ""), str),
                 "input document: 'event.pull_request.author' is not a string")
    _require(isinstance(event.get("action", ""), str), "input document: 'event.action' is not a string")
    _require(isinstance(event.get("actor", ""), str), "input document: 'event.actor' is not a string")
    _require(isinstance(event.get("triggering_actor", ""), str),
             "input document: 'event.triggering_actor' is not a string")
    _require(isinstance(event.get("base_ref", ""), str), "input document: 'event.base_ref' is not a string")
    if "dispatch" in event:
        dispatch = event["dispatch"]
        _require(isinstance(dispatch, dict) and set(dispatch) == set(DISPATCH_KEYS)
                 and isinstance(dispatch["block"], bool)
                 and all(isinstance(dispatch[key], str) for key in ("environment", "goal", "reason"))
                 and _is_strings(dispatch["inputs"]),
                 "input document: 'event.dispatch' needs exactly the boolean 'block', the strings 'environment', "
                 "'goal' and 'reason', and the list of strings 'inputs'")
    _require(isinstance(caller.get("workflow_name", ""), str), "input document: 'caller.workflow_name' is not a string")
    if "run" in document:
        run = document["run"]
        _require(isinstance(run, dict) and _is_count(run.get("id")) and _is_count(run.get("attempt")),
                 "input document: 'run' needs the integers 'id' and 'attempt'")
    _require(isinstance(document["workflow_inputs"], dict), "input document: 'workflow_inputs' is not an object")

    yaml = document["yaml"]
    _require(isinstance(yaml, dict) and set(yaml) == {"inputs", "environments"},
             "input document: 'yaml' needs exactly 'inputs' and 'environments'")
    _require(_is_parsed_map(yaml["inputs"]), "input document: 'yaml.inputs' is not a map of parse results")
    _require(isinstance(yaml["environments"], list) and all(_is_parsed_map(e) for e in yaml["environments"]),
             "input document: 'yaml.environments' is not a list of maps of parse results")

    directories = document["directories_exist"]
    _require(isinstance(directories, dict) and all(isinstance(v, bool) for v in directories.values()),
             "input document: 'directories_exist' is not a map of booleans")
    if "changed_files" in document:
        _require(_is_changed_files(document["changed_files"]),
                 "input document: 'changed_files' needs exactly 'available', 'truncated', 'error', 'api_head_sha', "
                 "'count' and 'files', typed as the adapter reports them")
    _require(document.get("mode", "project") in MODES,
             f"input document: 'mode' is {document.get('mode')!r}, expected one of {', '.join(MODES)}")
    if "admission" in document:
        _require(_is_admission(document["admission"]),
                 "input document: 'admission' needs exactly 'now', 'files', 'dependencies' and 'locks', shaped as "
                 "docs/Dependabot-admission.md §8 describes")
    if "automerge" in document:
        _require(_is_automerge(document["automerge"]),
                 "input document: 'automerge' needs exactly 'available', 'reason', 'head_ref', 'count' and 'commits', "
                 "shaped as docs/Module-auto-merge.md §4 describes")
    if "notify_target" in document:
        target = document["notify_target"]
        _require(isinstance(target, dict) and set(target) == set(NOTIFY_TARGET_KEYS)
                 and all(isinstance(value, str) for value in target.values()),
                 "input document: 'notify_target' needs exactly the strings 'bot_url', 'bot_audience' and 'alias'")
    if "tests" in document:
        _require(_is_tests(document["tests"]),
                 "input document: 'tests' needs exactly 'files' and 'directories_with_tf' (lists of strings) and "
                 "'environment_locks' (a map of lock maps or null)")
