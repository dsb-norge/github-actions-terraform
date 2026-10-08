"""decide-notifications and record-notifications on a runner (docs/Notifications.md §7, §9): the files they
read and write, what they ask GitHub, and the step outputs. gh is stood in for; the rules have their
own tests (test_notify_decide, test_notify_state)."""

import datetime
import hashlib
import io
import json
import os
import tempfile
import unittest

from dsb_tf_engine import notify_evidence

CLOCK = lambda: datetime.datetime(2026, 10, 7, 12, 0, 0, tzinfo=datetime.timezone.utc)  # noqa: E731
BEFORE, AFTER = "b" * 40, "a" * 40


OBJECT_ID = "http://schemas.microsoft.com/identity/claims/objectidentifier"
QUERY = ("query($org: String!, $login: String!) { organization(login: $org) { samlIdentityProvider { "
         "externalIdentities(login: $login, first: 1) { nodes { samlIdentity { username givenName familyName "
         "attributes { name value } } } } } } }")


class FakeTools:
    """gh api by endpoint: {endpoint: answer or (code, stdout, stderr)}; anything else is a 404. A GraphQL
    identity lookup in organisation o is answered from `identities` by login the same way."""

    def __init__(self, api=None, identities=None):
        self.api = api or {}
        self.identities = identities or {}
        self.calls = []
        self.envs = []

    def run(self, argv, stdin="", env=None):
        self.calls.append(tuple(argv))
        self.envs.append(env)
        if argv[:3] == ("gh", "api", "graphql"):
            assert argv[3:7] == ("-f", f"query={QUERY}", "-f", "org=o") and argv[7] == "-f" and len(argv) == 9, argv
            answer = self.identities.get(argv[8].removeprefix("login="))
            return answer if isinstance(answer, tuple) else (0, json.dumps(answer), "")
        assert argv[:2] == ("gh", "api") and len(argv) == 3 and env is None, argv
        answer = self.api.get(argv[2])
        if answer is None:
            return 1, "", f"gh: Not Found (HTTP 404)"
        return answer if isinstance(answer, tuple) else (0, json.dumps(answer), "")

    def endpoints(self):
        return [argv[2] for argv in self.calls]


def pull(number, author="jdoe", merged_by="asmith", base="main", merged=True, title="Add a storage account"):
    return {"number": number, "title": title, "merged_at": "2026-10-07T11:00:00Z" if merged else None,
            "base": {"ref": base}, "user": {"login": author, "type": "User"},
            "merged_by": {"login": merged_by, "type": "User"}}


def saml(username="100001@example.org", given="Jane", family="Doe", object_id="oid-jdoe"):
    attributes = [{"name": "http://schemas.microsoft.com/identity/claims/tenantid", "value": "tenant"}]
    attributes += [{"name": OBJECT_ID, "value": object_id}] if object_id is not None else []
    return {"data": {"organization": {"samlIdentityProvider": {"externalIdentities": {"nodes": [
        {"samlIdentity": {"username": username, "givenName": given, "familyName": family, "attributes": attributes}}]}}}}}


def metadata(name, apply="success"):
    steps = {step: {"outcome": "success", "outputs": {}} for step in ("init", "fmt", "validate", "lint", "plan")}
    steps["apply"] = {"outcome": apply, "outputs": {}}
    return {"metadata": {"environment": name}, "steps": steps}


SENDER = {"github-environment": "prod", "extra-envs": {"ARM_TENANT_ID": "t"},
          "extra-envs-from-secrets": {"ARM_CLIENT_ID": "PROD_CLIENT_ID"}}
RELEVANCE = {"environments": [{"environment": "prod", "verdict": "run", "stage": 1}],
             "notify": {"active": True, "reason": "on",
                        "target": {"bot-url": "https://relay.example.net/api", "bot-audience": "api://relay",
                                   "alias": "tf-alerts"},
                        "senders": {"prod": SENDER}, "runs-on": "ubuntu-24.04"}}
MATRIX = {"environment": ["prod"], "include": [{"environment": "prod", "vars": {
    "environment": "prod", "github-environment": "prod", "goals-granted": ["init", "plan", "apply"],
    "notifications": None}}]}
PAYLOAD = {"repository": {"default_branch": "main"}, "before": BEFORE, "after": AFTER,
           "sender": {"login": "asmith", "type": "User"}}
COMPARE = f"repos/o/r/compare/{BEFORE}...{AFTER}"
PEOPLE_API = {COMPARE: {"commits": [{"sha": AFTER, "parents": [{"sha": BEFORE}]}]},
              f"repos/o/r/commits/{AFTER}/pulls": [pull(7)], "repos/o/r/pulls/7": pull(7),
              "repos/o/r/environments/prod": {"name": "prod", "protection_rules": []}}


