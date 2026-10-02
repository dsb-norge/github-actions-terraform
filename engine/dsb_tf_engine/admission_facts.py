"""The admission's facts: what the create-matrix adapter gathers for a Dependabot pull request.

docs/Dependabot-admission.md §8. The change is read through git between the merge commit the run checks
out and its first parent, so what is judged is exactly what every job runs; the registry and GitHub answer
for each dependency it changes. A fact that cannot be gathered raises FactError, which fails the step
(D11); content that cannot be interpreted is reported as such, for the engine to refuse (D12).
"""

import base64
import datetime
import difflib
import json
import os
import re
import tempfile
import time

from . import admission, hashicorp

REGISTRY_API = "https://registry.terraform.io/v1"
LOCK_NAME = ".terraform.lock.hcl"
# Any other letter (a type change, an unmerged path) is "changed"; a mode change on M is too.
STATUSES = {"M": "modified", "A": "added", "D": "removed", "R": "renamed", "C": "added"}
LOCK_BLOCK = re.compile(r'^provider\s+"([^"]+)"\s*\{(.*?)^\}', re.M | re.S)
LOCK_ATTRIBUTE = re.compile(r'^\s*(version|constraints)\s*=\s*"([^"]*)"', re.M)
LOCK_HASH = re.compile(r'"((?:h1|zh):[^"]+)"')
CURL = ("curl", "--fail", "--silent", "--show-error", "--location", "--max-time", "20", "--retry", "1")
CLASSES = {"official": "signed by HashiCorp", "partner": "signed by a HashiCorp partner", "self": "self-signed"}
# A registry module source, optionally with the registry's host.
REGISTRY_SOURCE = re.compile(r"(?:registry\.terraform\.io/)?([A-Za-z0-9][A-Za-z0-9_-]*)/([A-Za-z0-9][A-Za-z0-9_-]*)/"
                             r"([a-z0-9]+)")
# A GitHub source in the forms Terraform accepts, with an optional subdirectory and query.
GITHUB_SOURCE = re.compile(r"(?:git::https://github\.com/|git::ssh://git@github\.com/|git@github\.com:|github\.com/)"
                           r"([A-Za-z0-9][A-Za-z0-9_.-]*)/([A-Za-z0-9_.-]+?)(?:\.git)?(?://[^?]*)?(?:\?(.*))?")


class FactError(Exception):
    """A fact the admission needs could not be gathered: the step fails, naming it (D11)."""


def _run(tools, argv, what):
    try:
        code, stdout, stderr = tools.run(argv)
    except OSError as error:
        raise FactError(f"{what}: '{argv[0]}' cannot be run on this runner: {error}") from None
    if code != 0:
        raise FactError(f"{what}: {(stderr or stdout).strip()[:300]}")
    return stdout


def _json(text, what):
    try:
        return json.loads(text)
    except ValueError:
        raise FactError(f"{what}: the answer is not JSON") from None


def _field(answer, key, kind, what):
    value = answer.get(key) if isinstance(answer, dict) else None
    if not isinstance(value, kind) or isinstance(value, bool):
        raise FactError(f"{what}: the answer has no '{key}'")
    return value


def _epoch(text, what):
    """A time with its zone as epoch seconds. A time without one would be read in the runner's zone, so it is
    refused rather than guessed."""
    try:
        moment = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        raise FactError(f"{what}: '{text}' is not a time") from None
    if moment.tzinfo is None:
        raise FactError(f"{what}: '{text}' has no time zone")
    return int(moment.timestamp())


# The change.

