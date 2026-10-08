"""What a run tells Teams (docs/Notifications.md §4, §5, §9, §11): from the environments' results, the
incident state and the people of the push, the messages to post, rendered, the observations the record
job keeps, and one deliver row per message.

Pure: the adapter (notify_evidence.py) gathers every fact, asks `wanted` which of the costly ones the
run needs, and writes every file. Facts the adapter could not gather are None, never an error.
"""

import hashlib
import json

from . import environments

SLOT = "apply"
# The steps before the apply, in the order the job runs them; the first that failed is the reason.
STEPS_BEFORE_APPLY = ("init", "verify-lock", "fmt", "validate", "lint", "plan")
OPENING = {"failed": "apply-failed", "cancelled": "apply-cancelled", "held-back": "held-back",
           "pending": "pending-change"}
DRIFT_SLOT = "drift"
# A drift message lists this many addresses, then how many more (Drift-detection.md §5).
ADDRESS_LIMIT = 20
# Drift reminds once a week, in working days, and mentions nobody (Drift-detection.md §5).
DRIFT_REMINDER_DAYS = 5
RESOLVING = ("applied", "clean")
# A dispatch may resolve, never open (D8): whoever dispatched it is looking at the run.
OPENING_EVENTS = ("push", "schedule")
TITLE_LIMIT = 100
PULL_REQUEST_LIMIT = 10
HEADERS = {
    "apply-failed": ("❌", "Apply failed"),
    "apply-cancelled": ("🚫", "Apply cancelled"),
    "held-back": ("⏸️", "Held back"),
    "pending-change": ("⏳", "Not applied"),
}
WHAT = {"apply-failed": "apply failed", "apply-cancelled": "apply cancelled", "held-back": "held back",
        "pending-change": "not applied", "drift": "drift"}
REMINDED = {"apply-failed": "the apply failed", "apply-cancelled": "the apply was cancelled",
            "held-back": "its stage was held back", "pending-change": "the scheduled plan found changes"}
COUNTED = ("add", "change", "destroy", "import", "move", "remove")
# What a display name may hold to be written as it is: no character in it starts markup in a message.
NAME_PUNCTUATION = " .'-"


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


def _plan_outputs(content):
    outputs = path(content, "steps", "parse-plan", "outputs")
    return outputs if isinstance(outputs, dict) else {}


def _planned(content, event):
    """The apply slot of an environment the run does not apply, from its classified plan (Drift-detection.md
    §4): clean when the plan changes nothing of its own, drift alone included; pending, on a schedule, when it
    does. A plan without a class is clean only when it changes nothing at all."""
    if event not in ("schedule", "workflow_dispatch") or _outcome(content, "plan") != "success":
        return "none", {}
    outputs = _plan_outputs(content)
    plan_class, own = outputs.get("plan-class"), outputs.get("has-pending-changes")
    if plan_class == "clean" or (plan_class == "drift" and own == "false"):
        return "clean", {}
    if plan_class in ("pending", "drift"):
        # Pending on a dispatch too, which opens nothing (D8).
        return "pending", {"outputs": outputs}
    return ("clean" if not plan_class and _clean_plan(content) else "none"), {}


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
        return _planned(content, event)
    apply = _outcome(content, "apply")
    if apply == "success":
        return "applied", {}
    if apply in ("failure", "cancelled"):
        return ("failed" if apply == "failure" else "cancelled"), {"step": "apply"}
    for step in STEPS_BEFORE_APPLY:
        if _outcome(content, step) in ("failure", "cancelled"):
            return ("failed" if _outcome(content, step) == "failure" else "cancelled"), {"step": step}
    return "failed", {"step": "not-run"}


def _day(stamp):
    """The day number, since 1970-01-01, of an ISO 8601 UTC stamp's date (H. Hinnant's days_from_civil): the core
    imports no datetime."""
    year, month, day = int(stamp[0:4]), int(stamp[5:7]), int(stamp[8:10])
    year -= month <= 2
    era = year // 400
    year_of_era = year - era * 400
    day_of_year = (153 * (month + (-3 if month > 2 else 9)) + 2) // 5 + day - 1
    return era * 146097 + year_of_era * 365 + year_of_era // 4 - year_of_era // 100 + day_of_year - 719468


