"""The invariants of docs/Decision-engine.md §7 that apply to what the engine decides so far.

`check` is called on every table, port, generated and random case. A violation fails the case
even when its expected output matches.
"""

import re

from dsb_tf_engine import values

VERDICTS = ("run", "skip")
GRANTED_VOCABULARY = {"init", "format", "validate", "lint", "plan", "apply", "destroy-plan", "destroy"}
# Reasons of the rules before relevance (docs/Decision-engine.md §6, rules 2 and 3).
# Rules 2, 3 and 3a: an environment they drop is skipped for their reason, whatever relevance says.
EARLIER_RULES = ("trigger-events:", "dispatch:", "admission:")


def _contains(goals, goal):
    """Whether a row's goals name `goal`. A row carries its goals as a list of known names; anything
    else holds nothing. Written apart from the engine's, so the invariants do not inherit its mistakes."""
    return isinstance(goals, list) and goal in goals


def _gate_allows(document, goals, goal):
    """Whether the workflow's own gate for `goal` passes for these raw goals on this event (I1)."""
    event, default = document["event"], document["caller"]["default_branch"]
    on_default = event["ref_type"] == "branch" and event["ref_name"] == default
    on_pr = (event["name"] == "pull_request" and event.get("action", "") not in ("closed", "converted_to_draft")
             and event.get("base_ref", "") == default)
    if goal == "apply":
        return ((_contains(goals, "all") or _contains(goals, "apply"))
                and event["name"] in ("push", "workflow_dispatch", "schedule") and on_default
                or _contains(goals, "apply-on-pr") and on_pr)
    if goal == "destroy":
        return (_contains(goals, "destroy") and event["name"] in ("push", "workflow_dispatch") and on_default
                or _contains(goals, "destroy-on-pr") and on_pr)
    if goal == "destroy-plan":
        return _contains(goals, "destroy-plan")
    return _contains(goals, "all") or _contains(goals, goal)


def declared_environments(document):
    result = document["yaml"]["inputs"].get("environments-yml")
    return result["value"] if result and result["ok"] and isinstance(result["value"], list) else None


def _refused(output):
    admission = output.get("admission", {"applies": False})
    return admission["applies"] and not admission["push_run"] and not admission["admitted"]


