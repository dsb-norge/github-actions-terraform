"""Which run attempt of each artifact file a job reads after a re-run (docs/Re-run-attempts.md §4).

The rule of the newest-attempt command: the names of the files every attempt left, in; the file to
read for each name, out. A re-run keeps the earlier attempts' artifacts and a re-run job uploads its
own, so each name ends in the attempt that wrote it (D1), and the newest attempt is read (D2).
"""

import re

# `-attempt-<n>` ends the name, before one extension if it has one; n counts from 1, without zeros in front.
ATTEMPT = re.compile(r"(?P<name>.+)-attempt-(?P<attempt>[1-9][0-9]*)(?P<extension>\.[^.]*)?")


def split(file_name):
    """(the name without its attempt, the attempt); a name without one is attempt 0 (D6)."""
    match = ATTEMPT.fullmatch(file_name)
    if match is None:
        return file_name, 0
    return match["name"] + (match["extension"] or ""), int(match["attempt"])


def choose(file_names, min_attempt=0):
    """The newest attempt of each name, of the attempts from `min_attempt` on (D7).

    {"keep": [{"name", "file", "attempt", "found"}], by name, "found" every attempt of it from the
    minimum on; "below": [{"file", "attempt"}], by file, the files left out under the minimum}.
    """
    found, below = {}, []
    for file_name in file_names:
        name, attempt = split(file_name)
        if attempt < min_attempt:
            below.append({"file": file_name, "attempt": attempt})
        else:
            found.setdefault(name, {})[attempt] = file_name
    keep = []
    for name in sorted(found):
        newest = max(found[name])
        keep.append({"name": name, "file": found[name][newest], "attempt": newest, "found": sorted(found[name])})
    return {"keep": keep, "below": sorted(below, key=lambda entry: entry["file"])}
