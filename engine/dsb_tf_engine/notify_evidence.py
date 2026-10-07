"""The decide-notifications and record-notifications steps (docs/Notifications.md §7, §9), adapter side.

decide-notifications reads the run's evidence (the environment jobs' metadata, the matrix, relevance.json,
the stage results and the restored incident state), asks notify_decide which costly facts the run needs,
gathers them with gh (the push's pull requests, the senders' protection rules), and writes the events,
their messages, the observations and the summary for the jobs after it. record-notifications merges the
observations and the deliver jobs' answers into the newest state. A fact that cannot be gathered is a
fact; only a file the step cannot do without is a fault. The log goes through workflow.Log, so nothing
from a caller or a pull request is run as a workflow command.
"""

import datetime
import json
import os
import urllib.parse

from . import automerge_evidence, notify_decide, notify_state, workflow

DECIDE_TITLE = "decide-notifications"
RECORD_TITLE = "record-notifications"
EXIT_OK, EXIT_FAULT = 0, 1
ZERO_SHA = "0" * 40
# A push of more merges than this names the newest; the message lists ten.
COMMIT_LIMIT = 50
TOMBSTONE_DAYS = 30
ERROR_CAP = 500
AGAIN = "it is posted again by the next run that sees it"


class Fault(Exception):
    """A file the step cannot do without, or a runner that set no run number."""


class _Unanswered(Exception):
    def __init__(self, message, not_found=False):
        super().__init__(message)
        self.not_found = not_found


def _api(tools, endpoint):
    try:
        code, stdout, stderr = tools.run(("gh", "api", endpoint))
    except OSError as error:
        raise _Unanswered(f"'gh' cannot be run on this runner: {error}") from None
    if code != 0:
        raise _Unanswered(f"gh api {endpoint} failed: {(stderr or stdout).strip()[:ERROR_CAP]}",
                          "(HTTP 404)" in stderr)
    try:
        return json.loads(stdout)
    except ValueError:
        raise _Unanswered(f"gh api {endpoint} did not answer with JSON") from None


def _login(user):
    """A person's login, or None for nobody and for a bot that does not say so in its name."""
    if not isinstance(user, dict) or not isinstance(user.get("login"), str):
        return None
    return None if user.get("type") == "Bot" else user["login"]


def first_parent(commits, before, after):
    """The commits on the first-parent line from `after` back to `before`, newest first: the merges a push
    brought to the default branch, not the commits of the branches merged. ValueError for commits of another
    shape than the compare endpoint's."""
    try:
        parents = {commit["sha"]: [parent["sha"] for parent in commit["parents"]] for commit in commits}
    except (KeyError, TypeError):
        raise ValueError from None
    line, sha = [], after
    while sha in parents and sha != before and len(line) < COMMIT_LIMIT:
        line.append(sha)
        sha = parents[sha][0] if parents[sha] else None
    return line or [after]


def gather_people(tools, repository, payload, default_branch):
    """The pull requests a push merged and who pushed it (§5), or why they could not be read."""
    try:
        after, before = payload.get("after"), payload.get("before")
        if not isinstance(after, str) or not after:
            raise _Unanswered("the event payload carries no 'after' commit")
        if payload.get("forced") is True or not isinstance(before, str) or before == ZERO_SHA:
            line = [after]
        else:
            endpoint = f"repos/{repository}/compare/{before}...{after}"
            commits = _api(tools, endpoint)
            commits = commits.get("commits") if isinstance(commits, dict) else None
            if not isinstance(commits, list):
                raise _Unanswered(f"gh api {endpoint} answered without commits")
            try:
                line = first_parent(commits, before, after)
            except ValueError:
                raise _Unanswered(f"gh api {endpoint} answered with commits of another shape") from None
        numbers = []
        for sha in line:
            endpoint = f"repos/{repository}/commits/{sha}/pulls"
            pulls = _api(tools, endpoint)
            if not isinstance(pulls, list):
                raise _Unanswered(f"gh api {endpoint} answered without a list")
            numbers += [pull["number"] for pull in pulls
                        if isinstance(pull, dict) and pull.get("merged_at") and isinstance(pull.get("base"), dict)
                        and pull["base"].get("ref") == default_branch and isinstance(pull.get("number"), int)
                        and pull["number"] not in numbers]
        pull_requests = []
        for number in numbers:
            endpoint = f"repos/{repository}/pulls/{number}"
            pull = _api(tools, endpoint)
            if not isinstance(pull, dict):
                raise _Unanswered(f"gh api {endpoint} answered without a pull request")
            pull_requests.append({"number": number, "title": pull.get("title") if isinstance(pull.get("title"), str)
                                  else "", "author": _login(pull.get("user")), "merged_by": _login(pull.get("merged_by"))})
        return {"available": True, "error": None, "pull_requests": pull_requests, "pusher": _login(payload.get("sender"))}
    except _Unanswered as error:
        return {"available": False, "error": str(error), "pull_requests": [], "pusher": None}


