"""Ordering between environments: rule 6 (docs/Environment-ordering.md §4-§6, §12).

Every message and reason is compared as a literal; the invariants I18 to I24 hold on every case.
"""

import unittest

import invariants
import support
from dsb_tf_engine import decide


def document(environments, event="push", files=None, ref="main", dispatch=None, goals=("all",)):
    env_yaml = [{key: support.parsed(value) for key, value in entry.items() if key.endswith("-yml")}
                for entry in environments]
    doc = support.document(environments=environments, env_yaml=env_yaml, ref_name=ref)
    doc["yaml"]["inputs"]["goals-yml"] = support.parsed(list(goals))
    doc["event"]["name"] = event
    if event == "push":
        doc["event"]["push"] = {"created": False, "forced": False, "deleted": False}
    if event == "pull_request":
        doc["event"].update({"action": "synchronize", "base_ref": "main",
                             "pull_request": {"number": 87, "head_sha": "abc", "is_fork": False}})
        doc["run"] = {"id": 4711, "attempt": 1}
    if dispatch is not None:
        doc["event"]["dispatch"] = {"block": True, "environment": "", "goal": "", "reason": "", "inputs": [],
                                    **dispatch}
    if files is not None:
        doc["changed_files"] = {"available": True, "truncated": False, "error": None, "api_head_sha": "abc",
                                "count": len(files), "files": files}
    return doc


def decided(*args, **kwargs):
    doc = document(*args, **kwargs)
    output = decide.decide(doc)
    assert invariants.check(doc, output) == [], invariants.check(doc, output)
    return output


def stages(output):
    return {entry["environment"]: entry.get("stage") for entry in output["environments"]}


def ordering_reasons(output):
    return {entry["environment"]: [reason for reason in entry["reasons"] if reason.startswith("ordering:")]
            for entry in output["environments"]}


def errors(environments):
    return decided(environments)["errors"]


class StageAssignmentTest(unittest.TestCase):
    def test_a_chain_of_two(self):
        output = decided([{"environment": "shared"}, {"environment": "prod", "depends-on": ["shared"]}])
        self.assertEqual({"shared": 1, "prod": 2}, stages(output))
        self.assertEqual({"declared": True, "stages_used": 2, "cap": 3, "bypass": None}, output["ordering"])
        self.assertEqual(({"1": ["shared"], "2": ["prod"], "3": []}, {"1": 1, "2": 1, "3": 0}),
                         ({stage: matrix["environment"] for stage, matrix in output["matrices"].items()},
                          output["counts"]["by_stage"]))
        self.assertEqual({"shared": ["ordering: stage 1"], "prod": ["ordering: stage 2"]}, ordering_reasons(output))
        self.assertEqual(["relevance: all:not-computed", "ordering: stage 2",
                          "goals: init, format, validate, lint, plan, apply"], output["environments"][1]["reasons"])

    def test_a_chain_of_three(self):
        output = decided([{"environment": "a"}, {"environment": "b", "depends-on": ["a"]},
                          {"environment": "c", "depends-on": ["b"]}])
        self.assertEqual(({"a": 1, "b": 2, "c": 3}, 3), (stages(output), output["ordering"]["stages_used"]))

    def test_a_diamond_puts_its_tail_in_stage_three(self):
        output = decided([{"environment": "base"}, {"environment": "left", "depends-on": ["base"]},
                          {"environment": "right", "depends-on": "base"},
                          {"environment": "tail", "depends-on": ["left", "right"]}])
        self.assertEqual({"base": 1, "left": 2, "right": 2, "tail": 3}, stages(output))

    def test_independent_chains_share_stage_numbers(self):
        output = decided([{"environment": "a"}, {"environment": "b", "depends-on": ["a"]},
                          {"environment": "x"}, {"environment": "y", "depends-on": ["x"]}])
        self.assertEqual({"a": 1, "b": 2, "x": 1, "y": 2}, stages(output))

    def test_a_free_standing_environment_joins_the_last_stage_in_use(self):
        output = decided([{"environment": "sandbox"}, {"environment": "shared"},
                          {"environment": "prod", "depends-on": ["shared"]}])
        self.assertEqual({"sandbox": 2, "shared": 1, "prod": 2}, stages(output))
        self.assertEqual(["sandbox", "prod"], output["matrices"]["2"]["environment"])

    def test_without_a_chain_everything_is_stage_one_and_says_nothing(self):
        output = decided([{"environment": "a"}, {"environment": "b"}])
        self.assertEqual(({"a": 1, "b": 1}, {"declared": False, "stages_used": 1, "cap": 3, "bypass": None}),
                         (stages(output), output["ordering"]))
        self.assertEqual({"a": [], "b": []}, ordering_reasons(output))
        self.assertEqual([[], []], [entry["depends-on"] for entry in output["environments"]])

    def test_a_name_written_alone_is_one_dependency(self):
        output = decided([{"environment": "shared"}, {"environment": "prod", "depends-on": "shared"}])
        self.assertEqual(({"shared": 1, "prod": 2}, ["shared"]),
                         (stages(output), output["environments"][1]["depends-on"]))

    def test_depends_on_is_no_row_variable(self):
        output = decided([{"environment": "shared"}, {"environment": "prod", "depends-on": ["shared"]}])
        self.assertNotIn("depends-on", output["matrices"]["2"]["include"][0]["vars"])


