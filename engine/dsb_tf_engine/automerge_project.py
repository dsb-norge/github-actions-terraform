"""The project workflow's auto-merge: is every environment of the run eligible (docs/Auto-merge.md §5).

Pure: the adapter reads the files (automerge_evidence.py) and hands over their parsed content; this
module judges them and returns the verdict with its log, which the adapter writes. Values are read
as the bash evaluator read them with jq (D14): `// empty` treats null and false as absent, and a
path through something that is not an object reads as absent.
"""

import json
import re

LIMIT_FIELDS = ("plan-max-count-add", "plan-max-count-change", "plan-max-count-destroy", "plan-max-count-import",
                "plan-max-count-move", "plan-max-count-remove")
COUNT_TYPES = ("add", "change", "destroy", "import", "move", "remove")
# The goals the engine grants (goals-granted), the vocabulary of the workflow's operation gates.
GRANTED_GOALS = ("init", "format", "validate", "lint", "plan", "apply", "destroy-plan", "destroy")
# The environment job's Terraform operation steps; a tolerated failure of any blocks auto-merge (D13).
OPERATION_STEP_IDS = ("init", "verify-lock", "fmt", "validate", "lint", "plan", "apply", "destroy-plan", "destroy")
# Each plan: its facts' key, the step that counted it, the step that made it, and the operation that
# applies it on the pull request, by the environment job's step ids (structural test F2).
PLAN_STEPS = (("plan", "parse-plan", "plan", "apply"), ("destroy_plan", "parse-destroy-plan", "destroy-plan", "destroy"))
INTEGER = re.compile(r"-?[0-9]+")
INELIGIBLE = "environment is ineligible for PR auto merge"


class ConfigurationError(Exception):
    """A limits mapping the evaluator cannot judge: the run fails, as the bash evaluator's did."""


class Log:
    """The evaluator's log as data: ("line", text), ("warn", text) and ("group", title, lines)."""

    def __init__(self):
        self.entries = []
        self._open = None

    def group(self, title):
        """A collapsed group holding what is logged inside `with log.group(title):`."""
        self._open = []
        self.entries.append(("group", title, self._open))
        return self

    def __enter__(self):
        """group() opened the group already."""

    def __exit__(self, *_exception):
        self._open = None

    def _add(self, entry):
        (self._open if self._open is not None else self.entries).append(entry)

    def line(self, text):
        self._add(("line", text))

    def warn(self, text):
        self._add(("warn", text))


def _path(value, *keys):
    """jq's `.a.b.c`: None where a key is absent or a value on the way is not an object."""
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def raw(value):
    """jq -r of `<path> // empty`: null and false are empty, a string as it is, the rest as JSON."""
    if value is None or value is False:
        return ""
    if isinstance(value, str):
        return value
    return compact(value)


def compact(value):
    """jq -c."""
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def _flag(value):
    return "true" if value is True or value == "true" else "false"


def _environment(content):
    return raw(_path(content, "metadata", "environment"))


def _goals_problem(variables):
    if not isinstance(variables, dict) or "goals-granted" not in variables:
        return ("The metadata has no goals-granted, the goals this run granted the environment, so what it should have "
                f"planned is unknown (metadata from an older workflow?), {INELIGIBLE}")
    goals = variables["goals-granted"]
    if not isinstance(goals, list):
        return (f"The metadata's goals-granted is {compact(goals)}, not a list of goals, so what the environment should "
                f"have planned is unknown, {INELIGIBLE}")
    unknown = [goal for goal in goals if not isinstance(goal, str) or goal not in GRANTED_GOALS]
    if unknown:
        return (f"The metadata's goals-granted holds {compact(unknown[0])}, which is not a goal "
                f"({', '.join(GRANTED_GOALS)}), so what the environment should have planned is unknown, {INELIGIBLE}")
    return ""


def _granted(variables, goal):
    goals = _path(variables, "goals-granted")
    return isinstance(goals, list) and goal in goals


