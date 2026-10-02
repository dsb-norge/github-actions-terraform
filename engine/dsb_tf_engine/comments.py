"""The seed manifest: the pull request heads and tag purges the seed job reconciles.

docs/Path-relevance.md §6.1-§6.3. Heads are posted in manifest order, which fixes their order in
the conversation from the first run on: group heads first, then one head per ungrouped commenting
environment. A group head is always a placeholder, because the aggregator finalises every group on
every pull-request run. An environment's head is a placeholder when it is affected; when it is not,
no matrix job will finalise it, so it is written here, final. In mode `all` the manifest is the one
the seed job composed from the matrix before relevance.
"""

import re

from . import admission as admission_rule

# The matrix job purges its own environment's tags; an unaffected environment's job does not run.
TAG_KINDS = ("plan", "apply", "destroy-plan", "destroy")
# The seed job does not run for these, and a seed would reopen what they closed.
UNSEEDED_ACTIONS = ("closed", "converted_to_draft")
MODE_LINES = {"apply-on-pr": "🐙 applies on PR", "destroy-on-pr": "☠ destroys on PR"}
# Byte-identical to the summary's final title, so the head never renames itself mid-run.
TESTS_TITLE = "Terraform tests summary"
ADMISSION_TITLE = "🚫 Dependabot pull request not admitted"
SPEC = "https://github.com/dsb-norge/github-actions-terraform/blob/main/docs/Dependabot-admission.md"


def _commenting(entry):
    return entry["add-pr-comment"] == "true"


def _title(mutates):
    # The rendered head uses the same rule, so a placeholder never renames itself mid-run.
    return "Terraform summary" if mutates else "Terraform validation summary"


def _head(kind, key, state, mutates, text):
    subject = "group" if kind == "group" else "environment"
    title = _title(mutates)
    return {"kind": kind, "key": key, "state": state, "title": title, "marker": f"<!-- tf:head:{kind}:{key} -->",
            "body": f"### {title} for {subject}: `{key}`\n\n{text}"}


def _not_affected(entry, block, run, number):
    count = block["changed_count"]
    ignored = " · ".join(f"`{pattern}`" for pattern in entry["paths-ignore"]) or "none"
    return (f"➖ Not affected by this pull request: no changed file matches this environment's paths "
            f"(run #{run['id']} attempt #{run['attempt']}).\n\n"
            "<details><summary>Path rules</summary>\n\n"
            f"Included: {' · '.join(f'`{pattern}`' for pattern in entry['paths'])}\n"
            f"Ignored: {ignored}\n"
            f"Relevance: `{block['mode']}`, pull request #{number}, {count} changed file{'' if count == 1 else 's'}\n\n"
            "</details>")


def _not_taking_part(entry, run):
    events = ", ".join(entry["trigger-events"])
    return (f"➖ Does not take part in pull requests: this environment's trigger-events are {events} "
            f"(run #{run['id']} attempt #{run['attempt']}).")


def _not_admitted(run):
    return (f"🚫 Not admitted: this Dependabot pull request failed the admission, so nothing ran "
            f"(run #{run['id']} attempt #{run['attempt']}). See the admission comment.")


def _label(dependency):
    if dependency["kind"] == "provider":
        return f"provider `{dependency['address'].removeprefix(admission_rule.REGISTRY + '/')}`"
    return f"module `{dependency['address']}`"


def _help(dependency, check):
    """What to do when the change is trusted and intended, per failed check (docs/Dependabot-admission.md §7)."""
    label, version = _label(dependency), dependency["to"]
    name = dependency["address"].removeprefix(admission_rule.REGISTRY + "/").split("/")
    namespace = name[0]
    entry = "/".join(name[:2])
    if check["check"] == "allow":
        return (f"**If you trust {label} and the update is intended:** add `{entry}` (or `{namespace}`) to `allow` in "
                "`dependabot-admission-yml` in the calling workflow on the default branch, then comment "
                "`@dependabot rebase` on this pull request.")
    if check["check"] == "age":
        return f"**{label} {version} is too new:** {check['detail']}. Then re-run all jobs of this run."
    if check["check"] == "key":
        return (f"**{label} {version}:** {check['detail']}. A drop to self-signed is lock-file maintenance for a "
                "maintainer: verify the key with the publisher, then update the lock by hand in a commit of your own.")
    if check["check"] == "hashes":
        return f"**{label} {version}:** {check['detail']}. Do not merge; comment `@dependabot recreate`."
    return (f"**{label}:** {check['detail']}; the admission judges registry and GitHub sources only. A commit of "
            "your own runs it as you.")


def _problem_help(problem):
    if problem["check"] == "lock":
        return (f"**{problem['detail']}:** commit a lock file on the default branch, then comment "
                "`@dependabot rebase` on this pull request.")
    return f"**The change:** {problem['detail']}. Review it; a commit of your own runs it as you."


def admission_report(admitted):
    """The table of every changed dependency and problem with its result (D15); the run summary shows it too."""
    lines = ["| Dependency | Change | Result |", "|---|---|---|"]
    for dependency in admitted["dependencies"]:
        failed = [check for check in dependency["checks"] if not check["ok"]]
        result = "✅ admitted" if not failed else "❌ " + "; ".join(check["detail"] for check in failed)
        lines.append(f"| {_label(dependency)} | {dependency['from']} → {dependency['to']} | {result} |")
    lines += [f"| the change | — | ❌ {problem['detail']} |" for problem in admitted["problems"]]
    return "\n".join(lines)


