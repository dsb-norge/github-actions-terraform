"""The `decide` command: the input document in, the output document out."""

from . import SCHEMA_VERSION, environments, model, record, relevance


def _failed(errors):
    return {
        "schema_version": SCHEMA_VERSION,
        "errors": errors,
        "notices": [],
        "environments": [],
        "matrices": {},
        "counts": {"affected": 0, "unaffected": 0},
        "record": [],
    }


def _decided(block, rows, entries):
    affected = [row for row, entry in zip(rows, entries) if entry["verdict"] == "run"]
    matrix = {
        "environment": [row["environment"] for row in affected],
        "include": [{"environment": row["environment"], "vars": row} for row in affected],
    }
    return {
        "schema_version": SCHEMA_VERSION,
        "errors": [],
        "notices": [relevance.notice(block, entries)],
        "relevance": block,
        "environments": entries,
        # One stage until environment ordering assigns more.
        "matrices": {"1": matrix},
        "counts": {"affected": len(affected), "unaffected": len(rows) - len(affected)},
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
        block, entries = relevance.decide_relevance(document, declared, rows)
    except environments.ConfigError as error:
        return _failed(error.messages)
    return _decided(block, rows, entries)