def working_days(since, now):
    """The whole working days, Monday to Friday, between the day of `since` and the day of `now` (§10): an
    incident opened on a Tuesday is one working day old on Thursday. 1970-01-01 was a Thursday."""
    return sum(1 for day in range(_day(since) + 1, _day(now)) if (day + 3) % 7 < 5)


def reminder_due(age):
    """The reminder level due after `age` working days (§10): 1 after one, 2 after three, one more every five."""
    if age < 3:
        return 1 if age >= 1 else 0
    return 2 + (age - 3) // 5


def _route(row, kind):
    """The routing of a kind for an environment: its own kinds over its defaults (§6.2)."""
    settings = row.get("notifications") if isinstance(row.get("notifications"), dict) else {}
    defaults = settings.get("defaults") if isinstance(settings.get("defaults"), dict) else {}
    kinds = settings.get("kinds") if isinstance(settings.get("kinds"), dict) else {}
    own = kinds.get(kind) if isinstance(kinds.get(kind), dict) else {}
    return {**defaults, **own}, settings.get("deliver-as")


def _key(facts, environment, slot, action):
    """The relay's Idempotency-Key: one per message of a run attempt, so re-running only the deliver job does
    not post twice. Hashed: the relay's store refuses '/' in a key, and a name may make it too long."""
    run = facts["run"]
    text = "/".join((facts["repository"], str(run["id"]), str(run["attempt"]), environment, slot, action))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _incident(facts, environment, slot):
    state = facts["state"]
    return state["incidents"].get(f"{environment.lower()}/{slot}") if state else None


def _bot(login):
    return not isinstance(login, str) or not login or login.endswith("[bot]")


def _roles(people):
    """The people of a push by role (§5): the authors, the pusher of a direct push among them, and the
    mergers who are not authors; bots and Apps never."""
    if people is None or not people["available"]:
        return [], []
    authors = [pr["author"] for pr in people["pull_requests"] if not _bot(pr["author"])]
    if not people["pull_requests"] and not _bot(people["pusher"]):
        authors.append(people["pusher"])
    authors = list(dict.fromkeys(authors))
    mergers = [pr["merged_by"] for pr in people["pull_requests"] if not _bot(pr["merged_by"])]
    return authors, [login for login in dict.fromkeys(mergers) if login not in authors]


def named(people):
    """The people of a push (§5): each author, then each merger who is not an author."""
    authors, mergers = _roles(people)
    return authors + mergers


def _identity(facts, login):
    """The login's SAML identity when its UPN is in TF_NOTIFY_PEOPLE_DOMAINS, else None (§5, D18)."""
    identities = facts["identities"]
    found = identities["people"].get(login) if identities and identities["available"] else None
    if found is None or found["upn"].rpartition("@")[2].lower() not in facts["people_domains"]:
        return None
    return found


def _name(facts, login):
    """A person as the message names them: by display name when it is known and safe to write, else by login."""
    found = _identity(facts, login)
    name = found["name"] if found else ""
    return name if name and all(c.isalpha() or c in NAME_PUNCTUATION for c in name) else login


def _chosen(facts, observation):
    """Whom an opening or a reply means to mention (§6.2 `mention`): of the push's people, the roles the route
    chooses."""
    if observation["action"] not in ("open", "reply") or facts["event"] != "push":
        return []
    authors, mergers = _roles(facts["people"])
    chosen = environments.as_list(observation["route"].get("mention", ["author"]))
    return (authors if "author" in chosen else []) + (mergers if "merger" in chosen else [])


def _reminded(observation):
    """Whom a reminder mentions (§10): at level 1 the people the incident opened mentioning, at level 2 everyone it
    named, later nobody but the channel's tag. A state from before reminders mentions everyone named first."""
    incident = observation["incident"]
    if observation["level"] == 1:
        return incident.get("mentioned", incident["people"])
    return incident["people"] if observation["level"] == 2 else []


def _mentions(facts, logins):
    """The events' mentions once the relay can: each login with an identity in the people domains."""
    return [{"login": login, "object_id": _identity(facts, login)["object_id"], "name": _name(facts, login)}
            for login in logins if _identity(facts, login)]


def _addresses(outputs):
    """The drifted addresses parse-terraform-plan lists, or None when they cannot be read."""
    try:
        addresses = json.loads(outputs.get("drift-addresses") or "")
    except ValueError:
        return None
    return addresses if isinstance(addresses, list) and all(isinstance(each, str) for each in addresses) else None


