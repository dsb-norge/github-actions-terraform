"""The relevance.json the reading actions' contract tests use is the one create-matrix publishes.

`relevance_fixture.py` writes it for the aggregator's, the run summary's and the auto-merge
evaluator's suites. These tests keep that helper honest: every scenario decides, and the file has
the keys and entry fields those actions read, spelled as literals here so a rename in the engine
fails here as well as there.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

import relevance_fixture
import support

READ_BY_THE_ACTIONS = {"environment", "github-environment", "verdict", "reasons", "add-pr-comment", "pr-comment-group",
                       "mutates-on-pr", "pr-auto-merge-enabled", "pr-auto-merge-from-actors", "pr-auto-merge-limits",
                       "paths", "paths-ignore", "depends-on"}
# The decision itself, published beside what the actions read: every entry's trigger events, and the
# goals a running environment is granted (docs/Decision-engine.md I16).
DECISION_FIELDS = {"trigger-events", "relevant"}


def written(scenario):
    with tempfile.TemporaryDirectory() as temp:
        path = os.path.join(temp, "relevance.json")
        relevance_fixture.write(scenario, path)
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)


class ContractTest(unittest.TestCase):
    def test_every_scenario_publishes_the_keys_the_actions_read(self):
        for scenario in relevance_fixture.SCENARIOS:
            with self.subTest(scenario=scenario):
                published = written(scenario)
                self.assertEqual({"schema_version", "relevance", "counts", "environments", "tests", "comments",
                                  "notices", "warnings", "record", "trigger", "ordering", "admission"}, set(published))
                self.assertEqual({"declared", "stages_used", "cap", "bypass"}, set(published["ordering"]))
                self.assertEqual({"affected", "unaffected", "by_stage"}, set(published["counts"]))
                self.assertEqual({"event", "lines"}, set(published["trigger"]))
                self.assertEqual({"mode", "reason", "changed_count"}, set(published["relevance"]))
                for entry in published["environments"]:
                    goals = {"goals", "stage"} if entry["verdict"] == "run" else set()
                    self.assertEqual(READ_BY_THE_ACTIONS | DECISION_FIELDS | goals, set(entry))

    def test_the_event_scenarios_publish_their_trigger_lines(self):
        dispatch = written("dispatch-staging")
        self.assertEqual({"event": "workflow_dispatch", "lines": [
            'dispatched by octocat: environment staging, goal plan, reason "reconcile after incident 42"']},
            dispatch["trigger"])
        self.assertEqual(["skip", "run", "skip"], [entry["verdict"] for entry in dispatch["environments"]])
        schedule = written("schedule-nothing")
        self.assertEqual({"event": "schedule", "lines": [
            "schedule: no environment takes part in scheduled runs; add 'schedule' to the trigger-events of the "
            "environment the schedule is for"]}, schedule["trigger"])
        self.assertEqual({"affected": 0, "unaffected": 3, "by_stage": {"1": 0, "2": 0, "3": 0}}, schedule["counts"])

    def test_the_scenarios_decide_what_the_actions_tests_expect(self):
        cases = {
            "docs-only": (["skip", "skip", "skip"], "diff"),
            "one-environment": (["skip", "run", "skip"], "diff"),
            "workflow-changed": (["run", "run", "run"], "all"),
        }
        for scenario, (verdicts, mode) in cases.items():
            with self.subTest(scenario=scenario):
                published = written(scenario)
                self.assertEqual(verdicts, [entry["verdict"] for entry in published["environments"]])
                self.assertEqual(mode, published["relevance"]["mode"])
                prod = published["environments"][0]
                self.assertEqual(("prod-gh", "true", ["renovate[bot]"], "true"),
                                 (prod["github-environment"], prod["pr-auto-merge-enabled"],
                                  prod["pr-auto-merge-from-actors"], prod["add-pr-comment"]))
                self.assertEqual(-1, prod["pr-auto-merge-limits"]["plan-max-count-import"])
                self.assertEqual(["apply-on-pr"], published["environments"][2]["mutates-on-pr"])
                self.assertEqual([("true", ["renovate[bot]", "dependabot[bot]"])] * 2,
                                 [(e["pr-auto-merge-enabled"], e["pr-auto-merge-from-actors"])
                                  for e in published["environments"][1:]])

    def test_the_command_line_writes_the_file_and_refuses_anything_else(self):
        script = os.path.join(support.TESTS_DIR, "relevance_fixture.py")
        with tempfile.TemporaryDirectory() as temp:
            path = os.path.join(temp, "out.json")
            done = subprocess.run([sys.executable, "-I", "-B", script, "docs-only", path], capture_output=True,
                                  text=True, cwd=temp)
            self.assertEqual(0, done.returncode, done.stderr)
            with open(path, encoding="utf-8") as handle:
                self.assertEqual(3, json.load(handle)["counts"]["unaffected"])
            for argv in ([], ["nonsense", path], ["docs-only"]):
                with self.subTest(argv=argv):
                    done = subprocess.run([sys.executable, "-I", "-B", script, *argv], capture_output=True, text=True,
                                          cwd=temp)
                    self.assertNotEqual(0, done.returncode)
                    self.assertIn("usage: relevance_fixture.py <docs-only|one-environment|workflow-changed|dispatch-staging|schedule-nothing|"
                                  "schedule-capped|push-staged>",
                                  done.stderr)

    def test_the_staged_scenario_publishes_its_stages(self):
        published = written("push-staged")
        self.assertEqual(({"declared": True, "stages_used": 2, "cap": 3, "bypass": None}, {"1": 1, "2": 2, "3": 0}),
                         (published["ordering"], published["counts"]["by_stage"]))
        self.assertEqual([("shared", 1, []), ("prod", 2, ["shared"]), ("sandbox", 2, [])],
                         [(e["environment"], e["stage"], e["depends-on"]) for e in published["environments"]])

    def test_a_scenario_that_does_not_decide_is_refused(self):
        original = relevance_fixture.ENVIRONMENTS
        relevance_fixture.ENVIRONMENTS = [{"environment": "prod", "paths": "not a list"}]
        self.addCleanup(setattr, relevance_fixture, "ENVIRONMENTS", original)
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(SystemExit) as raised:
                relevance_fixture.write("docs-only", os.path.join(temp, "x.json"))
        self.assertIn("scenario 'docs-only' does not decide", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
