"""The create-matrix adapter: how it reads, parses, learns facts, builds the document and publishes.

yq and gh are stood in for by FakeTools, so every branch is reached without the programs; the
create-tf-vars-matrix suite runs the real ones end to end. FakeTools' yq reads JSON, which is
YAML, and refuses anything else, so a case written as JSON text parses as yq would parse it.
"""

import io
import json
import os
import sys
import tempfile
import unittest

import support
from dsb_tf_engine import adapter, decide, environments


class FakeTools:
    """yq and gh as the adapter calls them; records every call."""

    def __init__(self, yq_broken=None, gh=(0, '{"default_branch": "from-api"}', ""), missing=(), api=None):
        self.calls = []
        self.yq_broken = yq_broken
        self.gh = gh
        self.missing = missing
        # The changed-file endpoints: {endpoint: (code, stdout, stderr) or a JSON-able answer}.
        self.api = api or {}

    def run(self, argv, stdin=""):
        self.calls.append((tuple(argv), stdin))
        if argv[0] in self.missing:
            raise FileNotFoundError(2, "No such file or directory", argv[0])
        if argv[0] == "gh" and (len(argv) != 3 or argv[1] != "api"):
            return 1, "", f"unknown command {argv[1:]} for gh"
        if argv[0] == "gh" and argv[2] in self.api:
            answer = self.api[argv[2]]
            return answer if isinstance(answer, tuple) else (0, json.dumps(answer), "")
        if argv[0] == "gh" and argv[2] != "repos/o/r":
            return 1, "", f"gh: Not Found (HTTP 404) for {argv[2]}"
        if argv[0] == "gh":
            return self.gh
        if self.yq_broken is not None:
            return self.yq_broken
        if argv == ("yq", "e", "-o=json", "-I=0", "-") and stdin == "probe: [1]\n":
            return 0, '{"probe":[1]}\n', ""
        if argv != ("yq", "e", "-o=json", "-"):
            return 64, "", f"unexpected yq arguments {argv}"
        if stdin.strip() == "":
            return 0, "null\n", ""
        try:
            return 0, json.dumps(json.loads(stdin)) + "\n", ""
        except ValueError:
            return 1, "", "Error: bad file '-': yaml: line 1: did not find expected node content\n"

    def yq_inputs(self):
        return [stdin for argv, stdin in self.calls if argv[0] == "yq" and "-I=0" not in argv]

    def endpoints(self):
        return [argv[2] for argv, _ in self.calls if argv[0] == "gh"]


DEFAULT_INPUTS = {
    "environments-yml": '[{"environment": "env-a"}]',
    "add-pr-comment": True, "apply-extract-include-outputs": False, "cache-terraform-modules": True,
    "pr-auto-merge-enabled": False, "pr-comment-group": "", "terraform-version": "latest",
    "tflint-version": "latest", "verify-lock-file": True, "path-relevance-enabled": True,
}


PUSH_PAYLOAD = {"repository": {"default_branch": "main"}, "before": "b" * 40, "after": "a" * 40}
COMPARE = f"repos/o/r/compare/{'b' * 40}...{'a' * 40}"


class Runner:
    """A temporary runner: inputs file, event payload, GITHUB_OUTPUT and a captured log."""

    def __init__(self, test, inputs=None, payload=None, environ=None):
        self.work = tempfile.TemporaryDirectory()
        test.addCleanup(self.work.cleanup)
        path = self.work.name
        self.inputs_file = os.path.join(path, "inputs.json")
        with open(self.inputs_file, "w", encoding="utf-8") as handle:
            handle.write(inputs if isinstance(inputs, str) else json.dumps(DEFAULT_INPUTS if inputs is None else inputs))
        self.event_file = os.path.join(path, "event.json")
        with open(self.event_file, "w", encoding="utf-8") as handle:
            json.dump(PUSH_PAYLOAD if payload is None else payload, handle)
        self.output_file = os.path.join(path, "output.txt")
        open(self.output_file, "w").close()
        self.environ = {"GITHUB_REPOSITORY": "o/r", "GITHUB_EVENT_NAME": "push", "GITHUB_REF_NAME": "main",
                        "GITHUB_EVENT_PATH": self.event_file, "GITHUB_OUTPUT": self.output_file,
                        "GITHUB_RUN_ID": "4711", "GITHUB_RUN_ATTEMPT": "2", "RUNNER_TEMP": os.path.join(path, "temp")}
        os.mkdir(self.environ["RUNNER_TEMP"])
        self.environ.update(environ or {})
        self.log = io.StringIO()

    def run(self, tools=None, isdir=lambda path: True):
        self.tools = tools or FakeTools(api={COMPARE: {"files": [{"filename": "envs/env-a/main.tf"}]}})
        return adapter.run(self.inputs_file, self.environ, self.log, self.tools, isdir)

    def output(self):
        with open(self.output_file, encoding="utf-8") as handle:
            return handle.read()

    def outputs(self):
        """{name: value} of the step outputs, in the order written; each one line under its delimiter."""
        lines, outputs = self.output().splitlines(), {}
        for index in range(0, len(lines), 3):
            name, delimiter = lines[index].split("<<")
            assert lines[index + 2] == delimiter, lines
            outputs[name] = lines[index + 1]
        return outputs

    def matrix(self):
        outputs = self.outputs()
        return json.loads(outputs["matrix-json"]) if outputs else None


class TextTest(unittest.TestCase):
    """How a value is read before yq sees it: the port's contract with the bash builder."""

    def test_an_input_gets_exactly_one_trailing_newline(self):
        for value, text in [("a: 1", "a: 1\n"), ("a: 1\n\n\n", "a: 1\n"), ("", "\n"), (None, "\n"), (False, "\n"),
                            (True, "true\n"), (5, "5\n"), ([1], "[1]\n"), ({"a": 1}, '{"a": 1}\n'), ("a\n\nb", "a\n\nb\n")]:
            with self.subTest(value=value):
                self.assertEqual(text, adapter.input_text(value))

    def test_a_field_gets_no_trailing_newline_and_false_stays_false(self):
        for value, text in [("- a\n", "- a"), ("x\n\n", "x"), (None, ""), (False, "false"), (True, "true"),
                            (0, "0"), (["a"], '["a"]'), ({"a": None}, '{"a": null}'), ("", "")]:
            with self.subTest(value=value):
                self.assertEqual(text, adapter.field_text(value))