def _failed_operations(content):
    steps = content.get("steps") if isinstance(content, dict) else None
    if steps is None or steps is False:
        steps = {}
    if not isinstance(steps, dict):
        return "steps (unreadable)"
    return ", ".join(f"{step} ({_path(steps, step, 'outcome')})" for step in OPERATION_STEP_IDS
                     if _path(steps, step, "outcome") in ("failure", "cancelled"))


def _succeeded(content, step):
    return raw(_path(content, "steps", step, "outcome")) == "success"


def _output(content, step, name):
    return raw(_path(content, "steps", step, "outputs", name))


def _settings(holder):
    """enabled, the limits as jq -c, the actors as they are: the same reader for a metadata row and a
    relevance entry, so an unaffected environment is judged as an affected one would be."""
    limits = holder.get("pr-auto-merge-limits") if isinstance(holder, dict) else None
    return {"enabled": _flag(holder.get("pr-auto-merge-enabled") if isinstance(holder, dict) else None),
            "limits": limits if limits is not None and limits is not False else {},
            "actors": holder.get("pr-auto-merge-from-actors") if isinstance(holder, dict) else None}


def environment_facts(content):
    """What the evaluator reads from one environment's metadata (the bash extract_environment_data)."""
    variables = _path(content, "matrix_context", "vars")
    facts = {"name": _environment(content), **_settings(variables),
             "goals": variables.get("goals-granted") if isinstance(variables, dict) else None,
             "goals_problem": _goals_problem(variables), "failed": _failed_operations(content)}
    for kind, parse, goal, operation in PLAN_STEPS:
        facts[kind] = {"expected": _granted(variables, goal), "created": _succeeded(content, goal),
                       "on_pr": _granted(variables, operation), "on_pr_succeeded": _succeeded(content, operation),
                       "counts": {count: _output(content, parse, f"count-{count}") for count in COUNT_TYPES},
                       "source": _output(content, parse, "counts-source"),
                       "complete": _output(content, parse, "plan-complete")}
    return facts


def metadata_problem(entry):
    """Why a metadata file cannot be used, or None (the bash validate_metadata_file)."""
    if not entry["readable"]:
        return f"Metadata file '{entry['file']}' does not exist or is not readable"
    if not entry["json"]:
        return f"Metadata file '{entry['file']}' is not valid JSON"
    if not _environment(entry["content"]):
        return f"Metadata file '{entry['file']}' is missing .metadata.environment field"
    variables = _path(entry["content"], "matrix_context", "vars")
    if variables is None or variables is False:
        return f"Metadata file '{entry['file']}' is missing .matrix_context.vars field"
    return None


