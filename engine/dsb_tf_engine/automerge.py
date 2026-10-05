"""Module auto-merge: whose pull request merges without review, and in which run
(docs/Module-auto-merge.md §3). Pure: the adapter lists the commits (§4)."""

import re

from . import admission, environments, tests, triggers, values
from .environments import shown

ENABLED = environments.ENABLED
ACTORS = environments.ACTORS
DEPENDABOT = admission.DEPENDABOT
# GitHub signs the commits it makes itself, Dependabot's and an App's through the API, as this committer.
WEB_FLOW = "web-flow"
# GitHub lists at most 250 commits of a pull request.
MAX_COMMITS = 250
RELEASE_BRANCH = "release-please--branches--{default}"
# The docs job's commit message in Dependabot's own run, the only run that commits to Dependabot's pull request,
# and only once the admission admitted it (docs/Dependabot-admission.md D22): proof of the admitted head beneath.
DEPENDABOT_DOCS_MESSAGE = "terraform-docs: automated action [dependabot skip]"
RELEASE_FILES = ("CHANGELOG.md", ".release-please-manifest.json")
DOCS_CONFIGS = (".terraform-docs.yml", "examples/.terraform-docs.yml")
EXAMPLE_README = re.compile(r"examples/[^/]+/README\.md")
NOT_APPLYING = {"applies": False}


def settings(document):
    """Whether auto-merge is switched on, and the bots it may merge for; a ConfigError with every mistake.

    Validated on every event, as the project workflow validates its global list (docs/Module-auto-merge.md §5).
    """
    switch = document["workflow_inputs"].get(ENABLED, False)
    # Compared by identity: 1 == True, and 1 is not a boolean.
    if switch is not True and switch is not False and switch not in ("true", "false"):
        raise environments.ConfigError([f"The input '{ENABLED}' is {shown(switch)}; it must be true or false!"])
    switched_on = switch in (True, "true")
    result = document["yaml"]["inputs"].get(ACTORS, {"ok": True, "value": None})
    if not result["ok"]:
        raise environments.ConfigError([f"The specification for input '{ACTORS}' is not valid yaml!"])
    errors = environments.actor_problems(ACTORS, f"{ACTORS} is", result["value"])
    if errors:
        raise environments.ConfigError(errors)
    actors = environments.as_list(result["value"])
    errors = [f"{ACTORS} names {actor}, which is not a bot; the module workflow merges bots' pull requests only "
              "(their commits are signed by GitHub, a person's web edits are too)."
              for actor in actors if not actor.endswith("[bot]")]
    if switched_on and not actors:
        errors.append(f"Auto-merge is switched on ({ENABLED}), but {ACTORS} names nobody, "
                      + environments.NAME_THE_ACTORS.format(where=""))
    if switched_on and DEPENDABOT in {actor.casefold() for actor in actors} \
            and not admission.settings(document, default_enabled=False)["enabled"]:
        errors.append(f"Auto-merge may merge Dependabot's pull requests ({ACTORS} names {DEPENDABOT}), but the "
                      "Dependabot admission is off, so nothing judges them before they run. Switch "
                      f"{admission.SWITCH} on, or remove {DEPENDABOT} from the list.")
    if errors:
        raise environments.ConfigError(errors)
    return {"enabled": switched_on, "actors": [actor.casefold() for actor in actors]}


def _is_docs_file(readme, item):
    """A file the docs job writes, written as the docs job writes it: a README modified, a default config
    added or modified, nothing renamed or removed (docs/Module-auto-merge.md §3, rule 4)."""
    if item["name"] in DOCS_CONFIGS:
        written = item["status"] in ("added", "modified")
    else:
        written = item["status"] == "modified" and (item["name"] == readme
                                                    or EXAMPLE_README.fullmatch(item["name"]) is not None)
    return written and item["previous"] is None


def _readme(document):
    # Absent, as empty, is the root.
    readme_dir = tests.normalise_dir(str(values.get_val(document["workflow_inputs"].get("readme-file-path", ""))))
    return "README.md" if readme_dir == "." else f"{readme_dir}/README.md"