class Runner:
    def __init__(self, test, metadata_files=None, relevance=RELEVANCE, matrix=MATRIX, payload=PAYLOAD, state=None,
                 environ=None):
        self.work = tempfile.TemporaryDirectory()
        test.addCleanup(self.work.cleanup)
        self.dir = self.work.name
        self.out = os.path.join(self.dir, "out")
        self.metadata_pattern = os.path.join(self.dir, "matrix-job-meta-*.json")
        for name, content in (metadata_files if metadata_files is not None
                              else {"prod": metadata("prod", "failure")}).items():
            self.write(f"matrix-job-meta-{name}.json", content)
        self.relevance = self.write("relevance.json", relevance)
        self.matrix = self.write("matrix.json", matrix)
        self.stages = self.write("stages.json", {"1": "success", "2": "skipped", "3": "skipped"})
        self.state = self.write("state.json", state) if state is not None else os.path.join(self.dir, "none.json")
        self.payload = self.write("event.json", payload)
        self.output_file = self.write("output.txt", "")
        self.summary_file = self.write("summary.md", "")
        self.environ = {"GITHUB_REPOSITORY": "o/r", "GITHUB_EVENT_NAME": "push", "GITHUB_RUN_ID": "4711",
                        "GITHUB_RUN_NUMBER": "42", "GITHUB_RUN_ATTEMPT": "1", "GITHUB_SERVER_URL": "https://github.com",
                        "GITHUB_EVENT_PATH": self.payload, "GITHUB_OUTPUT": self.output_file,
                        "GITHUB_STEP_SUMMARY": self.summary_file, **(environ or {})}
        self.log = io.StringIO()
        self.clock = CLOCK

    def write(self, name, content):
        path = os.path.join(self.dir, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content if isinstance(content, str) else json.dumps(content))
        return path

    def decide(self, tools):
        self.tools = tools
        return notify_evidence.run_decide(self.metadata_pattern, self.matrix, self.relevance, self.stages, self.state,
                                          self.out, self.environ, self.log, tools, self.clock)

    def read(self, *parts):
        with open(os.path.join(*parts), encoding="utf-8") as handle:
            return handle.read()

    def outputs(self):
        lines, outputs = self.read(self.output_file).splitlines(), {}
        for index in range(0, len(lines), 3):
            name, delimiter = lines[index].split("<<")
            assert lines[index + 2] == delimiter, lines
            outputs[name] = lines[index + 1]
        return outputs


class DecideTest(unittest.TestCase):
    def test_a_failed_apply_writes_its_event_message_observations_and_one_deliver_row(self):
        runner = Runner(self)
        self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API)))
        key = hashlib.sha256(b"o/r/4711/1/prod/apply/open").hexdigest()
        self.assertEqual({"id": "e1", "environment": "prod", "slot": "apply", "kind": "apply-failed", "action": "open",
                          "alias": "tf-alerts", "reply_to": None, "update": None, "sender": "prod",
                          "idempotency_key": key, "message": "e1.md", "mentions": []},
                         json.loads(runner.read(runner.out, "events", "e1.json")))
        self.assertIn("Change: [#7](https://github.com/o/r/pull/7) `Add a storage account` by jdoe, merged by asmith.",
                      runner.read(runner.out, "events", "e1.md"))
        observations = json.loads(runner.read(runner.out, "observations.json"))
        self.assertEqual(42, observations["run_number"])
        self.assertEqual(["jdoe", "asmith"], observations["observations"][0]["people"])
        outputs = runner.outputs()
        self.assertEqual(["deliver-matrix-json", "deliver-count"], list(outputs))
        self.assertEqual("1", outputs["deliver-count"])
        self.assertEqual({"include": [{"id": "e1", "sender": "prod", "github-environment": "prod",
                                       "runs-on": "ubuntu-24.04", "alias": "tf-alerts",
                                       "reply-to": "", "update": "", "idempotency-key": key,
                                       "extra-envs": {"ARM_TENANT_ID": "t"},
                                       "extra-envs-from-secrets": {"ARM_CLIENT_ID": "PROD_CLIENT_ID"}}]},
                         json.loads(outputs["deliver-matrix-json"]))
        self.assertIn("| `prod` | apply failed | to `tf-alerts` as `prod` |", runner.read(runner.summary_file))
        self.assertEqual(runner.read(runner.out, "summary.md"), runner.read(runner.summary_file))
        self.assertEqual([COMPARE, f"repos/o/r/commits/{AFTER}/pulls", "repos/o/r/pulls/7",
                          "repos/o/r/environments/prod"], runner.tools.endpoints())

    def test_a_step_run_again_writes_over_its_own_files(self):
        runner = Runner(self)
        self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API)))
        self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API)))
        self.assertEqual(["e1.json", "e1.md", "e1.mentions.json"], sorted(os.listdir(os.path.join(runner.out, "events"))))

    def test_nothing_to_send_asks_github_nothing(self):
        runner = Runner(self, metadata_files={"prod": metadata("prod")})
        self.assertEqual(0, runner.decide(FakeTools()))
        self.assertEqual([], runner.tools.endpoints())
        self.assertEqual(("0", {"include": []}), (runner.outputs()["deliver-count"],
                                                  json.loads(runner.outputs()["deliver-matrix-json"])))
        self.assertEqual([], os.listdir(os.path.join(runner.out, "events")))

    def test_a_schedule_asks_for_no_people(self):
        runner = Runner(self, environ={"GITHUB_EVENT_NAME": "schedule"})
        self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API)))
        self.assertEqual(["repos/o/r/environments/prod"], runner.tools.endpoints())

    def test_the_state_is_read(self):
        state = {"schema_version": 1, "incidents": {"prod/apply": {
            "kind": "apply-failed", "status": "open", "message_id": "msg-1", "alias": "tf-alerts", "sender": "prod",
            "opened_at": "2026-10-05T08:30:00Z", "opened_run": 40, "seen_run": 40, "people": [], "resolved_at": None}}}
        runner = Runner(self, metadata_files={"prod": metadata("prod")}, state=state)
        self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API)))
        self.assertEqual("resolve", json.loads(runner.read(runner.out, "events", "e1.json"))["action"])

    def test_a_state_of_another_shape_is_started_over_with_a_warning(self):
        runner = Runner(self, metadata_files={"prod": metadata("prod")}, state={"schema_version": 9})
        self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API)))
        self.assertIn("::warning title=decide-notifications::the stored incident state is not one this version "
                      "reads; it starts over\n", runner.log.getvalue())

    def test_metadata_that_cannot_be_used_is_a_warning_and_the_stage_decides(self):
        runner = Runner(self, metadata_files={"prod": "not json", "x": {"no": "environment"}})
        self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API)))
        log = runner.log.getvalue()
        self.assertIn(f"::warning title=decide-notifications::{runner.dir}/matrix-job-meta-prod.json is not JSON\n",
                      log)
        self.assertIn(f"::warning title=decide-notifications::{runner.dir}/matrix-job-meta-x.json names no "
                      "environment\n", log)
        self.assertEqual("0", runner.outputs()["deliver-count"])

    def test_without_the_relevance_file_or_the_matrix_it_is_a_fault(self):
        for broken in ("relevance", "matrix"):
            with self.subTest(broken=broken):
                runner = Runner(self)
                os.remove(getattr(runner, broken))
                self.assertEqual(1, runner.decide(FakeTools(PEOPLE_API)))
                self.assertIn("::error title=decide-notifications::", runner.log.getvalue())
                self.assertEqual("", runner.read(runner.output_file))

    def test_a_relevance_file_without_a_target_is_a_fault(self):
        for notify in ({**RELEVANCE["notify"], "target": None}, {**RELEVANCE["notify"], "runs-on": None}, None):
            with self.subTest(notify=notify):
                runner = Runner(self, relevance={**RELEVANCE, "notify": notify})
                self.assertEqual(1, runner.decide(FakeTools()))
                self.assertIn("::error title=decide-notifications::the relevance file names no notification target, so "
                              "this run does not notify\n", runner.log.getvalue())

    def test_a_matrix_of_another_shape_is_a_fault(self):
        runner = Runner(self, matrix={"include": [{"vars": "x"}]})
        self.assertEqual(1, runner.decide(FakeTools()))
        self.assertIn("::error title=decide-notifications::the matrix is not create-matrix's matrix-json\n",
                      runner.log.getvalue())

    def test_unreadable_stage_results_are_a_warning(self):
        runner = Runner(self)
        runner.write("stages.json", "{")
        self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API)))
        self.assertIn("::warning title=decide-notifications::the stage results cannot be read; every stage reads as "
                      "unknown\n", runner.log.getvalue())

    def test_a_run_number_that_is_not_one_is_a_fault(self):
        runner = Runner(self, environ={"GITHUB_RUN_NUMBER": "x"})
        self.assertEqual(1, runner.decide(FakeTools()))
        self.assertIn("::error title=decide-notifications::the runner set GITHUB_RUN_NUMBER to 'x', which is not a "
                      "run number\n", runner.log.getvalue())


