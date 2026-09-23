"""The invariants of docs/Decision-engine.md §7 that apply to what the engine decides so far.

`check` is called on every table, port, generated and random case. A violation fails the case
even when its expected output matches.
"""

from dsb_tf_engine import values

VERDICTS = ("run", "skip")


def declared_environments(document):
    result = document["yaml"]["inputs"].get("environments-yml")
    return result["value"] if result and result["ok"] and isinstance(result["value"], list) else None


def check(document, output):
    """Return the list of violated invariants, empty when all hold."""
    violations = []
    environments = output["environments"]
    matrices = output["matrices"]

    # Fail closed: an output with errors carries no matrix to run.
    if output["errors"] and (environments or matrices):
        violations.append("errors present but environments or matrices are not empty")

    # I7: every declared environment is decided exactly once, and no name appears twice.
    if not output["errors"]:
        declared = declared_environments(document)
        names = [values.get_val(entry["environment"]) for entry in environments]
        if declared is None or len(environments) != len(declared):
            violations.append("I7: decided environments do not match the declared ones")
        if len(set(names)) != len(names):
            violations.append("I7: an environment name appears twice")
        if any(entry["verdict"] not in VERDICTS for entry in environments):
            violations.append("I7: a verdict outside run/skip")

    # I8: the union of the stage matrices is exactly the run set, in declaration order, and no
    # environment is in more than one matrix.
    run_names = [entry["environment"] for entry in environments if entry["verdict"] == "run"]
    matrix_names = [row["environment"] for stage in sorted(matrices) for row in matrices[stage]["include"]]
    if matrix_names != run_names:
        violations.append("I8: matrix rows are not the run environments in declaration order")
    for stage, matrix in matrices.items():
        if matrix["environment"] != [row["environment"] for row in matrix["include"]]:
            violations.append(f"I8: stage {stage}'s environment list does not match its rows")

    # I11: every skip has a reason.
    if any(entry["verdict"] == "skip" and not entry["reasons"] for entry in environments):
        violations.append("I11: a skip without a reason")

    # The record is derived from the reasons, one line per environment.
    if len(output["record"]) != len(environments):
        violations.append("record: not one line per environment")

    if output["counts"]["affected"] != len(run_names):
        violations.append("counts: affected does not equal the run set")
    return violations
