"""The newest-attempt step: the files every attempt's artifacts left, in; the newest of each, out.

Adapter side (docs/Re-run-attempts.md §5): lists the directory the download-newest-attempt action
downloaded into, asks attempts.choose which file of each name to read, and writes it under its name,
where the readers' patterns look. A file name is shown through Log.verbatim, never run as a
workflow command.
"""

import os
import shutil

from . import attempts, workflow

TITLE = "download-newest-attempt"
EXIT_OK, EXIT_FAULT = 0, 1


def _listing(from_dir):
    """The download's file names and directory names; a download that never happened has neither."""
    try:
        entries = sorted(os.listdir(from_dir))
    except FileNotFoundError:
        entries = []
    files = [entry for entry in entries if not os.path.isdir(os.path.join(from_dir, entry))]
    return files, [entry for entry in entries if entry not in files]


def run(from_dir, to_dir, min_attempt_text, stream):
    """The step: 0 with the chosen files written to `to_dir`; 1 on a fault."""
    log = workflow.Log(stream, TITLE)
    if min_attempt_text and not (min_attempt_text.isascii() and min_attempt_text.isdigit()):
        log.error(f"min-attempt is '{min_attempt_text}', not an attempt number")
        return EXIT_FAULT
    min_attempt = int(min_attempt_text or "0")
    try:
        files, directories = _listing(from_dir)
    except OSError as error:
        log.error(f"the downloaded files cannot be listed: {error}")
        return EXIT_FAULT
    for directory in directories:
        log.warning(f"{directory} is a directory, not an artifact's file; it is left out (docs/Re-run-attempts.md §5)")
    chosen = attempts.choose(files, min_attempt)
    os.makedirs(to_dir, exist_ok=True)
    lines = []
    for entry in chosen["keep"]:
        try:
            shutil.copyfile(os.path.join(from_dir, entry["file"]), os.path.join(to_dir, entry["name"]))
        except OSError as error:
            log.error(f"{entry['name']} cannot be written: {error}")
            return EXIT_FAULT
        lines.append(f"{entry['name']}: attempt {entry['attempt']} (found {', '.join(map(str, entry['found']))})")
    for entry in chosen["below"]:
        lines.append(f"{entry['file']}: left out, attempt {entry['attempt']} is before attempt {min_attempt}")
    if lines:
        log.verbatim("\n".join(lines))
    else:
        log.line("No artifact file was downloaded.")
    return EXIT_OK
