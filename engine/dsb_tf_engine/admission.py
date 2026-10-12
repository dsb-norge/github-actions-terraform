"""The Dependabot admission: rule 3a of docs/Decision-engine.md §6, specified in docs/Dependabot-admission.md.

A run whose actor is Dependabot executes Terraform only when every dependency its pull request changes
passes the checks below. The facts (the change, the registry's and GitHub's answers, the time of the
run) are gathered by the adapter and arrive as `admission` in the input document; this module judges
them and reads nothing else, so times are epoch seconds and the clock is a fact.
"""

import re

from .environments import ConfigError, shown

DEPENDABOT = "dependabot[bot]"
SWITCH = "dependabot-admission-enabled"
POLICY = "dependabot-admission-yml"
INPUTS = (SWITCH, POLICY)
POLICY_KEYS = ("allow", "hold", "min-age-days", "min-age-exempt")
KEYS_TEXT = "allow, hold, min-age-days and min-age-exempt"
HOLD_KEYS = ("provider", "module", "versions", "reason")
HOLD_SHAPE = "provider or module, versions and reason"
# docs/Dependabot-admission.md D6 and D7: the publishers the organisation trusts, and its own namespace.
BUILT_IN_ALLOW = ("dsb-norge", "hashicorp", "microsoft", "Azure")
BUILT_IN_EXEMPT = ("dsb-norge",)
DEFAULT_MIN_AGE_DAYS = 3
MAX_MIN_AGE_DAYS = 90
ENTRY = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*(/[A-Za-z0-9][A-Za-z0-9_.-]*)?")
REFUSED = "admission: not admitted"
PUSH_RUN = "admission: Dependabot push run"
PUSH_NOTICE = "admission: a Dependabot push run runs nothing; its pull request's run judges the change"
REGISTRY = "registry.terraform.io"
DAY = 86400
HOUR = 3600
# What a version constraint, an exact version and a git ref look like in a line Dependabot rewrote.
VERSION_ARGUMENT = re.compile(r'(\bversion\s*=\s*)"[^"]*"')
REF_ARGUMENT = re.compile(r"([?&]ref=)[^\"&\s]+")
FILE_KINDS = ("tf", "lock")


def _kind(value):
    if isinstance(value, bool):
        return "a boolean"
    if isinstance(value, (int, float)):
        return "a number"
    if isinstance(value, dict):
        return "a mapping"
    return "a list" if isinstance(value, list) else "a string"


def _entries(name, value, errors):
    """A policy list: a string written alone is its one item (as the list settings elsewhere). Every item is
    checked; a list with a mistake is never used, since the mistake is raised."""
    items = [value] if isinstance(value, str) else value
    if not isinstance(items, list):
        errors.append(f"{POLICY}: {name} must be a list of namespaces; it holds {_kind(value)}.")
        items = []
    for item in items:
        if not isinstance(item, str) or not ENTRY.fullmatch(item):
            errors.append(f"{POLICY}: {name} holds {shown(item)}, which is not a namespace or namespace/name, for "
                          "example 'elastic' or 'cyrilgdn/postgresql'.")
    return items


