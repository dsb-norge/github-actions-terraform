"""The module mode: a module repository's test stage, decided alone (docs/Module-ci.md §5)."""

import json
import os
import unittest

import support
from dsb_tf_engine import adapter, decide, model
from test_adapter import FakeTools, Runner

MODULE_INPUTS = {
    "terraform-version": "1.14.x", "tflint-version": "v0.64.0", "readme-file-path": ".",
    "runs-on": "ubuntu-latest", "add-pr-comment": True, "cache-terraform-modules": True,
    "terraform-test-enabled": True, "terraform-test-required": True, "allow-failing-terraform-tests": False,
    "terraform-test-runs-on": "ubuntu-latest", "terraform-test-timeout-minutes": 30,
    "terraform-test-lanes-yml": "", "terraform-test-exclude-paths-yml": "",
}
UNIT = "tests/unit-tests.tftest.hcl"
INTEGRATION = "tests/integration-basic.tftest.hcl"


def document(files, event="pull_request", inputs=None, lanes=None, exclude=None, action="synchronize",
             is_fork=False, dirs=(".", "examples/01-basic"), tests=True):
    doc = {
        "schema_version": 1,
        "mode": "module",
        "caller": {"repository": "example-org/terraform-azurerm-thing", "default_branch": "main",
                   "workflow_name": "Terraform module CI"},
        "event": {"name": event, "ref_name": "main", "ref_type": "branch", "actor": "octocat"},
        "workflow_inputs": {**MODULE_INPUTS, **(inputs or {})},
        "yaml": {"inputs": {"terraform-test-lanes-yml": support.parsed(lanes),
                            "terraform-test-exclude-paths-yml": support.parsed(exclude)},
                 "environments": []},
        "directories_exist": {},
        "run": {"id": 4711, "attempt": 1},
    }
    if event == "pull_request":
        doc["event"]["action"] = action
        doc["event"]["pull_request"] = {"number": 12, "head_sha": "abc", "is_fork": is_fork}
    if tests:
        doc["tests"] = {"files": list(files), "directories_with_tf": list(dirs), "environment_locks": {}}
    return doc


def decided(*args, **kwargs):
    output = decide.decide(document(*args, **kwargs))
    assert output["errors"] == [], output["errors"]
    return output


class EventsTest(unittest.TestCase):
    def test_every_event_of_the_four_runs_the_tests(self):
        for event in ("pull_request", "push", "workflow_dispatch", "schedule"):
            with self.subTest(event=event):
                tests = decided([UNIT], event=event)["tests"]
                self.assertEqual((1, True, False), (tests["count"], tests["active"], tests["missing"]))

    def test_another_event_is_refused(self):
        self.assertEqual(["event 'merge_group' is not supported by this workflow; supported: pull_request, push, "
                          "workflow_dispatch, schedule"], decide.decide(document([UNIT], event="merge_group"))["errors"])

    def test_a_closing_pull_request_tests_nothing_and_misses_nothing(self):
        for action in ("closed", "converted_to_draft"):
            with self.subTest(action=action):
                tests = decided([], action=action)["tests"]
                self.assertEqual((0, False, False), (tests["count"], tests["active"], tests["missing"]))


