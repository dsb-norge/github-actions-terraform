"""The invariant checker catches what it claims to: each check fires on a crafted bad output.

Every case of the suite passes through invariants.check; a checker that let everything through
would look the same as one that works. These tests prove each check against an output broken in
exactly one way.
"""

import copy
import unittest

import invariants
import support
from dsb_tf_engine import decide


def decided(count=2):
    document = support.document(environments=[{"environment": f"env-{index}"} for index in range(count)])
    return document, decide.decide(document)


class InvariantCheckerTest(unittest.TestCase):
    def assertViolation(self, document, output, fragment):
        violations = invariants.check(document, output)
        self.assertTrue(any(fragment in violation for violation in violations),
                        f"expected a violation containing {fragment!r}, got {violations}")

    def test_a_sound_output_has_no_violations(self):
        self.assertEqual([], invariants.check(*decided()))

    def test_an_error_output_that_still_carries_a_matrix(self):
        document, output = decided()
        output["errors"] = ["something"]
        self.assertViolation(document, output, "errors present")

    def test_an_error_output_that_still_carries_environments(self):
        document, output = decided()
        output["errors"] = ["something"]
        output["matrices"] = {}
        self.assertViolation(document, output, "errors present")

    def test_a_declared_environment_left_undecided(self):
        document, output = decided()
        output["environments"].pop()
        self.assertViolation(document, output, "I7: decided environments do not match")

    def test_decided_environments_without_a_declared_list(self):
        document, output = decided()
        document["yaml"]["inputs"]["environments-yml"] = support.parsed(None, ok=False)
        self.assertViolation(document, output, "I7: decided environments do not match")

    def test_a_name_decided_twice(self):
        document, output = decided()
        output["environments"][1]["environment"] = "env-0"
        self.assertViolation(document, output, "I7: an environment name appears twice")

    def test_a_verdict_outside_the_vocabulary(self):
        document, output = decided()
        output["environments"][0]["verdict"] = "maybe"
        self.assertViolation(document, output, "I7: a verdict outside run/skip")

    def test_a_run_environment_missing_from_the_matrix(self):
        document, output = decided()
        output["matrices"]["1"]["include"].pop()
        self.assertViolation(document, output, "I8: matrix rows are not the run environments")

    def test_matrix_rows_out_of_declaration_order(self):
        document, output = decided()
        output["matrices"]["1"]["include"].reverse()
        self.assertViolation(document, output, "I8: matrix rows are not the run environments")

    def test_a_skipped_environment_in_the_matrix(self):
        document, output = decided()
        output["environments"][1]["verdict"] = "skip"
        output["environments"][1]["reasons"] = ["relevance: no changed file matches"]
        self.assertViolation(document, output, "I8: matrix rows are not the run environments")

    def test_an_environment_in_two_stages(self):
        document, output = decided()
        output["matrices"]["2"] = copy.deepcopy(output["matrices"]["1"])
        self.assertViolation(document, output, "I8: matrix rows are not the run environments")

    def test_a_stage_whose_environment_list_disagrees_with_its_rows(self):
        document, output = decided()
        output["matrices"]["1"]["environment"].reverse()
        self.assertViolation(document, output, "I8: stage 1's environment list")

    def test_a_skip_without_a_reason(self):
        document, output = decided()
        output["environments"][1]["verdict"] = "skip"
        output["environments"][1]["reasons"] = []
        output["matrices"]["1"]["include"].pop()
        output["matrices"]["1"]["environment"].pop()
        output["counts"] = {"affected": 1, "unaffected": 1}
        output["relevance"] = {"mode": "diff", "reason": "diff", "changed_count": 0}
        self.assertEqual(["I11: a skip without a reason"], invariants.check(document, output))

    def test_a_record_that_is_not_one_line_per_environment(self):
        document, output = decided()
        output["record"].pop()
        self.assertViolation(document, output, "record: not one line per environment")

    def test_counts_that_disagree_with_the_run_set(self):
        document, output = decided()
        output["counts"]["affected"] = 3
        self.assertViolation(document, output, "counts: affected")

    def test_counts_that_do_not_sum_to_the_environments(self):
        document, output = decided()
        output["counts"]["unaffected"] = 1
        self.assertEqual(["counts: affected and unaffected do not sum to the environments decided"],
                         invariants.check(document, output))

    def test_mode_all_with_an_environment_skipped(self):
        document, output = decided()
        output["environments"][1]["verdict"] = "skip"
        output["matrices"]["1"]["include"].pop()
        output["matrices"]["1"]["environment"].pop()
        output["counts"] = {"affected": 1, "unaffected": 1}
        self.assertEqual(["I6: mode all but an environment does not run for it"], invariants.check(document, output))

    def test_mode_all_with_an_environment_running_for_another_reason(self):
        document, output = decided()
        output["environments"][0]["reasons"] = ["relevance: main/**"]
        self.assertEqual(["I6: mode all but an environment does not run for it"], invariants.check(document, output))

    def test_relevance_switched_off_without_the_reason(self):
        document, output = decided()
        document["workflow_inputs"]["path-relevance-enabled"] = False
        self.assertEqual(["I13: relevance switched off but the reason is not 'disabled'"],
                         invariants.check(document, output))

    def seeded(self, files):
        environments = [{"environment": "a"}, {"environment": "b", "pr-comment-group": "g"}]
        document = support.document(environments=environments,
                                    directories={"./envs/a": True, "./envs/b": True})
        document["event"].update(name="pull_request", action="synchronize")
        document["event"]["pull_request"] = {"number": 1, "head_sha": "x", "is_fork": False}
        document["run"] = {"id": 1, "attempt": 1}
        document["changed_files"] = {"available": True, "truncated": False, "error": None, "api_head_sha": "x",
                                     "count": len(files), "files": files}
        output = decide.decide(document)
        self.assertEqual([], invariants.check(document, output))
        return document, output

    def test_a_manifest_where_the_seed_does_not_run(self):
        document, output = self.seeded(["README.md"])
        document["event"]["action"] = "closed"
        self.assertEqual(["I14: a manifest where the seed does not run"], invariants.check(document, output))

    def test_an_environment_head_for_a_grouped_environment(self):
        document, output = self.seeded(["README.md"])
        output["comments"]["heads"].append({**output["comments"]["heads"][-1], "key": "b"})
        self.assertIn("I14: an environment head for 'b', which gets none", invariants.check(document, output))

    def test_an_environment_head_for_an_unknown_environment(self):
        document, output = self.seeded(["envs/a/x.tf"])
        output["comments"]["heads"].append({**output["comments"]["heads"][-1], "key": "zzz"})
        self.assertEqual(["I14: an environment head for 'zzz', which gets none"], invariants.check(document, output))

    def test_a_not_affected_head_for_an_affected_environment(self):
        document, output = self.seeded(["envs/a/x.tf"])
        output["comments"]["heads"][-1]["state"] = "not-affected"
        self.assertEqual(["I14: a 'not affected' head for 'a', which is not skipped by relevance"], invariants.check(document, output))

    def test_a_purge_for_an_affected_environment(self):
        document, output = self.seeded(["envs/a/x.tf"])
        output["comments"]["purge_tags_for"].append("a")
        output["comments"]["gc"] += output["comments"]["gc"][:4]
        self.assertEqual(["I14: a tag purge for 'a', which is not an unaffected commenting environment"],
                         invariants.check(document, output))

    def test_purge_rules_that_do_not_match_the_purges(self):
        document, output = self.seeded(["README.md"])
        output["comments"]["gc"].pop()
        self.assertEqual(["I14: not four purge rules per purged environment"], invariants.check(document, output))

    def tested(self, **kwargs):
        import test_tests
        document = test_tests.document(["tests/a.tftest.hcl", "tests/b.tftest.hcl"], **kwargs)
        output = decide.decide(document)
        self.assertEqual([], invariants.check(document, output))
        return document, output

    def test_a_test_count_that_disagrees_with_the_rows(self):
        document, output = self.tested()
        output["tests"]["count"] = 5
        self.assertEqual(["tests: the count, the active flag and the rows disagree"], invariants.check(document, output))

    def test_a_test_slug_twice(self):
        document, output = self.tested()
        output["tests"]["matrix"]["include"][1]["slug"] = output["tests"]["matrix"]["include"][0]["slug"]
        self.assertEqual(["tests: a slug appears twice"], invariants.check(document, output))

    def test_a_credentialed_row_on_a_fork(self):
        document, output = self.tested(is_fork=True)
        output["tests"]["matrix"]["include"][0]["test"]["extra-envs-from-secrets"] = {"X": "S"}
        self.assertEqual(["I4: a credentialed test row where secrets are unavailable"],
                         invariants.check(document, output))

    def test_a_row_outside_the_environment_pattern_or_taken(self):
        for name in ("prod-tests", "tftest-UP", "prod"):
            with self.subTest(name=name):
                environments = [{"environment": "prod"}] if name != "prod" else [{"environment": "x", "github-environment": "PROD"}]
                document, output = self.tested(environments=environments, locks={})
                output["tests"]["matrix"]["include"][0]["test"]["github-environment"] = name
                self.assertEqual([f"I9: the test row 'root--a' runs in '{name}'"], invariants.check(document, output))

    def test_an_error_output_with_a_relevance_block(self):
        document, output = decided()
        output.update(errors=["something"], environments=[], matrices={}, record=[],
                      counts={"affected": 0, "unaffected": 0})
        self.assertEqual(["errors present but a relevance block is emitted"], invariants.check(document, output))


