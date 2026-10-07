"""What a run tells Teams (docs/Notifications.md §4, §5, §9, §11): from the environments' results, the
incident state and the people of the push, the messages to post, rendered, the observations the record
job keeps, and one deliver row per message.

Pure: the adapter (notify_evidence.py) gathers every fact, asks `wanted` which of the costly ones the
run needs, and writes every file. Facts the adapter could not gather are None, never an error.
"""

import hashlib

from . import environments

SLOT = "apply"
# The steps before the apply, in the order the job runs them; the first that failed is the reason.
STEPS_BEFORE_APPLY = ("init", "verify-lock", "fmt", "validate", "lint", "plan")
OPENING = {"failed": "apply-failed", "cancelled": "apply-cancelled", "held-back": "held-back"}
RESOLVING = ("applied", "clean")
# A dispatch may resolve, never open (D8): whoever dispatched it is looking at the run.
OPENING_EVENTS = ("push", "schedule")
TITLE_LIMIT = 100
PULL_REQUEST_LIMIT = 10
HEADERS = {
    "apply-failed": ("❌", "Apply failed"),
    "apply-cancelled": ("🚫", "Apply cancelled"),
    "held-back": ("⏸️", "Held back"),
}
WHAT = {"apply-failed": "apply failed", "apply-cancelled": "apply cancelled", "held-back": "held back"}


def path(value, *keys):
    """The value under `keys`, or None where one is absent or a value on the way is not a mapping."""
    for each in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(each)
    return value


def _outcome(content, step):
    return path(content, "steps", step, "outcome")


def _clean_plan(content):
    """A plan that succeeded, was read, and changes nothing, outputs included: an unread count is '?'."""
    return (_outcome(content, "plan") == "success"
            and path(content, "steps", "parse-plan", "outputs", "count-total") == "0"
            and path(content, "steps", "parse-plan", "outputs", "has-output-only-changes") == "false")


def _held_back(stage, stage_results):
    """The earlier stage that failed or was cancelled, or None."""
    for earlier in range(1, stage):
        if stage_results.get(str(earlier)) in ("failure", "cancelled"):
            return earlier
    return None


def classify(row, entry, content, stage_results, event):
    """The environment's result in the apply slot and what says so (§4)."""
    due = "apply" in row["goals-granted"]
    stage = entry["stage"]
    if content is None:
        result = stage_results.get(str(stage), "")
        cause = _held_back(stage, stage_results) if result == "skipped" else None
        if due and cause is not None:
            return "held-back", {"stage": stage, "cause": cause, "cause_result": stage_results[str(cause)]}
        if due and result in ("failure", "cancelled"):
            return ("failed" if result == "failure" else "cancelled"), {"step": None}
        return ("unknown" if due else "none"), {}
    if not due:
        return ("clean" if event in ("schedule", "workflow_dispatch") and _clean_plan(content) else "none"), {}
    apply = _outcome(content, "apply")
    if apply == "success":
        return "applied", {}
    if apply in ("failure", "cancelled"):
        return ("failed" if apply == "failure" else "cancelled"), {"step": "apply"}
    for step in STEPS_BEFORE_APPLY:
        if _outcome(content, step) in ("failure", "cancelled"):
            return ("failed" if _outcome(content, step) == "failure" else "cancelled"), {"step": step}
    return "failed", {"step": "not-run"}


def _route(row, kind):
    """The routing of a kind for an environment: its own kinds over its defaults (§6.2)."""
    settings = row.get("notifications") if isinstance(row.get("notifications"), dict) else {}
    defaults = settings.get("defaults") if isinstance(settings.get("defaults"), dict) else {}
    kinds = settings.get("kinds") if isinstance(settings.get("kinds"), dict) else {}
    own = kinds.get(kind) if isinstance(kinds.get(kind), dict) else {}
    return {**defaults, **own}, settings.get("deliver-as")


def _key(facts, environment, action):
    """The relay's Idempotency-Key: one per message of a run attempt, so re-running only the deliver job does
    not post twice. Hashed: the relay's store refuses '/' in a key, and a name may make it too long."""
    run = facts["run"]
    text = "/".join((facts["repository"], str(run["id"]), str(run["attempt"]), environment, SLOT, action))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _incident(facts, environment):
    state = facts["state"]
    return state["incidents"].get(f"{environment.lower()}/{SLOT}") if state else None


def _bot(login):
    return not isinstance(login, str) or not login or login.endswith("[bot]")


def named(people):
    """The people of a push (§5): each author, then each merger who is not an author; bots and Apps never."""
    if people is None or not people["available"]:
        return []
    names = [pr["author"] for pr in people["pull_requests"] if not _bot(pr["author"])]
    names += [pr["merged_by"] for pr in people["pull_requests"] if not _bot(pr["merged_by"])]
    if not people["pull_requests"] and not _bot(people["pusher"]):
        names.append(people["pusher"])
    return list(dict.fromkeys(names))


