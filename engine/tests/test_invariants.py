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
        self.assertEqual(["I14: a 'not affected' head for 'a', which is affected"], invariants.check(document, output))

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


if __name__ == "__main__":
    unittest.main()
