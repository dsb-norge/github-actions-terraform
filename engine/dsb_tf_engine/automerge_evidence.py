"""The evaluate-automerge step: reads the project run's evidence, judges it, publishes the verdict.

Adapter side (docs/Auto-merge.md §14): the metadata files of the environment jobs, the test jobs'
metadata, relevance.json and the stage results become the facts automerge_project judges; a file
that cannot be read is a fact, never an error. The log is written through workflow.Log, so a name
from a caller's configuration is shown, never run as a workflow command.
"""

import glob
import json
import os

from . import automerge_project, workflow

TITLE = "evaluate-automerge-eligibility"
EXIT_OK, EXIT_FAULT = 0, 1


def read_file(path):
    """{"file", "readable", "json", "content"}: whether the file can be read, and parsed."""
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except (OSError, UnicodeDecodeError):
        return {"file": path, "readable": False, "json": False, "content": None}
    try:
        return {"file": path, "readable": True, "json": True, "content": json.loads(text)}
    except ValueError:
        return {"file": path, "readable": True, "json": False, "content": None}


def matches(pattern):
    """The files a glob pattern matches in the working directory, sorted as the shell lists them."""
    return sorted(path for path in glob.glob(pattern) if os.path.isfile(path))


def gather(metadata_pattern, relevance_path, tests_pattern, stage_results_text, actor):
    """The facts automerge_project.evaluate judges."""
    relevance = None
    if relevance_path:
        relevance = {**read_file(relevance_path), "exists": os.path.exists(relevance_path)}
    return {"actor": actor, "metadata_pattern": metadata_pattern, "tests_pattern": tests_pattern,
            "metadata": [read_file(path) for path in matches(metadata_pattern)],
            "tests": [read_file(path) for path in matches(tests_pattern)],
            "relevance": relevance, "stage_results": stage_results_text}


def _text(entries):
    return "\n".join(("WARN: " if entry[0] == "warn" else "") + entry[1] for entry in entries)


def write_log(log, entries):
    """The evaluator's log: plain lines verbatim, each group collapsed."""
    plain = []
    for entry in entries:
        if entry[0] == "group":
            if plain:
                log.verbatim(_text(plain))
                plain = []
            log.group(entry[1], _text(entry[2]))
        else:
            plain.append(entry)
    if plain:
        log.verbatim(_text(plain))


def run(metadata_pattern, relevance_path, tests_pattern, stage_results_file, environ, stream):
    """The step: 0 with is-eligible published, 1 when a limits mapping cannot be judged."""
    log = workflow.Log(stream, TITLE)
    try:
        with open(stage_results_file, encoding="utf-8") as handle:
            stage_results_text = handle.read()
    except OSError as error:
        log.error(f"the stage results cannot be read: {error}")
        return EXIT_FAULT
    facts = gather(metadata_pattern, relevance_path, tests_pattern, stage_results_text, environ.get("GITHUB_ACTOR", ""))
    verdict = automerge_project.evaluate(facts)
    write_log(log, verdict["log"].entries)
    if verdict["fatal"]:
        for message in verdict["fatal"]:
            log.error(message)
        return EXIT_FAULT
    for message in verdict["notices"]:
        log.notice("Auto-merge", message)
    workflow.append_output(environ["GITHUB_OUTPUT"], "is-eligible", "true" if verdict["eligible"] else "false")
    return EXIT_OK