class ParseTest(unittest.TestCase):
    def test_parse_results(self):
        tools = FakeTools()
        self.assertEqual({"ok": True, "value": {"a": 1}}, adapter.parse_yaml(tools, '{"a": 1}'))
        self.assertEqual({"ok": True, "value": None}, adapter.parse_yaml(tools, ""))
        self.assertEqual({"ok": False, "value": None}, adapter.parse_yaml(tools, "a: [b"))
        self.assertEqual([(("yq", "e", "-o=json", "-"), '{"a": 1}')], tools.calls[:1])

    def test_a_failed_yq_does_not_parse_even_when_it_printed_json(self):
        self.assertEqual({"ok": False, "value": None}, adapter.parse_yaml(FakeTools(yq_broken=(1, "null\n", "e")), "x"))

    def test_output_that_is_not_one_json_document_does_not_parse(self):
        for stdout in ('{"a": 1}\n{"b": 2}\n', "", "not json"):
            with self.subTest(stdout=stdout):
                tools = FakeTools(yq_broken=(0, stdout, ""))
                self.assertEqual({"ok": False, "value": None}, adapter.parse_yaml(tools, "x"))

    def test_only_yml_inputs_are_parsed_in_sorted_order_as_echo_fed_them(self):
        tools = FakeTools()
        parsed = adapter.parse_inputs(tools, {"z-yml": "[1]\n\n", "a-yml": None, "terraform-version": "x",
                                              "b-yml": "bad: [", "yml": "[2]"})
        self.assertEqual(["a-yml", "b-yml", "z-yml"], sorted(parsed))
        self.assertEqual(["\n", "bad: [\n", "[1]\n"], tools.yq_inputs())
        self.assertEqual({"ok": True, "value": None}, parsed["a-yml"])
        self.assertFalse(parsed["b-yml"]["ok"])
        self.assertEqual([1], parsed["z-yml"]["value"])

    def test_environment_fields_align_with_the_entries_and_skip_what_is_not_a_mapping(self):
        tools = FakeTools()
        parsed = adapter.parse_environments(tools, [
            {"environment": "a", "goals-yml": "[\"plan\"]\n", "url": "x", "extra-envs-yml": False},
            "not-a-mapping", None, {"environment": "b"}])
        self.assertEqual([{"extra-envs-yml": {"ok": True, "value": False}, "goals-yml": {"ok": True, "value": ["plan"]}},
                          {}, {}, {}], parsed)
        self.assertEqual(["false", '["plan"]'], tools.yq_inputs())

    def test_environments_that_are_not_a_list_yield_no_field_results(self):
        for entries in (None, {"environment": "a"}, "text"):
            with self.subTest(entries=entries):
                self.assertEqual([], adapter.parse_environments(FakeTools(), entries))


class YqProbeTest(unittest.TestCase):
    def test_a_working_yq_passes(self):
        tools = FakeTools()
        adapter.require_yq(tools)
        self.assertEqual([(("yq", "e", "-o=json", "-I=0", "-"), "probe: [1]\n")], tools.calls)

    def test_a_broken_yq_is_named_with_its_own_message(self):
        for result, detail in [((127, "", "yq: not found\n"), "yq: not found"), ((1, "Error: unknown command\n", ""), "Error: unknown command"),
                               ((0, "not json\n", ""), "not json"), ((0, '{"probe": [1]}\n', ""), '{"probe": [1]}')]:
            with self.subTest(result=result):
                with self.assertRaises(adapter.AdapterError) as raised:
                    adapter.require_yq(FakeTools(yq_broken=result))
                self.assertEqual("yq on the runner cannot parse YAML to JSON, so no input can be read", raised.exception.message)
                self.assertEqual(detail, raised.exception.detail)

    def test_a_missing_program_is_named(self):
        with self.assertRaises(adapter.AdapterError) as raised:
            adapter.require_yq(FakeTools(missing=("yq",)))
        self.assertIn("'yq' cannot be run on this runner", raised.exception.message)

    def test_the_detail_is_capped(self):
        with self.assertRaises(adapter.AdapterError) as raised:
            adapter.require_yq(FakeTools(yq_broken=(1, "", "x" * 5000)))
        self.assertEqual(500, len(raised.exception.detail))


class DefaultBranchTest(unittest.TestCase):
    def test_the_payload_answers_without_the_api(self):
        tools = FakeTools()
        self.assertEqual("trunk", adapter.default_branch({"repository": {"default_branch": "trunk"}}, "o/r", tools))
        self.assertEqual([], tools.calls)

    def test_the_api_answers_when_the_payload_cannot(self):
        for payload in ({}, {"repository": {}}, {"repository": {"default_branch": ""}},
                        {"repository": {"default_branch": 5}}, {"repository": None}, {"repository": []}):
            with self.subTest(payload=payload):
                tools = FakeTools()
                self.assertEqual("from-api", adapter.default_branch(payload, "o/r", tools))
                self.assertEqual([(("gh", "api", "repos/o/r"), "")], tools.calls)

    def test_an_api_that_cannot_answer_is_an_error_showing_its_answer(self):
        for gh in [(1, "", "HTTP 404: Not Found"), (0, "not json", ""), (0, '{"name": "r"}', ""), (0, '{"default_branch": ""}', ""),
                   (0, "[]", ""), (1, '{"default_branch": "main"}', "")]:
            with self.subTest(gh=gh):
                with self.assertRaises(adapter.AdapterError) as raised:
                    adapter.default_branch({}, "o/r", FakeTools(gh=gh))
                self.assertEqual("could not resolve the default branch of 'o/r', the API answered:", raised.exception.message)
                self.assertEqual((gh[1] + gh[2]).strip(), raised.exception.detail)

    def test_the_apis_answer_is_capped(self):
        with self.assertRaises(adapter.AdapterError) as raised:
            adapter.default_branch({}, "o/r", FakeTools(gh=(1, "y" * 5000, "")))
        self.assertEqual(2000, len(raised.exception.detail))

    def test_an_adapter_error_reads_as_its_message(self):
        self.assertEqual("m", str(adapter.AdapterError("m", "d")))

    def test_a_missing_gh_is_named(self):
        with self.assertRaises(adapter.AdapterError) as raised:
            adapter.default_branch({}, "o/r", FakeTools(missing=("gh",)))
        self.assertIn("'gh' cannot be run", raised.exception.message)