def settings(document, default_enabled):
    """The switch and the policy in effect, or a ConfigError with every mistake (D13, §6).

    Validated on every event, so a mistake shows on the pull request that makes it.
    """
    errors = []
    switch = document["workflow_inputs"].get(SWITCH, default_enabled)
    # Compared by identity: 1 == True, and 1 is not a boolean.
    if switch is not True and switch is not False and switch not in ("true", "false"):
        errors.append(f"The input '{SWITCH}' is {shown(switch)}; it must be true or false!")
    result = document["yaml"]["inputs"].get(POLICY, {"ok": True, "value": None})
    policy = result["value"]
    if not result["ok"]:
        errors.append(f"The specification for input '{POLICY}' is not valid yaml!")
        policy = {}
    elif policy in (None, ""):
        policy = {}
    elif not isinstance(policy, dict):
        errors.append(f"{POLICY} must be a mapping with the keys {KEYS_TEXT}; it holds {_kind(policy)}.")
        policy = {}
    for key in sorted(policy, key=str):
        if key not in POLICY_KEYS:
            errors.append(f"{POLICY} holds the unknown key {shown(key)}; the keys are {KEYS_TEXT}.")
    allow = _entries("allow", policy.get("allow", []), errors)
    exempt = _entries("min-age-exempt", policy.get("min-age-exempt", []), errors)
    days = policy.get("min-age-days", DEFAULT_MIN_AGE_DAYS)
    if isinstance(days, bool) or not isinstance(days, int) or not 0 <= days <= MAX_MIN_AGE_DAYS:
        errors.append(f"{POLICY}: min-age-days must be a whole number from 0 to {MAX_MIN_AGE_DAYS}; it holds "
                      f"{shown(days)}.")
    holds = _holds(policy.get("hold"), errors)
    # D29: a hold the admission never applies would hold nothing, silently. An empty one sets nothing.
    if policy.get("hold") not in (None, []) and (switch is False or switch == "false"):
        errors.append(f"{POLICY} sets hold, but the Dependabot admission is off, so no hold is applied. Switch "
                      f"{SWITCH} on, or remove hold.")
    if errors:
        raise ConfigError(errors)
    return {"enabled": switch is True or switch == "true", "allow": [*BUILT_IN_ALLOW, *allow],
            "exempt": [*BUILT_IN_EXEMPT, *exempt], "min_age_days": days, "holds": holds}


# Holds (docs/Dependabot-admission.md §4.6): what a hold names, and the versions it keeps out.

_NAME = r"[A-Za-z0-9][A-Za-z0-9_-]*"
_REST = r"((?://[^?]*)?(?:\?.*)?)"
HOLD_PROVIDER = re.compile(rf"(?:(?i:registry\.terraform\.io)/)?({_NAME})/({_NAME})")
HOLD_REGISTRY = re.compile(rf"(?:(?i:registry\.terraform\.io)/)?({_NAME})/({_NAME})/([A-Za-z0-9]+){_REST}")
HOLD_GITHUB = re.compile(r"(?i:git::https://github\.com/|git::ssh://git@github\.com/|git@github\.com:|github\.com/)"
                         rf"([A-Za-z0-9][A-Za-z0-9_.-]*)/([A-Za-z0-9_.-]+){_REST}")
_HOLD_CONDITION = re.compile(r"\s*(=|!=|>=|<=|>|<|~>)?\s*(\d+(?:\.\d+){0,2})\s*")
# A version a hold can compare: a release, or a pre-release, with its three numbers written.
_COMPARABLE = re.compile(r"v?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?")


def _github_repository(owner, repository):
    """A GitHub module's package, `.git` dropped without case, as a hold names it."""
    return f"github.com/{owner}/{repository[:-4] if repository.casefold().endswith('.git') else repository}"


def _module_package(name):
    """(the package as a hold names it, whether the name adds a subdirectory or a ref), or None."""
    if not isinstance(name, str):
        return None
    github = HOLD_GITHUB.fullmatch(name)
    if github:
        return _github_repository(github[1], github[2]), bool(github[3])
    registry = HOLD_REGISTRY.fullmatch(name)
    if registry:
        return f"{registry[1]}/{registry[2]}/{registry[3]}", bool(registry[4])
    return None


def _hold_key(kind, name, number, problems):
    """The key a hold matches dependencies by, or None with the problem added."""
    if kind == "provider":
        match = HOLD_PROVIDER.fullmatch(name) if isinstance(name, str) else None
        if match:
            return f"{match[1]}/{match[2]}".casefold()
        problems.append(f"{POLICY}: hold entry {number}: provider {shown(name)} is not a provider; a provider is "
                        "'<namespace>/<type>', for example 'hashicorp/azurerm'.")
        return None
    package = _module_package(name)
    if package is None:
        problems.append(f"{POLICY}: hold entry {number}: module {shown(name)} is not a module a hold can name; a "
                        "registry module is '<namespace>/<name>/<provider>', for example 'Azure/naming/azurerm', and a "
                        "GitHub module 'github.com/<owner>/<repo>'.")
        return None
    if package[1]:
        problems.append(f"{POLICY}: hold entry {number}: module {shown(name)} names a subdirectory or a ref; a hold "
                        f"names the package, {shown(package[0])}.")
        return None
    return package[0].casefold()