def _kind(readme, author, commit):
    """'author' for the author's commit, signed by GitHub itself; 'docs' for a docs commit; else 'other'."""
    if commit["parents"] != 1:
        return "other"
    if (commit["author"] or "").casefold() == author.casefold() and commit["verified"] \
            and commit["committer"] == WEB_FLOW:
        return "author"
    files = commit["files"]
    if files and not commit["files_truncated"] and all(_is_docs_file(readme, item) for item in files):
        return "docs"
    return "other"


def _other(readme, commit, author):
    """Why a commit is neither the author's nor docs, for the notice."""
    who = commit["author"] or "an account GitHub could not resolve"
    if commit["parents"] != 1:
        return f"commit {commit['sha'][:7]} by {who} is a merge commit"
    files = commit["files"] or []
    first = next((item for item in files if not _is_docs_file(readme, item)), None)
    change = (f"{first['status']} {first['name']}" if first else "too many files to list" if commit["files_truncated"]
              else "no file")
    return (f"commit {commit['sha'][:7]} by {who} is neither the author's ({author}), signed by GitHub, nor a docs "
            f"commit ({change})")


def _listing_problem(facts, head_sha):
    """Why the listing cannot be trusted to be this head's commits, or None (rule 2)."""
    commits = facts["commits"]
    if len(commits) >= MAX_COMMITS:
        return f"it has {MAX_COMMITS} commits or more, more than GitHub lists"
    if len(commits) != facts["count"]:
        return f"GitHub listed {len(commits)} of its {facts['count']} commits"
    if commits[-1]["sha"] != head_sha:
        return "its listed commits do not end with the head this run tested"
    return None


def _release_problem(document, facts, commits):
    """Why another bot's pull request is not a release, or None (rule 6)."""
    branch = RELEASE_BRANCH.format(default=document["caller"]["default_branch"])
    if facts["head_ref"] != branch:
        return (f"another bot's pull request merges only as a release, from {branch}; this one is from "
                f"{facts['head_ref']}")
    for commit in commits:
        changed = [item["name"] for item in commit["files"] or [] if item["name"] not in RELEASE_FILES]
        if commit["files"] is None or commit["files_truncated"] or changed:
            what = changed[0] if changed else "files that were not listed"
            return f"release commit {commit['sha'][:7]} changes {what}, not only {' and '.join(RELEASE_FILES)}"
    return None


def _applies(document, policy):
    """A pull request run, not closing, with the switch on: the runs auto-merge judges."""
    event = document["event"]
    return (policy["enabled"] and event["name"] == "pull_request" and event.get("pull_request") is not None
            and event.get("action", "") not in triggers.CLOSING_ACTIONS)


def _scope_problem(document, policy):
    """Why the pull request is not one auto-merge considers, or None (M10, rule 1)."""
    event = document["event"]
    pull_request = event["pull_request"]
    author = pull_request.get("author", "")
    if pull_request["is_fork"]:
        return "it comes from a fork"
    default = document["caller"]["default_branch"]
    if event.get("base_ref", "") != default:
        return f"it is against {event.get('base_ref') or 'an unknown branch'}, not the default branch {default}"
    if author.casefold() not in policy["actors"]:
        return f"its author, {author or 'unknown'}, is not in {ACTORS}"
    return None


def wants_facts(document, policy):
    """Whether the rule reads the commits: the adapter lists them only then (docs/Module-auto-merge.md §4)."""
    return _applies(document, policy) and _scope_problem(document, policy) is None


def _breaking(old, new):
    """Whether a version change leaves what semver promises compatible: another major, or below 1.0 another
    minor. A version that cannot be read is treated as breaking."""
    before, after = admission.parse_version(old), admission.parse_version(new)
    if before is None or after is None:
        return True
    return before[0] != after[0] or (before[0] == 0 and before[1] != after[1])