class DecideEdgesTest(unittest.TestCase):
    def test_a_run_with_everything_in_order_warns_of_nothing_and_logs_each_message(self):
        runner = Runner(self)
        self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API)))
        log = runner.log.getvalue()
        self.assertNotIn("::warning", log)
        self.assertIn("::group::decide-notifications: e1: open prod\n::stop-commands::", log)
        self.assertIn("\n❌ **Apply failed** in `prod` · o/r\n", log)

    def test_no_state_file_and_an_empty_path_are_no_state_without_a_warning(self):
        for state in (None, ""):
            with self.subTest(state=state):
                runner = Runner(self, metadata_files={"prod": metadata("prod")})
                if state == "":
                    runner.state = ""
                self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API)))
                self.assertNotIn("::warning", runner.log.getvalue())

    def test_a_state_file_that_cannot_be_read_is_started_over(self):
        for broken in ("{", "dir"):
            with self.subTest(broken=broken):
                runner = Runner(self, metadata_files={"prod": metadata("prod")})
                if broken == "dir":
                    runner.state = os.path.join(runner.dir, "a-directory")
                    os.mkdir(runner.state)
                else:
                    runner.state = runner.write("state.json", broken)
                self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API)))
                self.assertIn("::warning title=decide-notifications::the stored incident state is not one this version "
                              "reads; it starts over\n", runner.log.getvalue())

    def test_metadata_that_cannot_be_decoded_or_names_an_empty_environment(self):
        runner = Runner(self, metadata_files={"x": {"metadata": {"environment": ""}}})
        with open(os.path.join(runner.dir, "matrix-job-meta-bytes.json"), "wb") as handle:
            handle.write(b"\xff\xfe")
        self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API)))
        log = runner.log.getvalue()
        self.assertIn(f"::warning title=decide-notifications::{runner.dir}/matrix-job-meta-bytes.json cannot be read\n",
                      log)
        self.assertIn(f"::warning title=decide-notifications::{runner.dir}/matrix-job-meta-x.json names no environment\n",
                      log)

    def test_the_faults_name_the_file(self):
        for broken, message in (("relevance", "the relevance file cannot be read: "),
                                ("matrix", "the matrix cannot be read: ")):
            with self.subTest(broken=broken):
                runner = Runner(self)
                runner.write(os.path.basename(getattr(runner, broken)), "{")
                self.assertEqual(1, runner.decide(FakeTools()))
                self.assertIn(f"::error title=decide-notifications::{message}", runner.log.getvalue())

    def test_a_relevance_file_or_a_matrix_of_another_shape(self):
        for relevance in ([], {**RELEVANCE, "notify": {**RELEVANCE["notify"], "senders": None}}):
            with self.subTest(relevance=relevance):
                runner = Runner(self, relevance=relevance)
                self.assertEqual(1, runner.decide(FakeTools()))
                self.assertIn("the relevance file names no notification target", runner.log.getvalue())
        runner = Runner(self, matrix=[])
        self.assertEqual(1, runner.decide(FakeTools()))
        self.assertIn("::error title=decide-notifications::the matrix is not create-matrix's matrix-json\n",
                      runner.log.getvalue())

    def test_without_a_job_summary_the_summary_is_only_a_file(self):
        runner = Runner(self)
        del runner.environ["GITHUB_STEP_SUMMARY"]
        self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API)))
        self.assertIn("| `prod` | apply failed |", runner.read(runner.out, "summary.md"))
        self.assertEqual("", runner.read(runner.summary_file))

    def test_unreadable_stage_results_read_every_stage_as_unknown(self):
        runner = Runner(self, metadata_files={})
        runner.write("stages.json", "[1]")
        self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API)))
        self.assertEqual("unknown", json.loads(runner.read(runner.out, "observations.json"))["observations"][0]["result"])

    def test_a_payload_that_is_not_an_object_has_no_people(self):
        runner = Runner(self, payload=[1])
        self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API)))
        self.assertIn("Who made the change could not be read.", runner.read(runner.out, "events", "e1.md"))


