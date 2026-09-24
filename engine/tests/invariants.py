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
    if output["counts"]["affected"] + output["counts"]["unaffected"] != len(environments):
        violations.append("counts: affected and unaffected do not sum to the environments decided")

    # I6 and I13: mode all runs every environment, and says why in every one.
    relevance = output.get("relevance")
    if relevance is not None and relevance["mode"] == "all":
        reason = f"relevance: all:{relevance['reason']}"
        if any(entry["verdict"] != "run" or reason not in entry["reasons"] for entry in environments):
            violations.append("I6: mode all but an environment does not run for it")
    if relevance is not None and document["workflow_inputs"].get("path-relevance-enabled") is False \
            and relevance["reason"] != "disabled":
        violations.append("I13: relevance switched off but the reason is not 'disabled'")
    if output["errors"] and relevance is not None:
        violations.append("errors present but a relevance block is emitted")

    # I14: "not affected" heads and tag purges only where the seed runs, only for commenting
    # environments skipped by relevance, and no environment head for a grouped environment.
    manifest = output.get("comments")
    if manifest is not None:
        event = document["event"]
        seeded = (event["name"] == "pull_request" and "pull_request" in event and not event["pull_request"]["is_fork"]
                  and event.get("action", "") not in ("closed", "converted_to_draft") and "run" in document)
        by_key = {entry["github-environment"]: entry for entry in environments}
        if not seeded and (manifest["heads"] or manifest["purge_tags_for"] or manifest["gc"]):
            violations.append("I14: a manifest where the seed does not run")
        for head in manifest["heads"]:
            entry = by_key.get(head["key"]) if head["kind"] == "env" else None
            if head["kind"] == "env" and (entry is None or entry["pr-comment-group"] != ""
                                          or entry["add-pr-comment"] != "true"):
                violations.append(f"I14: an environment head for '{head['key']}', which gets none")
            if head["state"] == "not-affected" and (entry is None or entry["verdict"] != "skip"):
                violations.append(f"I14: a 'not affected' head for '{head['key']}', which is affected")
        for name in manifest["purge_tags_for"]:
            entry = by_key.get(name)
            if entry is None or entry["verdict"] != "skip" or entry["add-pr-comment"] != "true":
                violations.append(f"I14: a tag purge for '{name}', which is not an unaffected commenting environment")
        if len(manifest["gc"]) != 4 * len(manifest["purge_tags_for"]):
            violations.append("I14: not four purge rules per purged environment")
    return violations
