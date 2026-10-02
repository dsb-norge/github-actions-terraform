"""The `decide` command: the input document in, the output document out."""

from . import SCHEMA_VERSION, comments, environments, model, ordering, record, relevance, tests, triggers


def _failed(errors):
    return {
        "schema_version": SCHEMA_VERSION,
        "errors": errors,
        "notices": [],
        "warnings": [],
        "environments": [],
        "matrices": {},
        "counts": {"affected": 0, "unaffected": 0},
        "record": [],
    }


def _matrix(rows):
    return {"environment": [row["environment"] for row in rows],
            "include": [{"environment": row["environment"], "vars": row} for row in rows]}


def _decided(document, block, rows, entries, staged, tests_block, warnings, notices, trigger):
    order_block, stages, order_notices = staged
    affected = [row for row, entry in zip(rows, entries) if entry["verdict"] == "run"]
    by_stage = {stage: [rows[index] for index in sorted(stages) if str(stages[index]) == stage]
                for stage in ordering.STAGES}
    return {
        "schema_version": SCHEMA_VERSION,
        "errors": [],
        "notices": [*trigger, relevance.notice(block, entries), *order_notices, *notices],
        "warnings": warnings,
        "relevance": block,
        "environments": entries,
        "ordering": order_block,
        # Every stage, an empty one included: the workflow reads each stage's matrix and count.
        "matrices": {stage: _matrix(stage_rows) for stage, stage_rows in by_stage.items()},
        "counts": {"affected": len(affected), "unaffected": len(rows) - len(affected),
                   "by_stage": {stage: len(stage_rows) for stage, stage_rows in by_stage.items()}},
        "tests": tests_block,
        "trigger": {"event": document["event"]["name"], "lines": trigger},
        "comments": comments.manifest(document, block, entries, tests_block),
        "record": record.lines(entries),
    }


def _module(document):
    """A module's decision: its test stage alone (docs/Module-ci.md §5)."""
    try:
        triggers.check_event(document)
        tests_block, warnings, notices = tests.decide_tests(document, [], tests.MODULE_TEST_EVENTS)
    except environments.ConfigError as error:
        return _failed(error.messages)
    return {
        "schema_version": SCHEMA_VERSION,
        "mode": "module",
        "errors": [],
        "notices": notices,
        "warnings": warnings,
        "tests": tests_block,
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
        rows = environments.build_rows(document)
        declared = environments.parsed_inputs(document)["environments-yml"]
        ordering.check(declared)
        events, dropped = triggers.participation(document, declared, rows)
        block, entries = relevance.decide_relevance(document, declared, rows, dropped)
        granted = triggers.grant(document, declared, rows, entries)
        # Rule 6: before the goals reason, so an entry's reasons read in the rules' order.
        staged = ordering.assign(document, declared, rows, entries, granted)
        tests_block, warnings, notices = tests.decide_tests(document, rows)
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
                    triggers.lines(document, declared, entries))