def _plan(facts):
    """Every environment's observation, and the actions, before anything is rendered."""
    observations = []
    for entry in facts["environments"]:
        if entry["verdict"] != "run":
            continue
        name = entry["environment"]
        row = facts["rows"][name]
        result, detail = classify(row, entry, facts["metadata"].get(name), facts["stage_results"], facts["event"])
        kind = OPENING.get(result)
        route, deliver_as = _route(row, kind)
        incident = _incident(facts, name)
        status = incident["status"] if incident else "none"
        action = "none"
        if kind and facts["event"] in OPENING_EVENTS and status in ("none", "resolved", "pending"):
            action = "none" if route.get("off") in (True, "true") else "open"
        elif kind and facts["event"] == "push" and status == "open":
            action = "reply"
        elif result in RESOLVING and status in ("open", "pending"):
            action = "resolve"
        # The incident's later messages go where its first went, as its sender (§9).
        later = action in ("reply", "resolve")
        observations.append({"environment": name, "result": result, "detail": detail, "kind": kind, "action": action,
                             "incident": incident,
                             "alias": incident["alias"] if later else route.get("alias", facts["target"]["alias"]),
                             "sender": incident["sender"] if later else deliver_as or name})
    seen = {observation["environment"].lower() for observation in observations}
    names = {name.lower() for name in facts["senders"]}
    incidents = facts["state"]["incidents"] if facts["state"] else {}
    for state_key, incident in sorted(incidents.items()):
        environment = state_key.rpartition("/")[0]
        if environment in seen or environment in names or incident["status"] not in ("open", "pending"):
            continue
        observations.append({"environment": environment, "result": "removed", "kind": None, "action": "resolve",
                             "incident": incident, "alias": incident["alias"], "sender": incident["sender"]})
    return observations


def _messaged(observation):
    """Whether the observation's action is a message: a pending incident never reached Teams, so it resolves
    quietly."""
    if observation["action"] in ("open", "reply"):
        return True
    return observation["action"] == "resolve" and observation["incident"]["status"] == "open"


def wanted(facts):
    """Which costly facts the run needs: the people of the push when it opens or repeats an incident, and the
    protection rules of the senders it posts as."""
    observations = [o for o in _plan(facts) if _messaged(o) and o["sender"] in facts["senders"]]
    return {"people": facts["event"] == "push" and any(o["action"] in ("open", "reply") for o in observations),
            "protection": sorted({facts["senders"][o["sender"]]["github-environment"] for o in observations})}


def _title(text):
    """A pull request's title as a code span's content: nothing in it can end the span or start markup."""
    text = text.replace("`", "'").replace("<", "‹").replace(">", "›")
    text = " ".join(text.split())
    return text if len(text) <= TITLE_LIMIT else text[:TITLE_LIMIT - 1] + "…"


def _people_line(facts):
    if facts["event"] == "schedule":
        return "Found by the scheduled run."
    people = facts.get("people")
    if people is None or not people["available"]:
        return "Who made the change could not be read."
    pull_requests = people["pull_requests"]
    if not pull_requests:
        return f"Pushed by {people['pusher']}." if not _bot(people["pusher"]) else "Pushed by an app."
    parts = []
    for pr in pull_requests[:PULL_REQUEST_LIMIT]:
        part = f"[#{pr['number']}]({facts['server_url']}/{facts['repository']}/pull/{pr['number']})"
        title = _title(pr["title"] or "")
        part += f" `{title}`" if title else ""
        part += f" by {pr['author']}" if not _bot(pr["author"]) else ""
        part += f", merged by {pr['merged_by']}" if not _bot(pr["merged_by"]) and pr["merged_by"] != pr["author"] else ""
        parts.append(part)
    if len(pull_requests) > PULL_REQUEST_LIMIT:
        parts.append(f"and {len(pull_requests) - PULL_REQUEST_LIMIT} more")
    return f"{'Change' if len(pull_requests) == 1 else 'Changes'}: {'; '.join(parts)}."


def _when(stamp):
    """2026-10-05T08:30:00Z, as the record job writes it, as 2026-10-05 08:30 UTC."""
    return f"{stamp[:10]} {stamp[11:16]} UTC"


def _reason(observation):
    name, detail = observation["environment"], observation["detail"]
    not_applied = f"so the default branch is not applied in `{name}`."
    if observation["result"] == "held-back":
        verb = "failed" if detail["cause_result"] == "failure" else "was cancelled"
        return f"Stage {detail['stage']} did not run because stage {detail['cause']} {verb}, {not_applied}"
    step = detail["step"]
    if step is None:
        verb = "failed without reporting its steps" if observation["result"] == "failed" else \
            "was cancelled before it reported its steps"
        return f"The job {verb}, so the default branch may not be applied in `{name}`."
    if step == "not-run":
        return f"`apply` did not run, and no step says why, {not_applied}"
    if step == "apply" and observation["result"] == "failed":
        return f"The `apply` step failed, {not_applied}"
    if step == "apply":
        return f"The `apply` step was cancelled, so `{name}` may be partly applied."
    if observation["result"] == "failed":
        return f"The `{step}` step failed, so `apply` did not run and the default branch is not applied in `{name}`."
    return f"The job was cancelled at the `{step}` step, so `apply` did not run and the default branch is not " \
           f"applied in `{name}`."