class PeopleTest(unittest.TestCase):
    def gather(self, api, payload=PAYLOAD):
        tools = FakeTools(api)
        return notify_evidence.gather_people(tools, "o/r", payload, "main"), tools.endpoints()

    def test_the_first_parent_line_from_after_to_before(self):
        merge, side, middle = "m" * 40, "s" * 40, "c" * 40
        api = {COMPARE: {"commits": [{"sha": side, "parents": [{"sha": BEFORE}]},
                                     {"sha": middle, "parents": [{"sha": BEFORE}]},
                                     {"sha": AFTER, "parents": [{"sha": middle}, {"sha": side}]}]},
               f"repos/o/r/commits/{AFTER}/pulls": [pull(8, base="main"), pull(9, base="other")],
               f"repos/o/r/commits/{middle}/pulls": [pull(7), pull(8), pull(10, merged=False)],
               "repos/o/r/pulls/7": pull(7, author="kim"), "repos/o/r/pulls/8": pull(8)}
        people, endpoints = self.gather(api)
        self.assertEqual({"available": True, "error": None, "pusher": "asmith", "pull_requests": [
            {"number": 8, "title": "Add a storage account", "author": "jdoe", "merged_by": "asmith"},
            {"number": 7, "title": "Add a storage account", "author": "kim", "merged_by": "asmith"}]}, people)
        self.assertEqual([COMPARE, f"repos/o/r/commits/{AFTER}/pulls", f"repos/o/r/commits/{middle}/pulls",
                          "repos/o/r/pulls/8", "repos/o/r/pulls/7"], endpoints)

    def test_a_new_branch_or_a_forced_push_reads_the_head_commit_only(self):
        api = {f"repos/o/r/commits/{AFTER}/pulls": [], "repos/o/r/pulls/7": pull(7)}
        for payload in ({**PAYLOAD, "before": "0" * 40}, {**PAYLOAD, "forced": True}, {**PAYLOAD, "before": None}):
            with self.subTest(payload=payload):
                people, endpoints = self.gather(api, payload)
                self.assertEqual(([], "asmith", [f"repos/o/r/commits/{AFTER}/pulls"]),
                                 (people["pull_requests"], people["pusher"], endpoints))

    def test_a_bot_is_a_bot_by_its_type_too(self):
        api = {**PEOPLE_API, "repos/o/r/pulls/7": {**pull(7), "user": {"login": "renovate", "type": "Bot"},
                                                   "merged_by": None}}
        people, _ = self.gather(api, {**PAYLOAD, "sender": {"login": "merge-app", "type": "Bot"}})
        self.assertEqual(([{"number": 7, "title": "Add a storage account", "author": None, "merged_by": None}], None),
                         (people["pull_requests"], people["pusher"]))

    def test_a_failure_is_a_fact(self):
        for api, error in (({COMPARE: (1, "", "HTTP 502")}, f"gh api {COMPARE} failed: HTTP 502"),
                           ({COMPARE: {"files": []}}, f"gh api {COMPARE} answered without commits"),
                           ({**PEOPLE_API, f"repos/o/r/commits/{AFTER}/pulls": {"x": 1}},
                            f"gh api repos/o/r/commits/{AFTER}/pulls answered without a list"),
                           ({**PEOPLE_API, "repos/o/r/pulls/7": [1]}, "gh api repos/o/r/pulls/7 answered without a "
                                                                      "pull request"),
                           ({COMPARE: (0, "not json", "")}, f"gh api {COMPARE} did not answer with JSON")):
            with self.subTest(error=error):
                self.assertEqual({"available": False, "error": error, "pull_requests": [], "pusher": None},
                                 self.gather(api)[0])
        self.assertEqual("the event payload carries no 'after' commit",
                         self.gather({}, {**PAYLOAD, "after": None})[0]["error"])

    def test_more_answers_that_are_not_what_was_asked(self):
        for api, payload, error in (
                ({COMPARE: [1]}, PAYLOAD, f"gh api {COMPARE} answered without commits"),
                ({COMPARE: {"commits": [{"sha": AFTER}]}}, PAYLOAD, f"gh api {COMPARE} answered with commits of another "
                                                                   "shape"),
                ({COMPARE: {"commits": [{"sha": AFTER, "parents": ["x"]}]}}, PAYLOAD,
                 f"gh api {COMPARE} answered with commits of another shape"),
                ({}, {**PAYLOAD, "after": ""}, "the event payload carries no 'after' commit")):
            with self.subTest(error=error):
                self.assertEqual(error, self.gather(api, payload)[0]["error"])

    def test_a_long_error_is_cut(self):
        self.assertEqual(f"gh api {COMPARE} failed: " + "x" * 500,
                         self.gather({COMPARE: (1, "", "x" * 600)})[0]["error"])

    def test_a_pull_request_without_a_title_and_a_user_without_a_login(self):
        api = {**PEOPLE_API, "repos/o/r/pulls/7": {**pull(7), "title": None, "user": {"type": "User"}}}
        people, _ = self.gather(api)
        self.assertEqual([{"number": 7, "title": "", "author": None, "merged_by": "asmith"}], people["pull_requests"])

    def test_gh_that_cannot_run_is_a_fact(self):
        class Missing(FakeTools):
            def run(self, argv, stdin=""):
                raise FileNotFoundError(2, "No such file or directory", "gh")
        self.assertEqual("'gh' cannot be run on this runner: [Errno 2] No such file or directory: 'gh'",
                         notify_evidence.gather_people(Missing(), "o/r", PAYLOAD, "main")["error"])

    def test_the_line_stops_at_its_limit(self):
        shas = [f"{n:040d}" for n in range(1, 70)]
        commits = [{"sha": sha, "parents": [{"sha": shas[index - 1] if index else BEFORE}]}
                   for index, sha in enumerate(shas)]
        line = notify_evidence.first_parent(commits, BEFORE, shas[-1])
        self.assertEqual(shas[::-1][:50], line)
        self.assertEqual([AFTER], notify_evidence.first_parent([], BEFORE, AFTER))
        self.assertEqual([AFTER], notify_evidence.first_parent([{"sha": AFTER, "parents": []}], BEFORE, AFTER))