class _Environment:
    """One environment's checks, in the order of docs/Auto-merge.md §5.1."""

    def __init__(self, log, actor, facts):
        self.log, self.actor, self.facts = log, actor, facts
        self.eligible = True

    def fail(self, reason):
        self.eligible = False
        self.log.warn(reason)

    def configuration(self):
        limits = self.facts["limits"]
        errors = []
        for field in LIMIT_FIELDS:
            value = raw(limits.get(field)) if isinstance(limits, dict) else ""
            if value in ("", "null"):
                errors.append(f"Configuration error: '{field}' is missing, null, or empty")
            elif not INTEGER.fullmatch(value):
                errors.append(f"Configuration error: '{field}' value '{value}' is not a valid integer")
        if errors:
            raise ConfigurationError(errors)
        self.log.line("Configuration validation: PASS")

    def enabled(self):
        if self.facts["enabled"] == "true":
            self.log.line("PR automerge enabled: PASS")
        else:
            self.fail("PR automerge is disabled for this environment")

    def actors(self):
        actors = self.facts["actors"]
        if not isinstance(actors, list):
            self.fail(f"The actor list that applies to this environment (pr-auto-merge-from-actors) is {compact(actors)}, not a "
                      "list of logins, so no pull request may auto-merge")
        elif not [login for login in actors if isinstance(login, str) and login != ""]:
            self.fail("The actor list that applies to this environment (pr-auto-merge-from-actors) names nobody, so no "
                      "pull request may auto-merge; name the accounts in pr-auto-merge-from-actors-yml")
        elif any(isinstance(login, str) and login.lower() == self.actor.lower() for login in actors):
            self.log.line(f"Actor '{self.actor}' found in allowed list")
            self.log.line("Actor authorization: PASS")
        else:
            self.fail(f"Actor '{self.actor}' is not authorized for PR automerge")

    def _expected(self, label, plan, expected_key, done_key, failure, passed, skipped):
        if not plan[expected_key]:
            self.log.line(f"{label}: {skipped} - SKIPPED")
        elif plan[done_key]:
            self.log.line(f"{label}: {passed} - PASS")
        else:
            self.fail(failure)

    def plan_checks(self):
        plan, destroy = self.facts["plan"], self.facts["destroy_plan"]
        self._expected("Plan creation", plan, "expected", "created",
                       f"Plan was expected to have been created but was not, {INELIGIBLE}",
                       "expected and succeeded", "not expected")
        self._expected("Destroy plan creation", destroy, "expected", "created",
                       f"Destroy plan was expected to have been created but was not, {INELIGIBLE}",
                       "expected and succeeded", "not expected")
        self._expected("Apply on PR", plan, "on_pr", "on_pr_succeeded",
                       f"Apply operation on PR was not expected to fail, {INELIGIBLE}",
                       "performed and succeeded", "not performed")
        self._expected("Destroy on PR", destroy, "on_pr", "on_pr_succeeded",
                       f"Destroy operation on PR was not expected to fail, {INELIGIBLE}",
                       "performed and succeeded", "not performed")
        judged = []
        for label, plan_, what, operation in (("Plan limits", plan, "plan", "apply"),
                                              ("Destroy plan limits", destroy, "destroy plan", "destroy")):
            if not plan_["expected"]:
                self.log.line(f"{label}: IGNORED ({what} was not supposed to be created)")
            elif plan_["on_pr"]:
                self.log.line(f"{label}: IGNORED ({operation} is being performed on PR)")
            else:
                self.log.line(f"{label}: INCLUDED")
                judged.append((what, plan_))
        if judged:
            self._limits(judged)
        else:
            self.log.line("Skipping count validation and limit evaluation (all limits ignored)")

    def _evidence(self, what, plan):
        """Why the plan's counts cannot be trusted for auto-merge, or ''."""
        name, source, complete = self.facts["name"], plan["source"], plan["complete"]
        if source != "json":
            problem = (f"The {what} of '{name}' was not counted from its JSON plan "
                       f"({'counts-source: ' + source if source else 'no counts-source'}), so its counts cannot be "
                       "trusted for auto-merge")
        elif complete == "false":
            problem = (f"The {what} of '{name}' is not complete (a -target plan, or changes deferred to a later plan), "
                       "so its counts do not cover every change")
        elif complete != "true":
            problem = (f"The {what} of '{name}' does not say it is complete "
                       f"({'plan-complete: ' + complete if complete else 'no plan-complete'}), so its counts may not "
                       "cover every change")
        else:
            problem = ""
        return problem

    def _limits(self, judged):
        problems = [problem for problem in (self._evidence(what, plan) for what, plan in judged) if problem]
        for problem in problems:
            self.fail(problem)
        counts_valid = all(INTEGER.fullmatch(plan["counts"][count]) for _, plan in judged for count in COUNT_TYPES)
        if not counts_valid:
            self.fail("Required plan counts are missing or invalid. Plan parsing may have failed, environment is "
                      "ineligible for PR auto merge")
        if problems or not counts_valid:
            self.log.line("Count validation: FAIL")
            return
        self.log.line("Count validation: PASS")
        limits = self.facts["limits"]
        for count, field in zip(COUNT_TYPES, LIMIT_FIELDS):
            total = sum(int(plan["counts"][count]) for _, plan in judged)
            limit = int(raw(limits[field]))
            if limit == -1:
                self.log.line(f"{count.capitalize()}: {total} / unlimited - PASS")
            elif total <= limit:
                self.log.line(f"{count.capitalize()}: {total} / {limit} - PASS")
            else:
                self.log.line(f"{count.capitalize()}: {total} / {limit} - FAIL")
                self.fail(f"{count.capitalize()} count ({total}) exceeds limit ({limit}) in environment")

    def operations(self):
        failed = self.facts["failed"]
        if not failed:
            self.log.line("No operation failed or was cancelled")
            self.log.line("Operation outcomes: PASS")
            return
        self.fail(f"Terraform operation(s) did not succeed: {failed}. A failure allow-failing-terraform-operations "
                  f"tolerates still blocks auto-merge, {INELIGIBLE}")
        self.log.line("Operation outcomes: FAIL")


