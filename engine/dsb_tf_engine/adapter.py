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
import os
import re
import subprocess
import tempfile
import urllib.parse

from . import (SCHEMA_VERSION, admission, admission_facts, automerge, automerge_facts, decide, environments, ordering,
               relevance, tests, workflow)

TITLE = "create-tf-vars-matrix"
EXIT_OK, EXIT_FAULT, EXIT_INVALID = 0, 1, 2

YQ = ("yq", "e", "-o=json")
YQ_PROBE_TEXT = "probe: [1]\n"
# The environment-variable settings are read with every plain scalar as its source text, so 1.10 stays
# 1.10 and 012 keeps its zero (docs/Configuration-validation.md §3.5); nothing else is read that way, so a
# per-environment terraform-version: 1.10 is still refused with "quote it".
VARIABLE_SETTINGS = ("extra-envs-from-secrets-per-goal-yml", "extra-envs-from-secrets-yml", "extra-envs-per-goal-yml",
                     "extra-envs-yml")
_TYPED_SCALARS = 'select(tag == "!!int" or tag == "!!float" or tag == "!!bool")'
# Only scalars inside a mapping: the document itself (false, null) keeps its meaning.
AS_TEXT = f'(select(tag == "!!map") | .. | {_TYPED_SCALARS}) tag = "!!str"'


def _as_text_in_entries(keys):
    """The rewrite for these keys of every mapping in a list, touching no key that is absent."""
    chosen = " or ".join(f'key == "{key}"' for key in keys)
    # Selecting the list first leaves any other document, null included, exactly as yq read it.
    return (f'(select(tag == "!!seq") | .[] | select(tag == "!!map") | .[] | select({chosen}) | .. | {_TYPED_SCALARS}) '
            'tag = "!!str"')


READ_AS = {**{name: AS_TEXT for name in VARIABLE_SETTINGS},
           "environments-yml": _as_text_in_entries(VARIABLE_SETTINGS),
           "terraform-test-lanes-yml": _as_text_in_entries(("extra-envs-yml",))}