class DirectoriesTest(unittest.TestCase):
    def test_every_named_or_default_directory_is_checked_as_the_engine_renders_it(self):
        seen = []
        result = adapter.check_directories(
            [{"environment": "a"}, {"environment": 7, "project-dir": None}, {"environment": "b", "project-dir": "d\n"},
             {"project-dir": "no-name"}, "not-a-mapping"],
            lambda path: seen.append(path) or path != "null")
        self.assertEqual({"./envs/a": True, "null": False, "d": True}, result)
        self.assertEqual(["./envs/a", "null", "d"], seen)

    def test_no_list_means_no_directories(self):
        self.assertEqual({}, adapter.check_directories(None, lambda path: True))

    def test_the_path_is_the_one_the_built_row_is_checked_with(self):
        for environment in ({"environment": "a"}, {"environment": "a", "project-dir": 3},
                            {"environment": "a", "project-dir": None}, {"environment": "a", "project-dir": "d\n"}):
            with self.subTest(environment=environment):
                document = support.document(environments=[environment], directories={})
                globals_ = environments.parsed_inputs(document)
                row = environments.build_row(document, globals_, 0, environment)
                from dsb_tf_engine import values
                self.assertEqual(values.render(row["project-dir"]), environments.project_dir_path(environment))


class ReadInputsTest(unittest.TestCase):
    def write(self, content):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        path = os.path.join(work.name, "inputs.json")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content)
        return path

    def test_an_object_is_read(self):
        self.assertEqual({"a": 1}, adapter.read_inputs(self.write('{"a": 1}')))

    def test_what_is_not_a_json_object_is_refused(self):
        for content, fragment in [("environments-yml: x", "cannot be read as JSON"), ("", "cannot be read as JSON"),
                                  ('["a"]', "is not a JSON object"), ("null", "is not a JSON object"), ('"s"', "is not a JSON object")]:
            with self.subTest(content=content):
                with self.assertRaises(adapter.AdapterError) as raised:
                    adapter.read_inputs(self.write(content))
                self.assertIn(fragment, raised.exception.message)

    def test_a_missing_file_is_refused(self):
        with self.assertRaises(adapter.AdapterError):
            adapter.read_inputs("/nonexistent/inputs.json")


class BuildDocumentTest(unittest.TestCase):
    FACTS = {"repository": "o/r", "default_branch": "main", "event_name": "workflow_dispatch", "ref_name": "feature/x",
             "payload": {}, "run": {"id": 4711, "attempt": 1}}

    def test_the_document_is_complete_and_valid(self):
        document = adapter.build_document(DEFAULT_INPUTS, self.FACTS, FakeTools(), lambda path: True)
        self.assertEqual({"schema_version": 1, "caller": {"repository": "o/r", "default_branch": "main"},
                          "event": {"name": "workflow_dispatch", "ref_name": "feature/x"}, "workflow_inputs": DEFAULT_INPUTS,
                          "yaml": {"inputs": {"environments-yml": {"ok": True, "value": [{"environment": "env-a"}]}},
                                   "environments": [{}]},
                          "directories_exist": {"./envs/env-a": True}, "run": {"id": 4711, "attempt": 1}}, document)
        self.assertEqual([], decide.decide(document)["errors"])

    def test_unparsable_or_absent_environments_leave_no_field_results_or_directories(self):
        for inputs in ({**DEFAULT_INPUTS, "environments-yml": "bad: ["}, {k: v for k, v in DEFAULT_INPUTS.items() if k != "environments-yml"}):
            with self.subTest(inputs=sorted(inputs)):
                document = adapter.build_document(inputs, self.FACTS, FakeTools(), lambda path: True)
                self.assertEqual([], document["yaml"]["environments"])
                self.assertEqual({}, document["directories_exist"])


PULL = "repos/o/r/pulls/87"
ZERO = "0" * 40


def page(number):
    return f"{PULL}/files?per_page=100&page={number}"


def files(count, start=0):
    return [{"filename": f"f{index}.tf", "status": "modified"} for index in range(start, start + count)]


def unavailable(error, api_head_sha=None):
    return {"available": False, "truncated": False, "error": error, "api_head_sha": api_head_sha, "count": 0,
            "files": []}


class PayloadTest(unittest.TestCase):
    def test_a_payload_is_read_or_is_empty(self):
        with tempfile.TemporaryDirectory() as work:
            cases = [('{"a": 1}', {"a": 1}), ("not json", {}), ("[1]", {}), ("null", {})]
            for content, expected in cases:
                with self.subTest(content=content):
                    path = os.path.join(work, "event.json")
                    with open(path, "w", encoding="utf-8") as handle:
                        handle.write(content)
                    self.assertEqual(expected, adapter.read_payload(path))
            self.assertEqual({}, adapter.read_payload(os.path.join(work, "missing.json")))
            self.assertEqual({}, adapter.read_payload(""))