def hold_conditions(text):
    """A hold's range as (operator, version) conditions, or None when it is not a Terraform constraint of releases:
    every condition is read, where allows() stops at the first a version fails (P34)."""
    conditions = []
    for part in text.split(","):
        match = _HOLD_CONDITION.fullmatch(part)
        if match is None:
            return None
        conditions.append((match[1] or "", parse_version(match[2])))
    return conditions


def _covers(conditions, version):
    return all(_allows(op, bound, version) for op, bound in conditions)


def _satisfiable(conditions):
    """Whether some release satisfies the conditions. The smallest one that does is 0.0.0, a bound, or the release
    after a bound, so those are the only candidates to try."""
    candidates = [parse_version("0.0.0")]
    for _, (major, minor, patch, _, written) in conditions:
        candidates += [(major, minor, patch, "", written), (major, minor, patch + 1, "", written)]
    return any(_covers(conditions, release) for release in candidates)


def _versions_problem(label, entry):
    """What is wrong with a hold's versions, or None."""
    value = entry["versions"]
    if not isinstance(value, str):
        return (f"{POLICY}: {label} sets versions to {shown(value)}, which is not a string; write one constraint in "
                "quotes, for example '> 3.116.0'.")
    if not value.strip():
        return (f"{POLICY}: {label} sets versions to {shown(value)}, which names no version; write the versions "
                "Dependabot may not bring in, for example '> 3.116.0'.")
    conditions = hold_conditions(value)
    if conditions is None:
        return (f"{POLICY}: {label} sets versions to {shown(value)}, which is not a Terraform version constraint of "
                "releases, for example '> 3.116.0, < 4.12.0'.")
    if not _satisfiable(conditions):
        return f"{POLICY}: {label} sets versions to {shown(value)}, which no release satisfies."
    return None


def _hold(number, entry, errors):
    """One hold, read; None with every mistake added to errors."""
    if not isinstance(entry, dict):
        errors.append(f"{POLICY}: hold entry {number} must be a mapping with {HOLD_SHAPE}; it is {_kind(entry)}.")
        return None
    problems = [f"{POLICY}: hold entry {number} has the unknown key {shown(key)}; a hold has {HOLD_SHAPE}."
                for key in sorted(entry, key=str) if key not in HOLD_KEYS]
    kinds = [kind for kind in ("provider", "module") if kind in entry]
    key = None
    if len(kinds) == 1:
        key = _hold_key(kinds[0], entry[kinds[0]], number, problems)
    else:
        problems.append(f"{POLICY}: hold entry {number} must name either a provider or a module.")
    # Named by its position until its dependency reads, by its dependency after that.
    label = f"the hold on {kinds[0]} {shown(entry[kinds[0]])}" if key else f"hold entry {number}"
    if "versions" in entry:
        problem = _versions_problem(label, entry)
        if problem:
            problems.append(problem)
    else:
        problems.append(f"{POLICY}: {label} has no versions; write the versions Dependabot may not bring in, for "
                        "example '> 3.116.0'.")
    reason = entry.get("reason")
    if not isinstance(reason, str) or not reason.strip():
        problems.append(f"{POLICY}: {label} has no reason; say why the versions are held.")
    errors += problems
    if problems:
        return None
    return {"kind": kinds[0], "name": entry[kinds[0]], "key": key, "versions": entry["versions"],
            "conditions": hold_conditions(entry["versions"]), "reason": reason}