IDENTITIES = {"jdoe": saml(), "asmith": saml("100002@example.org", "Ola", "Nordmann", "oid-asmith")}
WITH_APP = {"NOTIFY_IDENTITY_TOKEN": "ghs_identity", "NOTIFY_PEOPLE_DOMAINS": "example.org"}


class IdentityDecideTest(unittest.TestCase):
    """The identity App's lookups in the decide step (§5, D21)."""

    def graphql(self, runner):
        return [(call[8], env) for call, env in zip(runner.tools.calls, runner.tools.envs) if call[2] == "graphql"]

    def test_a_push_names_and_mentions_people_by_their_identity(self):
        runner = Runner(self, environ=WITH_APP)
        self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API, IDENTITIES)))
        self.assertEqual([{"login": "jdoe", "object_id": "oid-jdoe", "name": "Jane Doe", "key": "p1"}],
                         json.loads(runner.read(runner.out, "events", "e1.json"))["mentions"])
        self.assertIn("`Add a storage account` by <at>p1</at>, merged by Ola Nordmann.",
                      runner.read(runner.out, "events", "e1.md"))
        # The relay's mentions, beside the message the deliver job posts.
        self.assertEqual([{"key": "p1", "id": "oid-jdoe", "name": "Jane Doe"}],
                         json.loads(runner.read(runner.out, "events", "e1.mentions.json")))
        self.assertEqual([("login=jdoe", {"GH_TOKEN": "ghs_identity"}), ("login=asmith", {"GH_TOKEN": "ghs_identity"})],
                         self.graphql(runner))
        self.assertNotIn("::warning", runner.log.getvalue())
        for root, _, files in os.walk(runner.dir):
            for name in files:
                self.assertNotIn("ghs_identity", runner.read(root, name))
        self.assertNotIn("ghs_identity", runner.log.getvalue())

    def test_only_a_run_that_names_people_looks_them_up(self):
        runner = Runner(self, metadata_files={"prod": metadata("prod")}, environ=WITH_APP)
        self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API, IDENTITIES)))
        self.assertEqual([], self.graphql(runner))
        runner = Runner(self, environ={**WITH_APP, "GITHUB_EVENT_NAME": "schedule"})
        self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API, IDENTITIES)))
        self.assertEqual([], self.graphql(runner))
        api = {**PEOPLE_API, "repos/o/r/pulls/7": pull(7, author="dependabot[bot]", merged_by="merger[bot]")}
        runner = Runner(self, environ=WITH_APP)
        self.assertEqual(0, runner.decide(FakeTools(api, IDENTITIES)))
        self.assertEqual([], self.graphql(runner))
        self.assertNotIn("::warning", runner.log.getvalue())

    def test_a_token_without_domains_or_domains_without_a_token_is_a_warning(self):
        for environ, warning in (
                ({"NOTIFY_PEOPLE_DOMAINS": "example.org"}, "TF_NOTIFY_PEOPLE_DOMAINS is set, but the decide job has no "
                 "identity App token (TF_NOTIFY_IDENTITY_APP_ID and its key): people are named by login and "
                 "mentioned by nobody"),
                ({"NOTIFY_IDENTITY_TOKEN": "ghs_identity", "NOTIFY_PEOPLE_DOMAINS": " , "},
                 "the identity App is set, but TF_NOTIFY_PEOPLE_DOMAINS is not: people are named by login and "
                 "mentioned by nobody")):
            with self.subTest(environ=environ):
                runner = Runner(self, environ=environ)
                self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API, IDENTITIES)))
                self.assertEqual([], self.graphql(runner))
                self.assertIn(f"::warning title=decide-notifications::{warning}\n", runner.log.getvalue())
                self.assertIn("by jdoe, merged by asmith.", runner.read(runner.out, "events", "e1.md"))
        runner = Runner(self)
        self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API, IDENTITIES)))
        self.assertEqual([], self.graphql(runner))
        self.assertNotIn("::warning", runner.log.getvalue())

    def test_a_lookup_that_fails_is_a_warning_and_names_logins(self):
        identities = {**IDENTITIES, "jdoe": (1, "", "GraphQL: Resource not accessible by integration "
                                                    "(organization.samlIdentityProvider)\n")}
        runner = Runner(self, environ=WITH_APP)
        self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API, identities)))
        self.assertEqual(["login=jdoe"], [login for login, _ in self.graphql(runner)])
        self.assertIn("::warning title=decide-notifications::the identities of the people named cannot be read, so "
                      "they are named by login and mentioned by nobody: the identity of jdoe cannot be read: GraphQL: "
                      "Resource not accessible by integration (organization.samlIdentityProvider)\n",
                      runner.log.getvalue())
        self.assertIn("by jdoe, merged by asmith.", runner.read(runner.out, "events", "e1.md"))
        self.assertEqual([], json.loads(runner.read(runner.out, "events", "e1.json"))["mentions"])

    def test_the_domains_are_a_comma_separated_list(self):
        self.assertEqual(["example.org", "example.com"], notify_evidence.people_domains(" Example.ORG , @Example.com ,,"))
        self.assertEqual([], notify_evidence.people_domains(""))