def _dependency_problem(facts):
    """Why Dependabot's pull request leaves a dependency's major, or None (rule 7)."""
    if facts is None:
        return "its dependency changes could not be read"
    if not facts["dependencies"]:
        return "it changes no dependency the admission recognised"
    for dependency in facts["dependencies"]:
        if _breaking(dependency["from"], dependency["to"]):
            name = dependency["address"].removeprefix(admission.REGISTRY + "/")
            return (f"it moves {dependency['kind']} {name} from {dependency['from']} to {dependency['to']}, past its "
                    "major (below 1.0, its minor); a person decides that")
    return None


def judge(document, policy, admitted):
    """The verdict on this run: does it merge (docs/Module-auto-merge.md §3, §5)."""
    if not _applies(document, policy):
        return NOT_APPLYING
    event = document["event"]
    pull_request = event["pull_request"]
    author, actor = pull_request.get("author", ""), event.get("actor", "")
    verdict = {"applies": True, "author": author, "actor": actor, "eligible": False, "reason": "",
               "confirm_app": False, "commits": []}

    def refused(reason):
        return {**verdict, "reason": reason}

    problem = _scope_problem(document, policy)
    if problem:
        return refused(problem)
    facts = document.get("automerge")
    if facts is None or not facts["available"]:
        return refused(f"its commits could not be listed ({facts['reason'] if facts else 'not gathered'})")
    problem = _listing_problem(facts, pull_request["head_sha"]) if facts["commits"] else \
        "GitHub listed no commit"
    if problem:
        return refused(problem)
    readme = _readme(document)
    kinds = [_kind(readme, author, commit) for commit in facts["commits"]]
    verdict["commits"] = [{"sha": commit["sha"], "author": commit["author"], "kind": kind}
                          for commit, kind in zip(facts["commits"], kinds)]
    # The docs commits at the head; every commit before them must be the author's.
    own = len(kinds)
    while own and kinds[own - 1] == "docs":
        own -= 1
    for commit, kind in zip(facts["commits"][:own], kinds[:own]):
        if kind == "docs":
            return refused(f"docs commit {commit['sha'][:7]} is followed by a commit of the author's; docs commits "
                           "come last")
        if kind != "author":
            return refused(_other(readme, commit, author))
    if own == 0:
        return refused("it has no commit of its author's")
    if own < len(kinds):
        if not actor.endswith("[bot]") or actor.casefold() == DEPENDABOT:
            return refused(f"the run was started by {actor or 'an unknown actor'}, not by the CI App's docs commit")
        unproven = [commit for commit in facts["commits"][own:] if commit["message"] != DEPENDABOT_DOCS_MESSAGE]
        if author.casefold() == DEPENDABOT and unproven:
            return refused(f"docs commit {unproven[0]['sha'][:7]} was not made in an admitted Dependabot run: its "
                           f"message is not '{DEPENDABOT_DOCS_MESSAGE}'")
        verdict["confirm_app"] = True
    elif actor.casefold() != author.casefold():
        return refused(f"the run was started by {actor or 'an unknown actor'}, neither the author ({author}) nor "
                       "the CI App's docs commit")
    elif author.casefold() == DEPENDABOT and not (admitted["applies"] and not admitted["push_run"]
                                                 and admitted["admitted"]):
        return refused("the Dependabot admission did not admit this run")
    if author.casefold() == DEPENDABOT:
        problem = _dependency_problem(document.get("admission"))
    else:
        problem = _release_problem(document, facts, facts["commits"][:own])
    if problem:
        return refused(problem)
    return {**verdict, "eligible": True}


def notice(verdict):
    """One line for the run page; None when auto-merge does not apply."""
    if not verdict["applies"]:
        return None
    if not verdict["eligible"]:
        return f"auto-merge: not eligible: {verdict['reason']}"
    count = len(verdict["commits"])
    docs = sum(commit["kind"] == "docs" for commit in verdict["commits"])
    return (f"auto-merge: eligible: {verdict['author']}'s pull request, {count} commit{'' if count == 1 else 's'} "
            f"({count - docs} the author's, {docs} docs)")
