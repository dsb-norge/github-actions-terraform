"""Whether a run notifies, and through which relay (docs/Notifications.md §6.1, §7).

The target is three GitHub variables the workflow reads and hands over as the document's
`notify_target`; they come from the organisation's configuration, never from a pull request, so a
target that is incomplete or malformed is a warning that turns notifications off, never an error
that turns every pull request of a landing zone red (D5). What a run sends is decided after the
environments ran, by decide-notifications; this decides only whether it runs at all.
"""

import re

from . import environments

NOTIFYING_EVENTS = ("push", "schedule", "workflow_dispatch")
# The document's keys, and the variables they come from, in the order a message lists them.
VARIABLES = (("bot_url", "TF_NOTIFY_BOT_URL"), ("bot_audience", "TF_NOTIFY_BOT_AUDIENCE"), ("alias", "TF_NOTIFY_ALIAS"))
URL = re.compile(r"https://[^\s/]+(/\S*)?/api/?")
AUDIENCE = re.compile(r"api://\S+")
OFF = "notifications are off: "
NO_TARGET = "no target: TF_NOTIFY_BOT_URL, TF_NOTIFY_BOT_AUDIENCE and TF_NOTIFY_ALIAS are not set"
SWITCHED_OFF = "switched off: notifications-yml sets enabled: false"
NOT_THIS_EVENT = "only a push, a schedule or a dispatch on the default branch notifies"
# What a deliver job exports to sign in as its environment, and nothing else (docs/Notifications.md D20).
IDENTITY = ("ARM_TENANT_ID", "ARM_CLIENT_ID")
DELIVER_RUNS_ON = "ubuntu-latest"


def _checked(target):
    """(the target as the workflow reads it, or None; why there is none; the warnings)."""
    if target is None or not any(target[key] for key, _ in VARIABLES):
        return None, NO_TARGET, []
    missing = [variable for key, variable in VARIABLES if not target[key]]
    if missing:
        return None, "the target is incomplete", [
            f"{OFF}TF_NOTIFY_BOT_URL, TF_NOTIFY_BOT_AUDIENCE and TF_NOTIFY_ALIAS are set together or not at all; "
            f"missing: {', '.join(missing)}"]
    problems = []
    if not URL.fullmatch(target["bot_url"]):
        problems.append(f"TF_NOTIFY_BOT_URL is {environments.shown(target['bot_url'])}; it must start with https:// "
                        "and end with /api")
    if not AUDIENCE.fullmatch(target["bot_audience"]):
        problems.append(f"TF_NOTIFY_BOT_AUDIENCE is {environments.shown(target['bot_audience'])}; it must start with "
                        "api://")
    if not environments.ALIAS.fullmatch(target["alias"]):
        problems.append(f"TF_NOTIFY_ALIAS is {environments.shown(target['alias'])}; {environments.ALIAS_RULE}")
    if problems:
        return None, "the target is invalid", [OFF + problem for problem in problems]
    return {"bot-url": target["bot_url"], "bot-audience": target["bot_audience"], "alias": target["alias"]}, None, []


def _switched_off(document):
    settings = environments.parsed_inputs(document)[environments.NOTIFICATIONS]
    return isinstance(settings, dict) and settings.get("enabled") in (False, "false")


def _identity(variables):
    return {name: value for name, value in variables.items() if name in IDENTITY} if isinstance(variables, dict) else {}


def senders(rows):
    """Every environment's GitHub environment and identity variables, as its job exports them: a deliver
    job may send for an environment this run did not run (deliver-as), so every one is listed."""
    return {row["environment"]: {"github-environment": row["github-environment"],
                                 "extra-envs": _identity(row["extra-envs"]),
                                 "extra-envs-from-secrets": _identity(row["extra-envs-from-secrets"])}
            for row in rows}


def _runs_on(document):
    """The deliver jobs' runner: notifications-yml's runs-on, which only the whole run may set."""
    settings = environments.parsed_inputs(document)[environments.NOTIFICATIONS]
    return settings.get("runs-on", DELIVER_RUNS_ON) if isinstance(settings, dict) else DELIVER_RUNS_ON


def _block(document, active, reason, target, rows):
    return {"active": active, "reason": reason, "target": target, "senders": senders(rows),
            "runs-on": _runs_on(document)}


def decide(document, rows):
    """The notify block, {active, reason, target, senders, runs-on}, and its warnings. A repository that switched
    notifications off is not warned about its landing zone's target."""
    target, reason, warnings = _checked(document.get("notify_target"))
    if _switched_off(document):
        return _block(document, False, SWITCHED_OFF, target, rows), []
    if target is None:
        return _block(document, False, reason, None, rows), warnings
    if document["event"]["name"] not in NOTIFYING_EVENTS or not environments.on_default_branch(document):
        return _block(document, False, NOT_THIS_EVENT, target, rows), []
    return _block(document, True, "on", target, rows), []
