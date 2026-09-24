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
OPTIONAL_KEYS = ("changed_files", "run")
CHANGED_FILES_KEYS = ("available", "truncated", "error", "api_head_sha", "count", "files")
PUSH_KEYS = ("created", "forced", "deleted")


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
             and isinstance(event.get("ref_name"), str),
             "input document: 'event' needs the strings 'name' and 'ref_name'")
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
    _require(isinstance(event.get("action", ""), str), "input document: 'event.action' is not a string")
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