def protected(tools, repository, name):
    """Whether a GitHub environment has a rule that holds a job (reviewers, a wait timer, a custom rule); a
    branch policy does not. None when the answer cannot be read (D16)."""
    try:
        answer = _api(tools, f"repos/{repository}/environments/{urllib.parse.quote(name, safe='')}")
    except _Unanswered as error:
        # GitHub creates an environment the first time a job uses it: one that does not exist holds nothing.
        return False if error.not_found else None
    rules = answer.get("protection_rules", []) if isinstance(answer, dict) else None
    if not isinstance(rules, list):
        return None
    return any(not (isinstance(rule, dict) and rule.get("type") == "branch_policy") for rule in rules)


def _read_json(path, what):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError) as error:
        raise Fault(f"{what} cannot be read: {error}") from None


# What a file that exists but cannot be read reads as: neither None (no file) nor any JSON value.
_UNREADABLE = object()


def _optional_json(path):
    """The file's JSON, None when there is no file, and _UNREADABLE when there is one that cannot be read."""
    if not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return _UNREADABLE


def _run_number(environ, name):
    value = environ.get(name, "")
    if not (value.isascii() and value.isdigit()):
        raise Fault(f"the runner set {name} to {value!r}, which is not a run number")
    return int(value)


def _metadata(pattern):
    """{environment: metadata} of every file the pattern matches, and why a file could not be used."""
    found, problems = {}, []
    for entry in (automerge_evidence.read_file(path) for path in automerge_evidence.matches(pattern)):
        environment = notify_decide.path(entry["content"], "metadata", "environment")
        if not entry["readable"]:
            problems.append(f"{entry['file']} cannot be read")
        elif not entry["json"]:
            problems.append(f"{entry['file']} is not JSON")
        elif not isinstance(environment, str) or not environment:
            problems.append(f"{entry['file']} names no environment")
        else:
            found[environment] = entry["content"]
    return found, problems


def _rows(matrix):
    include = matrix.get("include") if isinstance(matrix, dict) else None
    if not isinstance(include, list) or not all(
            isinstance(item, dict) and isinstance(item.get("vars"), dict)
            and isinstance(item["vars"].get("environment"), str) for item in include):
        raise Fault("the matrix is not create-matrix's matrix-json")
    return {item["vars"]["environment"]: item["vars"] for item in include}


def _state(path, log):
    """The stored incident state, or None: a document of another shape is warned about and started over."""
    stored = _optional_json(path)
    state = notify_state.valid(stored)
    if stored is not None and state is None:
        log.warning("the stored incident state is not one this version reads; it starts over")
    return state