def _record(log, result):
    log.line(f"  Plan creation: {result}")
    log.line(f"  Destroy plan creation: {result}")
    log.line(f"  Apply on PR: {result}")
    log.line(f"  Destroy on PR: {result}")
    log.line(f"  Plan limits: {result}")
    log.line(f"  Destroy plan limits: {result}")


def judge_environment(log, actor, facts, unaffected=False, unplanned=""):
    """True when the environment is eligible; raises ConfigurationError on a limits mapping that
    cannot be judged. Every check for an affected environment; for one without a job, the settings
    alone, and not eligible with the `unplanned` reason when the change may concern it (§5.1)."""
    checks = _Environment(log, actor, facts)
    with log.group(f"Environment '{facts['name']}'"):
        log.line(f"Actor: {actor}; auto-merge enabled: {facts['enabled']}")
        log.line(f"Limits: {compact(facts['limits'])}; actors: {compact(facts['actors'])}")
        checks.configuration()
    with log.group(f"Checks of '{facts['name']}'"):
        checks.enabled()
        checks.actors()
        if unaffected:
            log.line("Environment is not affected by this change and no job ran for it")
            _record(log, "NOT AFFECTED")
            log.line("  Operation outcomes: NOT AFFECTED")
        elif unplanned:
            checks.fail(unplanned)
            log.line("No job ran for the environment, so nothing shows what the change does to it")
            _record(log, "NOT PLANNED")
            log.line("  Operation outcomes: NOT PLANNED")
        else:
            log.line(f"Goals granted: {compact(facts['goals'])}; failed or cancelled operations: "
                     f"{facts['failed'] or '<none>'}")
            if facts["goals_problem"]:
                checks.fail(facts["goals_problem"])
                log.line("The goals this run granted are unknown, so no plan-based check can be judged")
                _record(log, "UNKNOWN")
            else:
                checks.plan_checks()
            checks.operations()
        log.line(f"Final eligibility: {'true' if checks.eligible else 'false'}")
    return checks.eligible


def relevance_problem(entry):
    """Why the relevance file cannot be trusted to name every environment, or None."""
    name = entry["file"]
    if not entry["readable"]:
        return f"Relevance file '{name}' is not readable"
    if not entry["json"]:
        return f"Relevance file '{name}' is not valid JSON"
    content = entry["content"]
    environments = content.get("environments") if isinstance(content, dict) else None
    if not isinstance(environments, list):
        return f"Relevance file '{name}' has no 'environments' list"
    bad = sum(1 for item in environments if not _good_entry(item))
    if bad:
        return (f"Relevance file '{name}' has {bad} malformed environment entr(y/ies): each needs a non-empty "
                "'github-environment' and a 'verdict' of 'run' or 'skip', and 'relevant' is a boolean, 'reasons' a "
                "list of text and 'trigger-events' a list where given")
    names = [item["github-environment"] for item in environments]
    duplicates = sorted({item for item in names if names.count(item) > 1})
    if duplicates:
        return f"Relevance file '{name}' lists these github-environments more than once: {', '.join(duplicates)}"
    return None