def _holds(value, errors):
    """The policy's holds; a list with a mistake is never used, since the mistake is raised."""
    if value is None:
        return []
    if not isinstance(value, list):
        errors.append(f"{POLICY}: hold must be a list of holds, each with {HOLD_SHAPE}; it is {_kind(value)}.")
        value = []
    # An entry with a mistake is None, and never used: the mistake is raised.
    return [_hold(number, entry, errors) for number, entry in enumerate(value, 1)]


def applies(document, policy):
    """Whether this run meets the admission (§3): Dependabot's own pull request or push, switch on."""
    event = document["event"]
    return policy["enabled"] and event.get("actor", "") == DEPENDABOT and event["name"] in ("pull_request", "push")


# Version constraints, read as Terraform reads them (§4.3). Shared with the adapter, which needs the version a
# constraint resolves to before it can ask the registry about it.

_VERSION = re.compile(r"v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?")
_CONSTRAINT = re.compile(r"\s*(=|!=|>=|<=|>|<|~>)?\s*(\S+)\s*")


def parse_version(text):
    """(major, minor, patch, pre-release, segments written), or None when it is not a version."""
    match = _VERSION.fullmatch(text.strip()) if isinstance(text, str) else None
    if not match:
        return None
    major, minor, patch, pre = match.groups()
    written = 1 + (minor is not None) + (patch is not None)
    return int(major), int(minor or 0), int(patch or 0), pre or "", written


def _key(version):
    major, minor, patch, pre, _ = version
    # A pre-release sorts below its release; pre-releases compare by their text, which is enough to order them.
    return major, minor, patch, pre == "", pre


def _allows(op, bound, version):
    key, limit = _key(version), _key(bound)
    if op == "" or op == "=":
        return key == limit
    if op == "!=":
        return key != limit
    if op == ">":
        return key > limit
    if op == ">=":
        return key >= limit
    if op == "<":
        return key < limit
    if op == "<=":
        return key <= limit
    # '~>': at least the bound, below the next release of the segment before the last one written. Only a release
    # reaches here (a pre-release is allowed by an exact constraint alone), and the next release ends in .0, so a
    # version's major and minor decide.
    major, minor, _, _, written = bound
    upper = (major + 1, 0) if written <= 2 else (major, minor + 1)
    return limit <= key and (version[0], version[1]) < upper


def allows(constraint, text):
    """Whether a constraint string allows a version string; None when either cannot be read."""
    version = parse_version(text)
    if version is None or not isinstance(constraint, str):
        return None
    parts = constraint.split(",") if constraint.strip() else []
    for part in parts:
        match = _CONSTRAINT.fullmatch(part)
        bound = parse_version(match.group(2)) if match else None
        if bound is None:
            return None
        op = match.group(1) or ""
        # A pre-release is allowed only by an exact constraint, which then has to name it.
        if version[3] and op != "" and op != "=":
            return False
        if not _allows(op, bound, version):
            return False
    return not version[3] or bool(parts)


def newest_allowed(constraint, versions):
    """The newest version string a constraint allows, None when none does or the constraint cannot be read."""
    allowed = [(parse_version(text), text) for text in versions if allows(constraint, text)]
    return max(allowed, key=lambda pair: _key(pair[0]))[1] if allowed else None


# The checks.

def _days(count):
    return f"{count} day{'' if count == 1 else 's'}"