class EventFactsTest(unittest.TestCase):
    def test_a_push_reports_its_three_booleans(self):
        self.assertEqual({"push": {"created": False, "forced": True, "deleted": False}},
                         adapter.event_facts("push", {"created": False, "forced": True, "deleted": False,
                                                      "before": "a" * 40}))
        self.assertEqual({"push": {"created": True, "forced": False, "deleted": True}},
                         adapter.event_facts("push", {"created": True, "deleted": True}))

    def test_a_zero_before_is_a_created_branch_too(self):
        self.assertEqual({"push": {"created": True, "forced": False, "deleted": False}},
                         adapter.event_facts("push", {"before": ZERO}))

    def test_what_is_not_true_is_false(self):
        self.assertEqual({"push": {"created": False, "forced": False, "deleted": False}},
                         adapter.event_facts("push", {"created": "true", "forced": 1, "deleted": None, "before": "0"}))

    def test_a_pull_request_reports_its_action_number_head_and_fork(self):
        self.assertEqual({"action": "opened", "pull_request": {"number": 87, "head_sha": "abc", "is_fork": False}},
                         adapter.event_facts("pull_request", {"action": "opened",
                                                              "pull_request": {"number": 87, "head": {"sha": "abc"}}}))
        head = {"sha": "abc", "repo": {"fork": True}}
        self.assertEqual({"action": "", "pull_request": {"number": 87, "head_sha": "abc", "is_fork": True}},
                         adapter.event_facts("pull_request", {"pull_request": {"number": 87, "head": head}}))

    def test_only_a_true_fork_is_a_fork(self):
        for repo in (None, {}, {"fork": "true"}, {"fork": False}, []):
            with self.subTest(repo=repo):
                payload = {"action": 5, "pull_request": {"number": 87, "head": {"sha": "abc", "repo": repo}}}
                self.assertEqual({"action": "", "pull_request": {"number": 87, "head_sha": "abc", "is_fork": False}},
                                 adapter.event_facts("pull_request", payload))

    def test_a_pull_request_payload_without_them_reports_nothing(self):
        for payload in ({}, {"pull_request": None}, {"pull_request": {"number": "87", "head": {"sha": "a"}}},
                        {"pull_request": {"number": True, "head": {"sha": "a"}}},
                        {"pull_request": {"number": 87, "head": {}}}, {"pull_request": {"number": 87, "head": None}},
                        {"pull_request": {"number": 87}}, {"pull_request": {"number": 87, "head": {"sha": 5}}}):
            with self.subTest(payload=payload):
                self.assertEqual({}, adapter.event_facts("pull_request", payload))

    def test_other_events_report_nothing(self):
        for name in ("schedule", "workflow_dispatch", "pull_request_target"):
            with self.subTest(name=name):
                self.assertEqual({}, adapter.event_facts(name, {"created": True, "pull_request": {"number": 1}}))


class PullRequestFilesTest(unittest.TestCase):
    EVENT = {"name": "pull_request", "ref_name": "x", "pull_request": {"number": 87, "head_sha": "abc", "is_fork": False}}

    def fetch(self, api, event=None):
        tools = FakeTools(api=api)
        return adapter.fetch_changed_files(tools, "o/r", "main", event or self.EVENT, {}), tools.endpoints()

    def test_a_small_pull_request(self):
        api = {PULL: {"changed_files": 2, "head": {"sha": "abc"}},
               page(1): [{"filename": "a.tf", "status": "added"},
                         {"filename": "docs/new.md", "status": "renamed", "previous_filename": "envs/prod/old.md"}]}
        self.assertEqual(({"available": True, "truncated": False, "error": None, "api_head_sha": "abc", "count": 2,
                           "files": ["a.tf", "docs/new.md", "envs/prod/old.md"]}, [PULL, page(1)]), self.fetch(api))

    def test_the_files_are_paged_at_a_hundred(self):
        api = {PULL: {"changed_files": 250, "head": {"sha": "abc"}},
               page(1): files(100), page(2): files(100, 100), page(3): files(50, 200)}
        changed, endpoints = self.fetch(api)
        self.assertEqual([PULL, page(1), page(2), page(3)], endpoints)
        self.assertEqual((250, [f"f{index}.tf" for index in range(250)], False),
                         (changed["count"], changed["files"], changed["truncated"]))

    def test_a_short_page_ends_the_list(self):
        api = {PULL: {"changed_files": 250, "head": {"sha": "abc"}}, page(1): files(100), page(2): files(30, 100)}
        changed, endpoints = self.fetch(api)
        self.assertEqual(([PULL, page(1), page(2)], 130, True), (endpoints, changed["count"], changed["available"]))

    def test_an_empty_pull_request_reads_no_page(self):
        changed, endpoints = self.fetch({PULL: {"changed_files": 0, "head": {"sha": "abc"}}})
        self.assertEqual(([PULL], 0, [], True), (endpoints, changed["count"], changed["files"], changed["available"]))

    def test_a_pull_request_over_the_cap_is_truncated_without_paging(self):
        changed, endpoints = self.fetch({PULL: {"changed_files": 3001, "head": {"sha": "abc"}}})
        self.assertEqual(({"available": True, "truncated": True, "error": None, "api_head_sha": "abc", "count": 3001,
                           "files": []}, [PULL]), (changed, endpoints))

    def test_three_thousand_paged_files_are_the_cap(self):
        api = {PULL: {"changed_files": 3000, "head": {"sha": "abc"}}}
        api.update({page(number): files(100, 100 * (number - 1)) for number in range(1, 31)})
        changed, endpoints = self.fetch(api)
        self.assertEqual((31, 3000, True), (len(endpoints), changed["count"], changed["truncated"]))

    def test_one_file_under_the_cap_is_not_truncated(self):
        api = {PULL: {"changed_files": 2999, "head": {"sha": "abc"}}}
        api.update({page(number): files(100 if number < 30 else 99, 100 * (number - 1)) for number in range(1, 31)})
        changed, _ = self.fetch(api)
        self.assertEqual((2999, False), (changed["count"], changed["truncated"]))

    def test_the_live_head_is_reported_as_the_api_saw_it(self):
        changed, _ = self.fetch({PULL: {"changed_files": 0, "head": {"sha": "newer"}}})
        self.assertEqual("newer", changed["api_head_sha"])

    def test_a_failed_pull_request_call_is_a_fact(self):
        cases = [
            ((1, "", "gh: Server Error (HTTP 502)\n"), "gh api repos/o/r/pulls/87 failed: gh: Server Error (HTTP 502)"),
            ((1, '{"message": "Not Found"}', ""), 'gh api repos/o/r/pulls/87 failed: {"message": "Not Found"}'),
            ((0, "not json", ""), "gh api repos/o/r/pulls/87 did not answer with JSON"),
            ((0, "[]", ""), "gh api repos/o/r/pulls/87 answered without a changed-file count and a head commit"),
            ((0, '{"changed_files": "2", "head": {"sha": "a"}}', ""),
             "gh api repos/o/r/pulls/87 answered without a changed-file count and a head commit"),
            ((0, '{"changed_files": true, "head": {"sha": "a"}}', ""),
             "gh api repos/o/r/pulls/87 answered without a changed-file count and a head commit"),
            ((0, '{"changed_files": -1, "head": {"sha": "a"}}', ""),
             "gh api repos/o/r/pulls/87 answered without a changed-file count and a head commit"),
            ((0, '{"changed_files": 2, "head": {"sha": 5}}', ""),
             "gh api repos/o/r/pulls/87 answered without a changed-file count and a head commit"),
            ((0, '{"changed_files": 2, "head": null}', ""),
             "gh api repos/o/r/pulls/87 answered without a changed-file count and a head commit"),
            ((0, '{"changed_files": 2}', ""),
             "gh api repos/o/r/pulls/87 answered without a changed-file count and a head commit"),
        ]
        for answer, error in cases:
            with self.subTest(answer=answer):
                changed, endpoints = self.fetch({PULL: answer})
                self.assertEqual((unavailable(error), [PULL]), (changed, endpoints))

    def test_a_failed_page_is_a_fact_that_keeps_the_head(self):
        not_a_list = "gh api repos/o/r/pulls/87/files?per_page=100&page=2 answered without a list of files"
        cases = [
            ((1, "", "HTTP 500"), "gh api repos/o/r/pulls/87/files?per_page=100&page=2 failed: HTTP 500"),
            ({"files": []}, not_a_list), ([None], not_a_list), ([{"status": "added"}], not_a_list),
            ([{"filename": 5}], not_a_list), ([{"filename": "a", "previous_filename": None}], not_a_list),
        ]
        for answer, error in cases:
            with self.subTest(answer=answer):
                changed, endpoints = self.fetch({PULL: {"changed_files": 150, "head": {"sha": "abc"}},
                                                 page(1): files(100), page(2): answer})
                self.assertEqual((unavailable(error, "abc"), [PULL, page(1), page(2)]), (changed, endpoints))

    def test_the_error_is_capped(self):
        changed, _ = self.fetch({PULL: (1, "", "x" * 2000)})
        self.assertEqual(len("gh api repos/o/r/pulls/87 failed: ") + 500, len(changed["error"]))

    def test_a_missing_gh_is_a_fact(self):
        tools = FakeTools(missing=("gh",))
        changed = adapter.fetch_changed_files(tools, "o/r", "main", self.EVENT, {})
        self.assertFalse(changed["available"])
        self.assertIn("'gh' cannot be run on this runner", changed["error"])

    def test_a_payload_without_the_pull_request_is_a_fact(self):
        changed, endpoints = self.fetch({}, event={"name": "pull_request", "ref_name": "x"})
        self.assertEqual((unavailable("the event payload carries no pull request number and head commit"), []),
                         (changed, endpoints))


