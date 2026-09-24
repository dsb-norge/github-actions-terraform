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

    def __init__(self, yq_broken=None, gh=(0, '{"default_branch": "from-api"}', ""), missing=()):
        self.calls = []
        self.yq_broken = yq_broken
        self.gh = gh
        self.missing = missing

    def run(self, argv, stdin=""):
        self.calls.append((tuple(argv), stdin))
        if argv[0] in self.missing:
            raise FileNotFoundError(2, "No such file or directory", argv[0])
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


DEFAULT_INPUTS = {
    "environments-yml": '[{"environment": "env-a"}]',
    "add-pr-comment": True, "apply-extract-include-outputs": False, "cache-terraform-modules": True,
    "pr-auto-merge-enabled": False, "pr-comment-group": "", "terraform-version": "latest",
    "tflint-version": "latest", "verify-lock-file": True,
}


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
            json.dump({"repository": {"default_branch": "main"}} if payload is None else payload, handle)
        self.output_file = os.path.join(path, "output.txt")
        open(self.output_file, "w").close()
        self.environ = {"GITHUB_REPOSITORY": "o/r", "GITHUB_EVENT_NAME": "push", "GITHUB_REF_NAME": "main",
                        "GITHUB_EVENT_PATH": self.event_file, "GITHUB_OUTPUT": self.output_file}
        self.environ.update(environ or {})
        self.log = io.StringIO()

    def run(self, tools=None, isdir=lambda path: True):
        self.tools = tools or FakeTools()
        return adapter.run(self.inputs_file, self.environ, self.log, self.tools, isdir)

    def output(self):
        with open(self.output_file, encoding="utf-8") as handle:
            return handle.read()

    def matrix(self):
        lines = self.output().splitlines()
        if not lines:
            return None
        self.assert_delimited(lines)
        return json.loads(lines[1])

    @staticmethod
    def assert_delimited(lines):
        name, delimiter = lines[0].split("<<")
        assert name == "matrix-json" and lines[2] == delimiter and len(lines) == 3, lines


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
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.event = os.path.join(self.work.name, "event.json")

    def payload(self, content):
        with open(self.event, "w", encoding="utf-8") as handle:
            handle.write(content if isinstance(content, str) else json.dumps(content))

    def test_the_payload_answers_without_the_api(self):
        self.payload({"repository": {"default_branch": "trunk"}})
        tools = FakeTools()
        self.assertEqual("trunk", adapter.default_branch(self.event, "o/r", tools))
        self.assertEqual([], tools.calls)

    def test_the_api_answers_when_the_payload_cannot(self):
        for content in ({}, {"repository": {}}, {"repository": {"default_branch": ""}}, {"repository": {"default_branch": 5}},
                        {"repository": None}, [], "not json", None):
            with self.subTest(content=content):
                if content is None:
                    path = os.path.join(self.work.name, "missing.json")
                else:
                    self.payload(content)
                    path = self.event
                tools = FakeTools()
                self.assertEqual("from-api", adapter.default_branch(path, "o/r", tools))
                self.assertEqual([(("gh", "api", "repos/o/r"), "")], tools.calls)

    def test_an_empty_event_path_goes_to_the_api(self):
        self.assertEqual("from-api", adapter.default_branch("", "o/r", FakeTools()))

    def test_an_api_that_cannot_answer_is_an_error_showing_its_answer(self):
        self.payload({})
        for gh in [(1, "", "HTTP 404: Not Found"), (0, "not json", ""), (0, '{"name": "r"}', ""), (0, '{"default_branch": ""}', ""),
                   (0, "[]", ""), (1, '{"default_branch": "main"}', "")]:
            with self.subTest(gh=gh):
                with self.assertRaises(adapter.AdapterError) as raised:
                    adapter.default_branch(self.event, "o/r", FakeTools(gh=gh))
                self.assertEqual("could not resolve the default branch of 'o/r', the API answered:", raised.exception.message)
                self.assertEqual((gh[1] + gh[2]).strip(), raised.exception.detail)

    def test_the_apis_answer_is_capped(self):
        self.payload({})
        with self.assertRaises(adapter.AdapterError) as raised:
            adapter.default_branch(self.event, "o/r", FakeTools(gh=(1, "y" * 5000, "")))
        self.assertEqual(2000, len(raised.exception.detail))

    def test_an_adapter_error_reads_as_its_message(self):
        self.assertEqual("m", str(adapter.AdapterError("m", "d")))

    def test_a_missing_gh_is_named(self):
        self.payload({})
        with self.assertRaises(adapter.AdapterError) as raised:
            adapter.default_branch(self.event, "o/r", FakeTools(missing=("gh",)))
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
    FACTS = {"repository": "o/r", "default_branch": "main", "event_name": "push", "ref_name": "feature/x"}

    def test_the_document_is_complete_and_valid(self):
        document = adapter.build_document(DEFAULT_INPUTS, self.FACTS, FakeTools(), lambda path: True)
        self.assertEqual({"schema_version": 1, "caller": {"repository": "o/r", "default_branch": "main"},
                          "event": {"name": "push", "ref_name": "feature/x"}, "workflow_inputs": DEFAULT_INPUTS,
                          "yaml": {"inputs": {"environments-yml": {"ok": True, "value": [{"environment": "env-a"}]}},
                                   "environments": [{}]},
                          "directories_exist": {"./envs/env-a": True}}, document)
        self.assertEqual([], decide.decide(document)["errors"])

    def test_unparsable_or_absent_environments_leave_no_field_results_or_directories(self):
        for inputs in ({**DEFAULT_INPUTS, "environments-yml": "bad: ["}, {k: v for k, v in DEFAULT_INPUTS.items() if k != "environments-yml"}):
            with self.subTest(inputs=sorted(inputs)):
                document = adapter.build_document(inputs, self.FACTS, FakeTools(), lambda path: True)
                self.assertEqual([], document["yaml"]["environments"])
                self.assertEqual({}, document["directories_exist"])


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
        self.assertIn("env-a: run — port", log)
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
        self.assertEqual("env-a: run — port\nb: run — port", groups["decision record"])
        matrix = runner.matrix()
        self.assertEqual(json.dumps(matrix, indent=2, sort_keys=True, ensure_ascii=False), groups["matrix-json"])
        self.assertIn('"https://example.com/å"', runner.output())

    def test_the_published_matrix_is_the_engines_compact_and_sorted(self):
        runner = Runner(self)
        runner.run()
        line = runner.output().splitlines()[1]
        self.assertNotIn(" ", line.replace("run — port", ""))
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
        for name in ("GITHUB_REPOSITORY", "GITHUB_EVENT_NAME", "GITHUB_REF_NAME", "GITHUB_OUTPUT"):
            with self.subTest(name=name):
                runner = Runner(self, environ={name: ""})
                self.assertEqual(1, runner.run())
                self.assertIn(f"the runner did not set {name}", runner.log.getvalue())
                self.assertEqual([], runner.tools.calls)

    def test_several_missing_variables_are_named_together(self):
        runner = Runner(self)
        runner.environ = {"GITHUB_OUTPUT": runner.output_file}
        runner.run()
        self.assertIn("the runner did not set GITHUB_REPOSITORY, GITHUB_EVENT_NAME, GITHUB_REF_NAME", runner.log.getvalue())

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