def _age(published, now):
    age = now - published
    if age < DAY:
        hours = max(age // HOUR, 0)
        return f"{hours} hour{'' if hours == 1 else 's'}"
    return _days(age // DAY)


def civil(epoch):
    """An epoch second as 'YYYY-MM-DD HH:MM UTC', by days-from-civil inverted (H. Hinnant)."""
    days, seconds = divmod(epoch, DAY)
    era, day_of_era = divmod(days + 719468, 146097)
    year_of_era = (day_of_era - day_of_era // 1460 + day_of_era // 36524 - day_of_era // 146096) // 365
    day_of_year = day_of_era - (365 * year_of_era + year_of_era // 4 - year_of_era // 100)
    month_index = (5 * day_of_year + 2) // 153
    day = day_of_year - (153 * month_index + 2) // 5 + 1
    month = month_index + 3 if month_index < 10 else month_index - 9
    year = year_of_era + era * 400 + (month <= 2)
    return f"{year:04d}-{month:02d}-{day:02d} {seconds // HOUR:02d}:{seconds % HOUR // 60:02d} UTC"


def _listed(entries, namespace, name):
    """Whether namespace (or namespace/name) is in a policy list, compared without case (D6)."""
    wanted = {entry.casefold() for entry in entries}
    return namespace.casefold() in wanted or f"{namespace}/{name}".casefold() in wanted


def _check(check, ok, detail):
    return {"check": check, "ok": ok, "detail": detail}


def _age_check(namespace, name, published, now, policy):
    if _listed(policy["exempt"], namespace, name):
        return _check("age", True, f"`{namespace}` is exempt from the minimum age")
    if published is None:
        return _check("age", False, "no release was published for this version")
    minimum = policy["min_age_days"]
    ok = now - published >= minimum * DAY
    detail = (f"published {_age(published, now)} ago" if ok else
              f"published {_age(published, now)} ago; the minimum is {_days(minimum)}, reached at "
              f"{civil(published + minimum * DAY)}")
    return _check("age", ok, detail)


def _allow_check(namespace, name, policy):
    ok = _listed(policy["allow"], namespace, name)
    return _check("allow", ok, f"`{namespace}` is on the allow list" if ok else f"`{namespace}` is not on the allow list")


def comparable(text):
    """A version a hold can compare, parsed, or None: three numbers written, an optional `v`, an optional
    pre-release (D26)."""
    return parse_version(text) if _COMPARABLE.fullmatch(text) else None


def dependency_key(dependency):
    """The key a hold names a dependency of the admission's facts by, or None for a source no hold can name."""
    if dependency["kind"] == "provider":
        parts = dependency["address"].split("/")
        return f"{parts[1]}/{parts[2]}".casefold() if len(parts) == 3 and parts[0] == REGISTRY else None
    return module_key(dependency)


def module_key(module):
    """The key a hold names a module by, from its source kind, namespace or owner, name and provider; None for a
    source kind no hold can name."""
    if module["source_kind"] == "registry":
        return f"{module['namespace']}/{module['name']}/{module['provider']}".casefold()
    if module["source_kind"] == "github":
        return _github_repository(module["namespace"], module["name"]).casefold()
    return None


def _held(conditions, version):
    """A version inside a hold's range: by its place in version order, or by its release (D26)."""
    return _covers(conditions, version) or _covers(conditions, version[:3] + ("",) + version[4:])


def holds_on(holds, dependency):
    """(the holds that name a dependency, those that keep its new version out, whether that version could be
    compared). A version that cannot be compared is kept out by every hold that names it (D26)."""
    key = dependency_key(dependency)
    named = [hold for hold in holds if hold["key"] == key]
    version = comparable(dependency["to"])
    return named, [hold for hold in named if version is None or _held(hold["conditions"], version)], version is not None


def reading(hold):
    """A hold's range as written, and as Terraform reads a `~>` in it."""
    written = f"`{hold['versions']}`"
    if all(op != "~>" for op, _ in hold["conditions"]):
        return written
    parts = []
    for (op, bound), text in zip(hold["conditions"], hold["versions"].split(",")):
        if op == "~>":
            major, minor, patch, _, segments = bound
            parts.append(f">= {major}.{minor}.{patch}, < " + (f"{major + 1}.0.0" if segments <= 2 else
                                                               f"{major}.{minor + 1}.0"))
        else:
            parts.append(text.strip())
    return f"{written} (`{', '.join(parts)}`)"


def _hold_checks(dependency, policy):
    """The `hold` check, listed only when the policy sets holds (§4.6, I30)."""
    if not policy["holds"]:
        return []
    named, covering, readable = holds_on(policy["holds"], dependency)
    if not named:
        detail = "no hold names it"
    elif not covering:
        detail = f"no hold covers {dependency['to']}"
    elif not readable:
        detail = f"held by this repository: `{dependency['to']}` is not a version a hold can compare"
    else:
        detail = "held by this repository: " + " and ".join(reading(hold) for hold in covering)
    return [{**_check("hold", not covering, detail),
             "holds": [{key: hold[key] for key in ("name", "versions", "reason")} for hold in covering]}]


def _provider_checks(dependency, now, policy):
    parts = dependency["address"].split("/")
    if len(parts) != 3 or parts[0] != REGISTRY or not all(parts):
        return [_check("host", False, f"`{dependency['address']}` is not a provider on {REGISTRY}")]
    _, namespace, name = parts
    facts = dependency["facts"]
    checks = [_check("host", True, REGISTRY), *_hold_checks(dependency, policy), _allow_check(namespace, name, policy),
              _age_check(namespace, name, facts["published"], now, policy)]
    same = sorted(set(facts["keys_from"]) & set(facts["keys_to"]))
    if same:
        checks.append(_check("key", True, f"signed with `{same[0]}`, as the base version"))
    elif facts["vouched"]:
        checks.append(_check("key", True, f"signed with a new key, `{', '.join(facts['keys_to'])}`, which HashiCorp "
                                          f"vouches for ({facts['class_to']})"))
    else:
        checks.append(_check("key", False, f"the signing key changed from `{', '.join(facts['keys_from'])}` "
                                           f"({facts['class_from']}) to `{', '.join(facts['keys_to'])}` "
                                           f"({facts['class_to']})"))
    if dependency["locked"]:
        unknown = sorted(set(facts["zh"]) - set(facts["shasums"]))
        checks.append(_check("hashes", not unknown, "every `zh:` hash is in the publisher's checksums" if not unknown
                             else f"the lock records {len(unknown)} `zh:` hash{'' if len(unknown) == 1 else 'es'} the "
                                  "publisher did not publish"))
    return checks


def _module_checks(dependency, now, policy):
    kind, owner, name = dependency["source_kind"], dependency["namespace"], dependency["name"]
    if kind not in ("registry", "github"):
        return [_check("source", False, f"`{dependency['address']}` is neither a {REGISTRY} module nor a GitHub source")]
    return [_check("source", True, "registry module" if kind == "registry" else "GitHub source"),
            *_hold_checks(dependency, policy), _allow_check(owner, name, policy),
            _age_check(owner, name, dependency["facts"]["published"], now, policy)]


def normalised(line):
    """A line with every version value and git ref masked: two lines that differ only there normalise alike.
    The adapter uses it too, to find a version change no dependency explains."""
    return REF_ARGUMENT.sub(r"\1<ref>", VERSION_ARGUMENT.sub(r'\1"<version>"', line))


def _shape_problems(files):
    """The changes that are not ones Dependabot's Terraform updater makes (§4.1), one detail each."""
    problems = []
    for item in files:
        path = item["path"]
        if item["status"] != "modified" or item["kind"] not in FILE_KINDS:
            what = item["status"] if item["status"] != "modified" else "not a .tf or .terraform.lock.hcl file"
            problems.append(f"`{path}`: {what}")
            continue
        if item["kind"] == "tf":
            problems += [f"`{path}`: a version changed outside a module block or a required_providers entry: "
                         f"`{line.strip()}`" for line in item["unmapped"]]
            for change in item["lines"]:
                old, new = change["old"], change["new"]
                if old is None or new is None:
                    problems.append(f"`{path}`: a line {'added' if old is None else 'removed'}: "
                                    f"`{(new if old is None else old).strip()}`")
                elif normalised(old) != normalised(new):
                    problems.append(f"`{path}`: a change outside a version: `{old.strip()}` → `{new.strip()}`")
            continue
        before, after = item["before"], item["after"]
        if before is None or after is None:
            problems.append(f"`{path}`: cannot be read as a lock file")
            continue
        if set(before) != set(after):
            problems.append(f"`{path}`: the providers changed: {', '.join(sorted(set(before) ^ set(after)))}")
            continue
        for address in sorted(before):
            if before[address] != after[address] and before[address]["version"] == after[address]["version"]:
                problems.append(f"`{path}`: `{address}` changed without a version change")
    return problems


def judge(document, policy, relevant):
    """The admission block for a run it applies to. `relevant` maps each environment whose change is relevant
    to its project directory, normalised; the lock check reads it (§4.5)."""
    if document["event"]["name"] == "push":
        return {"applies": True, "admitted": True, "push_run": True, "dependencies": [], "problems": [],
                "refused_count": 0, "total": 0}
    facts = document["admission"]
    now = facts["now"]
    dependencies = []
    for dependency in facts["dependencies"]:
        checks = (_provider_checks(dependency, now, policy) if dependency["kind"] == "provider"
                  else _module_checks(dependency, now, policy))
        dependencies.append({key: dependency[key] for key in ("kind", "address", "from", "to", "files")}
                            | {"admitted": all(check["ok"] for check in checks), "checks": checks})
    problems = [{"check": "shape", "detail": detail} for detail in _shape_problems(facts["files"])]
    problems += [{"check": "lock", "detail": f"environment `{name}`: no committed .terraform.lock.hcl in `{directory}`"}
                 for name, directory in sorted(relevant.items()) if not facts["locks"].get(directory, False)]
    refused = sum(not dependency["admitted"] for dependency in dependencies)
    return {"applies": True, "admitted": not refused and not problems, "push_run": False,
            "dependencies": dependencies, "problems": problems, "refused_count": refused,
            "total": len(dependencies)}


NOT_APPLYING = {"applies": False}


# The audit (docs/Dependabot-admission.md D27): the holds against what the repository's committed files use.

def _paths(paths):
    return paths[0] if len(paths) == 1 else f"{', '.join(paths[:-1])} and {paths[-1]}"


def _used(inventory):
    """{key: [(version written, path)]} of every dependency the repository's files name; an entry without a version
    names it all the same."""
    used = {}
    for lock in inventory["locks"]:
        for address, version in lock["providers"].items():
            used.setdefault(dependency_key({"kind": "provider", "address": address}), []).append((version, lock["path"]))
    for entry in inventory["providers"]:
        used.setdefault(dependency_key({"kind": "provider", "address": entry["address"]}), [])
    for entry in inventory["modules"]:
        used.setdefault(module_key(entry), []).append((entry["version"], entry["path"]))
    return used


def audit(document, policy, admitted):
    """Warnings about holds that match nothing, and about committed locks and pins a hold covers; never errors."""
    inventory = document.get("dependency_inventory")
    if not policy["holds"] or inventory is None:
        return []
    if not inventory["available"]:
        return [f"{POLICY}: the holds were not audited: the repository's committed files could not be listed."]
    # The held versions a judged pull request brings in are in its merge commit; its admission's verdict says so.
    judged = {dependency_key(dependency) for dependency in document["admission"]["dependencies"]} \
        if admitted["applies"] and not admitted["push_run"] else set()
    used = _used(inventory)
    warnings = []
    for hold in policy["holds"]:
        label = f"{POLICY}: the hold on {hold['kind']} {shown(hold['name'])}"
        if hold["key"] not in used:
            warnings.append(f"{label} matches nothing in the repository: no committed lock file, required_providers "
                            "entry or module block names it.")
            continue
        found = {}
        for version, path in used[hold["key"]] if hold["key"] not in judged else []:
            parsed = comparable(version)
            if parsed is not None and _held(hold["conditions"], parsed):
                found.setdefault(version, []).append(path)
        verbs = ("records", "record") if hold["kind"] == "provider" else ("pins", "pin")
        warnings += [f"{label} covers {version}, which {_paths(paths)} {verbs[len(paths) > 1]}; a hold names the "
                     "versions Dependabot may not bring in." for version, paths in found.items()]
    return warnings + [f"{POLICY}: the holds were not audited against {shown(path)}, which cannot be read."
                       for path in inventory["unreadable"]]