def _good_entry(item):
    return (isinstance(item, dict)
            and isinstance(item.get("github-environment"), str) and item["github-environment"] != ""
            and item.get("verdict") in ("run", "skip")
            and ("relevant" not in item or isinstance(item["relevant"], bool))
            and ("reasons" not in item or (isinstance(item["reasons"], list)
                                           and all(isinstance(reason, str) for reason in item["reasons"])))
            and ("trigger-events" not in item or isinstance(item["trigger-events"], list)))


def unplanned_reason(item):
    """Why a skipped environment was never planned although the change may concern it, or "" when the
    skip means "not affected" (docs/Auto-merge.md D6)."""
    name = raw(item.get("environment")) or item["github-environment"]
    reasons = item.get("reasons") or []
    reason = reasons[0] if reasons else ""
    events = item.get("trigger-events")
    out_of_pull_requests = reason.startswith("trigger-events:") or (
        isinstance(events, list) and "pull_request" not in events)
    if item.get("relevant") is True and out_of_pull_requests:
        return f"The change touches '{name}', which takes no part in pull requests, so it was never planned, {INELIGIBLE}"
    if item.get("relevant") is True:
        return f"The change touches '{name}', which was skipped ({reason}), so it was never planned, {INELIGIBLE}"
    if "relevant" not in item and out_of_pull_requests:
        return (f"'{name}' takes no part in pull requests and the relevance file does not say whether the change "
                f"touches it, so it may never have been planned, {INELIGIBLE}")
    return ""


def stage_results(text):
    """The stage results as an object of strings, None without any, or False when not an object."""
    if text.strip() == "":
        return None
    try:
        value = json.loads(text)
    except ValueError:
        return False
    if not isinstance(value, dict):
        return False
    return {key: result for key, result in value.items() if isinstance(result, str)}


def held_back(content, results):
    """{github-environment: reason} for each affected environment a failed stage held back (§7.5)."""
    by_stage = _path(content, "counts", "by_stage")
    by_stage = by_stage if isinstance(by_stage, dict) else {}
    reasons = {}
    for item in content["environments"]:
        if item["verdict"] != "run":
            continue
        stage = _number(item.get("stage"), None)
        if stage is None or stage < 2 or results.get(str(stage)) != "skipped" \
                or _number(by_stage.get(str(stage)), 0) <= 0:
            continue
        cause = next((earlier for earlier in range(1, int(stage))
                      if results.get(str(earlier)) in ("failure", "cancelled")), None)
        name = item["github-environment"]
        why = (f"it is in stage {stage}, which did not run" if cause is None
               else f"it is in stage {stage} and stage {cause} was cancelled" if results[str(cause)] == "cancelled"
               else f"it is in stage {stage} and stage {cause} failed")
        reasons[name] = f"'{name}' was held back: {why}, so it was never planned, {INELIGIBLE}"
    return reasons


def _number(value, default):
    """jq's `tonumber? // default`, as the held-back reading uses it."""
    if isinstance(value, bool) or value is None:
        return default
    if isinstance(value, (int, float)):
        return value
    try:
        return float(value) if "." in str(value) else int(value)
    except (TypeError, ValueError):
        return default


def failing_tests(tests):
    """(tolerated, status, file, lane) for each test job whose test failed or errored; the conclusion
    judges them, so nothing here decides eligibility (D13)."""
    found = []
    for entry in tests:
        content = entry["content"]
        status = _path(content, "steps", "test", "outputs", "status")
        if status not in ("fail", "error"):
            continue
        test = _path(content, "matrix_context", "test")
        test = test if isinstance(test, dict) else {}
        file = raw(test.get("file")) or raw(_path(content, "metadata", "environment")) or "unknown test"
        found.append((test.get("allow-failing-terraform-tests") in (True, "true"), status, file,
                      raw(test.get("lane"))))
    return found


def _tolerated_message(eligible, status, file, lane):
    what = (f"the tolerated {'erroring' if status == 'error' else 'failing'} test {file}"
            f"{f' (lane {lane})' if lane else ''}")
    if eligible:
        return f"auto-merge eligible despite {what}"
    return f"{what[0].upper()}{what[1:]} does not block auto-merge; the pull request is not eligible for other reasons"