def changed_files(tools):
    """(path, status, base path) of every file the merge commit changes against its first parent."""
    stdout = _run(tools, ("git", "diff", "--raw", "-z", "-M", "HEAD^1", "HEAD"), "the pull request's change")
    fields, files = iter(stdout.split("\0")), []
    # Each entry is its metadata, its path, and a second path for a rename or a copy; the output ends in a NUL,
    # which leaves an empty field last.
    entry = next(fields)
    while entry:
        meta = entry.lstrip(":").split()
        letter = meta[4][0]
        old_path = next(fields)
        path = next(fields) if letter in "RC" else old_path
        status = STATUSES.get(letter, "changed")
        if status == "modified" and meta[0] != meta[1]:
            status = "changed"
        files.append((path, status, old_path))
        entry = next(fields)
    return files


def _show(tools, revision, path):
    return _run(tools, ("git", "show", f"{revision}:{path}"), f"the content of '{path}' at {revision}")


def parse_lock_blocks(text):
    """A lock file's provider blocks (version, constraints, hashes), or None when it is not one."""
    blocks = {}
    for address, body in LOCK_BLOCK.findall(text):
        attributes = dict(LOCK_ATTRIBUTE.findall(body))
        if "version" not in attributes:
            return None
        blocks[address] = {"version": attributes["version"], "constraints": attributes.get("constraints"),
                           "hashes": LOCK_HASH.findall(body)}
    return blocks if blocks or not text.strip() else None


def line_changes(old, new):
    """The changed lines, one {"old", "new"} per line: replaced lines paired, added or removed ones alone."""
    a, b = old.splitlines(), new.splitlines()
    changes = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag == "equal":
            continue
        olds, news = a[i1:i2], b[j1:j2]
        for index in range(max(len(olds), len(news))):
            changes.append({"old": olds[index] if index < len(olds) else None,
                            "new": news[index] if index < len(news) else None})
    return changes


# Where a changed line of a .tf file belongs.

_TOKEN = re.compile(r'"(?:[^"\\]|\\.)*"|#[^\n]*|//[^\n]*|/\*.*?\*/|<<-?([A-Za-z_][A-Za-z0-9_]*)\n.*?^\s*\1$|[{}]|\n',
                    re.S | re.M)
_MODULE = re.compile(r'module\s+"([^"]+)"\s*$')
_ENTRY = re.compile(r'([A-Za-z0-9_-]+)\s*=\s*$')
# An argument starts a line, or follows a comma or the brace in an object written on one line; it never spans
# lines, so where its match starts is its line.
_STRING = re.compile(r'(?:^|[,{])[ \t]*(source|version)[ \t]*=[ \t]*"([^"]*)"', re.M)


def _opens(text):
    """(line number, header before the brace, line of the closing brace) of every block and object."""
    stack, spans, line, start = [], [], 1, 0
    for match in _TOKEN.finditer(text):
        token = match.group(0)
        if token == "{":
            stack.append((line, text[start:match.start()].strip(), match.end()))
        elif token == "}" and stack:
            opened, header, body = stack.pop()
            spans.append((opened, header, line, text[body:match.start()]))
        else:
            # A newline, a comment, a heredoc or a string. A header is what follows the last newline, comment or
            # heredoc on its line; a quoted label is part of it.
            line += token.count("\n")
            if token[0] != '"':
                start = match.end()
    return spans


def dependency_lines(text):
    """{line number of a `version` or `source` argument: (kind, name, source, version)} for every module block and
    required_providers entry, so a changed line can be traced to its dependency."""
    found = {}
    for opened, header, closed, body in _opens(text):
        module = _MODULE.fullmatch(header)
        entry = _ENTRY.fullmatch(header)
        if not module and not entry:
            continue
        values = {}
        offset = opened
        for match in _STRING.finditer(body):
            values[match.group(1)] = (match.group(2), offset + body.count("\n", 0, match.start()))
        if module or "source" in values:
            kind = "module" if module else "provider"
            name = module.group(1) if module else entry.group(1)
            source = values["source"][0] if "source" in values else ""
            version = values["version"][0] if "version" in values else ""
            for _, number in values.values():
                found[number] = (kind, name, source, version)
    return found


