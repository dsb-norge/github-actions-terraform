"""The `decide` command: the input document in, the output document out."""

from . import (SCHEMA_VERSION, admission, comments, environments, model, ordering, record, relevance, tests, triggers,
               values)


def _failed(errors):
    return {
        "schema_version": SCHEMA_VERSION,
        "errors": errors,
        "notices": [],
        "warnings": [],
        "environments": [],
        "matrices": {},
        "counts": {"affected": 0, "unaffected": 0},
        "admission": admission.NOT_APPLYING,
        "record": [],
    }


def _matrix(rows):
    return {"environment": [row["environment"] for row in rows],
            "include": [{"environment": row["environment"], "vars": row} for row in rows]}


def _decided(document, block, rows, entries, staged, tests_block, warnings, notices, trigger, admitted):
    order_block, stages, order_notices = staged
    affected = [row for row, entry in zip(rows, entries) if entry["verdict"] == "run"]
    by_stage = {stage: [rows[index] for index in sorted(stages) if str(stages[index]) == stage]
                for stage in ordering.STAGES}
    return {
        "schema_version": SCHEMA_VERSION,
        "errors": [],
        "notices": [*trigger, *_admission_notices(admitted), relevance.notice(block, entries), *order_notices,
                    *notices],
        "warnings": warnings,
        "relevance": block,
        "environments": entries,
        "ordering": order_block,
        # Every stage, an empty one included: the workflow reads each stage's matrix and count.
        "matrices": {stage: _matrix(stage_rows) for stage, stage_rows in by_stage.items()},
        "counts": {"affected": len(affected), "unaffected": len(rows) - len(affected),
                   "by_stage": {stage: len(stage_rows) for stage, stage_rows in by_stage.items()}},
        "tests": tests_block,
        "admission": admitted,
        "trigger": {"event": document["event"]["name"], "lines": trigger},
        "comments": comments.manifest(document, block, entries, tests_block, admitted),
        "record": record.lines(entries),
    }


def _admission_notices(admitted):
    if not admitted["applies"]:
        return []
    if admitted["push_run"]:
        return [admission.PUSH_NOTICE]
    if admitted["admitted"]:
        return [f"admission: admitted ({admitted['total']} dependenc{'y' if admitted['total'] == 1 else 'ies'})"]
    return [f"admission: not admitted: {refusal(admitted)}"]


def refusal(admitted):
    """One line saying why a run was not admitted, for the notice, the conclusion and the step outputs."""
    parts = []
    if admitted["refused_count"]:
        parts.append(f"{admitted['refused_count']} of {admitted['total']} dependencies failed")
    if admitted["problems"]:
        count = len(admitted["problems"])
        parts.append(f"{count} problem{'' if count == 1 else 's'} with the change")
    return "; ".join(parts)


def _require_facts(document):
    if document["event"]["name"] == "pull_request" and "admission" not in document:
        raise model.DocumentError("input document: a Dependabot pull request the admission applies to needs the "
                                  "'admission' facts")


def _admit(document, policy, rows, entries, dropped):
    """Rule 3a (docs/Dependabot-admission.md): when the run is not admitted, or is Dependabot's push, every
    environment rules 2 and 3 kept is dropped; relevance has been computed for each all the same."""
    if not admission.applies(document, policy):
        return admission.NOT_APPLYING
    _require_facts(document)
    relevant = {entry["environment"]: tests.normalise_dir(values.render(row["project-dir"]))
                for row, entry, earlier in zip(rows, entries, dropped) if earlier is None and entry["relevant"]}
    admitted = admission.judge(document, policy, relevant)
    if admitted["push_run"] or not admitted["admitted"]:
        reason = admission.PUSH_RUN if admitted["push_run"] else admission.REFUSED
        for entry, earlier in zip(entries, dropped):
            if earlier is None:
                entry["verdict"], entry["reasons"] = "skip", [reason]
    return admitted


def _module(document):
    """A module's decision: its test stage alone (docs/Module-ci.md §5)."""
    try:
        triggers.check_event(document)
        policy = admission.settings(document, default_enabled=False)
        admitted = admission.NOT_APPLYING
        if admission.applies(document, policy):
            _require_facts(document)
            admitted = admission.judge(document, policy, {})
        tests_block, warnings, notices = tests.decide_tests(document, [], tests.MODULE_TEST_EVENTS, admitted)
    except environments.ConfigError as error:
        return _failed(error.messages)
    return {
        "schema_version": SCHEMA_VERSION,
        "mode": "module",
        "errors": [],
        "notices": [*_admission_notices(admitted), *notices],
        "warnings": warnings,
        "tests": tests_block,
        "admission": admitted,
        "trigger": {"event": document["event"]["name"], "lines": []},
        "record": tests.record(tests_block),
    }


def decide(document):
    """Return the output document; configuration errors are in its `errors`, not raised.

    Raises model.DocumentError when the document itself is malformed.
    """
    model.check(document)
    if document.get("mode") == "module":
        return _module(document)
    try:
        policy = admission.settings(document, default_enabled=True)
        rows = environments.build_rows(document)
        declared = environments.parsed_inputs(document)["environments-yml"]
        ordering.check(declared)
        events, dropped = triggers.participation(document, declared, rows)
        block, entries = relevance.decide_relevance(document, declared, rows, dropped)
        admitted = _admit(document, policy, rows, entries, dropped)
        granted = triggers.grant(document, declared, rows, entries)
        # Rule 6: before the goals reason, so an entry's reasons read in the rules' order.
        staged = ordering.assign(document, declared, rows, entries, granted)
        tests_block, warnings, notices = tests.decide_tests(document, rows, admission=admitted)
        warnings = environments.setting_warnings(document, rows) + triggers.setting_warnings(declared, events) + warnings
    except environments.ConfigError as error:
        return _failed(error.messages)
    scheduled = triggers.schedule_goals(document, declared)
    for index, entry in enumerate(entries):
        entry["trigger-events"] = events[index]
        if index in granted:
            if scheduled is not None:
                entry["reasons"].append(f"{triggers.SCHEDULE_GOAL}: {scheduled[index]}")
            # Rule 7: the operation gates read the granted goals (D10); the entry says the same (I16).
            rows[index]["goals-granted"] = granted[index]
            entry["goals"] = granted[index]
            entry["reasons"].append(f"goals: {', '.join(granted[index]) or 'none'}")
    return _decided(document, block, rows, entries, staged, tests_block, warnings, notices,
                    triggers.lines(document, declared, entries), admitted)