class _Run:
    """The counters and per-environment results of one evaluation."""

    def __init__(self, log, actor):
        self.log, self.actor = log, actor
        self.eligible = True
        self.processed = self.passed = self.refused = 0
        self.results = []

    def record(self, eligible, name, note=""):
        self.processed += 1
        label = f"{name} {note}" if note else name
        if eligible:
            self.passed += 1
            self.results.append(("ELIGIBLE", label))
            self.log.line(f"✅ Environment '{name}' is eligible for automerge")
        else:
            self.refused += 1
            self.results.append(("INELIGIBLE", label))
            self.eligible = False
            self.log.line(f"❌ Environment '{name}' is NOT eligible for automerge")

    def invalid(self, kind, name, warning):
        self.eligible = False
        self.results.append((kind, name))
        self.log.warn(warning)

    def metadata(self, entries):
        for entry in entries:
            problem = metadata_problem(entry)
            if problem:
                self.log.warn(problem)
                self.invalid("INVALID", entry["file"], f"Skipping invalid metadata file: {entry['file']}")
                continue
            facts = environment_facts(entry["content"])
            self.record(judge_environment(self.log, self.actor, facts), facts["name"])

    def with_relevance(self, relevance, entries, stages_text):
        with self.log.group("Relevance File"):
            problem = relevance_problem(relevance)
            if problem:
                self.log.warn(problem)
                self.log.warn(f"Relevance file '{relevance['file']}' is unusable, the environments of this run are "
                              "unknown, not eligible for PR auto merge")
                self.eligible = False
                return None
            content = relevance["content"]
            environments = content["environments"]
            affected = sum(item["verdict"] == "run" for item in environments)
            if not environments:
                self.log.warn(f"Relevance file '{relevance['file']}' lists no environments, nothing establishes that "
                              "auto-merge is permitted, not eligible for PR auto merge")
                self.eligible = False
                return 0, 0
            self.log.line(f"Relevance file lists {len(environments)} environment(s), {affected} affected")
        results = stage_results(stages_text)
        if results is False:
            self.log.warn("stage-results-json is not a JSON object of stage results, an environment without metadata is "
                          "reported as cancelled or crashed")
        held = held_back(content, results) if results else {}
        listed = {item["github-environment"] for item in environments}
        found = {}
        with self.log.group("Metadata Matching"):
            for entry in entries:
                problem = metadata_problem(entry)
                if problem:
                    self.log.warn(problem)
                    self.invalid("INVALID", entry["file"], f"Skipping invalid metadata file: {entry['file']}")
                    continue
                name = _environment(entry["content"])
                if name not in listed:
                    self.invalid("UNKNOWN", name, f"Metadata file '{entry['file']}' is for environment '{name}', which "
                                                  "the relevance file does not list, not eligible for PR auto merge")
                    continue
                found.setdefault(name, []).append(entry)
                self.log.line(f"  {entry['file']} -> {name}")
        for item in environments:
            name, files = item["github-environment"], found.get(item["github-environment"], [])
            if len(files) > 1:
                self.log.warn(f"{len(files)} metadata files for environment '{name}', expected exactly one, "
                              f"{INELIGIBLE}")
                self.record(False, name, f"({len(files)} metadata files)")
            elif files:
                if item["verdict"] == "skip":
                    self.log.warn(f"Environment '{name}' has a metadata file although the relevance file marks it "
                                  "unaffected, judging it on its metadata")
                self.record(judge_environment(self.log, self.actor, environment_facts(files[0]["content"])), name)
            elif item["verdict"] == "run" and name in held:
                self.log.warn(held[name])
                self.record(False, name, "(held back)")
            elif item["verdict"] == "run":
                self.log.warn(f"No metadata file for affected environment '{name}': its job was cancelled or failed "
                              f"before capturing metadata, {INELIGIBLE}")
                self.record(False, name, "(affected, no metadata)")
            else:
                facts = {"name": name, **_settings(item)}
                reason = unplanned_reason(item)
                if reason:
                    self.record(judge_environment(self.log, self.actor, facts, unplanned=reason), name,
                                "(skipped, never planned)")
                else:
                    self.record(judge_environment(self.log, self.actor, facts, unaffected=True), name, "(not affected)")
        return len(environments), affected


