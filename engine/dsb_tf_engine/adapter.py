"""The create-matrix adapter: everything create-tf-vars-matrix does that the decision core may not.

It reads the workflow's inputs from a file, parses every YAML value with yq, learns the default
branch and which project directories exist, builds the input document, decides in-process and
publishes the matrix. It is the impure edge around the pure core (docs/Decision-engine.md §3):
it reads the environment, the filesystem and the network, runs programs and writes the log, and
it sits under the same coverage and mutation gates as the core.

How each value is read before yq sees it is part of the port's contract, because YAML is
sensitive to it: the bash builder fed a workflow input through `echo` (one trailing newline) and
an environment's field through `printf '%s'` (none), after command substitution had stripped
the value's own trailing newlines.
"""

import json
import subprocess

from . import SCHEMA_VERSION, decide, environments, workflow

TITLE = "create-tf-vars-matrix"
EXIT_OK, EXIT_FAULT, EXIT_INVALID = 0, 1, 2

YQ = ("yq", "e", "-o=json")
YQ_PROBE_TEXT = "probe: [1]\n"
YQ_PROBE_JSON = '{"probe":[1]}'
REQUIRED_ENVIRONMENT = ("GITHUB_REPOSITORY", "GITHUB_EVENT_NAME", "GITHUB_REF_NAME", "GITHUB_OUTPUT")


class AdapterError(Exception):
    """A fault that is not the caller's configuration: a message, and detail shown verbatim."""

    def __init__(self, message, detail=""):
        super().__init__(message)
        self.message = message
        self.detail = detail


class Tools:
    """The external programs, behind one method so the tests can stand in for them."""

    def run(self, argv, stdin=""):
        completed = subprocess.run(argv, input=stdin, capture_output=True, text=True, check=False)
        return completed.returncode, completed.stdout, completed.stderr


def _run(tools, argv, stdin=""):
    try:
        return tools.run(argv, stdin)
    except OSError as error:
        raise AdapterError(f"'{argv[0]}' cannot be run on this runner: {error}") from None


def require_yq(tools):
    """Probe yq on a known document, so a broken yq is never reported as the caller's YAML."""
    code, stdout, stderr = _run(tools, YQ + ("-I=0", "-"), YQ_PROBE_TEXT)
    if code != 0 or stdout.strip() != YQ_PROBE_JSON:
        raise AdapterError("yq on the runner cannot parse YAML to JSON, so no input can be read",
                           (stderr or stdout).strip()[:500])


def parse_yaml(tools, text):
    """yq's reading of `text` as a parse result {"ok", "value"}; several documents do not parse."""
    code, stdout, _ = _run(tools, YQ + ("-",), text)
    if code != 0:
        return {"ok": False, "value": None}
    try:
        return {"ok": True, "value": json.loads(stdout)}
    except ValueError:
        return {"ok": False, "value": None}


def input_text(value):
    """A workflow input as the bash builder handed it to yq: jq's `// ""`, then echo."""
    if value is None or value is False:
        value = ""
    text = value if isinstance(value, str) else json.dumps(value)
    return text.rstrip("\n") + "\n"


def field_text(value):
    """An environment's field as the bash builder handed it to yq: jq -r, then printf '%s'."""
    if value is None:
        return ""
    return value.rstrip("\n") if isinstance(value, str) else json.dumps(value)


def parse_inputs(tools, inputs):
    return {name: parse_yaml(tools, input_text(value)) for name, value in sorted(inputs.items())
            if name.endswith("-yml")}


def parse_environments(tools, entries):
    """One map of parse results per environment entry, aligned by index; {} for a non-mapping."""
    if not isinstance(entries, list):
        return []
    return [{key: parse_yaml(tools, field_text(value)) for key, value in sorted(entry.items()) if key.endswith("-yml")}
            if isinstance(entry, dict) else {} for entry in entries]