class DependencyNotInTheRunTest(unittest.TestCase):
    def test_dropped_by_relevance_it_runs_at_once_and_says_so(self):
        output = decided([{"environment": "shared"}, {"environment": "prod", "depends-on": ["shared"]}],
                         files=["envs/prod/main.tf"])
        self.assertEqual(({"shared": None, "prod": 1}, 1), (stages(output), output["ordering"]["stages_used"]))
        self.assertEqual({"shared": [], "prod": ["ordering: depends-on 'shared' not in this run (relevance: no "
                                                 "changed file matches)"]}, ordering_reasons(output))
        self.assertIn("ordering: 'prod' depends on 'shared', which is not in this run (relevance: no changed file "
                      "matches), so it runs without waiting for it", output["notices"])

    def test_dropped_by_its_trigger_events(self):
        output = decided([{"environment": "shared", "trigger-events": ["pull_request"]},
                          {"environment": "prod", "depends-on": ["shared"]}])
        self.assertEqual(["ordering: depends-on 'shared' not in this run (trigger-events: push not enabled)"],
                         ordering_reasons(output)["prod"])

    def test_the_rest_of_the_chain_keeps_its_order(self):
        output = decided([{"environment": "a"}, {"environment": "b", "depends-on": ["a"]},
                          {"environment": "c", "depends-on": ["b"]}], files=["envs/b/x.tf", "envs/c/x.tf"])
        self.assertEqual({"a": None, "b": 1, "c": 2}, stages(output))

    def test_a_run_that_mutates_nothing_says_nothing_about_it(self):
        output = decided([{"environment": "shared"}, {"environment": "prod", "depends-on": ["shared"]}],
                         files=["envs/prod/main.tf"], goals=("init", "plan"))
        self.assertEqual({"shared": [], "prod": []}, ordering_reasons(output))
        self.assertFalse(any(notice.startswith("ordering") for notice in output["notices"]))


class OneStageTest(unittest.TestCase):
    ENVIRONMENTS = [{"environment": "shared"}, {"environment": "prod", "depends-on": ["shared"]},
                    {"environment": "sandbox"}]

    def test_a_destroy_alone_is_staged(self):
        environments = [{"environment": "shared", "goals-yml": ["init", "destroy-plan", "destroy"]},
                        {"environment": "prod", "depends-on": ["shared"], "goals-yml": ["init", "plan"]}]
        self.assertEqual({"shared": 1, "prod": 2}, stages(decided(environments)))

    def test_a_plan_only_run_is_one_stage(self):
        output = decided(self.ENVIRONMENTS, goals=("init", "plan"))
        self.assertEqual(({"shared": 1, "prod": 1, "sandbox": 1}, 1), (stages(output), output["ordering"]["stages_used"]))

    def test_a_pull_request_that_only_plans_is_one_stage(self):
        output = decided(self.ENVIRONMENTS, event="pull_request", files=["main/x.tf"])
        self.assertEqual({"shared": 1, "prod": 1, "sandbox": 1}, stages(output))

    def test_a_pull_request_that_applies_is_staged(self):
        environments = [{"environment": "shared", "goals-yml": ["all", "apply-on-pr"]},
                        {"environment": "prod", "depends-on": ["shared"]}]
        output = decided(environments, event="pull_request", files=["main/x.tf"])
        self.assertEqual({"shared": 1, "prod": 2}, stages(output))

    def test_a_plan_capped_dispatch_is_one_stage(self):
        output = decided(self.ENVIRONMENTS, event="workflow_dispatch", dispatch={"goal": "plan"})
        self.assertEqual(({"shared": 1, "prod": 1, "sandbox": 1}, None),
                         (stages(output), output["ordering"]["bypass"]))

    def test_a_dispatch_of_every_environment_is_staged(self):
        output = decided(self.ENVIRONMENTS, event="workflow_dispatch", dispatch={"goal": "default"})
        self.assertEqual({"shared": 1, "prod": 2, "sandbox": 2}, stages(output))

    def test_a_single_environment_dispatch_bypasses_its_dependencies(self):
        output = decided(self.ENVIRONMENTS, event="workflow_dispatch", dispatch={"environment": "prod", "goal": "apply"})
        self.assertEqual(({"shared": None, "prod": 1, "sandbox": None}, "single-environment-dispatch"),
                         (stages(output), output["ordering"]["bypass"]))
        self.assertEqual(["ordering: single-environment dispatch, stage 1"], ordering_reasons(output)["prod"])
        self.assertIn("ordering bypassed: 'prod' depends on 'shared', which a single-environment dispatch does not run",
                      output["notices"])

    def test_the_bypass_names_every_dependency(self):
        environments = [{"environment": "a"}, {"environment": "b"}, {"environment": "prod", "depends-on": ["a", "b"]}]
        output = decided(environments, event="workflow_dispatch", dispatch={"environment": "prod"})
        self.assertIn("ordering bypassed: 'prod' depends on 'a', 'b', which a single-environment dispatch does not run",
                      output["notices"])

    def test_a_single_environment_dispatch_without_dependencies_records_nothing(self):
        output = decided(self.ENVIRONMENTS, event="workflow_dispatch", dispatch={"environment": "sandbox"})
        self.assertEqual(([], "single-environment-dispatch"),
                         (ordering_reasons(output)["sandbox"], output["ordering"]["bypass"]))
        self.assertFalse(any(notice.startswith("ordering") for notice in output["notices"]))