def _admission_invariants(document, output):
    """I26-I29 (docs/Dependabot-admission.md §9)."""
    from dsb_tf_engine import decide
    violations = []
    admission = output.get("admission")
    if admission is None or output["errors"]:
        return violations
    event = document["event"]
    switch = document["workflow_inputs"].get("dependabot-admission-enabled", output.get("mode") != "module")
    if admission["applies"] and not (event.get("actor") == "dependabot[bot]" and switch in (True, "true")
                                     and event["name"] in ("pull_request", "push")):
        violations.append("I26: the admission applies to a run that does not meet it")
    held_back = admission["applies"] and (admission["push_run"] or not admission["admitted"])
    if held_back and (any(entry["verdict"] == "run" for entry in output.get("environments", []))
                      or output["tests"]["matrix"]["include"]):
        violations.append("I27: a refused or Dependabot push run runs an environment or a test")
    if not admission["applies"] and "admission" in document:
        without = {key: value for key, value in document.items() if key != "admission"}
        if decide.decide(without) != output:
            violations.append("I28: the admission's facts change a run it does not apply to")
    if admission["applies"] and admission["admitted"] and not admission["push_run"] and output.get("mode") != "module":
        off = {**document, "workflow_inputs": {**document["workflow_inputs"], "dependabot-admission-enabled": False}}
        other = decide.decide(off)
        if [(e["environment"], e["verdict"]) for e in other["environments"]] != \
                [(e["environment"], e["verdict"]) for e in output["environments"]] or other["matrices"] != output["matrices"]:
            violations.append("I29: an admitted run is decided otherwise than with the admission off")
    return violations


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

    # I8: the union of the stage matrices is exactly the run set, each stage in declaration order,
    # and no environment is in more than one matrix.
    run_names = [entry["environment"] for entry in environments if entry["verdict"] == "run"]
    matrix_names = [row["environment"] for stage in sorted(matrices) for row in matrices[stage]["include"]]
    if sorted(matrix_names) != sorted(run_names) or len(set(matrix_names)) != len(matrix_names):
        violations.append("I8: matrix rows are not the run environments, each once")
    for stage, matrix in matrices.items():
        names = [row["environment"] for row in matrix["include"]]
        if names != [name for name in run_names if name in names]:
            violations.append(f"I8: stage {stage}'s rows are not in declaration order")
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

    # I6 and I13: mode all runs every environment the earlier rules left, and says why in every one.
    relevance = output.get("relevance")
    if relevance is not None and relevance["mode"] == "all":
        reason = f"relevance: all:{relevance['reason']}"
        if any((entry["verdict"] != "run" or reason not in entry["reasons"])
               and not entry["reasons"][0].startswith(EARLIER_RULES) for entry in environments):
            violations.append("I6: mode all but an environment does not run for it")
    if any(entry["verdict"] == "run" and entry["reasons"][0].startswith(EARLIER_RULES) for entry in environments):
        violations.append("rules 2-3: an environment dropped by an earlier rule runs")
    # Relevance is published for every environment: a run one is relevant, a relevance skip is not.
    for entry in environments:
        if entry["verdict"] == "run" and entry.get("relevant") is not True:
            violations.append(f"relevant: '{entry['environment']}' runs but is not marked relevant")
        if entry["verdict"] == "skip" and entry["reasons"][:1] == ["relevance: no changed file matches"] \
                and entry.get("relevant") is not False:
            violations.append(f"relevant: '{entry['environment']}' is skipped by relevance but marked relevant")
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
            if head["state"] == "not-affected" and (entry is None or entry["verdict"] != "skip"
                                                    or not entry["reasons"][0].startswith("relevance:")):
                violations.append(f"I14: a 'not affected' head for '{head['key']}', which is not skipped by relevance")
            if head["state"] == "not-taking-part" and (entry is None or entry["verdict"] != "skip"
                                                       or not entry["reasons"][0].startswith("trigger-events:")):
                violations.append(f"I14: a 'not taking part' head for '{head['key']}', which takes part")
            if head["state"] == "not-admitted" and (entry is None or entry["reasons"] != ["admission: not admitted"]):
                violations.append(f"I14: a 'not admitted' head for '{head['key']}', which was not refused")
            if head["kind"] == "admission" and not _refused(output):
                violations.append("I14: an admission head on a run that was not refused")
        for name in manifest["purge_tags_for"]:
            entry = by_key.get(name)
            if entry is None or entry["verdict"] != "skip" or entry["add-pr-comment"] != "true":
                violations.append(f"I14: a tag purge for '{name}', which is not an unaffected commenting environment")
        admission_purges = [rule for rule in manifest["gc"] if rule["marker-prefix"].startswith("<!-- tf:head:admission:")]
        if len(manifest["gc"]) - len(admission_purges) != 4 * len(manifest["purge_tags_for"]):
            violations.append("I14: not four purge rules per purged environment")
        if admission_purges and (_refused(output) or len(admission_purges) != 1
                                 or event.get("pull_request", {}).get("author") != "dependabot[bot]"):
            violations.append("I14: an admission head purged where none can be stale")

    violations += _admission_invariants(document, output)
    violations += _goal_invariants(document, output)
    violations += _ordering_invariants(document, output)

    tests = output.get("tests")
    if tests is not None:
        rows = tests["matrix"]["include"]
        if tests["count"] != len(rows) or tests["active"] != bool(rows) or len(rows) > 256:
            violations.append("tests: the count, the active flag and the rows disagree")
        if len({row["slug"] for row in rows}) != len(rows):
            violations.append("tests: a slug appears twice")
        event = document["event"]
        # I4: where secrets are unavailable, no row asks for them: a fork, or Dependabot with the admission not
        # applying (an admitted Dependabot run runs credentialed lanes, docs/Dependabot-admission.md D20).
        applying = output.get("admission", {"applies": False})["applies"]
        if event.get("pull_request", {}).get("is_fork", False) or (event.get("actor") == "dependabot[bot]"
                                                                    and not applying):
            if any(row["test"]["github-environment"] or row["test"]["extra-envs-from-secrets"] for row in rows):
                violations.append("I4: a credentialed test row where secrets are unavailable")
        # I9: a test row's environment is a tftest- name and no Terraform environment's.
        taken = {entry["github-environment"].casefold() for entry in environments}
        for row in rows:
            name = row["test"]["github-environment"]
            if name and (re.fullmatch(r"tftest-[a-z0-9-]{1,40}", name) is None or name.casefold() in taken):
                violations.append(f"I9: the test row '{row['slug']}' runs in '{name}'")
    return violations