def _drift(facts, name, row, content, applied):
    """The environment's drift slot (Drift-detection.md §5), or None when there is nothing to observe: a
    scheduled plan-only run reads drift from its classified plan, and an apply changes drift back."""
    incident = _incident(facts, name, DRIFT_SLOT)
    status = incident["status"] if incident else "none"
    outputs = _plan_outputs(content)
    scheduled = facts["event"] == "schedule" and "apply" not in row["goals-granted"] \
        and _outcome(content, "plan") == "success"
    plan_class = outputs.get("plan-class") if scheduled else None
    fingerprint = outputs.get("plan-fingerprint") or None
    route, deliver_as = _route(row, "drift")
    action, level, age, result = "none", None, None, "drift"
    if applied and status in ("open", "pending"):
        action, result = "resolve", "applied"
    elif plan_class == "drift" and status in ("none", "resolved", "pending"):
        action = "none" if route.get("off") in (True, "true") else "open"
    elif plan_class == "drift" and incident.get("fingerprint") != fingerprint:
        action = "reply"
    elif plan_class == "drift":
        age = working_days(incident["opened_at"], facts["now"])
        due = age // DRIFT_REMINDER_DAYS
        if due > incident.get("reminder_level", 0) and route.get("remind") not in (False, "false"):
            action, level = "remind", due
    elif plan_class in ("pending", "clean") and status in ("open", "pending"):
        action, result = "resolve", "no-drift"
    if incident is None and action == "none":
        return None
    later = action in ("reply", "resolve", "remind")
    return {"environment": name, "slot": DRIFT_SLOT, "result": result, "kind": "drift",
            "action": action, "incident": incident, "level": level, "age": age,
            "detail": {"outputs": outputs}, "fingerprint": fingerprint,
            "alias": incident["alias"] if later else route.get("alias", facts["target"]["alias"]),
            "sender": incident["sender"] if later else deliver_as or name}


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
        incident = _incident(facts, name, SLOT)
        status = incident["status"] if incident else "none"
        action, level, age = "none", None, None
        if kind and facts["event"] in OPENING_EVENTS and status in ("none", "resolved", "pending"):
            action = "none" if route.get("off") in (True, "true") else "open"
        elif kind and facts["event"] == "push" and status == "open":
            action = "reply"
        elif result in RESOLVING and status in ("open", "pending"):
            action = "resolve"
        elif facts["event"] == "schedule" and status == "open":
            # A schedule's repeat of an open incident is its reminder, when one is due and the incident's kind
            # wants them (§10).
            age = working_days(incident["opened_at"], facts["now"])
            due = reminder_due(age)
            if due > incident.get("reminder_level", 0) and _route(row, incident["kind"])[0].get("remind") \
                    not in (False, "false"):
                action, level = "remind", due
        # The incident's later messages go where its first went, as its sender (§9).
        later = action in ("reply", "resolve", "remind")
        observations.append({"environment": name, "slot": SLOT, "result": result, "detail": detail, "kind": kind,
                             "action": action, "incident": incident, "route": route, "level": level, "age": age,
                             "fingerprint": None,
                             "alias": incident["alias"] if later else route.get("alias", facts["target"]["alias"]),
                             "sender": incident["sender"] if later else deliver_as or name})
        drift = _drift(facts, name, row, facts["metadata"].get(name), result == "applied")
        observations += [drift] if drift else []
    seen = {observation["environment"].lower() for observation in observations}
    names = {name.lower() for name in facts["senders"]}
    incidents = facts["state"]["incidents"] if facts["state"] else {}
    for state_key, incident in sorted(incidents.items()):
        environment, _, slot = state_key.rpartition("/")
        if environment in seen or environment in names or incident["status"] not in ("open", "pending"):
            continue
        observations.append({"environment": environment, "slot": slot, "result": "removed", "kind": None,
                             "action": "resolve", "incident": incident, "alias": incident["alias"],
                             "sender": incident["sender"], "fingerprint": None})
    return observations


def _messaged(observation):
    """Whether the observation's action is a message: a pending incident never reached Teams, so it resolves
    quietly."""
    if observation["action"] in ("open", "reply", "remind"):
        return True
    return observation["action"] == "resolve" and observation["incident"]["status"] == "open"


