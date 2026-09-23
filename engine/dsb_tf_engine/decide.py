"""The `decide` command: the input document in, the output document out."""

from . import SCHEMA_VERSION, environments, model, record


def _output(errors=(), decided=()):
    rows = [row for row, _ in decided]
    entries = [entry for _, entry in decided]
    matrix = {
        "environment": [row["environment"] for row in rows],
        "include": [{"environment": row["environment"], "vars": row} for row in rows],
    }
    return {
        "schema_version": SCHEMA_VERSION,
        "errors": list(errors),
        "notices": [],
        "environments": entries,
        # One stage until environment ordering assigns more.
        "matrices": {"1": matrix} if rows else {},
        "counts": {"affected": len(rows), "unaffected": 0},
        "record": record.lines(entries),
    }


def decide(document):
    """Return the output document; configuration errors are in its `errors`, not raised.

    Raises model.DocumentError when the document itself is malformed.
    """
    model.check(document)
    try:
        rows = environments.build_rows(document)
    except environments.ConfigError as error:
        return _output(errors=error.messages)
    return _output(decided=[
        (row, {"environment": row["environment"], "verdict": "run", "reasons": ["port"]}) for row in rows
    ])