class PushFilesTest(unittest.TestCase):
    def fetch(self, api, payload, default="main"):
        tools = FakeTools(api=api)
        event = {"name": "push", "ref_name": "x", **adapter.event_facts("push", payload)}
        return adapter.fetch_changed_files(tools, "o/r", default, event, payload), tools.endpoints()

    def test_a_push_is_compared_from_before_to_after(self):
        compare = f"repos/o/r/compare/{'b' * 40}...{'a' * 40}"
        api = {compare: {"files": [{"filename": "envs/prod/main.tf"},
                                   {"filename": "new.tf", "status": "renamed", "previous_filename": "old.tf"}]}}
        self.assertEqual(({"available": True, "truncated": False, "error": None, "api_head_sha": None, "count": 2,
                           "files": ["envs/prod/main.tf", "new.tf", "old.tf"]}, [compare]),
                         self.fetch(api, {"before": "b" * 40, "after": "a" * 40}))

    def test_a_created_branch_is_compared_against_the_default_branch(self):
        for payload in ({"created": True, "before": ZERO, "after": "a" * 40}, {"before": ZERO, "after": "a" * 40},
                        {"created": True, "before": "c" * 40, "after": "a" * 40}):
            with self.subTest(payload=payload):
                compare = f"repos/o/r/compare/main...{'a' * 40}"
                changed, endpoints = self.fetch({compare: {"files": [{"filename": "x.tf"}]}}, payload)
                self.assertEqual(([compare], ["x.tf"]), (endpoints, changed["files"]))

    def test_the_default_branch_is_quoted_for_the_path(self):
        compare = f"repos/o/r/compare/release/v%C3%B8%20x...{'a' * 40}"
        changed, endpoints = self.fetch({compare: {"files": []}}, {"created": True, "after": "a" * 40},
                                        default="release/vø x")
        self.assertEqual(([compare], True), (endpoints, changed["available"]))

    def test_three_hundred_files_are_the_compare_cap(self):
        compare = f"repos/o/r/compare/{'b' * 40}...{'a' * 40}"
        for count, truncated in ((299, False), (300, True)):
            with self.subTest(count=count):
                changed, _ = self.fetch({compare: {"files": files(count)}}, {"before": "b" * 40, "after": "a" * 40})
                self.assertEqual((count, truncated), (changed["count"], changed["truncated"]))

    def test_a_forced_or_deleting_push_fetches_nothing(self):
        for payload in ({"forced": True, "before": "b" * 40, "after": "a" * 40},
                        {"deleted": True, "before": "b" * 40, "after": ZERO}):
            with self.subTest(payload=payload):
                self.assertEqual((None, []), self.fetch({}, payload))

    def test_a_failed_compare_is_a_fact(self):
        compare = f"repos/o/r/compare/{'b' * 40}...{'a' * 40}"
        without = f"gh api {compare} answered without a list of files"
        for answer, error in (((1, "", "HTTP 404"), f"gh api {compare} failed: HTTP 404"), ({}, without), ([], without),
                              ({"files": None}, without), ({"files": [{"filename": None}]}, without)):
            with self.subTest(answer=answer):
                self.assertEqual((unavailable(error), [compare]),
                                 self.fetch({compare: answer}, {"before": "b" * 40, "after": "a" * 40}))

    def test_a_payload_without_the_commits_is_a_fact(self):
        error = "the event payload carries no 'before' and 'after' commits"
        for payload in ({}, {"before": "b" * 40}, {"after": "a" * 40}, {"before": 5, "after": "a" * 40},
                        {"before": "b" * 40, "after": None}):
            with self.subTest(payload=payload):
                self.assertEqual((unavailable(error), []), self.fetch({}, payload))

    def test_a_created_branch_needs_only_after(self):
        compare = f"repos/o/r/compare/main...{'a' * 40}"
        changed, _ = self.fetch({compare: {"files": []}}, {"created": True, "after": "a" * 40})
        self.assertTrue(changed["available"])
        changed, endpoints = self.fetch({}, {"created": True})
        self.assertEqual((unavailable("the event payload carries no 'before' and 'after' commits"), []),
                         (changed, endpoints))

    def test_other_events_fetch_nothing(self):
        tools = FakeTools()
        for name in ("schedule", "workflow_dispatch"):
            with self.subTest(name=name):
                self.assertIsNone(adapter.fetch_changed_files(tools, "o/r", "main", {"name": name, "ref_name": "x"}, {}))
        self.assertEqual([], tools.calls)


