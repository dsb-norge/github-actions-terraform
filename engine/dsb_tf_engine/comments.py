"""The seed manifest: the pull request heads and tag purges the seed job reconciles.

docs/Path-relevance.md §6.1-§6.3. Heads are posted in manifest order, which fixes their order in
the conversation from the first run on: group heads first, then one head per ungrouped commenting
environment. A group head is always a placeholder, because the aggregator finalises every group on
every pull-request run. An environment's head is a placeholder when it is affected; when it is not,
no matrix job will finalise it, so it is written here, final. In mode `all` the manifest is the one
the seed job composed from the matrix before relevance.
"""

# The matrix job purges its own environment's tags; an unaffected environment's job does not run.
TAG_KINDS = ("plan", "apply", "destroy-plan", "destroy")
# The seed job does not run for these, and a seed would reopen what they closed.
UNSEEDED_ACTIONS = ("closed", "converted_to_draft")
MODE_LINES = {"apply-on-pr": "🐙 applies on PR", "destroy-on-pr": "☠ destroys on PR"}


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


def manifest(document, block, entries):
    """The heads and tag purges for this run, empty where the seed job does not run."""
    event = document["event"]
    pull_request = event.get("pull_request")
    if (event["name"] != "pull_request" or pull_request is None or pull_request["is_fork"]
            or event.get("action", "") in UNSEEDED_ACTIONS or "run" not in document):
        return {"heads": [], "purge_tags_for": [], "gc": []}
    run = document["run"]
    waiting = f"⏳ Awaiting results (run #{run['id']} attempt #{run['attempt']})…"

    heads = []
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
        else:
            heads.append(_head("env", entry["github-environment"], "not-affected", mutates,
                               _not_affected(entry, block, run, pull_request["number"])))

    purge = [entry["github-environment"] for entry in entries if _commenting(entry) and entry["verdict"] == "skip"]
    gc = [{"marker-prefix": f"<!-- tf:tag:{kind}:{name}:", "keep-marker-substring": ""}
          for name in purge for kind in TAG_KINDS]
    return {"heads": heads, "purge_tags_for": purge, "gc": gc}