def render(facts, observation):
    """The message, markdown text (D23): a first line that says what and where, why, who, and the run."""
    name, repository = observation["environment"], facts["repository"]
    run = facts["run"]
    link = f"[Open the run]({facts['server_url']}/{repository}/actions/runs/{run['id']}/attempts/{run['attempt']})"
    action = observation["action"]
    if action == "resolve":
        since = _when(observation["incident"]["opened_at"])
        if observation["result"] == "removed":
            lines = [f"✅ **No longer watched** `{name}` · `{repository}`",
                     f"`{name}` is no longer in environments-yml: the incident opened at {since} is closed."]
        elif observation["result"] == "clean":
            lines = [f"✅ **Applied** `{name}` · `{repository}`",
                     f"A plan of `{name}` has no changes: the incident opened at {since} is resolved."]
        else:
            lines = [f"✅ **Applied** `{name}` · `{repository}`",
                     f"`{name}` is applied again: the incident opened at {since} is resolved."]
        return "\n\n".join(lines + [link]) + "\n"
    icon, title = HEADERS[observation["kind"]]
    reason = _reason(observation)
    if action == "reply":
        title += " again"
        reason += f" It has not been applied since {_when(observation['incident']['opened_at'])}."
    return "\n\n".join([f"{icon} **{title}** in `{name}` · `{repository}`", reason, _people_line(facts), link]) + "\n"


def _identity_complete(sender):
    present = set(sender["extra-envs"]) | set(sender["extra-envs-from-secrets"])
    return {"ARM_TENANT_ID", "ARM_CLIENT_ID"} <= present


def _not_sent(facts, observation):
    """Why a message cannot be sent, or None (D16, §12)."""
    sender = facts["senders"][observation["sender"]]
    protection = (facts.get("protection") or {}).get(sender["github-environment"])
    if protection is None:
        return f"whether its sender `{observation['sender']}` has protection rules could not be read"
    if protection:
        return (f"its sender `{observation['sender']}` has protection rules; set deliver-as to an environment "
                "without them")
    if not _identity_complete(sender):
        return f"its sender `{observation['sender']}` has no ARM_TENANT_ID and ARM_CLIENT_ID"
    return None


def decide(facts):
    """{events, messages, deliver, observations, summary} for the run (§7)."""
    events, messages, deliver, observed, table, notes = [], {}, [], [], [], []
    for observation in _plan(facts):
        event_id, sending = None, False
        name, action = observation["environment"], observation["action"]
        what = "resolved" if action == "resolve" else WHAT.get(observation["kind"])
        if _messaged(observation) and observation["sender"] not in facts["senders"]:
            notes.append(f"`{name}`: removed from environments-yml, and its sender `{observation['sender']}` with it; "
                         "closed without a message")
        elif _messaged(observation):
            event_id = f"e{len(events) + 1}"
            incident = observation["incident"]
            event_action = "removed" if observation["result"] == "removed" else action
            reply_to = incident["message_id"] if action != "open" else None
            event = {"id": event_id, "environment": name, "slot": SLOT, "kind": observation["kind"],
                     "action": event_action, "alias": observation["alias"], "reply_to": reply_to, "update": None,
                     "sender": observation["sender"], "idempotency_key": _key(facts, name, event_action),
                     "message": f"{event_id}.md"}
            events.append(event)
            messages[event["message"]] = render(facts, observation)
            why_not = _not_sent(facts, observation)
            if why_not:
                table.append(f"| `{name}` | {what} | not sent: {why_not} |")
            else:
                sender = facts["senders"][observation["sender"]]
                deliver.append({"id": event_id, "sender": observation["sender"],
                                "github-environment": sender["github-environment"], "runs-on": facts["runs_on"],
                                "alias": observation["alias"], "reply-to": reply_to or "", "update": "",
                                "idempotency-key": event["idempotency_key"], "extra-envs": sender["extra-envs"],
                                "extra-envs-from-secrets": sender["extra-envs-from-secrets"]})
                table.append(f"| `{name}` | {what} | to `{observation['alias']}` as `{observation['sender']}` |")
                sending = True
        people = named(facts["people"]) if action in ("open", "reply") and facts["event"] == "push" else []
        observed.append({"environment": name, "slot": SLOT, "result": observation["result"], "kind": observation["kind"],
                         "action": action, "event": event_id, "people": people, "alias": observation["alias"],
                         "sender": observation["sender"], "sending": sending})
    parts = []
    if table:
        parts.append("\n".join(["| Environment | What | Sent |", "|---|---|---|", *table]))
    if notes:
        parts.append("\n".join(f"- {note}" for note in notes))
    summary = "### 📣 Teams notifications\n\n" + ("\n\n".join(parts) if parts else "Nothing to tell Teams.") + "\n"
    return {"events": events, "messages": messages, "deliver": deliver, "observations": observed, "summary": summary}