class RelevanceDocumentTest(unittest.TestCase):
    FACTS = {"repository": "o/r", "default_branch": "main", "event_name": "pull_request", "ref_name": "x",
             "payload": {"pull_request": {"number": 87, "head": {"sha": "abc"}}}, "run": {"id": 4711, "attempt": 1}}
    API = {PULL: {"changed_files": 1, "head": {"sha": "abc"}}, page(1): [{"filename": "envs/env-a/main.tf"}]}

    def test_the_document_carries_the_event_facts_and_the_changed_files(self):
        document = adapter.build_document(DEFAULT_INPUTS, self.FACTS, FakeTools(api=self.API), lambda path: True)
        self.assertEqual({"name": "pull_request", "ref_name": "x", "action": "",
                          "pull_request": {"number": 87, "head_sha": "abc", "is_fork": False}}, document["event"])
        self.assertEqual({"available": True, "truncated": False, "error": None, "api_head_sha": "abc", "count": 1,
                          "files": ["envs/env-a/main.tf"]}, document["changed_files"])
        self.assertEqual({"mode": "diff", "reason": "diff", "changed_count": 1}, decide.decide(document)["relevance"])

    def test_nothing_is_fetched_when_relevance_is_off(self):
        for value in (False, "false"):
            with self.subTest(value=value):
                tools = FakeTools(api=self.API)
                document = adapter.build_document({**DEFAULT_INPUTS, "path-relevance-enabled": value}, self.FACTS,
                                                  tools, lambda path: True)
                self.assertNotIn("changed_files", document)
                self.assertEqual([], tools.endpoints())
                self.assertEqual({"number": 87, "head_sha": "abc", "is_fork": False}, document["event"]["pull_request"])

    def test_an_event_without_changed_files_has_no_section(self):
        facts = {**self.FACTS, "event_name": "schedule", "payload": {}}
        document = adapter.build_document(DEFAULT_INPUTS, facts, FakeTools(), lambda path: True)
        self.assertEqual({"name": "schedule", "ref_name": "x"}, document["event"])
        self.assertNotIn("changed_files", document)