class ReminderDecideTest(unittest.TestCase):
    """A scheduled run reminds of an open incident (§10), with the run's clock and the people it mentions."""

    def runner(self, environ=None):
        opened = {"kind": "apply-failed", "status": "open", "message_id": "msg-1", "alias": "tf-alerts",
                  "sender": "prod", "opened_at": "2026-10-05T08:30:00Z", "opened_run": 40, "seen_run": 40,
                  "people": ["jdoe", "asmith"], "resolved_at": None, "mentioned": ["jdoe"], "reminder_level": 0,
                  "reminded_at": None}
        return Runner(self, state={"schema_version": 1, "incidents": {"prod/apply": opened}},
                      environ={"GITHUB_EVENT_NAME": "schedule", **(environ or {})})

    def test_a_working_day_after_it_opened_a_schedule_reminds(self):
        runner = self.runner(WITH_APP)
        self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API, IDENTITIES)))
        event = json.loads(runner.read(runner.out, "events", "e1.json"))
        self.assertEqual(("remind", "msg-1", [{"login": "jdoe", "object_id": "oid-jdoe", "name": "Jane Doe", "key": "p1"}]),
                         (event["action"], event["reply_to"], event["mentions"]))
        self.assertEqual("⏰ **Still not applied** in `prod` · o/r",
                         runner.read(runner.out, "events", "e1.md").split("\n")[0])
        self.assertIn("The change was by <at>p1</at> and Ola Nordmann.", runner.read(runner.out, "events", "e1.md"))
        self.assertEqual(["login=jdoe", "login=asmith"], [call[8] for call in runner.tools.calls if call[2] == "graphql"])
        self.assertEqual(1, json.loads(runner.read(runner.out, "observations.json"))["observations"][0]["reminder_level"])

    def test_the_day_after_it_opened_nothing_is_due(self):
        runner = self.runner()
        runner.clock = lambda: datetime.datetime(2026, 10, 6, 23, 0, 0, tzinfo=datetime.timezone.utc)
        self.assertEqual(0, runner.decide(FakeTools(PEOPLE_API)))
        self.assertEqual("0", runner.outputs()["deliver-count"])