def classify_source(source):
    """(source kind, namespace or owner, name, ref) of a module source."""
    github = GITHUB_SOURCE.fullmatch(source)
    if github:
        query = dict(part.partition("=")[::2] for part in (github.group(3) or "").split("&"))
        return "github", github.group(1), github.group(2), query.get("ref", "")
    registry = REGISTRY_SOURCE.fullmatch(source)
    if registry:
        return "registry", registry.group(1), registry.group(2), ""
    return "other", "", "", ""


def provider_address(source):
    """A required_providers source as a lock file writes it."""
    return f"{admission.REGISTRY}/{source}" if source.count("/") == 1 else source


# The registry and GitHub.

def _registry(tools, path, what):
    return _json(_run(tools, (*CURL, f"{REGISTRY_API}/{path}"), what), what)


def provider_versions(tools, address):
    _, namespace, name = address.split("/")
    what = f"the versions of provider {namespace}/{name}"
    answer = _registry(tools, f"providers/{namespace}/{name}/versions", what)
    versions = answer.get("versions") if isinstance(answer, dict) else None
    if not isinstance(versions, list):
        raise FactError(f"{what}: the answer has no 'versions'")
    return [item["version"] for item in versions if isinstance(item, dict) and isinstance(item.get("version"), str)]


def module_versions(tools, namespace, name, provider):
    what = f"the versions of module {namespace}/{name}/{provider}"
    answer = _registry(tools, f"modules/{namespace}/{name}/{provider}/versions", what)
    modules = answer.get("modules") if isinstance(answer, dict) else None
    if not isinstance(modules, list) or not modules or not isinstance(modules[0], dict):
        raise FactError(f"{what}: the answer has no 'modules'")
    return [item["version"] for item in modules[0].get("versions", [])
            if isinstance(item, dict) and isinstance(item.get("version"), str)]


def _vouched(tools, key):
    """Whether HashiCorp vouches for a signing key, and Terraform's class for it (P18)."""
    if key.get("key_id") == hashicorp.HASHICORP_KEY_ID:
        return True, CLASSES["official"]
    signature = key.get("trust_signature") or ""
    if not signature:
        return False, CLASSES["self"]
    armour = key.get("ascii_armor") or ""
    lines = armour.partition("\n\n")[2].partition("-----END")[0].splitlines()
    try:
        body = base64.b64decode("".join(line for line in lines if line and not line.startswith("=")))
    except ValueError:
        return False, CLASSES["self"] + " (an unreadable key)"
    with tempfile.TemporaryDirectory() as home:
        key_file, signature_file, partners = (os.path.join(home, name) for name in ("key.bin", "trust.asc",
                                                                                     "partners.asc"))
        with open(key_file, "wb") as handle:
            handle.write(body)
        with open(signature_file, "w", encoding="utf-8") as handle:
            handle.write(signature)
        with open(partners, "w", encoding="utf-8") as handle:
            handle.write(hashicorp.HASHICORP_PARTNERS_KEY)
        _run(tools, ("gpg", "--homedir", home, "--batch", "--quiet", "--import", partners), "HashiCorp's partner key")
        code, _, _ = tools.run(("gpg", "--homedir", home, "--batch", "--quiet", "--verify", signature_file, key_file))
    return (True, CLASSES["partner"]) if code == 0 else (False, CLASSES["self"] + " (a trust signature that does "
                                                                                  "not verify)")


def _signing(tools, namespace, name, version):
    what = f"the signing keys of provider {namespace}/{name} {version}"
    answer = _registry(tools, f"providers/{namespace}/{name}/{version}/download/linux/amd64", what)
    signing = answer.get("signing_keys") if isinstance(answer, dict) else None
    keys = signing.get("gpg_public_keys") if isinstance(signing, dict) else None
    if not isinstance(keys, list) or not keys or not all(isinstance(key, dict) and isinstance(key.get("key_id"), str)
                                                        for key in keys):
        raise FactError(f"{what}: the answer has no 'signing_keys'")
    return keys, _field(answer, "shasums_url", str, what)