class RunTest(unittest.TestCase):
    def test_a_decision_publishes_the_matrix_and_logs_everything_verbatim(self):
        runner = Runner(self)
        self.assertEqual(0, runner.run())
        matrix = runner.matrix()
        self.assertEqual(["env-a"], matrix["environment"])
        self.assertEqual("main", matrix["include"][0]["vars"]["caller-repo-default-branch"])
        log = runner.log.getvalue()
        for group in ("input 'inputs-json'", "decision engine input document", "decision record", "matrix-json"):
            self.assertIn(f"::group::create-tf-vars-matrix: {group}\n::stop-commands::", log)
        self.assertIn("env-a: run — relevance: envs/env-a/**", log)
        self.assertNotIn("::error", log)

    def test_the_exit_codes(self):
        self.assertEqual((0, 1, 2), (adapter.EXIT_OK, adapter.EXIT_FAULT, adapter.EXIT_INVALID))

    def test_the_log_groups_hold_the_exact_documents_indented_sorted_and_unescaped(self):
        inputs = {**DEFAULT_INPUTS, "environments-yml": '[{"environment": "env-a", "url": "https://example.com/å"}, {"environment": "b"}]'}
        runner = Runner(self, inputs=inputs)
        self.assertEqual(0, runner.run())
        groups = _groups(runner.log.getvalue())
        self.assertEqual(json.dumps(inputs, indent=2, ensure_ascii=False), groups["input 'inputs-json'"])
        document = json.loads(groups["decision engine input document"])
        self.assertEqual(json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False), groups["decision engine input document"])
        self.assertIn("example.com/å", groups["decision engine input document"])
        self.assertEqual("env-a: run — relevance: envs/env-a/**\nb: skip — relevance: no changed file matches",
                         groups["decision record"])
        matrix = runner.matrix()
        self.assertEqual(json.dumps(matrix, indent=2, sort_keys=True, ensure_ascii=False), groups["matrix-json"])
        self.assertIn('"https://example.com/å"', runner.output())

    def test_the_changed_files_are_listed_once_in_their_own_group(self):
        runner = Runner(self)
        self.assertEqual(0, runner.run(FakeTools(api={COMPARE: {"files": [{"filename": "envs/env-a/main.tf"},
                                                                          {"filename": "::warning::a%.md"}]}})))
        log = runner.log.getvalue()
        groups = _groups(log)
        self.assertEqual("envs/env-a/main.tf\n::warning::a%.md", groups["changed files"])
        document = json.loads(groups["decision engine input document"])
        self.assertEqual({"available": True, "truncated": False, "error": None, "api_head_sha": None, "count": 2,
                          "files": "2 paths, listed in the group 'changed files'"}, document["changed_files"])
        self.assertEqual({"name": "push", "ref_name": "main", "push": {"created": False, "forced": False,
                                                                       "deleted": False}}, document["event"])
        self.assertEqual([], [line for line in _outside_verbatim(log) if line.startswith("::warning")])
        self.assertLess(log.index("changed files"), log.index("decision engine input document"))

    def test_without_changed_files_there_is_no_group(self):
        runner = Runner(self, environ={"GITHUB_EVENT_NAME": "schedule"})
        self.assertEqual(0, runner.run())
        self.assertNotIn("changed files", _groups(runner.log.getvalue()))
        self.assertNotIn("changed_files", json.loads(_groups(runner.log.getvalue())["decision engine input document"]))

    def test_a_failed_fetch_runs_everything_and_the_step_succeeds(self):
        runner = Runner(self)
        self.assertEqual(0, runner.run(FakeTools(api={COMPARE: (1, "", "HTTP 502")})))
        self.assertEqual(["env-a"], runner.matrix()["environment"])
        self.assertIn("env-a: run — relevance: all:api-error", runner.log.getvalue())
        self.assertNotIn("::error", runner.log.getvalue())

    def test_the_outputs_are_the_matrix_the_counts_the_mode_and_the_file(self):
        runner = Runner(self, inputs={**DEFAULT_INPUTS, "environments-yml": '[{"environment": "env-a"}, {"environment": "b"}]'})
        self.assertEqual(0, runner.run())
        outputs = runner.outputs()
        self.assertEqual(["matrix-json", "affected-count", "unaffected-count", "relevance-mode", "relevance-reason",
                          "changed-count", "relevance-file"], list(outputs))
        self.assertEqual(("1", "1", "diff", "diff", "1"),
                         (outputs["affected-count"], outputs["unaffected-count"], outputs["relevance-mode"],
                          outputs["relevance-reason"], outputs["changed-count"]))
        path = outputs["relevance-file"]
        self.assertEqual(runner.environ["RUNNER_TEMP"], os.path.dirname(os.path.dirname(path)))
        self.assertEqual("relevance.json", os.path.basename(path))
        with open(path, encoding="utf-8") as handle:
            published = json.load(handle)
        self.assertEqual({"schema_version", "relevance", "counts", "environments", "comments", "notices", "record"},
                         set(published))
        self.assertEqual((["env-a", "b"], ["run", "skip"], {"affected": 1, "unaffected": 1}),
                         ([e["environment"] for e in published["environments"]],
                          [e["verdict"] for e in published["environments"]], published["counts"]))

    def test_the_file_is_the_engines_output_without_the_matrices(self):
        runner = Runner(self)
        runner.run()
        with open(runner.outputs()["relevance-file"], encoding="utf-8") as handle:
            text = handle.read()
        document = adapter.build_document(DEFAULT_INPUTS, {
            "repository": "o/r", "default_branch": "main", "event_name": "push", "ref_name": "main",
            "payload": PUSH_PAYLOAD, "run": {"id": 4711, "attempt": 2}}, runner.tools, lambda path: True)
        output = decide.decide(document)
        del output["matrices"], output["errors"]
        self.assertEqual(json.dumps(output, indent=2, sort_keys=True, ensure_ascii=False) + "\n", text)

    def test_the_decision_is_announced_once(self):
        runner = Runner(self)
        runner.run()
        notices = [line for line in _outside_verbatim(runner.log.getvalue()) if line.startswith("::notice")]
        self.assertEqual(["::notice title=Terraform CI::relevance diff (diff): 1 of 1 environment affected"], notices)

    def test_a_relevance_file_that_cannot_be_written_is_a_fault(self):
        runner = Runner(self, environ={"RUNNER_TEMP": "/nonexistent/runner/temp"})
        self.assertEqual(1, runner.run())
        self.assertEqual("", runner.output())
        self.assertIn("::error title=create-tf-vars-matrix::the relevance file cannot be written under "
                      "'/nonexistent/runner/temp'", runner.log.getvalue())

    def test_a_configuration_error_announces_and_writes_nothing(self):
        runner = Runner(self, inputs={**DEFAULT_INPUTS, "tflint-version": ""})
        self.assertEqual(2, runner.run())
        self.assertNotIn("::notice", runner.log.getvalue())
        self.assertEqual([], os.listdir(runner.environ["RUNNER_TEMP"]))

    def test_the_published_matrix_is_the_engines_compact_and_sorted(self):
        runner = Runner(self)
        runner.run()
        line = runner.outputs()["matrix-json"]
        self.assertNotIn(" ", line)
        self.assertEqual(json.dumps(json.loads(line), sort_keys=True, separators=(",", ":")), line)

    def test_facts_come_from_the_runner(self):
        runner = Runner(self, payload={"repository": {"default_branch": "trunk"}},
                        environ={"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF_NAME": "trunk", "GITHUB_REPOSITORY": "a/b"})
        runner.run()
        row = runner.matrix()["include"][0]["vars"]
        self.assertEqual(("trunk", "trunk", "true"), (row["caller-repo-default-branch"], row["caller-repo-calling-branch"],
                                                      row["caller-repo-is-on-default-branch"]))

    def test_a_configuration_error_is_annotated_escaped_and_publishes_nothing(self):
        runner = Runner(self, inputs={**DEFAULT_INPUTS, "environments-yml": '[{"environment": "x%\\n::warning::no"}]'})
        self.assertEqual(2, runner.run())
        self.assertEqual("", runner.output())
        log = runner.log.getvalue()
        errors = [line for line in log.splitlines() if line.startswith("::error")]
        self.assertEqual(["::error title=create-tf-vars-matrix::The environment name 'x%25\\n::warning::no' must be "
                          "1 to 255 of the characters A-Z a-z 0-9 . _ - starting with a letter or a digit!"], errors)
        self.assertEqual([], [line for line in log.splitlines() if line.startswith("::warning")])

    def test_every_error_is_its_own_annotation(self):
        runner = Runner(self, inputs={**DEFAULT_INPUTS, "tflint-version": "", "terraform-version": ""})
        self.assertEqual(2, runner.run())
        self.assertEqual(2, runner.log.getvalue().count("::error "))

    def test_a_directory_that_does_not_exist_is_an_error(self):
        runner = Runner(self)
        self.assertEqual(2, runner.run(isdir=lambda path: False))
        self.assertIn("The directory './envs/env-a' does not exist", runner.log.getvalue())

    def test_faults_exit_1_name_themselves_and_publish_nothing(self):
        cases = [
            ("a broken yq", {}, FakeTools(yq_broken=(1, "", "boom")), "yq on the runner cannot parse YAML"),
            ("inputs that are not JSON", {"inputs": "environments-yml: x"}, None, "cannot be read as JSON"),
            ("a failing API", {"payload": {}}, FakeTools(gh=(1, "", "HTTP 404")), "could not resolve the default branch"),
        ]
        for label, kwargs, tools, fragment in cases:
            with self.subTest(label=label):
                runner = Runner(self, **kwargs)
                self.assertEqual(1, runner.run(tools))
                self.assertEqual("", runner.output())
                errors = [line for line in runner.log.getvalue().splitlines() if line.startswith("::error")]
                self.assertEqual(1, len(errors))
                self.assertIn(fragment, errors[0])

    def test_a_faults_detail_is_shown_verbatim(self):
        runner = Runner(self, payload={})
        runner.run(FakeTools(gh=(1, "", "::warning::from the API")))
        log = runner.log.getvalue()
        self.assertIn("::warning::from the API", log)
        outside = [line for line in _outside_verbatim(log) if line.startswith("::warning")]
        self.assertEqual([], outside)

    def test_a_fault_without_detail_prints_no_verbatim_block(self):
        runner = Runner(self, inputs="[1]")
        runner.run()
        self.assertNotIn("::stop-commands::", runner.log.getvalue())

    def test_missing_runner_variables_are_named_before_anything_runs(self):
        for name in ("GITHUB_REPOSITORY", "GITHUB_EVENT_NAME", "GITHUB_REF_NAME", "GITHUB_OUTPUT", "GITHUB_RUN_ID",
                     "GITHUB_RUN_ATTEMPT", "RUNNER_TEMP"):
            with self.subTest(name=name):
                runner = Runner(self, environ={name: ""})
                self.assertEqual(1, runner.run())
                self.assertIn(f"the runner did not set {name}", runner.log.getvalue())
                self.assertEqual([], runner.tools.calls)

    def test_several_missing_variables_are_named_together(self):
        runner = Runner(self)
        runner.environ = {"GITHUB_OUTPUT": runner.output_file}
        runner.run()
        self.assertIn("the runner did not set GITHUB_REPOSITORY, GITHUB_EVENT_NAME, GITHUB_REF_NAME, GITHUB_RUN_ID, "
                      "GITHUB_RUN_ATTEMPT, RUNNER_TEMP", runner.log.getvalue())

    def test_the_run_comes_from_the_runner(self):
        runner = Runner(self)
        self.assertEqual(0, runner.run())
        self.assertEqual({"id": 4711, "attempt": 2},
                         json.loads(_groups(runner.log.getvalue())["decision engine input document"])["run"])

    def test_a_run_that_is_not_a_number_is_a_fault(self):
        for name, value in (("GITHUB_RUN_ID", "x"), ("GITHUB_RUN_ATTEMPT", "-1"), ("GITHUB_RUN_ID", "1.5"),
                            ("GITHUB_RUN_ID", "²")):
            with self.subTest(name=name, value=value):
                runner = Runner(self, environ={name: value})
                self.assertEqual(1, runner.run())
                self.assertIn(f"the runner set {name} to {value!r}, which is not a run number", runner.log.getvalue())
                self.assertEqual([], runner.tools.calls)

    def test_yq_is_probed_before_the_inputs_are_read(self):
        runner = Runner(self, inputs="not json")
        runner.run(FakeTools(yq_broken=(1, "", "boom")))
        self.assertIn("yq on the runner", runner.log.getvalue())
        self.assertNotIn("inputs-json", runner.log.getvalue())

    def test_a_name_carrying_a_workflow_command_never_reaches_the_record(self):
        runner = Runner(self, inputs={**DEFAULT_INPUTS, "environments-yml": '[{"environment": "a\\n::warning::no", "project-dir": "."}]'})
        self.assertEqual(2, runner.run())
        log = runner.log.getvalue()
        self.assertNotIn("decision record", log)
        self.assertEqual([], [line for line in log.splitlines() if line.startswith("::warning")])


