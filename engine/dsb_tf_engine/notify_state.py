"""The incident state (docs/Notifications.md §9): one document per repository, which the record job merges
a run's observations and the relay's answers into, under a lock, from the newest stored document.

Pure: the adapter restores and saves the document, and passes the time and the tombstone cutoff as
ISO 8601 UTC text, which sorts as it reads. A run older than the one an incident last saw changes
nothing about it (D19), so a re-run of an old commit, or an earlier run finishing last, cannot reopen
what a newer run resolved.
"""

import json

SCHEMA_VERSION = 1
SLOT = "apply"


def valid(document):
    """The document when it has the shape this version writes, else None: a state from another version
    is started over, never misread."""
    if not (isinstance(document, dict) and document.get("schema_version") == SCHEMA_VERSION
            and isinstance(document.get("incidents"), dict)
            and all(isinstance(each, dict) for each in document["incidents"].values())):
        return None
    return document


def merge(state, observations, results, run_number, now, cutoff):
    """(the new state, whether it differs from `state`)."""
    before = valid(state) or {"schema_version": SCHEMA_VERSION, "incidents": {}}
    # A copy, through JSON: the document is JSON, and the core imports nothing else to copy it.
    incidents = json.loads(json.dumps(before["incidents"]))
    for observation in observations:
        key = f"{observation['environment'].lower()}/{SLOT}"
        incident = incidents.get(key)
        if incident is not None and incident["seen_run"] > run_number:
            continue
        answer = results.get(observation["event"])
        accepted = bool(answer and answer["accepted"])
        action = observation["action"]
        if action == "open" and incident is not None and incident["status"] == "open":
            # An overlapping run opened it first: its thread stays the incident's.
            incident["seen_run"] = run_number
        elif action == "open":
            incidents[key] = {"kind": observation["kind"], "status": "open" if accepted else "pending",
                              "message_id": answer["message_id"] if accepted else None,
                              "alias": observation["alias"], "sender": observation["sender"], "opened_at": now,
                              "opened_run": run_number, "seen_run": run_number, "people": observation["people"],
                              "resolved_at": None}
        elif incident is None or incident["status"] == "resolved":
            continue
        elif action == "resolve":
            incident.update(status="resolved", resolved_at=now, seen_run=run_number)
        elif action == "reply":
            incident.update(kind=observation["kind"], seen_run=run_number)
        else:
            incident["seen_run"] = run_number
    for key in [key for key, incident in incidents.items()
                if incident["status"] == "resolved" and (incident["resolved_at"] or "") < cutoff]:
        del incidents[key]
    after = {"schema_version": SCHEMA_VERSION, "incidents": incidents}
    return after, json.dumps(after, sort_keys=True) != json.dumps(before, sort_keys=True)