# What each schedule-goal leaves of a scheduled environment's goals, written apart from the engine's caps;
# default leaves everything.
SCHEDULE_CAPS = {"plan": {"init", "format", "validate", "lint", "plan"},
                 "apply": {"init", "format", "validate", "lint", "plan", "apply"},
                 "destroy-plan": {"init", "destroy-plan"}}


def _schedule_goal(document, name):
    """The environment's schedule-goal as declared, plan where it sets none."""
    for entry in declared_environments(document) or []:
        if entry.get("environment") == name:
            return entry.get("schedule-goal", "plan")
    return "plan"


def _goal_invariants(document, output):
    """I1, I2, I3, I15, I16, I17 and I25: what the granted goals, a dispatch and a schedule may be."""
    violations = []
    if output["errors"]:
        return violations
    event = document["event"]
    rows = {row["environment"]: row["vars"] for stage in output["matrices"].values() for row in stage["include"]}
    running = [entry for entry in output["environments"] if entry["verdict"] == "run"]
    for entry in running:
        name, granted = entry["environment"], entry.get("goals")
        row = rows.get(name, {})
        # I16: the entry and the row the gates read say the same.
        if granted is None or row.get("goals-granted") != granted:
            violations.append(f"I16: '{name}' has goals {granted} but goals-granted {row.get('goals-granted')}")
            continue
        raw = row.get("goals")
        # I1: only the eight goals, and each one the workflow's own gate would let through.
        if not set(granted) <= GRANTED_VOCABULARY:
            violations.append(f"I1: '{name}' is granted a goal outside the vocabulary: {granted}")
        for goal in granted:
            if not _gate_allows(document, raw, goal):
                violations.append(f"I1: '{name}' is granted '{goal}', which its goals and this event do not allow")
        # I15: never destroy on a schedule.
        if event["name"] == "schedule" and "destroy" in granted:
            violations.append(f"I15: '{name}' is granted destroy on a schedule")
        # I25: on a schedule, exactly what the gates let through on the default branch, less destroy, within the
        # environment's schedule-goal; a cap only removes.
        if event["name"] == "schedule":
            allowed = {goal for goal in GRANTED_VOCABULARY if goal != "destroy" and _gate_allows(document, raw, goal)}
            cap = SCHEDULE_CAPS.get(_schedule_goal(document, name))
            expected = allowed if cap is None else allowed & cap
            if set(granted) != expected:
                violations.append(f"I25: '{name}' is granted {sorted(granted)} on a schedule, expected {sorted(expected)}")
        # I3: a dispatch only removes from what a push to the same ref would grant.
        if event["name"] == "workflow_dispatch":
            as_push = {**document, "event": {**event, "name": "push"}}
            if any(not _gate_allows(as_push, raw, goal) for goal in granted):
                violations.append(f"I3: the dispatch grants '{name}' more than a push to the same ref would")
    named = event.get("dispatch", {}).get("environment", "") if event["name"] == "workflow_dispatch" else ""
    # I2 and I17: a dispatch naming one environment runs exactly that one.
    if named and [entry["environment"] for entry in running] != [named]:
        violations.append(f"I2: the dispatch named '{named}' but {[e['environment'] for e in running]} run")
    return violations


def _declared_graph(document):
    """Each declared environment's depends-on, a single name read as one; written apart from the engine's."""
    graph = {}
    for entry in declared_environments(document) or []:
        value = entry.get("depends-on")
        graph[entry["environment"]] = [] if value is None else [value] if isinstance(value, str) else list(value)
    return graph


def _expected_stages(graph, running):
    """The stages of the running environments by relaxation: start everyone at 1 and raise a dependent
    above each running dependency until nothing moves (I24's pure function), then free-standing
    environments to the last stage in use."""
    stages = {name: 1 for name in running}
    for _ in range(len(running)):
        for name in running:
            for dependency in graph.get(name, []):
                if dependency in stages and stages[name] <= stages[dependency]:
                    stages[name] = stages[dependency] + 1
    last = max(stages.values(), default=1)
    depended_on = {dependency for dependencies in graph.values() for dependency in dependencies}
    for name in running:
        if not graph.get(name) and name not in depended_on:
            stages[name] = last
    return stages