def _stamp(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def _append_summary(environ, text):
    if environ.get("GITHUB_STEP_SUMMARY"):
        with open(environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(text)


def _write(path, text):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def run_decide(metadata_pattern, matrix_file, relevance_file, stage_results_file, state_file, out_dir, environ, stream,
               tools):
    """The decide step: 0 with deliver-matrix-json and deliver-count published, 1 on a fault."""
    log = workflow.Log(stream, DECIDE_TITLE)
    try:
        relevance = _read_json(relevance_file, "the relevance file")
        notify = relevance.get("notify") if isinstance(relevance, dict) else None
        if not (isinstance(notify, dict) and isinstance(notify.get("target"), dict)
                and isinstance(notify.get("senders"), dict) and isinstance(notify.get("runs-on"), str)):
            raise Fault("the relevance file names no notification target, so this run does not notify")
        rows = _rows(_read_json(matrix_file, "the matrix"))
        run = {"id": _run_number(environ, "GITHUB_RUN_ID"), "number": _run_number(environ, "GITHUB_RUN_NUMBER"),
               "attempt": _run_number(environ, "GITHUB_RUN_ATTEMPT")}
    except Fault as error:
        log.error(str(error))
        return EXIT_FAULT
    metadata, problems = _metadata(metadata_pattern)
    for problem in problems:
        log.warning(problem)
    stage_results = _optional_json(stage_results_file)
    if not isinstance(stage_results, dict):
        log.warning("the stage results cannot be read; every stage reads as unknown")
        stage_results = {}
    state = _state(state_file, log)
    payload = automerge_evidence.read_file(environ["GITHUB_EVENT_PATH"])["content"]
    payload = payload if isinstance(payload, dict) else {}
    facts = {"repository": environ["GITHUB_REPOSITORY"], "server_url": environ["GITHUB_SERVER_URL"],
             "event": environ["GITHUB_EVENT_NAME"], "run": run, "target": notify["target"],
             "senders": notify["senders"], "runs_on": notify["runs-on"], "environments": relevance["environments"],
             "rows": rows, "metadata": metadata, "stage_results": stage_results, "state": state}
    wanted = notify_decide.wanted(facts)
    facts["people"] = gather_people(tools, facts["repository"], payload, notify_decide.path(
        payload, "repository", "default_branch")) if wanted["people"] else None
    facts["protection"] = {name: protected(tools, facts["repository"], name) for name in wanted["protection"]}
    decided = notify_decide.decide(facts)

    os.makedirs(os.path.join(out_dir, "events"), exist_ok=True)
    for event in decided["events"]:
        _write(os.path.join(out_dir, "events", f"{event['id']}.json"), json.dumps(event))
        _write(os.path.join(out_dir, "events", event["message"]), decided["messages"][event["message"]])
        log.group(f"{event['id']}: {event['action']} {event['environment']}", decided["messages"][event["message"]])
    _write(os.path.join(out_dir, "observations.json"),
           json.dumps({"run_number": run["number"], "observations": decided["observations"]}))
    _write(os.path.join(out_dir, "summary.md"), decided["summary"])
    _append_summary(environ, decided["summary"])
    workflow.append_output(environ["GITHUB_OUTPUT"], "deliver-matrix-json", json.dumps({"include": decided["deliver"]}))
    workflow.append_output(environ["GITHUB_OUTPUT"], "deliver-count", str(len(decided["deliver"])))
    return EXIT_OK


def _results(pattern, log):
    """{event id: {accepted, message_id}} from the deliver jobs' answer files."""
    results = {}
    for entry in (automerge_evidence.read_file(path) for path in automerge_evidence.matches(pattern)):
        content = entry["content"]
        if not (isinstance(content, dict) and isinstance(content.get("id"), str)):
            log.warning(f"{entry['file']} is not a deliver job's answer")
            continue
        message_id = content.get("message_id")
        results[content["id"]] = {"accepted": content.get("accepted") in (True, "true"),
                                  "message_id": message_id if isinstance(message_id, str) and message_id else None,
                                  "http_status": str(content.get("http_status", ""))}
    return results


def run_record(state_file, observations_file, results_pattern, out_file, environ, stream, clock):
    """The record step: the new state written to `out_file`, `changed` published; 1 on a fault."""
    log = workflow.Log(stream, RECORD_TITLE)
    try:
        observed = _read_json(observations_file, "the observations")
        if not (isinstance(observed, dict) and isinstance(observed.get("run_number"), int)
                and isinstance(observed.get("observations"), list)):
            raise Fault("the observations are not decide-notifications' observations.json")
    except Fault as error:
        log.error(str(error))
        return EXIT_FAULT
    state = _state(state_file, log)
    results = _results(results_pattern, log)
    now = clock()
    new_state, changed = notify_state.merge(state, observed["observations"], results, observed["run_number"],
                                            _stamp(now), _stamp(now - datetime.timedelta(days=TOMBSTONE_DAYS)))
    os.makedirs(os.path.dirname(os.path.abspath(out_file)), exist_ok=True)
    _write(out_file, json.dumps(new_state))
    lines = []
    for observation in observed["observations"]:
        if not observation.get("sending"):
            continue
        result = results.get(observation["event"])
        if result is None:
            lines.append(f"- `{observation['environment']}`: its deliver job left no answer; {AGAIN}")
        elif not result["accepted"]:
            lines.append(f"- `{observation['environment']}`: not accepted by the relay (HTTP "
                         f"{result['http_status']}); {AGAIN}")
    if lines:
        _append_summary(environ, "### 📣 Teams deliveries\n\n" + "\n".join(lines) + "\n")
    workflow.append_output(environ["GITHUB_OUTPUT"], "changed", "true" if changed else "false")
    return EXIT_OK
