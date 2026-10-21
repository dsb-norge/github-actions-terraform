"""Which attempt of each artifact file a job reads after a re-run (docs/Re-run-attempts.md §4)."""

import unittest

from dsb_tf_engine import attempts


class SplitTest(unittest.TestCase):
    def test_the_names_of_the_spec(self):
        for file_name, expected in (
                ("matrix-job-meta-prod-attempt-2.json", ("matrix-job-meta-prod.json", 2)),
                ("matrix-job-meta-prod.json", ("matrix-job-meta-prod.json", 0)),
                ("matrix-job-meta-eu.west-attempt-12.json", ("matrix-job-meta-eu.west.json", 12)),
                ("notes-attempt-3", ("notes", 3)),
                ("matrix-job-meta-prod-attempt-02.json", ("matrix-job-meta-prod-attempt-02.json", 0)),
                ("report-attempt-2.tar.gz", ("report-attempt-2.tar.gz", 0))):
            with self.subTest(file_name=file_name):
                self.assertEqual(expected, attempts.split(file_name))

    def test_only_the_last_attempt_counts(self):
        self.assertEqual(("a-attempt-1.json", 2), attempts.split("a-attempt-1-attempt-2.json"))

    def test_an_attempt_needs_a_name_and_a_number(self):
        for file_name in ("-attempt-2.json", "a-attempt-.json", "a-attempt-0.json", "a-attempt-2x.json",
                          "a_attempt-2.json", "a-attempt-2-b.json"):
            with self.subTest(file_name=file_name):
                self.assertEqual((file_name, 0), attempts.split(file_name))


class ChooseTest(unittest.TestCase):
    def test_a_partial_re_run_reads_each_environment_from_its_newest_attempt(self):
        # prod failed in the first attempt and was re-run; test was not.
        self.assertEqual(
            {"keep": [{"name": "matrix-job-meta-prod.json", "file": "matrix-job-meta-prod-attempt-2.json", "attempt": 2,
                       "found": [1, 2]},
                      {"name": "matrix-job-meta-test.json", "file": "matrix-job-meta-test-attempt-1.json", "attempt": 1,
                       "found": [1]}],
             "below": []},
            attempts.choose(["matrix-job-meta-test-attempt-1.json", "matrix-job-meta-prod-attempt-2.json",
                             "matrix-job-meta-prod-attempt-1.json"]))

    def test_the_newest_attempt_wins_whatever_the_order(self):
        names = ["m-attempt-3.json", "m-attempt-10.json", "m-attempt-1.json", "m-attempt-2.json"]
        for ordered in (names, list(reversed(names)), sorted(names)):
            with self.subTest(ordered=ordered):
                self.assertEqual([{"name": "m.json", "file": "m-attempt-10.json", "attempt": 10, "found": [1, 2, 3, 10]}],
                                 attempts.choose(ordered)["keep"])

    def test_a_name_without_an_attempt_is_read_only_when_no_attempt_left_one(self):
        self.assertEqual([{"name": "m.json", "file": "m.json", "attempt": 0, "found": [0]}],
                         attempts.choose(["m.json"])["keep"])
        self.assertEqual([{"name": "m.json", "file": "m-attempt-1.json", "attempt": 1, "found": [0, 1]}],
                         attempts.choose(["m.json", "m-attempt-1.json"])["keep"])

    def test_names_are_kept_apart_and_sorted(self):
        self.assertEqual(["a.json", "b.json", "b.md"],
                         [entry["name"] for entry in attempts.choose(["b-attempt-1.md", "b-attempt-1.json", "a.json"])["keep"]])

    def test_the_minimum_leaves_out_older_attempts(self):
        self.assertEqual(
            {"keep": [{"name": "notify-result-e1.json", "file": "notify-result-e1-attempt-3.json", "attempt": 3,
                       "found": [2, 3]},
                      {"name": "notify-result-e2.json", "file": "notify-result-e2-attempt-2.json", "attempt": 2,
                       "found": [2]}],
             "below": [{"file": "notify-result-e1-attempt-1.json", "attempt": 1},
                       {"file": "notify-result-e3-attempt-1.json", "attempt": 1},
                       {"file": "notify-result-e3.json", "attempt": 0}]},
            attempts.choose(["notify-result-e3.json", "notify-result-e3-attempt-1.json", "notify-result-e2-attempt-2.json",
                             "notify-result-e1-attempt-3.json", "notify-result-e1-attempt-1.json",
                             "notify-result-e1-attempt-2.json"], 2))

    def test_without_a_minimum_nothing_is_left_out(self):
        self.assertEqual([], attempts.choose(["m.json", "n-attempt-1.json"])["below"])
        self.assertEqual([], attempts.choose(["m.json"], 0)["below"])

    def test_nothing_in_nothing_out(self):
        self.assertEqual({"keep": [], "below": []}, attempts.choose([], 1))


if __name__ == "__main__":
    unittest.main()