def evaluate(facts):
    """{"eligible": bool or None, "log": Log, "notices": [...], "fatal": [...] or None} (docs/Auto-merge.md §14).

    `eligible` is None when a limits mapping cannot be judged: the step then fails, as before.
    """
    log = Log()
    relevance = facts["relevance"]
    log.line(f"Metadata files pattern: {facts['metadata_pattern']}")
    log.line(f"Relevance file: {relevance['file'] if relevance else '<none>'}")
    log.line(f"Test metadata files pattern: {facts['tests_pattern'] or '<none>'}")
    if relevance is not None and not relevance["exists"]:
        log.warn(f"Relevance file '{relevance['file']}' does not exist, evaluating the metadata files alone")
        relevance = None

    tolerated = []
    with log.group("Test Jobs"):
        if not facts["tests_pattern"]:
            log.line("No test metadata files pattern, no test job is named")
        else:
            log.line(f"Found {len(facts['tests'])} test metadata file(s) matching: {facts['tests_pattern']}")
            for entry in facts["tests"]:
                if not entry["json"]:
                    log.warn(f"Test metadata file '{entry['file']}' is not valid JSON, it names no test")
                    continue
                for allowed, status, file, lane in failing_tests([entry]):
                    where = f"{file}{f' (lane {lane})' if lane else ''}"
                    if allowed:
                        tolerated.append((status, file, lane))
                        log.line(f"  {where}: {status}, tolerated by allow-failing-terraform-tests, does not block "
                                 "auto-merge")
                    else:
                        log.warn(f"  {where}: {status} and not tolerated; the conclusion judges the test jobs, not "
                                 "this step")
            log.line(f"Tolerated failing or erroring tests: {len(tolerated)}")

    def notices(eligible):
        return [_tolerated_message(eligible, *entry) for entry in tolerated]

    entries = facts["metadata"]
    with log.group("File Discovery"):
        if not entries and relevance is None:
            log.warn(f"No metadata files found matching pattern: {facts['metadata_pattern']}")
            log.line("Setting is-eligible=false (no files to process)")
            return {"eligible": False, "log": log, "notices": notices(False), "fatal": None}
        log.line(f"Found {len(entries)} metadata file(s):")
        for entry in entries:
            log.line(f"  - {entry['file']}")

    run = _Run(log, facts["actor"])
    try:
        listed = run.with_relevance(relevance, entries, facts["stage_results"]) if relevance else run.metadata(entries)
    except ConfigurationError as error:
        return {"eligible": None, "log": log, "notices": [], "fatal": [*error.args[0],
                                                                       "Configuration validation failed"]}

    marks = {"ELIGIBLE": "✅ {}", "INELIGIBLE": "❌ {}", "INVALID": "⚠️  {} (invalid file)",
             "UNKNOWN": "❓ {} (not in the relevance file)"}
    with log.group("Final Summary"):
        log.line(f"Files found: {len(entries)}")
        if listed:
            log.line(f"Environments in relevance file: {listed[0]} ({listed[1]} affected)")
        log.line(f"Environments processed: {run.processed}")
        log.line(f"Environments eligible: {run.passed}")
        log.line(f"Environments ineligible: {run.refused}")
        log.line("Per-environment results:")
        for kind, name in run.results:
            log.line("  " + marks[kind].format(name))
        log.line("✅ FINAL RESULT: All environments eligible - PR CAN be automerged" if run.eligible
                 else "❌ FINAL RESULT: Not all environments eligible - PR CANNOT be automerged")
        log.line(f"Tolerated failing or erroring tests: {len(tolerated)}")
    return {"eligible": run.eligible, "log": log, "notices": notices(run.eligible), "fatal": None}