class IdentityTest(unittest.TestCase):
    def gather(self, answers, logins=("jdoe",)):
        tools = FakeTools(identities=answers)
        return notify_evidence.gather_identities(tools, "o", list(logins), "ghs_identity"), tools

    def test_an_identity_is_its_name_object_id_and_upn(self):
        found, tools = self.gather({"jdoe": saml(given=" Jane ", family="van Doe ")})
        self.assertEqual({"available": True, "error": None, "people": {
            "jdoe": {"name": "Jane van Doe", "object_id": "oid-jdoe", "upn": "100001@example.org"}}}, found)
        self.assertEqual([("gh", "api", "graphql", "-f", f"query={QUERY}", "-f", "org=o", "-f", "login=jdoe")],
                         tools.calls)
        self.assertEqual([{"GH_TOKEN": "ghs_identity"}], tools.envs)

    def test_a_name_may_be_partly_or_wholly_absent(self):
        for given, family, name in (("Jane", None, "Jane"), (None, "Doe", "Doe"), ("", " ", ""), (5, None, "")):
            with self.subTest(given=given, family=family):
                found, _ = self.gather({"jdoe": saml(given=given, family=family)})
                self.assertEqual(name, found["people"]["jdoe"]["name"])

    def test_a_login_without_a_usable_identity_has_none(self):
        empty = {"data": {"organization": {"samlIdentityProvider": {"externalIdentities": {"nodes": []}}}}}
        no_saml = {"data": {"organization": {"samlIdentityProvider": {"externalIdentities": {"nodes": [
            {"samlIdentity": None}]}}}}}
        no_attributes = saml()
        no_attributes["data"]["organization"]["samlIdentityProvider"]["externalIdentities"]["nodes"][0][
            "samlIdentity"]["attributes"] = None
        odd_attribute = saml()
        odd_attribute["data"]["organization"]["samlIdentityProvider"]["externalIdentities"]["nodes"][0][
            "samlIdentity"]["attributes"].insert(0, "x")
        for answer, expected in ((empty, None), (no_saml, None), (saml(object_id=None), None),
                                 (saml(object_id=""), None), (saml(object_id=5), None), (saml(username=None), None),
                                 (saml(username="no-domain"), None), (no_attributes, None)):
            with self.subTest(answer=answer):
                found, _ = self.gather({"jdoe": answer})
                self.assertEqual({"available": True, "error": None, "people": {"jdoe": expected}}, found)
        found, _ = self.gather({"jdoe": odd_attribute})
        self.assertEqual("oid-jdoe", found["people"]["jdoe"]["object_id"])

    def test_every_login_is_looked_up_once_in_order(self):
        found, tools = self.gather({"jdoe": saml(), "asmith": saml(object_id=None)}, ("jdoe", "asmith"))
        self.assertEqual(["jdoe", "asmith"], list(found["people"]))
        self.assertEqual(["login=jdoe", "login=asmith"], [call[8] for call in tools.calls])

    def test_an_answer_that_cannot_be_used_is_a_fact(self):
        no_provider = {"data": {"organization": {"samlIdentityProvider": None}}}
        for answer, error in (
                ((1, "", "GraphQL: Resource not accessible by integration\n"),
                 "the identity of jdoe cannot be read: GraphQL: Resource not accessible by integration"),
                ((1, "out\n", ""), "the identity of jdoe cannot be read: out"),
                ((0, "not json", ""), "the identity of jdoe cannot be read: the answer is not JSON"),
                (no_provider, "the identity App's token sees no SAML identities in o"),
                ({"data": None}, "the identity App's token sees no SAML identities in o")):
            with self.subTest(answer=answer):
                found, tools = self.gather({"jdoe": answer, "asmith": saml()}, ("jdoe", "asmith"))
                self.assertEqual({"available": False, "error": error, "people": {}}, found)
                self.assertEqual(1, len(tools.calls))

    def test_a_long_error_is_cut(self):
        found, _ = self.gather({"jdoe": (1, "", "x" * 600)})
        self.assertEqual("the identity of jdoe cannot be read: " + "x" * 500, found["error"])

    def test_gh_that_cannot_run_is_a_fact(self):
        class Missing(FakeTools):
            def run(self, argv, stdin="", env=None):
                raise FileNotFoundError("gh")

        found = notify_evidence.gather_identities(Missing(), "o", ["jdoe"], "t")
        self.assertEqual({"available": False, "error": "'gh' cannot be run on this runner: gh", "people": {}}, found)


class ProtectionTest(unittest.TestCase):
    def protected(self, answer):
        return notify_evidence.protected(FakeTools({"repos/o/r/environments/prod%20x": answer}
                                                   if answer is not None else {}), "o/r", "prod x")

    def test_rules_that_hold_a_job(self):
        self.assertEqual(True, self.protected({"protection_rules": [{"type": "required_reviewers"}]}))
        self.assertEqual(True, self.protected({"protection_rules": [{"type": "branch_policy"}, {"type": "wait_timer"}]}))
        self.assertEqual(True, self.protected({"protection_rules": ["?"]}))

    def test_no_rule_that_holds_a_job(self):
        self.assertEqual(False, self.protected({"protection_rules": [{"type": "branch_policy"}]}))
        self.assertEqual(False, self.protected({"protection_rules": []}))
        self.assertEqual(False, self.protected({"name": "prod x"}))
        # GitHub creates an environment the first time a job uses it: one that does not exist holds nothing.
        self.assertEqual(False, self.protected(None))

    def test_an_answer_that_cannot_be_read_is_unknown(self):
        self.assertEqual(None, self.protected((1, "", "HTTP 403")))
        self.assertEqual(None, self.protected((0, "not json", "")))
        self.assertEqual(None, self.protected({"protection_rules": "x"}))
        self.assertEqual(None, self.protected([]))