YQ_PROBE_JSON = '{"probe":[1]}'
REQUIRED_ENVIRONMENT = ("GITHUB_REPOSITORY", "GITHUB_EVENT_NAME", "GITHUB_REF_NAME", "GITHUB_REF_TYPE", "GITHUB_OUTPUT",
                        "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "RUNNER_TEMP")
NOTICE_TITLE = "Terraform CI"
# What the jobs after the matrix read, by file: never a job output, which nothing caps and every
# downstream interpolation would carry.
PUBLISHED = ("schema_version", "relevance", "counts", "environments", "tests", "comments", "notices", "warnings",
             "record", "trigger", "ordering", "admission")
# A module's decision has its test stage and its admission head alone (docs/Module-ci.md §5).
MODULE_PUBLISHED = ("schema_version", "mode", "tests", "notices", "warnings", "record", "trigger", "admission",
                    "comments", "automerge")

# Neither endpoint signals truncation, so its caps are the signal (docs/Path-relevance.md §4.2):
# the pull request files endpoint pages out at most 3000 files, a compare lists at most 300.
PER_PAGE = 100
PULL_REQUEST_CAP = 3000
COMPARE_CAP = 300
# `created` is documented; the zero `before` of a new branch is kept as a second signal.
ZERO_SHA = "0" * 40
ERROR_CAP = 500

# Committed files only: registry modules ship their own tests/, and nothing ignored or built belongs
# in the matrix (docs/Terraform-tests.md §4.1).
TEST_FILE_PATTERNS = ("*.tftest.hcl", "*.tftest.json")
TF_FILE_PATTERNS = ("*.tf", "*.tf.json")
# A provider block of a lock file, which `terraform init` writes with the closing brace at column 0.
LOCK_PROVIDER = re.compile(r'^provider\s+"([^"]+)"\s*\{(.*?)^\}', re.M | re.S)
LOCK_VERSION = re.compile(r'^\s*version\s*=\s*"([^"]+)"', re.M)


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

    def read_text(self, path):
        """A file's text, or None when there is none to read."""
        try:
            with open(path, encoding="utf-8") as handle:
                return handle.read()
        except OSError:
            return None


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


def parse_yaml(tools, text, expression=None):
    """yq's reading of `text` as a parse result {"ok", "value"}; several documents do not parse.
    `expression`, when given, is applied to the document before it becomes JSON."""
    code, stdout, _ = _run(tools, YQ + ((expression,) if expression else ()) + ("-",), text)
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
    return {name: parse_yaml(tools, input_text(value), READ_AS.get(name)) for name, value in sorted(inputs.items())
            if name.endswith("-yml")}


def parse_environments(tools, entries):
    """One map of parse results per environment entry, aligned by index; {} for a non-mapping."""
    if not isinstance(entries, list):
        return []
    return [{key: parse_yaml(tools, field_text(value), AS_TEXT if key in VARIABLE_SETTINGS else None)
             for key, value in sorted(entry.items()) if key.endswith("-yml")}
            if isinstance(entry, dict) else {} for entry in entries]


def check_directories(entries, isdir):
    """Existence of every directory an environment's check will read, keyed as the engine reads it."""
    if not isinstance(entries, list):
        return {}
    paths = [environments.project_dir_path(entry) for entry in entries
             if isinstance(entry, dict) and "environment" in entry]
    return {path: isdir(path) for path in paths}


def read_payload(event_path):
    """The event payload, or {} when there is none to read."""
    try:
        with open(event_path, encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, ValueError):
        return {}
    return payload if isinstance(payload, dict) else {}


def default_branch(payload, repository, tools):
    """The caller's default branch: from the event payload, which carries it on every event this
    workflow runs on, else from the API. A failed fallback is an error, never a guess."""
    repository_payload = payload.get("repository")
    branch = repository_payload.get("default_branch") if isinstance(repository_payload, dict) else None
    if isinstance(branch, str) and branch:
        return branch
    code, stdout, stderr = _run(tools, ("gh", "api", f"repos/{repository}"))
    try:
        branch = json.loads(stdout)["default_branch"] if code == 0 else None
    except (ValueError, KeyError, TypeError):
        branch = None
    if not isinstance(branch, str) or not branch:
        raise AdapterError(f"could not resolve the default branch of '{repository}', the API answered:",
                           (stdout + stderr).strip()[:2000])
    return branch


def _is_count(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def _input_text(value):
    """A dispatch input as text: absent is empty (P9), a string as given, anything else as JSON."""
    if value is None:
        return ""
    return value if isinstance(value, str) else json.dumps(value)


def dispatch_facts(payload):
    """The standard dispatch inputs (docs/Dispatch-and-triggers.md §3.1). The payload's `inputs` is
    null when the calling workflow declares no inputs block (P8), and a string input dispatched empty
    is absent from it (P9), so each input is read as text and 'block' says whether there was a block.
    'inputs' names what was delivered, never the values, which may be anything the caller declared."""
    inputs = payload.get("inputs")
    if not isinstance(inputs, dict):
        return {"block": False, "environment": "", "goal": "", "reason": "", "inputs": []}
    return {"block": True, **{key: _input_text(inputs.get(key)) for key in ("environment", "goal", "reason")},
            "inputs": sorted(inputs)}


def event_facts(event_name, payload):
    """What the payload says about the change: the three push booleans, the pull request's action,
    number, head commit and whether it comes from a fork, or a dispatch's inputs. A pull request
    payload without its number and head reports nothing."""
    if event_name == "workflow_dispatch":
        return {"dispatch": dispatch_facts(payload)}
    if event_name == "push":
        return {"push": {
            "created": payload.get("created") is True or payload.get("before") == ZERO_SHA,
            "forced": payload.get("forced") is True,
            "deleted": payload.get("deleted") is True,
        }}
    pull_request = payload.get("pull_request")
    if event_name != "pull_request" or not isinstance(pull_request, dict):
        return {}
    head = pull_request.get("head")
    head_sha = head.get("sha") if isinstance(head, dict) else None
    if not _is_count(pull_request.get("number")) or not isinstance(head_sha, str):
        return {}
    repo = head.get("repo")
    action = payload.get("action")
    user = pull_request.get("user")
    author = user.get("login") if isinstance(user, dict) else None
    # The author says whose pull request it is, which a person's push does not change; only the admission's
    # comment reads it (docs/Dependabot-admission.md §7).
    return {"action": action if isinstance(action, str) else "",
            "pull_request": {"number": pull_request["number"], "head_sha": head_sha,
                             "is_fork": isinstance(repo, dict) and repo.get("fork") is True,
                             "author": author if isinstance(author, str) else ""}}


class _Unanswered(Exception):
    """A changed-file request that did not answer; reported as a fact, never raised past the fetch."""

    def __init__(self, message, api_head_sha=None):
        super().__init__(message)
        self.api_head_sha = api_head_sha


def _api(tools, endpoint):
    try:
        code, stdout, stderr = tools.run(("gh", "api", endpoint))
    except OSError as error:
        raise _Unanswered(f"'gh' cannot be run on this runner: {error}") from None
    if code != 0:
        raise _Unanswered(f"gh api {endpoint} failed: {(stderr or stdout).strip()[:ERROR_CAP]}")
    try:
        return json.loads(stdout)
    except ValueError:
        raise _Unanswered(f"gh api {endpoint} did not answer with JSON") from None


def _paths(endpoint, entries):
    """Every path a list of changed files names; a renamed file under its new and its old path."""
    if not isinstance(entries, list) or not all(
            isinstance(entry, dict) and isinstance(entry.get("filename"), str)
            and isinstance(entry.get("previous_filename", ""), str) for entry in entries):
        raise _Unanswered(f"gh api {endpoint} answered without a list of files")
    paths = []
    for entry in entries:
        paths.append(entry["filename"])
        if "previous_filename" in entry:
            paths.append(entry["previous_filename"])
    return paths


def _facts(count, files, truncated, api_head_sha=None):
    return {"available": True, "truncated": truncated, "error": None, "api_head_sha": api_head_sha, "count": count,
            "files": files}


def _pull_request_files(tools, repository, number):
    endpoint = f"repos/{repository}/pulls/{number}"
    pull_request = _api(tools, endpoint)
    head = pull_request.get("head") if isinstance(pull_request, dict) else None
    head_sha = head.get("sha") if isinstance(head, dict) else None
    if not _is_count(pull_request.get("changed_files") if isinstance(pull_request, dict) else None) \
            or not isinstance(head_sha, str):
        raise _Unanswered(f"gh api {endpoint} answered without a changed-file count and a head commit")
    expected = pull_request["changed_files"]
    if expected > PULL_REQUEST_CAP:
        return _facts(expected, [], True, head_sha)
    paths, count, number_of_page = [], 0, 1
    while count < expected:
        page_endpoint = f"{endpoint}/files?per_page={PER_PAGE}&page={number_of_page}"
        try:
            entries = _api(tools, page_endpoint)
            paths += _paths(page_endpoint, entries)
        except _Unanswered as error:
            raise _Unanswered(str(error), head_sha) from None
        count += len(entries)
        if len(entries) < PER_PAGE:
            break
        number_of_page += 1
    return _facts(count, paths, count >= PULL_REQUEST_CAP, head_sha)


def _compare_files(tools, repository, base, head):
    endpoint = f"repos/{repository}/compare/{urllib.parse.quote(base)}...{head}"
    answer = _api(tools, endpoint)
    entries = answer.get("files") if isinstance(answer, dict) else None
    paths = _paths(endpoint, entries)
    return _facts(len(entries), paths, len(entries) >= COMPARE_CAP)


def fetch_changed_files(tools, repository, default_branch_name, event, payload):
    """The changed files of a pull request or a push, as facts (docs/Path-relevance.md §4.3), or
    None where there is nothing to fetch. A failure is a fact the core fails open on."""
    try:
        if event["name"] == "pull_request":
            if "pull_request" not in event:
                raise _Unanswered("the event payload carries no pull request number and head commit")
            return _pull_request_files(tools, repository, event["pull_request"]["number"])
        if event["name"] != "push" or event["push"]["forced"] or event["push"]["deleted"]:
            return None
        base = default_branch_name if event["push"]["created"] else payload.get("before")
        if not isinstance(base, str) or not isinstance(payload.get("after"), str):
            raise _Unanswered("the event payload carries no 'before' and 'after' commits")
        return _compare_files(tools, repository, base, payload["after"])
    except _Unanswered as error:
        return {"available": False, "truncated": False, "error": str(error),
                "api_head_sha": error.api_head_sha, "count": 0, "files": []}


def run_number(environ, name):
    value = environ[name]
    if not (value.isascii() and value.isdigit()):
        raise AdapterError(f"the runner set {name} to {value!r}, which is not a run number")
    return int(value)


def write_relevance_file(runner_temp, output, published=PUBLISHED):
    """The decision without its matrices, in a directory of its own under the runner's temp."""
    try:
        path = os.path.join(tempfile.mkdtemp(dir=runner_temp), "relevance.json")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(json.dumps({key: output[key] for key in published}, indent=2, sort_keys=True,
                                    ensure_ascii=False) + "\n")
    except OSError as error:
        raise AdapterError(f"the relevance file cannot be written under '{runner_temp}': {error}") from None
    return path


def parse_lock(text):
    """A lock file's providers and the versions it records."""
    versions = {}
    for provider, block in LOCK_PROVIDER.findall(text):
        version = LOCK_VERSION.search(block)
        if version is not None:
            versions[provider] = version.group(1)
    return versions


def list_committed(tools, patterns):
    code, stdout, stderr = _run(tools, ("git", "ls-files", "-z", "--", *patterns))
    if code != 0:
        raise AdapterError("git cannot list the repository's committed files", (stderr or stdout).strip()[:ERROR_CAP])
    return [path for path in stdout.split("\0") if path]


def gather_tests(tools, entries):
    """The test stage's facts (docs/Terraform-tests.md §9.1): reported raw, the engine decides."""
    files = list_committed(tools, TEST_FILE_PATTERNS)
    directories = sorted({path.rpartition("/")[0] or "." for path in list_committed(tools, TF_FILE_PATTERNS)})
    locks = {}
    for entry in entries or []:
        if isinstance(entry, dict) and "environment" in entry:
            directory = tests.normalise_dir(environments.project_dir_path(entry))
            text = tools.read_text(".terraform.lock.hcl" if directory == "." else f"{directory}/.terraform.lock.hcl")
            locks[directory] = None if text is None else parse_lock(text)
    return {"files": files, "directories_with_tf": directories, "environment_locks": locks}


def read_inputs(path):
    try:
        with open(path, encoding="utf-8") as handle:
            inputs = json.load(handle)
    except (OSError, ValueError) as error:
        raise AdapterError(f"the action's input 'inputs-json' cannot be read as JSON: {error}") from None
    if not isinstance(inputs, dict):
        raise AdapterError("the action's input 'inputs-json' is not a JSON object; it expects toJSON(inputs)")
    return inputs


def build_document(inputs, facts, tools, isdir, module=False):
    """The engine's input document (docs/Decision-engine.md §4) from the inputs and the run's facts;
    a module's has no environments and no changed files (docs/Module-ci.md §5)."""
    yaml_inputs = parse_inputs(tools, inputs)
    # A parse that failed carries the value null, which yields no entries; a module has no such input.
    entries = yaml_inputs.get("environments-yml", {}).get("value")
    event = {"name": facts["event_name"], "ref_name": facts["ref_name"], "ref_type": facts["ref_type"],
             **event_facts(facts["event_name"], facts["payload"])}
    # The operation gates compare github.base_ref, the runner's, not the payload's (docs/Decision-engine.md §4).
    for key in ("actor", "triggering_actor", "base_ref"):
        if facts.get(key):
            event[key] = facts[key]
    document = {
        "schema_version": SCHEMA_VERSION,
        "caller": {"repository": facts["repository"], "default_branch": facts["default_branch"],
                   **({"workflow_name": facts["workflow_name"]} if facts.get("workflow_name") else {})},
        "event": event,
        "workflow_inputs": inputs,
        "yaml": {"inputs": yaml_inputs, "environments": parse_environments(tools, entries)},
        "directories_exist": check_directories(entries, isdir),
        "run": facts["run"],
    }
    if module:
        document["mode"] = "module"
    # Switched off, relevance needs no facts, so it makes no requests; a module has none.
    if not module and inputs.get(relevance.SWITCH) not in (False, "false"):
        changed = fetch_changed_files(tools, facts["repository"], facts["default_branch"], event, facts["payload"])
        if changed is not None:
            document["changed_files"] = changed
    # A caller without the test stage's inputs has no test stage; one that switched it off lists nothing.
    if "terraform-test-enabled" in inputs and inputs["terraform-test-enabled"] not in (False, "false"):
        document["tests"] = gather_tests(tools, entries)
    if module and _automerge_applies(document):
        # A listing that fails is a fact the engine rules ineligible on; the run goes on (docs/Module-auto-merge.md M11).
        document["automerge"] = automerge_facts.gather(tools, facts["repository"], facts["payload"])
    if _admission_applies(document, module) and event["name"] == "pull_request":
        try:
            document["admission"] = admission_facts.gather(tools)
        except admission_facts.FactError as error:
            # D11: neither admitting nor refusing on a guess; "Re-run failed jobs" decides again.
            raise AdapterError(f"the Dependabot admission cannot be decided: {error}") from None
    if module and "admission" not in document and _automerge_applies(document) \
            and document["event"]["pull_request"].get("author", "").casefold() == admission.DEPENDABOT:
        # Auto-merge's rule 7 reads Dependabot's dependency changes in the run the docs commit starts too, which the
        # admission does not judge. Facts that cannot be gathered make the run not eligible, never failed (M11).
        try:
            document["admission"] = admission_facts.gather(tools)
        except admission_facts.FactError:
            pass
    return document


def _automerge_applies(document):
    """Whether the rule reads a module pull request's commits; an invalid setting gathers nothing and the
    engine reports it."""
    try:
        return automerge.wants_facts(document, automerge.settings(document))
    except environments.ConfigError:
        return False


def _admission_applies(document, module):
    """Whether the admission judges this run; an invalid policy gathers nothing and the engine reports it."""
    try:
        policy = admission.settings(document, default_enabled=not module)
    except environments.ConfigError:
        return False
    return admission.applies(document, policy)


def admission_outputs(output):
    """The step outputs the jobs read: whether the admission refused the run, and why in one line, and whether
    it judged and admitted it, which the module workflow's docs push needs (docs/Dependabot-admission.md D22)."""
    admitted = output["admission"]
    judged = admitted["applies"] and not admitted["push_run"]
    refused = judged and not admitted["admitted"]
    return {"admission-refused": "true" if refused else "false",
            "admission-reason": decide.refusal(admitted) if refused else "",
            "admission-admitted": "true" if judged and admitted["admitted"] else "false"}


def compact(value):
    """A value as a job output: one line, keys sorted, text unescaped."""
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def union_matrix(output):
    """Every stage's rows in one matrix, in environments-yml order: the matrix-json output, kept for the
    action's callers that read one matrix."""
    position = {entry["environment"]: index for index, entry in enumerate(output["environments"])}
    rows = sorted((row for stage in ordering.STAGES for row in output["matrices"][stage]["include"]),
                  key=lambda row: position[row["environment"]])
    return {"environment": [row["environment"] for row in rows], "include": rows}


def run(inputs_file, environ, stream, tools, isdir, module=False):
    """Run the create-matrix step. Returns the exit code: 0, 1 a fault, 2 an invalid configuration."""
    log = workflow.Log(stream, TITLE)
    try:
        missing = [name for name in REQUIRED_ENVIRONMENT if not environ.get(name)]
        if missing:
            raise AdapterError(f"the runner did not set {', '.join(missing)}")
        run_facts = {"id": run_number(environ, "GITHUB_RUN_ID"), "attempt": run_number(environ, "GITHUB_RUN_ATTEMPT")}
        require_yq(tools)
        inputs = read_inputs(inputs_file)
        log.group("input 'inputs-json'", json.dumps(inputs, indent=2, ensure_ascii=False))
        payload = read_payload(environ.get("GITHUB_EVENT_PATH", ""))
        facts = {
            "repository": environ["GITHUB_REPOSITORY"],
            "event_name": environ["GITHUB_EVENT_NAME"],
            "ref_name": environ["GITHUB_REF_NAME"],
            "ref_type": environ["GITHUB_REF_TYPE"],
            "default_branch": default_branch(payload, environ["GITHUB_REPOSITORY"], tools),
            "payload": payload,
            "run": run_facts,
            "workflow_name": environ.get("GITHUB_WORKFLOW", ""),
            "actor": environ.get("GITHUB_ACTOR", ""),
            "triggering_actor": environ.get("GITHUB_TRIGGERING_ACTOR", ""),
            "base_ref": environ.get("GITHUB_BASE_REF", ""),
        }
        document = build_document(inputs, facts, tools, isdir, module)
    except AdapterError as error:
        log.error(error.message)
        if error.detail:
            log.verbatim(error.detail)
        return EXIT_FAULT

    shown = document
    if "changed_files" in document:
        # Up to three thousand paths: listed once, one per line, not again inside the document.
        paths = document["changed_files"]["files"]
        log.group("changed files", "\n".join(paths))
        shown = {**document, "changed_files": {**document["changed_files"],
                                               "files": f"{len(paths)} paths, listed in the group 'changed files'"}}
    if "admission" in document:
        facts = document["admission"]
        log.group("admission facts", "\n".join(
            [f"{item['path']}: {item['status']} ({item['kind']})" for item in facts["files"]]
            + [f"{item['kind']} {item['address']} {item['from']} -> {item['to']}: {json.dumps(item['facts'])}"
               for item in facts["dependencies"]]))
        shown = {**shown, "admission": f"{len(facts['files'])} files and {len(facts['dependencies'])} dependencies, "
                                      "listed in the group 'admission facts'"}
    log.group("decision engine input document", json.dumps(shown, indent=2, sort_keys=True, ensure_ascii=False))
    output = decide.decide(document)
    if output["errors"]:
        for message in output["errors"]:
            log.error(message)
        return EXIT_INVALID

    try:
        relevance_file = write_relevance_file(environ["RUNNER_TEMP"], output,
                                              MODULE_PUBLISHED if module else PUBLISHED)
    except AdapterError as error:
        log.error(error.message)
        return EXIT_FAULT

    log.group("decision record", "\n".join(output["record"]))
    for notice in output["notices"]:
        log.notice(NOTICE_TITLE, notice)
    for warning in output["warnings"]:
        log.warning(warning)
    if module:
        outputs = {
            "relevance-file": relevance_file,
            "tests-matrix-json": compact(output["tests"]["matrix"]),
            "tests-count": str(output["tests"]["count"]),
            "tests-active": "true" if output["tests"]["active"] else "false",
            "tests-required-missing": "true" if output["tests"]["missing"] else "false",
            **admission_outputs(output),
            # The merge job reads them (docs/Module-auto-merge.md §6).
            "automerge-eligible": "true" if output["automerge"].get("eligible") else "false",
            "automerge-confirm-app": "true" if output["automerge"].get("confirm_app") else "false",
        }
        for name, value in outputs.items():
            workflow.append_output(environ["GITHUB_OUTPUT"], name, value)
        return EXIT_OK
    matrix = union_matrix(output)
    log.group("matrix-json", json.dumps(matrix, indent=2, sort_keys=True, ensure_ascii=False))
    outputs = {
        "matrix-json": compact(matrix),
        **{f"matrix-stage-{stage}-json": compact(output["matrices"][stage]) for stage in ordering.STAGES},
        **{f"stage-{stage}-count": str(output["counts"]["by_stage"][stage]) for stage in ordering.STAGES},
        "affected-count": str(output["counts"]["affected"]),
        "unaffected-count": str(output["counts"]["unaffected"]),
        "relevance-mode": output["relevance"]["mode"],
        "relevance-reason": output["relevance"]["reason"],
        "changed-count": str(output["relevance"]["changed_count"]),
        "relevance-file": relevance_file,
        "tests-matrix-json": compact(output["tests"]["matrix"]),
        "tests-count": str(output["tests"]["count"]),
        "tests-active": "true" if output["tests"]["active"] else "false",
        **admission_outputs(output),
    }
    for name, value in outputs.items():
        workflow.append_output(environ["GITHUB_OUTPUT"], name, value)
    return EXIT_OK