def provider_facts(tools, address, old, new, zh):
    _, namespace, name = address.split("/")
    what = f"provider {namespace}/{name} {new}"
    published = _epoch(_field(_registry(tools, f"providers/{namespace}/{name}/{new}", what), "published_at", str,
                              what), what)
    keys_from, _ = _signing(tools, namespace, name, old)
    keys_to, shasums_url = _signing(tools, namespace, name, new)
    vouched_to, class_to = _vouched(tools, keys_to[0])
    _, class_from = _vouched(tools, keys_from[0])
    shasums = []
    if zh:
        text = _run(tools, (*CURL, shasums_url), f"the checksums of {what}")
        shasums = [line.split()[0] for line in text.splitlines() if line.strip()]
    return {"published": published, "keys_from": [key["key_id"] for key in keys_from],
            "keys_to": [key["key_id"] for key in keys_to], "vouched": vouched_to, "class_from": class_from,
            "class_to": class_to, "zh": zh, "shasums": shasums}


def module_facts(tools, kind, namespace, name, provider, version):
    if kind == "registry":
        what = f"module {namespace}/{name}/{provider} {version}"
        answer = _registry(tools, f"modules/{namespace}/{name}/{provider}/{version}", what)
        return {"published": _epoch(_field(answer, "published_at", str, what), what)}
    if kind != "github":
        return {"published": None}
    what = f"the release of {namespace}/{name} {version}"
    try:
        code, stdout, stderr = tools.run(("gh", "api", f"repos/{namespace}/{name}/releases/tags/{version}"))
    except OSError as error:
        raise FactError(f"{what}: 'gh' cannot be run on this runner: {error}") from None
    if code != 0:
        if "HTTP 404" in stderr:
            return {"published": None}
        raise FactError(f"{what}: {(stderr or stdout).strip()[:300]}")
    return {"published": _epoch(_field(_json(stdout, what), "published_at", str, what), what)}


# Putting it together.

def _merge(dependencies, dependency, path):
    """One dependency per address and versions, listing every file it is changed in (a grouped pull request)."""
    key = (dependency["address"], dependency["from"], dependency["to"])
    if key in dependencies:
        dependencies[key]["files"].append(path)
    else:
        dependencies[key] = {**dependency, "files": [path]}


def _module_version(tools, kind, namespace, name, provider, constraint):
    """The exact version a module's `version` argument selects: itself when exact, else the newest it allows."""
    exact = re.fullmatch(r"=?\s*v?(\d+\.\d+\.\d+\S*)", constraint.strip())
    if exact or kind != "registry":
        return exact.group(1) if exact else constraint
    return admission.newest_allowed(constraint, module_versions(tools, namespace, name, provider)) or constraint


def _tf_dependencies(tools, path, old_text, new_text, locked_dirs, dependencies):
    """Each changed line traced to its dependency; returns the version-only changes no dependency explains, which
    the engine refuses rather than admitting a change it did not judge (§4.1)."""
    directory = path.rpartition("/")[0] or "."
    old_lines, new_lines = dependency_lines(old_text), dependency_lines(new_text)
    a, b = old_text.splitlines(), new_text.splitlines()
    unmapped = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag != "replace" or i2 - i1 != j2 - j1:
            continue  # an added or removed line is refused by its shape
        for offset in range(i2 - i1):
            before, after = old_lines.get(i1 + offset + 1), new_lines.get(j1 + offset + 1)
            if before is None or after is None or before[:2] != after[:2]:
                if admission.normalised(a[i1 + offset]) == admission.normalised(b[j1 + offset]):
                    unmapped.append(b[j1 + offset])
                continue
            kind, _, source, version = after
            if kind == "provider":
                if directory in locked_dirs:
                    continue  # its lock records what runs, and the lock's own change is judged (§4.2)
                address = provider_address(source)
                versions = provider_versions(tools, address)
                old = admission.newest_allowed(before[3], versions) or before[3]
                new = admission.newest_allowed(version, versions) or version
                if old == new:
                    continue  # init installs what it installed before: nothing new runs
                _merge(dependencies, {"kind": "provider", "address": address, "from": old, "to": new, "locked": False,
                                      "zh": []}, path)
                continue
            source_kind, namespace, name, ref = classify_source(source)
            _, _, _, old_ref = classify_source(before[2])
            provider = ""
            if source_kind == "registry":
                provider = REGISTRY_SOURCE.fullmatch(source).group(3)
                old = _module_version(tools, source_kind, namespace, name, provider, before[3])
                new = _module_version(tools, source_kind, namespace, name, provider, version)
            else:
                old, new = old_ref or before[3], ref or version
            _merge(dependencies, {"kind": "module", "address": source, "from": old, "to": new,
                                  "source_kind": source_kind, "namespace": namespace, "name": name,
                                  "provider": provider}, path)
    return unmapped