class RequiredTest(unittest.TestCase):
    MESSAGE = ("no test file: a module needs at least one test file, a unit suite such as "
               "tests/unit-tests.tftest.hcl; set terraform-test-required: false to run without (docs/Module-ci.md D9)")

    def test_no_test_file_is_missing_with_a_warning(self):
        output = decided([])
        self.assertTrue(output["tests"]["missing"])
        self.assertEqual([self.MESSAGE], output["warnings"])

    def test_an_excluded_or_misplaced_file_is_no_test_file(self):
        excluded = decided([UNIT], exclude=["tests/**"])
        self.assertTrue(excluded["tests"]["missing"])
        misplaced = decided(["nowhere/unit.tftest.hcl"], dirs=["."])
        self.assertTrue(misplaced["tests"]["missing"])
        self.assertEqual([{"file": "nowhere/unit.tftest.hcl", "lane": "default", "reason": "misplaced"}],
                         misplaced["tests"]["not_run"])
        self.assertEqual(2, len(misplaced["warnings"]))

    def test_a_file_held_back_from_a_fork_is_not_missing(self):
        lanes = [{"name": "azure", "extra-envs-from-secrets-yml": {"ARM_CLIENT_ID": "REPO_CLIENT_ID"}}]
        tests = decided([INTEGRATION], lanes=lanes, is_fork=True)["tests"]
        self.assertEqual((0, False, False), (tests["count"], tests["active"], tests["missing"]))

    def test_the_opt_out_and_a_stage_switched_off_miss_nothing(self):
        for inputs in ({"terraform-test-required": False}, {"terraform-test-enabled": False}):
            with self.subTest(inputs=inputs):
                output = decided([], inputs=inputs)
                self.assertEqual((False, []), (output["tests"]["missing"], output["warnings"]))
        self.assertFalse(decided([], tests=False)["tests"]["missing"])

    def test_the_input_is_a_boolean(self):
        self.assertEqual(["The input 'terraform-test-required' is 'yes'; it must be true or false!"],
                         decide.decide(document([UNIT], inputs={"terraform-test-required": "yes"}))["errors"])

    def test_the_project_workflow_never_requires(self):
        doc = support.document(inputs={"terraform-test-enabled": True, "terraform-test-lanes-yml": "",
                                       "terraform-test-exclude-paths-yml": ""})
        doc["yaml"]["inputs"].update({"terraform-test-lanes-yml": support.parsed(None),
                                      "terraform-test-exclude-paths-yml": support.parsed(None)})
        doc["tests"] = {"files": [], "directories_with_tf": [], "environment_locks": {}}
        self.assertFalse(decide.decide(doc)["tests"]["missing"])


class LanesTest(unittest.TestCase):
    def test_lanes_without_environments(self):
        lanes = [{"name": "unit", "match": ["**/unit-*.tftest.hcl"]},
                 {"name": "integration", "match": ["**/integration-*.tftest.hcl"], "github-environment": "auto"}]
        rows = decided([UNIT, INTEGRATION], lanes=lanes)["tests"]["matrix"]["include"]
        self.assertEqual([("tests/integration-basic.tftest.hcl", "integration", "tftest-integration", "repo-root", "",
                           False),
                          ("tests/unit-tests.tftest.hcl", "unit", "", "repo-root", "", True)],
                         [(row["test"]["file"], row["test"]["lane"], row["test"]["github-environment"],
                           row["test"]["root-kind"], row["test"]["provider-set"], row["test"]["fork-safe"])
                          for row in rows])

    def test_the_one_credential_lane(self):
        lanes = [{"name": "azure", "extra-envs-yml": {"ARM_USE_OIDC": "true"},
                  "extra-envs-from-secrets-yml": {"ARM_TENANT_ID": "REPO_AZURE_DSB_TENANT_ID"}}]
        row = decided([UNIT], lanes=lanes)["tests"]["matrix"]["include"][0]["test"]
        self.assertEqual(("azure", {"ARM_USE_OIDC": "true"}, {"ARM_TENANT_ID": "REPO_AZURE_DSB_TENANT_ID"}),
                         (row["lane"], row["extra-envs"], row["extra-envs-from-secrets"]))

    def test_a_bad_lane_is_refused_as_in_the_project_workflow(self):
        errors = decide.decide(document([UNIT], lanes=[{"name": "Unit!"}]))["errors"]
        self.assertEqual(1, len(errors))
        self.assertIn("'Unit!'", errors[0])


class OutputTest(unittest.TestCase):
    def test_the_output_is_the_test_stage_alone(self):
        output = decided([UNIT, "nowhere/x.tftest.hcl"], dirs=["."], event="workflow_dispatch")
        self.assertEqual(["admission", "automerge", "comments", "errors", "mode", "notices", "record", "relevance",
                          "schema_version", "tests", "trigger", "warnings"], sorted(output))
        self.assertEqual(("module", {"event": "workflow_dispatch", "lines": []}),
                         (output["mode"], output["trigger"]))
        self.assertEqual(["tests/unit-tests.tftest.hcl: run, lane default", "nowhere/x.tftest.hcl: not run, misplaced"],
                         output["record"])


