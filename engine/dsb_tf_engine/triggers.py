"""Trigger events, the dispatch filter and the granted goals: rules 2, 3 and 5 of docs/Decision-engine.md §6.

docs/Dispatch-and-triggers.md §4. An environment takes part in a run when the event is in its
trigger-events and, on a dispatch naming one environment, it is that one. It is granted the goals
the workflow's operation gates would let through for the goals it names, a list of known names by
now (environments.py); a dispatch's goal input, or on a schedule the environment's schedule-goal,
then caps them, and a cap only ever removes.
"""

from .environments import ConfigError, on_default_branch, shown

EVENTS = ("pull_request", "push", "workflow_dispatch", "schedule")
DEFAULT_EVENTS = ("pull_request", "push", "workflow_dispatch")
# Unattended runs are a decision about one environment, never the global list's (D7).
PER_ENVIRONMENT_ONLY = ("schedule",)
FIELD = "trigger-events"
INPUT = "trigger-events-yml"
DISPATCH = "workflow_dispatch"
SCHEDULE = "schedule"
# The goal a scheduled run is capped to, per environment, in the dispatch goal input's vocabulary; a
# run nobody watches plans unless the environment says otherwise (D12).
SCHEDULE_GOAL = "schedule-goal"
SCHEDULE_GOAL_DEFAULT = "plan"

# The granted vocabulary, in the workflow's order; 'all' grants the standard goals and apply.
STANDARD = ("init", "format", "validate", "lint", "plan")
APPLY_EVENTS = ("push", "workflow_dispatch", "schedule")
# The workflow's destroy gate has never accepted schedule.
DESTROY_EVENTS = ("push", "workflow_dispatch")
# Pull request actions the workflow's on-PR clauses exclude.
CLOSING_ACTIONS = ("closed", "converted_to_draft")
GOAL_INPUTS = ("default", "plan", "apply", "destroy-plan")
# Every goal input but default is a cap: someone who asked for an apply never gets a destroy with it.
CAPS = {"plan": STANDARD, "apply": STANDARD + ("apply",), "destroy-plan": ("init", "destroy-plan")}
# The absent block: nothing to filter or cap; its reason is never read.
NO_INPUTS = {"block": False, "environment": "", "goal": ""}
DOCS = "docs/Dispatch-and-triggers.md"


def dispatch_inputs(document):
    """The dispatch inputs, the absent block included; a document from before dispatch has none."""
    return document["event"].get("dispatch", NO_INPUTS)


def _check(value, where, subject, allowed, errors):
    """Every problem of one list of events; `where` prefixes a message, `subject` names the list."""
    if not isinstance(value, list) or not value:
        errors.append(f"{where}: {subject} must be a non-empty list of events, not {shown(value)}")
        return
    for event in value:
        if event in allowed:
            continue
        if event in PER_ENVIRONMENT_ONLY:
            errors.append(f"{where}: {shown(event)} is per environment only; add it to the {FIELD} of the environment "
                          "the schedule is for")
        else:
            errors.append(f"{where}: unknown trigger event {shown(event)}")


def resolve(document, declared):
    """Every environment's trigger events, validated whatever the event, or a ConfigError."""
    errors = []
    value = document["yaml"]["inputs"].get(INPUT, {"value": None})["value"]
    if value is not None:
        _check(value, INPUT, "the list", tuple(event for event in EVENTS if event not in PER_ENVIRONMENT_ONLY), errors)
    for entry in declared:
        if FIELD in entry:
            _check(entry[FIELD], f"environments-yml: environment '{entry['environment']}'", f"'{FIELD}'", EVENTS,
                   errors)
    if errors:
        raise ConfigError(errors)
    default = list(DEFAULT_EVENTS) if value is None else value
    return [entry[FIELD] if FIELD in entry else default for entry in declared]