def _longest(graph):
    """The number of environments on the longest declared chain, by relaxation."""
    depth = {name: 1 for name in graph}
    for _ in range(len(graph)):
        for name, dependencies in graph.items():
            for dependency in dependencies:
                if dependency in depth:
                    depth[name] = max(depth[name], depth[dependency] + 1)
    return max(depth.values(), default=0)


def _ordering_invariants(document, output):
    """I18 to I24: the stages and what they record."""
    violations = []
    if output["errors"]:
        return violations
    graph = _declared_graph(document)
    environments = output["environments"]
    running = [entry for entry in environments if entry["verdict"] == "run"]
    names = [entry["environment"] for entry in running]
    event = document["event"]
    named = event["name"] == "workflow_dispatch" and event.get("dispatch", {}).get("environment", "") != ""
    mutating = any(goal in ("apply", "destroy") for entry in running for goal in entry.get("goals", []))
    # I20 and I23: the declared graph is acyclic, names nothing unknown or itself, and fits the cap.
    for name, dependencies in graph.items():
        if name in dependencies or any(dependency not in graph for dependency in dependencies):
            violations.append(f"I20: '{name}' depends on itself or on an undeclared environment, yet no error")
    if _longest(graph) > 3 or _longest(graph) > len(graph):
        violations.append("I20/I23: the declared graph is cyclic or deeper than the cap, yet no error")
    # I18: every running environment has one stage and appears in that stage's matrix only.
    stages = {entry["environment"]: entry.get("stage") for entry in running}
    by_stage = output["counts"].get("by_stage")
    if any(stage not in (1, 2, 3) for stage in stages.values()) or not isinstance(by_stage, dict):
        return violations + [f"I18: a running environment without a stage of 1 to 3, or no counts by stage: {stages}"]
    for entry in environments:
        if entry["verdict"] == "skip" and "stage" in entry:
            violations.append(f"I18: '{entry['environment']}' is skipped but carries a stage")
        if entry.get("depends-on") != graph.get(entry["environment"], []):
            violations.append(f"I18: '{entry['environment']}' does not carry its declared depends-on")
    for stage in ("1", "2", "3"):
        expected = [name for name in names if stages[name] == int(stage)]
        if [row["environment"] for row in output["matrices"][stage]["include"]] != expected:
            violations.append(f"I18: stage {stage}'s matrix is not its environments in declaration order")
        if by_stage.get(stage) != len(expected):
            violations.append(f"I18: stage {stage}'s count is not its environments")
    used = max(stages.values(), default=1)
    if output["ordering"]["stages_used"] != used or output["ordering"]["cap"] != 3:
        violations.append(f"I18: stages_used {output['ordering']['stages_used']} but the highest stage is {used}")
    if output["ordering"]["declared"] != any(graph.values()):
        violations.append("ordering: 'declared' does not say whether any environment declares depends-on")
    # I21 and I22: one stage unless something mutates, and one stage for a dispatch naming one environment.
    if (named or not mutating) and used != 1:
        violations.append(f"I21/I22: {used} stages although nothing mutates or one environment is dispatched")
    if output["ordering"]["bypass"] != ("single-environment-dispatch" if named else None):
        violations.append(f"I22: bypass {output['ordering']['bypass']} for this event")
    for entry in running:
        bypassed = "ordering: single-environment dispatch, stage 1" in entry["reasons"]
        if bypassed != (named and bool(graph.get(entry["environment"]))):
            violations.append(f"I22: '{entry['environment']}' records the bypass wrongly")
    if named or not mutating:
        return violations
    # I24: the stages are the pure function of the graph restricted to the run and the last-stage rule.
    if _expected_stages(graph, names) != stages:
        violations.append(f"I24: stages {stages}, expected {_expected_stages(graph, names)}")
    # I19: a dependency in the run is in a strictly lower stage; one outside it is recorded.
    for entry in running:
        for dependency in graph.get(entry["environment"], []):
            if dependency in stages:
                if not stages[dependency] < stages[entry["environment"]]:
                    violations.append(f"I19: '{entry['environment']}' is not after its dependency '{dependency}'")
            elif not any(reason.startswith(f"ordering: depends-on '{dependency}' not in this run (")
                         for reason in entry["reasons"]):
                violations.append(f"I19: '{entry['environment']}' does not record that '{dependency}' is not in the run")
    return violations