class ModelTest(unittest.TestCase):
    def test_the_mode_is_project_or_module(self):
        doc = document([UNIT])
        doc["mode"] = "project-ish"
        with self.assertRaises(model.DocumentError) as raised:
            model.check(doc)
        self.assertEqual("input document: 'mode' is 'project-ish', expected one of project, module",
                         str(raised.exception))
        project = support.document()
        project["mode"] = "project"
        model.check(project)


class RelevanceTest(unittest.TestCase):
    """docs/Module-ci.md §5.1: the module is one unit, affected by any changed file that is not ignored."""

    def run_on(self, files=None, ignore=None, enabled=True, event="pull_request", changed=None, ok=True, **kwargs):
        doc = document([UNIT], event=event, inputs={"path-relevance-enabled": enabled}, **kwargs)
        doc["yaml"]["inputs"]["paths-ignore-yml"] = support.parsed(ignore, ok)
        if changed is not None or files is not None:
            doc["changed_files"] = changed or {"available": True, "truncated": False, "error": None,
                                               "api_head_sha": "abc", "count": len(files), "files": files}
        return decide.decide(doc)

    def test_a_markdown_only_change_holds_every_test_back(self):
        output = self.run_on(["README.md", "docs/Development.md"])
        self.assertEqual({"mode": "diff", "reason": "diff", "changed_count": 2, "affected": False, "first_relevant": None,
                          "paths-ignore": ["**/*.md"]}, output["relevance"])
        self.assertEqual((0, False, False, [{"file": UNIT, "lane": "default", "reason": "relevance: not affected"}]),
                         (output["tests"]["count"], output["tests"]["active"], output["tests"]["missing"],
                          output["tests"]["not_run"]))
        self.assertIn("relevance diff (diff): the module is not affected: every changed file is ignored (**/*.md); "
                      "nothing to validate or test", output["notices"])

    def test_one_file_that_is_not_ignored_affects_it(self):
        output = self.run_on(["README.md", "main.tf"])
        self.assertEqual((True, "main.tf", 1), (output["relevance"]["affected"], output["relevance"]["first_relevant"],
                                                output["tests"]["count"]))
        self.assertIn("relevance diff (diff): the module is affected (main.tf is not ignored)", output["notices"])

    def test_no_test_file_is_not_missing_when_not_affected(self):
        doc = document([], event="pull_request")
        doc["changed_files"] = {"available": True, "truncated": False, "error": None, "api_head_sha": "abc",
                                "count": 1, "files": ["README.md"]}
        output = decide.decide(doc)
        self.assertEqual((False, []), (output["tests"]["missing"], output["warnings"]))

    def test_the_ignore_list(self):
        self.assertTrue(self.run_on(["README.md"], ignore=[])["relevance"]["affected"])
        replaced = self.run_on(["notes.txt", "README.md"], ignore=["**/*.txt"])
        self.assertEqual((True, "README.md", ["**/*.txt"]), (replaced["relevance"]["affected"],
                                                              replaced["relevance"]["first_relevant"],
                                                              replaced["relevance"]["paths-ignore"]))
        both = self.run_on(["a.md", "b.txt"], ignore=["**/*.md", "*.txt", "**/*.md"])
        self.assertEqual((False, ["**/*.md", "*.txt"]), (both["relevance"]["affected"], both["relevance"]["paths-ignore"]))
        self.assertIn("relevance diff (diff): the module is not affected: every changed file is ignored (**/*.md, *.txt); "
                      "nothing to validate or test", both["notices"])
        self.assertEqual(["**/*.md"], self.run_on(["a.md"], ignore="")["relevance"]["paths-ignore"])

    def test_an_invalid_ignore_list_is_refused(self):
        self.assertEqual(["The specification for input 'paths-ignore-yml' is not valid yaml!"],
                         self.run_on(["a.md"], ok=False)["errors"])
        self.assertEqual(["The input 'paths-ignore-yml' is 'docs'; it must be a list of patterns!"],
                         self.run_on(["a.md"], ignore="docs")["errors"])
        errors = self.run_on(["a.md"], ignore=[7, "a**b"])["errors"]
        self.assertEqual(2, len(errors))
        self.assertTrue(all(error.startswith("The input 'paths-ignore-yml' has an invalid entry: ") for error in errors))
        self.assertEqual(["The input 'paths-ignore-yml' has an invalid entry: the pattern 7 is not a string!",
                          "The input 'paths-ignore-yml' has an invalid entry: the pattern 'a**b' is not supported: '**' "
                          "must be a whole segment!"], errors)

    def test_everything_runs_where_relevance_fails_open(self):
        cases = [("disabled", 1, dict(enabled=False, files=["README.md"])),
                 ("event", 0, dict(event="schedule")),
                 ("event", 0, dict(event="workflow_dispatch")),
                 ("not-computed", 0, dict()),
                 ("workflow-changed", 2, dict(files=["README.md", ".github/workflows/test.yaml"])),
                 ("pr-head-moved", 1, dict(changed={"available": True, "truncated": False, "error": None,
                                                    "api_head_sha": "def", "count": 1, "files": ["README.md"]}))]
        for reason, count, kwargs in cases:
            with self.subTest(reason=reason):
                output = self.run_on(**kwargs)
                self.assertEqual(("all", reason, count, True, None),
                                 (output["relevance"]["mode"], output["relevance"]["reason"],
                                  output["relevance"]["changed_count"], output["relevance"]["affected"],
                                  output["relevance"]["first_relevant"]))
                self.assertIn(f"relevance all ({reason}): the module is affected", output["notices"])

    def test_the_switch_is_a_boolean(self):
        self.assertEqual(["The input 'path-relevance-enabled' is 'yes'; it must be true or false!"],
                         self.run_on(["a.md"], enabled="yes")["errors"])
        for value in ("true", True):
            with self.subTest(value=value):
                self.assertFalse(self.run_on(["a.md"], enabled=value)["relevance"]["affected"])
        self.assertEqual("disabled", self.run_on(["a.md"], enabled="false")["relevance"]["reason"])
        doc = document([UNIT], event="pull_request")
        doc["changed_files"] = {"available": True, "truncated": False, "error": None, "api_head_sha": "abc",
                                "count": 1, "files": ["a.md"]}
        self.assertFalse(decide.decide(doc)["relevance"]["affected"])

    def test_a_refused_admission_holds_the_tests_back_first(self):
        import test_admission
        doc = test_admission.ModuleModeTest().document(
            support.admission_facts([support.provider_dependency(published=support.NOW)], locks={}))
        doc["changed_files"] = {"available": True, "truncated": False, "error": None, "api_head_sha": "abc",
                                "count": 1, "files": ["README.md"]}
        self.assertEqual("admission: not admitted", decide.decide(doc)["tests"]["not_run"][0]["reason"])


