"""The one glob matcher: the grammar of docs/Terraform-tests.md §4.4.

Paths are repository-relative and `/`-separated, without a leading `./`. `*` matches any run of
characters within one segment, `?` one such character, `**` any number of whole segments including
none; a pattern without a `/` matches the basename, unless a leading `/` or `./` anchors it at the
root, as a leading `/` does in `.gitignore`. No negation, character classes or braces: bash and
fnmatch would each do something different with them, so they are refused rather than guessed.
"""

import re


class GlobError(Exception):
    """A pattern outside the grammar."""


class Glob:
    """A compiled pattern: the normalised text, and a matcher for repository-relative paths."""

    def __init__(self, pattern, regex, basename):
        self.pattern = pattern
        self._regex = regex
        self._basename = basename

    def matches(self, path):
        subject = path.rpartition("/")[2] if self._basename else path
        return self._regex.fullmatch(subject) is not None


def _refuse(pattern, reason):
    raise GlobError(f"the pattern {pattern!r} is not supported: {reason}")


def compile_glob(pattern):
    """Validate a pattern and compile it, or raise GlobError naming what is wrong."""
    if not isinstance(pattern, str):
        raise GlobError(f"the pattern {pattern!r} is not a string")
    original = pattern
    anchored = pattern.startswith(("/", "./"))
    pattern = pattern.removeprefix(".").removeprefix("/") if anchored else pattern
    if not pattern:
        _refuse(original, "it is empty")
    if pattern.startswith("!"):
        _refuse(original, "negation; use paths-ignore")
    if "[" in pattern or "]" in pattern:
        _refuse(original, "character classes")
    if "{" in pattern or "}" in pattern:
        _refuse(original, "braces")

    segments = pattern.split("/")
    parts = []
    for index, segment in enumerate(segments):
        if segment == "":
            _refuse(original, "an empty segment")
        if segment in (".", ".."):
            _refuse(original, "'.' or '..' segments")
        if "**" in segment and segment != "**":
            _refuse(original, "'**' must be a whole segment")
        last = index == len(segments) - 1
        if segment == "**":
            # Any number of whole segments: before another segment it may be none of them.
            parts.append(".*" if last else "(?:.*/)?")
            continue
        parts.append("".join("[^/]*" if c == "*" else "[^/]" if c == "?" else re.escape(c) for c in segment))
        if not last:
            parts.append("/")
    # The anchor only matters where the basename rule would apply; elsewhere a pattern is anchored
    # already, and dropping the prefix lets equal patterns compare equal. `**` alone matches every
    # path either way.
    root_only = anchored and len(segments) == 1 and pattern != "**"
    return Glob(f"/{pattern}" if root_only else pattern, re.compile("".join(parts)),
                basename=len(segments) == 1 and not anchored)


def first_match(globs, path):
    """The text of the first pattern that matches the path, or None."""
    for glob in globs:
        if glob.matches(path):
            return glob.pattern
    return None