def _admission_body(admitted):
    files = [f"- {', '.join(f'`{path}`' for path in dependency['files'])}: {_label(dependency)}"
             for dependency in admitted["dependencies"]]
    helps = [_help(dependency, check) for dependency in admitted["dependencies"]
             for check in dependency["checks"] if not check["ok"]]
    helps += [_problem_help(problem) for problem in admitted["problems"]]
    parts = [f"### {ADMISSION_TITLE}",
             "No Terraform ran. Every dependency a Dependabot pull request changes must pass the admission before any "
             f"job runs it ([what the admission checks]({SPEC})).",
             admission_report(admitted)]
    if files:
        parts.append("<details><summary>Files</summary>\n\n" + "\n".join(files) + "\n\n</details>")
    parts += helps
    parts.append("**To run this pull request once without changing the policy:** push a commit to its branch. That "
                 "run is yours and is not judged; Dependabot stops rebasing the pull request.")
    return "\n\n".join(parts)


def _admission_head(document, admitted):
    """The admission head when the run is refused, else the purge of a stale one (docs/Dependabot-admission.md §7)."""
    caller = re.sub(r"[^A-Za-z0-9_-]", "", document["caller"].get("workflow_name", ""))
    marker = f"<!-- tf:head:admission:{caller} -->"
    refused = admitted["applies"] and not admitted["push_run"] and not admitted["admitted"]
    if refused:
        commenting = document["workflow_inputs"].get("add-pr-comment") in (True, "true")
        return ([{"kind": "admission", "key": caller, "state": "final", "title": ADMISSION_TITLE, "marker": marker,
                  "body": _admission_body(admitted)}] if commenting else []), []
    # Only Dependabot's pull requests can hold one: purge it when a later run is admitted or is a person's.
    author = document["event"]["pull_request"].get("author", "")
    return [], [{"marker-prefix": marker, "keep-marker-substring": ""}] if author == admission_rule.DEPENDABOT else []


def _tests_head(document, tests_block, waiting):
    """The tests head, after the environment heads: scoped per calling workflow, because a repository
    may call this workflow from two and both would discover the same files (docs/Terraform-tests.md §6.3)."""
    caller = re.sub(r"[^A-Za-z0-9_-]", "", document["caller"].get("workflow_name", ""))
    if not tests_block["count"] or document["workflow_inputs"].get("add-pr-comment") not in (True, "true"):
        return []
    return [{"kind": "tests", "key": caller, "state": "placeholder", "title": TESTS_TITLE,
             "marker": f"<!-- tf:head:tests:{caller} -->", "body": f"### {TESTS_TITLE}\n\n{waiting}"}]


def manifest(document, block, entries, tests_block, admitted=admission_rule.NOT_APPLYING):
    """The heads and tag purges for this run, empty where the seed job does not run."""
    event = document["event"]
    pull_request = event.get("pull_request")
    if (event["name"] != "pull_request" or pull_request is None or pull_request["is_fork"]
            or event.get("action", "") in UNSEEDED_ACTIONS or "run" not in document):
        return {"heads": [], "purge_tags_for": [], "gc": []}
    run = document["run"]
    waiting = f"⏳ Awaiting results (run #{run['id']} attempt #{run['attempt']})…"

    # The admission head first: on a refused run it is what the reader needs (docs/Dependabot-admission.md §7).
    heads, admission_gc = _admission_head(document, admitted)
    groups = sorted({entry["pr-comment-group"] for entry in entries
                     if _commenting(entry) and entry["pr-comment-group"] != ""})
    for group in groups:
        mutates = any(entry["mutates-on-pr"] for entry in entries if entry["pr-comment-group"] == group)
        heads.append(_head("group", group, "placeholder", mutates, waiting))
    for entry in entries:
        if not _commenting(entry) or entry["pr-comment-group"] != "":
            continue
        mutates = entry["mutates-on-pr"]
        if entry["verdict"] == "run":
            mode = " · ".join(MODE_LINES[goal] for goal in mutates)
            heads.append(_head("env", entry["github-environment"], "placeholder", mutates,
                               waiting + (f"\n\n{mode}" if mode else "")))
        elif entry["reasons"][0] == admission_rule.REFUSED:
            heads.append(_head("env", entry["github-environment"], "not-admitted", mutates, _not_admitted(run)))
        elif entry["reasons"][0].startswith("trigger-events:"):
            # Dropped before relevance: "not affected by this change" would be the wrong reason.
            heads.append(_head("env", entry["github-environment"], "not-taking-part", mutates,
                               _not_taking_part(entry, run)))
        else:
            heads.append(_head("env", entry["github-environment"], "not-affected", mutates,
                               _not_affected(entry, block, run, pull_request["number"])))

    heads += _tests_head(document, tests_block, waiting)

    purge = [entry["github-environment"] for entry in entries if _commenting(entry) and entry["verdict"] == "skip"]
    gc = [{"marker-prefix": f"<!-- tf:tag:{kind}:{name}:", "keep-marker-substring": ""}
          for name in purge for kind in TAG_KINDS]
    return {"heads": heads, "purge_tags_for": purge, "gc": gc + admission_gc}