MODULE_RUNNER_INPUTS = {**MODULE_INPUTS, "terraform-test-lanes-yml": "", "terraform-test-exclude-paths-yml": ""}


class AdapterTest(unittest.TestCase):
    def run_module(self, git, event="push", payload=None):
        runner = Runner(self, inputs=MODULE_RUNNER_INPUTS, payload=payload, environ={"GITHUB_EVENT_NAME": event})
        tools = FakeTools(git=git)
        code = adapter.run(runner.inputs_file, runner.environ, runner.log, tools, lambda path: True, True)
        return code, runner, tools

    def test_the_document_has_no_environments_and_fetches_the_changed_files(self):
        tools = FakeTools(git={("*.tftest.hcl", "*.tftest.json"): (0, f"{UNIT}\0", ""),
                               ("*.tf", "*.tf.json"): (0, "main.tf\0examples/01-basic/main.tf\0", "")})
        facts = {"repository": "o/r", "event_name": "push", "ref_name": "main", "ref_type": "branch",
                 "default_branch": "main", "payload": {"before": "b" * 40, "after": "a" * 40, "created": False,
                                                       "forced": False, "deleted": False},
                 "run": {"id": 1, "attempt": 1}}
        document = adapter.build_document(MODULE_RUNNER_INPUTS, facts, tools, lambda path: True, True)
        self.assertEqual(("module", [], {}, {"files": [UNIT], "directories_with_tf": [".", "examples/01-basic"],
                                            "environment_locks": {}}),
                         (document["mode"], document["yaml"]["environments"], document["directories_exist"],
                          document["tests"]))
        # The push's compare is fetched for the module's relevance (docs/Module-ci.md §5.1); here it fails open.
        self.assertEqual(False, document["changed_files"]["available"])
        self.assertEqual([("gh", "api", f"repos/o/r/compare/{'b' * 40}...{'a' * 40}")],
                         [argv for argv, _ in tools.calls if argv[0] == "gh"])

    def test_the_run_publishes_the_test_stage(self):
        code, runner, _ = self.run_module({("*.tftest.hcl", "*.tftest.json"): (0, f"{UNIT}\0", ""),
                                           ("*.tf", "*.tf.json"): (0, "main.tf\0", "")})
        self.assertEqual(0, code)
        outputs = runner.outputs()
        self.assertEqual(["relevance-file", "tests-matrix-json", "tests-count", "tests-active",
                          "tests-required-missing", "admission-refused", "admission-reason", "admission-admitted",
                          "automerge-eligible", "automerge-confirm-app", "relevance-mode", "relevance-reason",
                          "changed-count", "affected-count", "unaffected-count"],
                         list(outputs))
        self.assertEqual(("1", "true", "false"),
                         (outputs["tests-count"], outputs["tests-active"], outputs["tests-required-missing"]))
        # The push's compare is not answered here: relevance fails open and the module is affected.
        self.assertEqual(("all", "api-error", "0", "1", "0"),
                         (outputs["relevance-mode"], outputs["relevance-reason"], outputs["changed-count"],
                          outputs["affected-count"], outputs["unaffected-count"]))
        self.assertEqual("tests/unit-tests.tftest.hcl",
                         json.loads(outputs["tests-matrix-json"])["include"][0]["test"]["file"])
        with open(outputs["relevance-file"], encoding="utf-8") as handle:
            published = json.load(handle)
        self.assertEqual(["admission", "automerge", "comments", "mode", "notices", "record", "relevance", "schema_version",
                          "tests", "trigger", "warnings"], sorted(published))
        self.assertTrue(os.path.dirname(outputs["relevance-file"]).startswith(runner.environ["RUNNER_TEMP"]))

    def test_a_markdown_only_pull_request_publishes_not_affected(self):
        payload = {"action": "synchronize", "number": 12, "repository": {"default_branch": "main"},
                   "pull_request": {"number": 12, "head": {"sha": "c" * 40, "repo": {"fork": False}},
                                    "user": {"login": "octocat"}}}
        runner = Runner(self, inputs=MODULE_RUNNER_INPUTS, payload=payload,
                        environ={"GITHUB_EVENT_NAME": "pull_request", "GITHUB_BASE_REF": "main"})
        tools = FakeTools(git={("*.tftest.hcl", "*.tftest.json"): (0, f"{UNIT}\0", ""),
                               ("*.tf", "*.tf.json"): (0, "main.tf\0", "")},
                          api={"repos/o/r/pulls/12": {"head": {"sha": "c" * 40}, "changed_files": 1},
                               "repos/o/r/pulls/12/files?per_page=100&page=1": [{"filename": "README.md"}]})
        self.assertEqual(0, adapter.run(runner.inputs_file, runner.environ, runner.log, tools, lambda path: True, True))
        outputs = runner.outputs()
        self.assertEqual(("diff", "diff", "1", "0", "1", "0", "false"),
                         (outputs["relevance-mode"], outputs["relevance-reason"], outputs["changed-count"],
                          outputs["affected-count"], outputs["unaffected-count"], outputs["tests-count"],
                          outputs["tests-active"]))
        self.assertIn("the module is not affected", runner.log.getvalue())

    def test_a_repository_without_tests_publishes_the_finding(self):
        code, runner, _ = self.run_module({("*.tf", "*.tf.json"): (0, "main.tf\0", "")})
        self.assertEqual(0, code)
        outputs = runner.outputs()
        self.assertEqual(("0", "false", "true"),
                         (outputs["tests-count"], outputs["tests-active"], outputs["tests-required-missing"]))
        self.assertIn("::warning title=create-tf-vars-matrix::no test file: a module needs at least one test file",
                      runner.log.getvalue())

    def test_an_invalid_configuration_exits_2(self):
        runner = Runner(self, inputs={**MODULE_RUNNER_INPUTS, "terraform-test-required": "yes"})
        code = adapter.run(runner.inputs_file, runner.environ, runner.log, FakeTools(), lambda path: True, True)
        self.assertEqual(2, code)
        self.assertEqual("", runner.output())


if __name__ == "__main__":
    unittest.main()