def wanted(facts):
    """Which costly facts the run needs: the people of the push when it opens or repeats an incident, the
    people its reminders name, whose identities it reads, and the protection rules of the senders it posts as."""
    observations = [o for o in _plan(facts) if _messaged(o) and o["sender"] in facts["senders"]]
    # A reminder names everyone the incident opened with, and mentions some of them.
    reminded = [login for o in observations if o["action"] == "remind" for login in o["incident"]["people"]]
    return {"people": facts["event"] == "push" and any(o["action"] in ("open", "reply") for o in observations),
            "protection": sorted({facts["senders"][o["sender"]]["github-environment"] for o in observations}),
            "reminded": list(dict.fromkeys(reminded))}


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
        return f"Pushed by {_name(facts, people['pusher'])}." if not _bot(people["pusher"]) else "Pushed by an app."
    parts = []
    for pr in pull_requests[:PULL_REQUEST_LIMIT]:
        part = f"[#{pr['number']}]({facts['server_url']}/{facts['repository']}/pull/{pr['number']})"
        title = _title(pr["title"] or "")
        part += f" `{title}`" if title else ""
        part += f" by {_name(facts, pr['author'])}" if not _bot(pr["author"]) else ""
        part += f", merged by {_name(facts, pr['merged_by'])}" if not _bot(pr["merged_by"]) and pr["merged_by"] != pr["author"] else ""
        parts.append(part)
    if len(pull_requests) > PULL_REQUEST_LIMIT:
        parts.append(f"and {len(pull_requests) - PULL_REQUEST_LIMIT} more")
    return f"{'Change' if len(pull_requests) == 1 else 'Changes'}: {'; '.join(parts)}."


def _listed(names):
    """'a', 'a and b', 'a, b and c'."""
    return names[0] if len(names) == 1 else f"{', '.join(names[:-1])} and {names[-1]}"


def _when(stamp):
    """2026-10-05T08:30:00Z, as the record job writes it, as 2026-10-05 08:30 UTC."""
    return f"{stamp[:10]} {stamp[11:16]} UTC"


def _changes(outputs):
    """'has 3 changes (2 to add, 1 to change)', naming the non-zero counts, or 'changes only outputs'."""
    counts = [(int(given), kind) for given, kind in ((outputs.get(f"count-{kind}") or "", kind) for kind in COUNTED)
              if given.isdigit()]
    detail = [f"{count} to {kind}" for count, kind in counts if count]
    total = sum(count for count, _ in counts)
    if not total:
        return "changes only outputs"
    return f"has {total} change{'' if total == 1 else 's'} ({', '.join(detail)})"


def _reason(observation):
    name, detail = observation["environment"], observation["detail"]
    not_applied = f"so the default branch is not applied in `{name}`."
    if observation["result"] == "pending":
        return f"The scheduled plan of `{name}` {_changes(detail['outputs'])}, {not_applied}"
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


def _drift_list(observation):
    """The paragraphs that say what drifted: how many, and up to ADDRESS_LIMIT addresses as code spans."""
    outputs = observation["detail"]["outputs"]
    addresses = _addresses(outputs)
    given = outputs.get("count-drift") or ""
    count = int(given) if given.isdigit() else len(addresses or [])
    name = observation["environment"]
    them = "them" if count != 1 else "it"
    sentence = f"{count} resource{'' if count == 1 else 's'} in `{name}` changed outside Terraform, and the next " \
               f"apply would change {them} back"
    if not addresses:
        return [sentence + "."]
    shown = [f"- `{_title(address)}`" for address in addresses[:ADDRESS_LIMIT]]
    if count > len(shown):
        shown.append(f"- and {count - len(shown)} more")
    return [sentence + ":", "\n".join(shown)]


def _render_drift(facts, observation, link):
    name, repository, action = observation["environment"], facts["repository"], observation["action"]
    incident = observation["incident"]
    if action == "resolve" and observation["result"] == "applied":
        lines = [f"✅ **No drift** in `{name}` · {repository}",
                 f"`{name}` is applied, which changed back the drift found at {_when(incident['opened_at'])}."]
    elif action == "resolve":
        lines = [f"✅ **No drift** in `{name}` · {repository}",
                 f"The scheduled plan of `{name}` finds no drift: the drift found at {_when(incident['opened_at'])} "
                 "is gone."]
    elif action == "remind":
        days = observation["age"]
        lines = [f"⏰ **Still drifted** in `{name}` · {repository}",
                 f"`{name}` has drifted for {days} working days, since the scheduled plan "
                 f"found it at {_when(incident['opened_at'])}."]
    else:
        title = "Drift changed" if action == "reply" else "Drift"
        lines = [f"🌀 **{title}** in `{name}` · {repository}", *_drift_list(observation), "Found by the scheduled run."]
    return "\n\n".join(lines + [link]) + "\n"