class ValidationTest(unittest.TestCase):
    def test_an_unknown_name(self):
        self.assertEqual(["The environment 'prod' depends on 'stagng', which is not an environment of "
                          "environments-yml; did you mean 'staging'?"],
                         errors([{"environment": "staging"}, {"environment": "prod", "depends-on": ["stagng"]}]))
        self.assertEqual(["The environment 'prod' depends on 'zzz', which is not an environment of environments-yml. "
                          "The environments are staging, prod."],
                         errors([{"environment": "staging"}, {"environment": "prod", "depends-on": ["zzz"]}]))

    def test_itself(self):
        self.assertEqual(["The environment 'prod' depends on itself, so it could never run; remove 'prod' from its "
                          "depends-on."], errors([{"environment": "prod", "depends-on": ["prod"]}]))

    def test_a_cycle(self):
        self.assertEqual(["depends-on forms a cycle, shared → prod → shared, so none of them could ever run first; "
                          "remove one of the dependencies."],
                         errors([{"environment": "shared", "depends-on": ["prod"]},
                                 {"environment": "prod", "depends-on": ["shared"]}]))
        self.assertEqual(["depends-on forms a cycle, a → b → c → a, so none of them could ever run first; remove one "
                          "of the dependencies."],
                         errors([{"environment": "a", "depends-on": ["c"]}, {"environment": "b", "depends-on": ["a"]},
                                 {"environment": "c", "depends-on": ["b"]}, {"environment": "d", "depends-on": ["c"]}]))
        # Found from an environment outside the cycle, it still starts at the member declared first.
        self.assertEqual(["depends-on forms a cycle, a → b → a, so none of them could ever run first; remove one of "
                          "the dependencies."],
                         errors([{"environment": "x", "depends-on": ["b"]}, {"environment": "a", "depends-on": ["b"]},
                                 {"environment": "b", "depends-on": ["a"]}]))

    def test_deeper_than_the_cap(self):
        self.assertEqual(["depends-on needs 4 stages, but the workflow runs at most 3: shared → platform → regional → "
                          "app. Flatten the chain, or split the repository."],
                         errors([{"environment": "app", "depends-on": ["regional"]},
                                 {"environment": "shared"}, {"environment": "platform", "depends-on": ["shared"]},
                                 {"environment": "regional", "depends-on": ["platform"]}]))

    def test_the_cap_holds_for_the_declared_graph_whatever_the_run(self):
        environments = [{"environment": "a"}, {"environment": "b", "depends-on": ["a"]},
                        {"environment": "c", "depends-on": ["b"]}, {"environment": "d", "depends-on": ["c"]}]
        self.assertEqual(1, len(decided(environments, files=["envs/d/x.tf"])["errors"]))

    def test_the_shape(self):
        self.assertEqual(["The environment 'prod' sets 'depends-on' to {\"shared\": true}; it must be a list of "
                          "environment names.",
                          "The environment 'test' depends on 7, which is not an environment name; quote it if it is "
                          "one.",
                          "The environment 'test' depends on null, which is not an environment name."],
                         errors([{"environment": "shared"}, {"environment": "prod", "depends-on": {"shared": True}},
                                 {"environment": "test", "depends-on": [7, None]}]))

    def test_the_names_are_checked_before_the_cycle(self):
        self.assertEqual(["The environment 'b' depends on 'x', which is not an environment of environments-yml. The "
                          "environments are a, b."],
                         errors([{"environment": "a", "depends-on": ["b"]}, {"environment": "b", "depends-on": ["a", "x"]}]))

    def test_the_suffixed_spelling_names_the_setting(self):
        self.assertEqual(["The environment 'prod' sets 'depends-on-yml', which is not a setting: per environment it is "
                          "'depends-on', a list written directly in the entry."],
                         errors([{"environment": "prod", "depends-on-yml": ["shared"]}]))


if __name__ == "__main__":
    unittest.main()