class RelevantInvariantTest(unittest.TestCase):
    def test_a_run_environment_marked_not_relevant(self):
        document, output = decided()
        output["environments"][0]["relevant"] = False
        self.assertTrue(any(v.startswith("relevant: 'env-0' runs") for v in invariants.check(document, output)))

    def test_a_relevance_skip_marked_relevant(self):
        document = support.document(environments=[{"environment": "a"}])
        document["event"] = {"name": "push", "ref_name": "main", "push": {"created": False, "forced": False,
                                                                          "deleted": False}}
        document["changed_files"] = {"available": True, "truncated": False, "error": None, "api_head_sha": None,
                                     "count": 1, "files": ["README.md"]}
        output = decide.decide(document)
        self.assertEqual([], invariants.check(document, output))
        output["environments"][0]["relevant"] = True
        self.assertTrue(any(v.startswith("relevant: 'a' is skipped") for v in invariants.check(document, output)))


class GoalInvariantTest(unittest.TestCase):
    """I1, I2, I3, I15, I16 and rules 2-3, each against an output broken in one way."""

    def decide(self, event="push", goals=("all",), dispatch=None, trigger_events=None, ref="main"):
        environment = {"environment": "a", "goals-yml": list(goals)}
        if trigger_events is not None:
            environment["trigger-events"] = trigger_events
        document = support.document(environments=[environment, {"environment": "b"}],
                                    env_yaml=[{"goals-yml": support.parsed(list(goals))}, {}], ref_name=ref)
        document["event"]["name"] = event
        if dispatch is not None:
            document["event"]["dispatch"] = {"block": True, "environment": "", "goal": "", "reason": "", **dispatch}
        output = decide.decide(document)
        self.assertEqual([], invariants.check(document, output))
        return document, output

    def grant(self, output, goals):
        output["environments"][0]["goals"] = goals
        output["matrices"]["1"]["include"][0]["vars"]["goals-granted"] = goals

    def assertViolation(self, document, output, fragment):
        violations = invariants.check(document, output)
        self.assertTrue(any(fragment in violation for violation in violations),
                        f"expected a violation containing {fragment!r}, got {violations}")

    def test_an_environment_dropped_by_an_earlier_rule_that_runs(self):
        document, output = self.decide(event="schedule", trigger_events=["schedule"])
        output["environments"][1]["verdict"] = "run"
        self.assertViolation(document, output, "rules 2-3")

    def test_a_not_taking_part_head_for_an_environment_that_takes_part(self):
        document, output = decided(1)
        document["event"] = {"name": "pull_request", "ref_name": "main",
                             "pull_request": {"number": 1, "head_sha": "a", "is_fork": False}}
        document["run"] = {"id": 1, "attempt": 1}
        output["comments"] = {"heads": [{"kind": "env", "key": "env-0", "state": "not-taking-part"}],
                              "purge_tags_for": [], "gc": []}
        self.assertViolation(document, output, "I14: a 'not taking part' head")

    def test_goals_that_disagree_with_the_row(self):
        document, output = self.decide()
        output["environments"][0]["goals"] = ["init"]
        self.assertViolation(document, output, "I16")

    def test_a_running_entry_without_goals(self):
        document, output = self.decide()
        del output["environments"][0]["goals"]
        self.assertViolation(document, output, "I16")

    def test_a_goal_outside_the_vocabulary(self):
        document, output = self.decide()
        self.grant(output, ["init", "all"])
        self.assertViolation(document, output, "I1: 'a' is granted a goal outside the vocabulary")

    def test_a_goal_the_gate_would_not_pass(self):
        for goals, granted in ((("plan",), ["plan", "apply"]), (("apply",), ["destroy"]),
                               (("init",), ["destroy-plan"]), (("init",), ["lint"])):
            with self.subTest(goals=goals, granted=granted):
                document, output = self.decide(goals=goals)
                self.grant(output, granted)
                self.assertViolation(document, output, "I1: 'a' is granted")

    def test_apply_off_the_default_branch(self):
        document, output = self.decide(ref="feature/x")
        self.grant(output, ["apply"])
        self.assertViolation(document, output, "I1: 'a' is granted 'apply'")

    def test_destroy_on_a_schedule(self):
        document, output = self.decide(event="schedule", goals=("destroy", "destroy-plan"),
                                       trigger_events=["schedule"])
        self.grant(output, ["destroy-plan", "destroy"])
        self.assertViolation(document, output, "I15")

    def test_a_dispatch_that_grants_more_than_a_push(self):
        document, output = self.decide(event="workflow_dispatch", goals=("plan",), dispatch={"goal": "plan"})
        document["event"]["name"] = "workflow_dispatch"
        self.grant(output, ["plan", "apply"])
        self.assertViolation(document, output, "I3")

    def test_a_named_dispatch_that_runs_another_environment(self):
        document, output = self.decide(event="workflow_dispatch", dispatch={"environment": "a"})
        output["environments"][1]["verdict"] = "run"
        self.assertViolation(document, output, "I2")
        document, output = self.decide(event="workflow_dispatch", dispatch={"environment": "a"})
        output["environments"][0]["verdict"] = "skip"
        self.assertViolation(document, output, "I2")

    def test_the_goal_invariants_are_not_checked_on_an_error(self):
        document, output = self.decide()
        output.update({"errors": ["x"], "environments": [], "matrices": {}})
        self.assertEqual([], [v for v in invariants.check(document, output) if v.startswith(("I1", "I2", "I3", "I16"))])


if __name__ == "__main__":
    unittest.main()
