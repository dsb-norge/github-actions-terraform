"""The facts of a module pull request's auto-merge: its commits and their files (docs/Module-auto-merge.md §4).

Adapter side: it calls gh. A call that fails is a fact, `available: false`, never an error: the engine then
rules the run not eligible, and the run goes on (M11).
"""

import json

# GitHub lists at most 250 commits of a pull request, 100 a page, and at most 3000 files of a commit, 300 a page.
COMMITS_PER_PAGE, COMMIT_PAGES = 100, 3
FILES_PER_PAGE, FILE_PAGES = 300, 10
ERROR_CAP = 300


class _Unanswered(Exception):
    """A listing that did not answer as it should."""


def _api(tools, endpoint):
    try:
        code, stdout, stderr = tools.run(("gh", "api", endpoint))
    except OSError as error:
        raise _Unanswered(f"'gh' cannot be run on this runner: {error}") from None
    if code != 0:
        raise _Unanswered(f"gh api {endpoint} failed: {(stderr or stdout).strip()[:ERROR_CAP]}")
    try:
        return json.loads(stdout)
    except ValueError:
        raise _Unanswered(f"gh api {endpoint} did not answer with JSON") from None


def _login(account):
    """The login of a commit's author or committer, or None where GitHub resolved no account."""
    login = account.get("login") if isinstance(account, dict) else None
    return login if isinstance(login, str) else None


def _commit(endpoint, entry):
    """One listed commit as the engine reads it; its files come from their own listing."""
    commit = entry.get("commit") if isinstance(entry, dict) else None
    verification = commit.get("verification") if isinstance(commit, dict) else None
    if not (isinstance(verification, dict) and isinstance(entry.get("sha"), str) and isinstance(entry.get("parents"), list)
            and isinstance(commit.get("message"), str) and isinstance(verification.get("verified"), bool)):
        raise _Unanswered(f"gh api {endpoint} answered a commit without its SHA, parents, message or verification")
    # The subject line: the rule compares a docs commit's with the docs job's (docs/Module-auto-merge.md §3).
    return {"sha": entry["sha"], "parents": len(entry["parents"]), "author": _login(entry.get("author")),
            "committer": _login(entry.get("committer")), "verified": verification["verified"],
            "message": commit["message"].partition("\n")[0]}


def _commits(tools, repository, number):
    """The listed commits; a listing GitHub cut short at its cap the engine refuses by their count."""
    commits = []
    for page in range(1, COMMIT_PAGES + 1):
        endpoint = f"repos/{repository}/pulls/{number}/commits?per_page={COMMITS_PER_PAGE}&page={page}"
        entries = _api(tools, endpoint)
        if not isinstance(entries, list):
            raise _Unanswered(f"gh api {endpoint} answered without a list of commits")
        commits += [_commit(endpoint, entry) for entry in entries]
        if len(entries) < COMMITS_PER_PAGE:
            break
    return commits


def _file(endpoint, entry):
    if not (isinstance(entry, dict) and isinstance(entry.get("filename"), str) and isinstance(entry.get("status"), str)
            and isinstance(entry.get("previous_filename", ""), str)):
        raise _Unanswered(f"gh api {endpoint} answered a file without its name and status")
    return {"name": entry["filename"], "status": entry["status"], "previous": entry.get("previous_filename")}


def _files(tools, repository, sha):
    """A commit's files, and whether GitHub may have cut the listing short: every page it lists was full."""
    files = []
    for page in range(1, FILE_PAGES + 1):
        endpoint = f"repos/{repository}/commits/{sha}?per_page={FILES_PER_PAGE}&page={page}"
        answer = _api(tools, endpoint)
        entries = answer.get("files") if isinstance(answer, dict) else None
        if not isinstance(entries, list):
            raise _Unanswered(f"gh api {endpoint} answered without a list of files")
        files += [_file(endpoint, entry) for entry in entries]
        if len(entries) < FILES_PER_PAGE:
            return files, False
    return files, True


def gather(tools, repository, payload):
    """The pull request's commits, each with its files, and what the event says of its head branch and size."""
    pull_request = payload.get("pull_request") if isinstance(payload, dict) else None
    head = pull_request.get("head") if isinstance(pull_request, dict) else None
    head_ref = head.get("ref") if isinstance(head, dict) else None
    count = pull_request.get("commits") if isinstance(pull_request, dict) else None
    if not isinstance(head_ref, str) or isinstance(count, bool) or not isinstance(count, int) or count < 0:
        return {"available": False, "reason": "the event names no head branch and commit count", "head_ref": "",
                "count": 0, "commits": []}
    try:
        commits = _commits(tools, repository, pull_request["number"])
        for commit in commits:
            commit["files"], commit["files_truncated"] = _files(tools, repository, commit["sha"])
    except _Unanswered as error:
        return {"available": False, "reason": str(error), "head_ref": head_ref, "count": count, "commits": []}
    return {"available": True, "reason": None, "head_ref": head_ref, "count": count, "commits": commits}