def _groups(log):
    """{group name: its verbatim text} from a log."""
    groups, lines = {}, log.splitlines()
    for index, line in enumerate(lines):
        if line.startswith("::group::create-tf-vars-matrix: "):
            token = f"::{lines[index + 1][len('::stop-commands::'):]}::"
            end = lines.index(token, index + 2)
            groups[line[len("::group::create-tf-vars-matrix: "):]] = "\n".join(lines[index + 2:end])
    return groups


def _outside_verbatim(log):
    token, lines = None, []
    for line in log.splitlines():
        if token is None and line.startswith("::stop-commands::"):
            token = f"::{line[len('::stop-commands::'):]}::"
        elif token is not None and line == token:
            token = None
        elif token is None:
            lines.append(line)
    return lines


class ToolsTest(unittest.TestCase):
    def test_tools_run_a_program_with_stdin_and_capture_both_streams(self):
        code, stdout, stderr = adapter.Tools().run(
            [sys.executable, "-c", "import sys; print(sys.stdin.read().upper()); print('e', file=sys.stderr); sys.exit(3)"], "hi")
        self.assertEqual((3, "HI\n", "e\n"), (code, stdout, stderr))

    def test_a_missing_program_raises_os_error(self):
        with self.assertRaises(OSError):
            adapter.Tools().run(["/nonexistent/program"])


if __name__ == "__main__":
    unittest.main()
