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
POLICY_KEYS = ("allow", "min-age-days", "min-age-exempt")
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
        errors.append(f"{POLICY} must be a mapping with the keys allow, min-age-days and min-age-exempt; it holds "
                      f"{_kind(policy)}.")
        policy = {}
    for key in sorted(policy, key=str):
        if key not in POLICY_KEYS:
            errors.append(f"{POLICY} holds the unknown key {shown(key)}; the keys are allow, min-age-days and "
                          "min-age-exempt.")
    allow = _entries("allow", policy.get("allow", []), errors)
    exempt = _entries("min-age-exempt", policy.get("min-age-exempt", []), errors)
    days = policy.get("min-age-days", DEFAULT_MIN_AGE_DAYS)
    if isinstance(days, bool) or not isinstance(days, int) or not 0 <= days <= MAX_MIN_AGE_DAYS:
        errors.append(f"{POLICY}: min-age-days must be a whole number from 0 to {MAX_MIN_AGE_DAYS}; it holds "
                      f"{shown(days)}.")
    if errors:
        raise ConfigError(errors)
    return {"enabled": switch is True or switch == "true", "allow": [*BUILT_IN_ALLOW, *allow],
            "exempt": [*BUILT_IN_EXEMPT, *exempt], "min_age_days": days}


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


def _provider_checks(dependency, now, policy):
    parts = dependency["address"].split("/")
    if len(parts) != 3 or parts[0] != REGISTRY or not all(parts):
        return [_check("host", False, f"`{dependency['address']}` is not a provider on {REGISTRY}")]
    _, namespace, name = parts
    facts = dependency["facts"]
    checks = [_check("host", True, REGISTRY), _allow_check(namespace, name, policy),
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
            _allow_check(owner, name, policy), _age_check(owner, name, dependency["facts"]["published"], now, policy)]


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