def _schedule_goal_problem(entry, goals):
    """What is wrong with an environment's schedule-goal, or None: a value outside the goal input's
    vocabulary, or a cap that would add a goal the environment does not hold (D5)."""
    if SCHEDULE_GOAL not in entry:
        return None
    goal, where = entry[SCHEDULE_GOAL], f"environments-yml: environment '{entry['environment']}'"
    if goal not in GOAL_INPUTS:
        return f"{where}: '{SCHEDULE_GOAL}' is one of {', '.join(GOAL_INPUTS)}, not {shown(goal)}"
    if goal == "apply" and not ("all" in goals or "apply" in goals):
        return f"{where}: '{SCHEDULE_GOAL}: apply' needs the goal 'apply' or 'all' (goals: {', '.join(goals)})"
    if goal == "destroy-plan" and "destroy-plan" not in goals:
        return f"{where}: '{SCHEDULE_GOAL}: destroy-plan' needs the goal 'destroy-plan' (goals: {', '.join(goals)})"
    return None


def schedule_goals(document, declared):
    """On a schedule, each environment's schedule-goal, plan where it sets none; on any other event None."""
    if document["event"]["name"] != SCHEDULE:
        return None
    return [entry.get(SCHEDULE_GOAL, SCHEDULE_GOAL_DEFAULT) for entry in declared]


def setting_warnings(declared, resolved):
    """The schedule-goals that are valid but change nothing: their environment takes no part in schedules."""
    return [f"The environment '{entry['environment']}' sets {SCHEDULE_GOAL}: {entry[SCHEDULE_GOAL]}, but its "
            f"{FIELD} do not hold {SCHEDULE}, so it has no effect."
            for entry, events in zip(declared, resolved) if SCHEDULE_GOAL in entry and SCHEDULE not in events]


def check_event(document):
    """A ConfigError unless the event is one of the four the workflows support."""
    event = document["event"]["name"]
    if event not in EVENTS:
        raise ConfigError([f"event {shown(event)} is not supported by this workflow; supported: {', '.join(EVENTS)}"])


def participation(document, declared, rows):
    """Per row, the reason rules 2 and 3 drop it or None, beside the resolved events; a ConfigError
    for the whole run when the event, the configuration or the dispatch cannot be honoured."""
    resolved = resolve(document, declared)
    # Checked on every event, so a mistaken schedule-goal surfaces on a pull request, not at night.
    problems = [problem for entry, row in zip(declared, rows) if (problem := _schedule_goal_problem(entry, row["goals"]))]
    if problems:
        raise ConfigError(problems)
    check_event(document)
    event = document["event"]["name"]
    dropped = [None if event in events else f"{FIELD}: {event} not enabled" for events in resolved]
    name = dispatch_inputs(document)["environment"] if event == DISPATCH else ""
    if name:
        names = [row["environment"] for row in rows]
        if name not in names:
            raise ConfigError([f"dispatch: no environment named {shown(name)}. Environments: {', '.join(names)}"])
        chosen = names.index(name)
        if dropped[chosen] is not None:
            raise ConfigError([f"dispatch: environment '{name}' does not take part in {DISPATCH} "
                               f"({FIELD}: {', '.join(map(str, resolved[chosen]))})"])
        # The first rule that drops an environment is the one recorded.
        dropped = [reason if reason is not None or index == chosen else "dispatch: not the requested environment"
                   for index, reason in enumerate(dropped)]
    return resolved, dropped


def on_pr_goals_granted(document):
    """Whether this event grants the on-PR goals: an open pull request against the default branch."""
    event = document["event"]
    return (event["name"] == "pull_request" and event.get("action", "") not in CLOSING_ACTIONS
            and event.get("base_ref", "") == document["caller"]["default_branch"])


def expand(document, goals):
    """The goals the workflow's gates grant for this event, ref and branch."""
    event = document["event"]
    on_default = on_default_branch(document)
    on_pr = on_pr_goals_granted(document)
    every = "all" in goals
    granted = [goal for goal in STANDARD if every or goal in goals]
    if ((every or "apply" in goals) and event["name"] in APPLY_EVENTS and on_default
            or "apply-on-pr" in goals and on_pr):
        granted.append("apply")
    if "destroy-plan" in goals:
        granted.append("destroy-plan")
    if ("destroy" in goals and event["name"] in DESTROY_EVENTS and on_default
            or "destroy-on-pr" in goals and on_pr):
        granted.append("destroy")
    return granted


