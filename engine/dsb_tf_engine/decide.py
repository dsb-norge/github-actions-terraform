"""The `decide` command: the input document in, the output document out."""

from . import SCHEMA_VERSION, comments, environments, model, record, relevance, tests, triggers


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


def _decided(document, block, rows, entries, tests_block, warnings, notices, trigger):
    affected = [row for row, entry in zip(rows, entries) if entry["verdict"] == "run"]
    matrix = {
        "environment": [row["environment"] for row in affected],
        "include": [{"environment": row["environment"], "vars": row} for row in affected],
    }
    return {
        "schema_version": SCHEMA_VERSION,
        "errors": [],
        "notices": [*trigger, relevance.notice(block, entries), *notices],
        "warnings": warnings,
        "relevance": block,
        "environments": entries,
        # One stage until environment ordering assigns more.
        "matrices": {"1": matrix},
        "counts": {"affected": len(affected), "unaffected": len(rows) - len(affected)},
        "tests": tests_block,
        "trigger": {"event": document["event"]["name"], "lines": trigger},
        "comments": comments.manifest(document, block, entries, tests_block),
        "record": record.lines(entries),
    }


def decide(document):
    """Return the output document; configuration errors are in its `errors`, not raised.

    Raises model.DocumentError when the document itself is malformed.
    """
    model.check(document)
    try:
        rows = environments.build_rows(document)
        declared = environments.parsed_inputs(document)["environments-yml"]
        events, dropped = triggers.participation(document, declared, rows)
        block, entries = relevance.decide_relevance(document, declared, rows, dropped)
        granted = triggers.grant(document, rows, entries)
        tests_block, warnings, notices = tests.decide_tests(document, rows)
    except environments.ConfigError as error:
        return _failed(error.messages)
    for index, entry in enumerate(entries):
        entry["trigger-events"] = events[index]
        if index in granted:
            # Rule 7: the operation gates read the granted goals (D10); the entry says the same (I16).
            rows[index]["goals-granted"] = granted[index]
            entry["goals"] = granted[index]
            entry["reasons"].append(f"goals: {', '.join(granted[index]) or 'none'}")
    return _decided(document, block, rows, entries, tests_block, warnings, notices,
                    triggers.lines(document, entries))