def check_directories(entries, isdir):
    """Existence of every directory an environment's check will read, keyed as the engine reads it."""
    if not isinstance(entries, list):
        return {}
    paths = [environments.project_dir_path(entry) for entry in entries
             if isinstance(entry, dict) and "environment" in entry]
    return {path: isdir(path) for path in paths}


def default_branch(event_path, repository, tools):
    """The caller's default branch: from the event payload, which carries it on every event this
    workflow runs on, else from the API. A failed fallback is an error, never a guess."""
    try:
        with open(event_path, encoding="utf-8") as handle:
            branch = json.load(handle)["repository"]["default_branch"]
        if isinstance(branch, str) and branch:
            return branch
    except (OSError, ValueError, KeyError, TypeError):
        pass
    code, stdout, stderr = _run(tools, ("gh", "api", f"repos/{repository}"))
    try:
        branch = json.loads(stdout)["default_branch"] if code == 0 else None
    except (ValueError, KeyError, TypeError):
        branch = None
    if not isinstance(branch, str) or not branch:
        raise AdapterError(f"could not resolve the default branch of '{repository}', the API answered:",
                           (stdout + stderr).strip()[:2000])
    return branch


def read_inputs(path):
    try:
        with open(path, encoding="utf-8") as handle:
            inputs = json.load(handle)
    except (OSError, ValueError) as error:
        raise AdapterError(f"the action's input 'inputs-json' cannot be read as JSON: {error}") from None
    if not isinstance(inputs, dict):
        raise AdapterError("the action's input 'inputs-json' is not a JSON object; it expects toJSON(inputs)")
    return inputs


def build_document(inputs, facts, tools, isdir):
    """The engine's input document (docs/Decision-engine.md §4) from the inputs and the run's facts."""
    yaml_inputs = parse_inputs(tools, inputs)
    # A parse that failed carries the value null, which yields no entries.
    entries = yaml_inputs.get("environments-yml", {}).get("value")
    return {
        "schema_version": SCHEMA_VERSION,
        "caller": {"repository": facts["repository"], "default_branch": facts["default_branch"]},
        "event": {"name": facts["event_name"], "ref_name": facts["ref_name"]},
        "workflow_inputs": inputs,
        "yaml": {"inputs": yaml_inputs, "environments": parse_environments(tools, entries)},
        "directories_exist": check_directories(entries, isdir),
    }


def run(inputs_file, environ, stream, tools, isdir):
    """Run the create-matrix step. Returns the exit code: 0, 1 a fault, 2 an invalid configuration."""
    log = workflow.Log(stream, TITLE)
    try:
        missing = [name for name in REQUIRED_ENVIRONMENT if not environ.get(name)]
        if missing:
            raise AdapterError(f"the runner did not set {', '.join(missing)}")
        require_yq(tools)
        inputs = read_inputs(inputs_file)
        log.group("input 'inputs-json'", json.dumps(inputs, indent=2, ensure_ascii=False))
        facts = {
            "repository": environ["GITHUB_REPOSITORY"],
            "event_name": environ["GITHUB_EVENT_NAME"],
            "ref_name": environ["GITHUB_REF_NAME"],
            "default_branch": default_branch(environ.get("GITHUB_EVENT_PATH", ""), environ["GITHUB_REPOSITORY"], tools),
        }
        document = build_document(inputs, facts, tools, isdir)
    except AdapterError as error:
        log.error(error.message)
        if error.detail:
            log.verbatim(error.detail)
        return EXIT_FAULT

    log.group("decision engine input document", json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False))
    output = decide.decide(document)
    if output["errors"]:
        for message in output["errors"]:
            log.error(message)
        return EXIT_INVALID

    log.group("decision record", "\n".join(output["record"]))
    matrix = output["matrices"]["1"]
    log.group("matrix-json", json.dumps(matrix, indent=2, sort_keys=True, ensure_ascii=False))
    workflow.append_output(environ["GITHUB_OUTPUT"], "matrix-json",
                           json.dumps(matrix, sort_keys=True, ensure_ascii=False, separators=(",", ":")))
    return EXIT_OK