def render(facts, observation):
    """The message, markdown text (D23): a first line that says what and where, why, who, and the run.
    The repository is plain text: Teams draws a code span as a box, and an owner/name is letters, digits,
    '.', '-' and '_', none of which starts markup inside a word."""
    name, repository = observation["environment"], facts["repository"]
    run = facts["run"]
    link = f"[Open the run]({facts['server_url']}/{repository}/actions/runs/{run['id']}/attempts/{run['attempt']})"
    action = observation["action"]
    if observation["slot"] == DRIFT_SLOT and observation["result"] != "removed":
        return _render_drift(facts, observation, link)
    if action == "resolve":
        since = _when(observation["incident"]["opened_at"])
        if observation["result"] == "removed":
            lines = [f"✅ **No longer watched** `{name}` · {repository}",
                     f"`{name}` is no longer in environments-yml: the incident opened at {since} is closed."]
        elif observation["result"] == "clean":
            lines = [f"✅ **Applied** in `{name}` · {repository}",
                     f"A plan of `{name}` has no changes: the incident opened at {since} is resolved."]
        else:
            lines = [f"✅ **Applied** in `{name}` · {repository}",
                     f"`{name}` is applied again: the incident opened at {since} is resolved."]
        return "\n\n".join(lines + [link]) + "\n"
    if action == "remind":
        incident, days = observation["incident"], observation["age"]
        lines = [f"⏰ **Still not applied** in `{name}` · {repository}",
                 f"`{name}` has not been applied for {days} working day{'' if days == 1 else 's'}, since "
                 f"{REMINDED[incident['kind']]} at {_when(incident['opened_at'])}."]
        if incident["people"]:
            lines.append(f"The change was by {_listed([_name(facts, login) for login in incident['people']])}.")
        return "\n\n".join(lines + [link]) + "\n"
    icon, title = HEADERS[observation["kind"]]
    reason = _reason(observation)
    if action == "reply":
        title += " again"
        reason += f" It has not been applied since {_when(observation['incident']['opened_at'])}."
    return "\n\n".join([f"{icon} **{title}** in `{name}` · {repository}", reason, _people_line(facts), link]) + "\n"


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
        what = f"reminder {observation['level']}" if action == "remind" else what
        what = "drift changed" if action == "reply" and observation["slot"] == DRIFT_SLOT else what
        if _messaged(observation) and observation["sender"] not in facts["senders"]:
            notes.append(f"`{name}`: removed from environments-yml, and its sender `{observation['sender']}` with it; "
                         "closed without a message")
        elif _messaged(observation):
            event_id = f"e{len(events) + 1}"
            incident = observation["incident"]
            event_action = "removed" if observation["result"] == "removed" else action
            reply_to = incident["message_id"] if action != "open" else None
            event = {"id": event_id, "environment": name, "slot": observation["slot"], "kind": observation["kind"],
                     "action": event_action, "alias": observation["alias"], "reply_to": reply_to, "update": None,
                     "sender": observation["sender"],
                     "idempotency_key": _key(facts, name, observation["slot"], event_action),
                     "message": f"{event_id}.md",
                     "mentions": _mentions(facts, _reminded(observation) if action == "remind"
                                           else _chosen(facts, observation))}
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
        observed.append({"environment": name, "slot": observation["slot"], "result": observation["result"],
                         "kind": observation["kind"],
                         "action": action, "event": event_id, "people": people, "alias": observation["alias"],
                         "sender": observation["sender"], "sending": sending,
                         "mentioned": _chosen(facts, observation) if action == "open" else [],
                         "reminder_level": observation.get("level"), "fingerprint": observation["fingerprint"]})
    parts = []
    if table:
        parts.append("\n".join(["| Environment | What | Sent |", "|---|---|---|", *table]))
    if notes:
        parts.append("\n".join(f"- {note}" for note in notes))
    summary = "### 📣 Teams notifications\n\n" + ("\n\n".join(parts) if parts else "Nothing to tell Teams.") + "\n"
    return {"events": events, "messages": messages, "deliver": deliver, "observations": observed, "summary": summary}