class RecordTest(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.dir = self.work.name
        self.output_file = self.path("output.txt", "")
        self.summary_file = self.path("summary.md", "")
        self.environ = {"GITHUB_OUTPUT": self.output_file, "GITHUB_STEP_SUMMARY": self.summary_file}
        self.log = io.StringIO()

    def path(self, name, content):
        path = os.path.join(self.dir, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content if isinstance(content, str) else json.dumps(content))
        return path

    def record(self, observations, results=(), state=None):
        observations_file = self.path("observations.json", {"run_number": 42, "observations": observations})
        for index, result in enumerate(results):
            self.path(f"notify-result-e{index + 1}.json", result)
        state_file = self.path("state.json", state) if state is not None else os.path.join(self.dir, "none.json")
        self.out_file = os.path.join(self.dir, "new-state.json")
        return notify_evidence.run_record(state_file, observations_file, os.path.join(self.dir, "notify-result-*.json"),
                                          self.out_file, self.environ, self.log, CLOCK)

    def read(self, path):
        with open(path, encoding="utf-8") as handle:
            return handle.read()

    def observation(self, event="e1", sending=True):
        return {"environment": "prod", "slot": "apply", "result": "failed", "kind": "apply-failed", "action": "open",
                "event": event, "people": ["jdoe"], "alias": "tf-alerts", "sender": "prod", "sending": sending,
                "mentioned": ["jdoe"], "reminder_level": None, "fingerprint": None, "checks": None}

    def test_an_accepted_delivery_opens_the_incident_and_the_state_changed(self):
        self.assertEqual(0, self.record([self.observation()], [{"id": "e1", "accepted": "true",
                                                                "message_id": "msg-9", "http_status": "202"}]))
        state = json.loads(self.read(self.out_file))
        self.assertEqual(("open", "msg-9", "2026-10-07T12:00:00Z"),
                         (state["incidents"]["prod/apply"]["status"], state["incidents"]["prod/apply"]["message_id"],
                          state["incidents"]["prod/apply"]["opened_at"]))
        self.assertEqual("changed<<", self.read(self.output_file).split("EOF_")[0])
        self.assertEqual("true", self.read(self.output_file).splitlines()[1])
        self.assertEqual("", self.read(self.summary_file))

    def test_a_delivery_that_failed_or_never_answered_is_in_the_summary(self):
        observations = [self.observation(), {**self.observation(event="e2"), "environment": "dev"},
                        {**self.observation(event="e3", sending=False), "environment": "qa"}]
        self.assertEqual(0, self.record(observations, [{"id": "e1", "accepted": "false", "message_id": "",
                                                        "http_status": "503"}]))
        self.assertEqual("\n".join(["### 📣 Teams deliveries", "",
                                    "- `prod`: not accepted by the relay (HTTP 503); it is posted again by the next run "
                                    "that sees it",
                                    "- `dev`: its deliver job left no answer; it is posted again by the next run that "
                                    "sees it", ""]), self.read(self.summary_file))
        self.assertEqual("pending", json.loads(self.read(self.out_file))["incidents"]["prod/apply"]["status"])

    def test_nothing_new_is_no_change(self):
        state = {"schema_version": 1, "incidents": {}}
        self.assertEqual(0, self.record([], state=state))
        self.assertEqual("false", self.read(self.output_file).splitlines()[1])

    def test_tombstones_are_dropped_after_thirty_days(self):
        state = {"schema_version": 1, "incidents": {"old/apply": {
            "kind": "apply-failed", "status": "resolved", "message_id": "m", "alias": "a", "sender": "s",
            "opened_at": "x", "opened_run": 1, "seen_run": 1, "people": [], "resolved_at": "2026-09-07T11:59:59Z"},
            "new/apply": {"kind": "apply-failed", "status": "resolved", "message_id": "m", "alias": "a", "sender": "s",
                          "opened_at": "x", "opened_run": 1, "seen_run": 1, "people": [],
                          "resolved_at": "2026-09-07T12:00:00Z"}}}
        self.assertEqual(0, self.record([], state=state))
        self.assertEqual(["new/apply"], list(json.loads(self.read(self.out_file))["incidents"]))

    def test_a_result_that_cannot_be_read_counts_as_no_answer(self):
        self.path("notify-result-x.json", "not json")
        self.assertEqual(0, self.record([self.observation()]))
        self.assertIn("- `prod`: its deliver job left no answer", self.read(self.summary_file))
        self.assertIn("::warning title=record-notifications::", self.log.getvalue())

    def test_the_new_state_is_written_where_asked_its_directory_made(self):
        observations_file = self.path("observations.json", {"run_number": 42, "observations": []})
        out_file = os.path.join(self.dir, "new", "deeper", "state.json")
        self.assertEqual(0, notify_evidence.run_record(os.path.join(self.dir, "none.json"), observations_file,
                                                       os.path.join(self.dir, "r-*.json"), out_file, self.environ,
                                                       self.log, CLOCK))
        self.assertEqual({"incidents": {}, "schema_version": 1}, json.loads(self.read(out_file)))

    def test_an_answer_of_another_shape(self):
        results = [{"id": "e1", "accepted": True, "message_id": "", "http_status": "202"}]
        self.assertEqual(0, self.record([self.observation()], results))
        self.assertEqual(("open", None), (json.loads(self.read(self.out_file))["incidents"]["prod/apply"]["status"],
                                          json.loads(self.read(self.out_file))["incidents"]["prod/apply"]["message_id"]))
        self.path("notify-result-e1.json", {"id": "e1", "accepted": "true", "message_id": 5})
        self.assertEqual(0, self.record([self.observation()]))
        self.assertIsNone(json.loads(self.read(self.out_file))["incidents"]["prod/apply"]["message_id"])

    def test_a_stored_state_of_another_shape_is_started_over_and_none_is_quiet(self):
        self.assertEqual(0, self.record([], state={"schema_version": 9}))
        self.assertIn("::warning title=record-notifications::the stored incident state is not one this version reads; "
                      "it starts over\n", self.log.getvalue())
        self.log = io.StringIO()
        self.assertEqual(0, self.record([]))
        self.assertEqual("", self.log.getvalue())

    def test_observations_of_another_shape_are_a_fault(self):
        for observed in ({"run_number": "42", "observations": []}, {"run_number": 42, "observations": {}}, []):
            with self.subTest(observed=observed):
                observations_file = self.path("observations.json", observed)
                self.assertEqual(1, notify_evidence.run_record("x", observations_file, "none-*",
                                                               os.path.join(self.dir, "o"), self.environ, self.log, CLOCK))
                self.assertIn("::error title=record-notifications::the observations are not decide-notifications' "
                              "observations.json\n", self.log.getvalue())

    def test_observations_that_cannot_be_read_are_a_fault(self):
        observations_file = self.path("observations.json", "{")
        self.assertEqual(1, notify_evidence.run_record("x", observations_file, "none-*", os.path.join(self.dir, "o"),
                                                       self.environ, self.log, CLOCK))
        self.assertIn("::error title=record-notifications::the observations cannot be read", self.log.getvalue())


if __name__ == "__main__":
    unittest.main()