def gather(tools, now=None):
    """The `admission` facts of the input document (docs/Dependabot-admission.md §8)."""
    locks = [path for path in _run(tools, ("git", "ls-files", "-z", "--", f"*{LOCK_NAME}", LOCK_NAME),
                                   "the committed lock files").split("\0") if path]
    locked_dirs = {path.rpartition("/")[0] or "." for path in locks}
    files, dependencies = [], {}
    for path, status, old_path in changed_files(tools):
        kind = "lock" if path.endswith(LOCK_NAME) else ("tf" if path.endswith(".tf") else "other")
        if status != "modified" or kind == "other":
            # Only a modified .tf or lock file can be Dependabot's (§4.1); the engine refuses the rest by its status.
            files.append({"path": path, "status": status, "kind": "other"})
            continue
        old_text, new_text = _show(tools, "HEAD^1", old_path), _show(tools, "HEAD", path)
        if kind == "tf":
            unmapped = _tf_dependencies(tools, path, old_text, new_text, locked_dirs, dependencies)
            files.append({"path": path, "status": status, "kind": kind, "lines": line_changes(old_text, new_text),
                          "unmapped": unmapped})
            continue
        before, after = parse_lock_blocks(old_text), parse_lock_blocks(new_text)
        files.append({"path": path, "status": status, "kind": kind, "before": before, "after": after})
        for address in sorted(set(before or {}) & set(after or {})):
            if before[address]["version"] != after[address]["version"]:
                zh = [value[3:] for value in after[address]["hashes"] if value.startswith("zh:")]
                _merge(dependencies, {"kind": "provider", "address": address, "from": before[address]["version"],
                                      "to": after[address]["version"], "locked": True, "zh": zh}, path)
    gathered = []
    for dependency in dependencies.values():
        if dependency["kind"] == "provider":
            parts = dependency["address"].split("/")
            on_registry = len(parts) == 3 and parts[0] == admission.REGISTRY
            # Another host fails the engine's host check; there is nothing to ask the registry.
            facts = (provider_facts(tools, dependency["address"], dependency["from"], dependency["to"], dependency["zh"])
                     if on_registry else {"published": None, "keys_from": [], "keys_to": [], "vouched": False,
                                          "class_from": "", "class_to": "", "zh": [], "shasums": []})
            gathered.append({key: dependency[key] for key in ("kind", "address", "from", "to", "files", "locked")}
                            | {"facts": facts})
        else:
            facts = module_facts(tools, dependency["source_kind"], dependency["namespace"], dependency["name"],
                                 dependency["provider"], dependency["to"])
            gathered.append({key: dependency[key] for key in ("kind", "address", "from", "to", "files", "source_kind",
                                                             "namespace", "name")} | {"facts": facts})
    return {"now": int(time.time()) if now is None else now, "files": files,
            "dependencies": sorted(gathered, key=lambda item: (item["kind"], item["address"], item["to"])),
            "locks": {directory: True for directory in sorted(locked_dirs)}}