def grant(document, declared, rows, entries):
    """The granted goals of every running environment, by row index, or a ConfigError."""
    event = document["event"]
    scheduled = schedule_goals(document, declared)
    goal = (dispatch_inputs(document)["goal"] or "default") if event["name"] == DISPATCH else "default"
    if goal not in GOAL_INPUTS:
        raise ConfigError([f"dispatch: unknown goal {shown(goal)}; the goal input is one of {', '.join(GOAL_INPUTS)}"])
    if goal == "apply" and not on_default_branch(document):
        where = "the tag " if event["ref_type"] == "tag" else ""
        raise ConfigError([f"dispatch: apply is only allowed from the default branch "
                           f"'{document['caller']['default_branch']}'; this run is on {where}'{event['ref_name']}'"])
    errors, granted = [], {}
    for index, (row, entry) in enumerate(zip(rows, entries)):
        if entry["verdict"] != "run":
            continue
        goals = row["goals"]
        expanded = expand(document, goals)
        if goal == "apply" and not ("all" in goals or "apply" in goals):
            errors.append(f"dispatch: environment '{row['environment']}' does not hold the goal 'apply' "
                          f"(goals: {', '.join(goals)})")
        if goal == "destroy-plan" and "destroy-plan" not in expanded:
            errors.append(f"dispatch: environment '{row['environment']}' does not hold the goal 'destroy-plan' "
                          f"(goals: {', '.join(goals)})")
        # A schedule-goal was checked against the goals already; a dispatch's goal is checked above.
        cap = goal if scheduled is None else scheduled[index]
        granted[index] = [each for each in expanded if cap not in CAPS or each in CAPS[cap]]
    if errors:
        raise ConfigError(errors)
    return granted


def lines(document, declared, entries):
    """What the run summary and a notice say about who dispatched what, or a schedule: what each running
    environment was capped to, or that none takes part."""
    event = document["event"]
    if event["name"] == DISPATCH:
        actor, again = event.get("actor", ""), event.get("triggering_actor", "")
        who = f"dispatched by {actor or 'an unknown actor'}" + (f" (re-run by {again})" if again and again != actor
                                                                 else "")
        inputs = dispatch_inputs(document)
        if not inputs["block"]:
            return [f"{who}: the calling workflow declares no dispatch inputs, so every environment runs with its "
                    f"goals; copy the standard block from {DOCS} §3.1 to choose one environment and a goal"]
        # The standard block always delivers its goal, a choice; without either, the block is another one.
        if not inputs["environment"] and not inputs["goal"]:
            delivered = (f"the inputs {', '.join(inputs['inputs'])} but neither 'environment' nor 'goal'"
                         if inputs["inputs"] else "no inputs")
            return [f"{who}: this dispatch delivered {delivered}, so every environment runs with its goals; the "
                    f"standard block is in {DOCS} §3.1"]
        # Free text reaches a workflow command and Markdown: one line, never a second command.
        reason = " ".join(inputs["reason"].split())
        return [f"{who}: environment {inputs['environment'] or '(all)'}, goal {inputs['goal'] or 'default'}, "
                + (f'reason "{reason}"' if reason else "no reason given")]
    if event["name"] == SCHEDULE and not any(entry["verdict"] == "run" for entry in entries):
        return [f"{SCHEDULE}: no environment takes part in scheduled runs; add '{SCHEDULE}' to the {FIELD} of the "
                "environment the schedule is for"]
    if event["name"] == SCHEDULE:
        scheduled = schedule_goals(document, declared)
        by_goal = {goal: [entry["environment"] for index, entry in enumerate(entries)
                          if entry["verdict"] == "run" and scheduled[index] == goal] for goal in GOAL_INPUTS}
        return [f"{SCHEDULE}: " + "; ".join(f"goal {goal} for {', '.join(names)}" for goal, names in by_goal.items()
                                            if names)
                + f" ({SCHEDULE_GOAL}, {SCHEDULE_GOAL_DEFAULT} where an environment sets none)"]
    return []
