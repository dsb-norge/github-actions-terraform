"""Configuration validation: the keys of an environments-yml entry (docs/Configuration-validation.md §3.1).

Every message is compared as a literal, and every known key is listed here rather than read from
the module, so a key added or dropped there fails here too.
"""

import os
import re
import unittest

import invariants
import support
from dsb_tf_engine import decide, environments

WORKFLOW = os.path.join(os.path.dirname(os.path.dirname(support.TESTS_DIR)),
                        ".github", "workflows", "terraform-ci-cd-default.yml")
DOC = "The settings an environment may hold are listed in docs/Configuration-validation.md §3.1."
PER_ENVIRONMENT = {"add-pr-comment", "apply-extract-include-outputs", "cache-terraform-modules",
                   "format-check-in-root-dir", "pr-auto-merge-enabled", "pr-comment-group", "runs-on",
                   "terraform-version", "tflint-version", "verify-lock-file"}
YAML_SETTINGS = {"goals-yml", "terraform-init-additional-dirs-yml", "extra-envs-yml", "extra-envs-from-secrets-yml",
                 "extra-envs-per-goal-yml", "extra-envs-from-secrets-per-goal-yml", "pr-auto-merge-from-actors-yml",
                 "pr-auto-merge-limits-yml"}
WORKFLOW_ONLY = {"environments-yml", "trigger-events-yml", "path-relevance-enabled", "allow-failing-terraform-tests",
                 "terraform-test-enabled", "terraform-test-exclude-paths-yml", "terraform-test-lanes-yml",
                 "terraform-test-runs-on", "terraform-test-timeout-minutes", "pr-auto-merge-app-id",
                 "pr-auto-merge-app-private-key-secret"}


def errors(*entries):
    document = support.document(environments=list(entries))
    output = decide.decide(document)
    assert invariants.check(document, output) == [], invariants.check(document, output)
    return output["errors"]


class InputClassificationTest(unittest.TestCase):
    def test_every_declared_input_is_per_environment_or_workflow_only(self):
        with open(WORKFLOW, encoding="utf-8") as handle:
            text = handle.read()
        inputs = text[text.index("    inputs:\n"):text.index("\n    secrets:") if "\n    secrets:" in text else None]
        declared = set(re.findall(r"^      ([a-z0-9-]+):\n        type:", inputs, re.M))
        self.assertGreater(len(declared), 25, "the scan found too few inputs to be trusted")
        self.assertEqual(set(), PER_ENVIRONMENT & WORKFLOW_ONLY)
        self.assertEqual(declared, PER_ENVIRONMENT | YAML_SETTINGS | WORKFLOW_ONLY)
        self.assertEqual(PER_ENVIRONMENT, set(environments.PER_ENVIRONMENT_INPUTS))
        self.assertEqual(WORKFLOW_ONLY, set(environments.WORKFLOW_ONLY_INPUTS))
        self.assertEqual(YAML_SETTINGS, set(environments.REPLACE_FIELDS + environments.MERGE_FIELDS))


class EntryKeysTest(unittest.TestCase):
    def test_every_known_key_is_accepted(self):
        values = {"project-dir": "./envs/prod", "github-environment": "prod-gh", "url": "https://x", "paths": ["**"],
                  "paths-ignore": [], "trigger-events": ["push"], "allow-failing-terraform-operations": True,
                  "add-pr-comment": True, "apply-extract-include-outputs": False, "cache-terraform-modules": True,
                  "format-check-in-root-dir": False, "pr-auto-merge-enabled": False, "pr-comment-group": "g",
                  "runs-on": "ubuntu-latest", "terraform-version": "1.16", "tflint-version": "latest",
                  "verify-lock-file": True}
        for key, value in values.items():
            with self.subTest(key=key):
                self.assertEqual([], errors({"environment": "prod", key: value}))

    def test_an_unsuffixed_yaml_setting_names_its_spelling(self):
        for key in ("goals", "extra-envs", "extra-envs-from-secrets", "extra-envs-per-goal",
                    "extra-envs-from-secrets-per-goal", "pr-auto-merge-from-actors", "pr-auto-merge-limits",
                    "terraform-init-additional-dirs"):
            with self.subTest(key=key):
                self.assertEqual([f"The environment 'prod' sets '{key}', which is not a setting: per environment it "
                                  f"is '{key}-yml'. Written like this it would have been ignored, and the environment "
                                  "would have run with the global value."], errors({"environment": "prod", key: []}))

    def test_a_suffixed_plain_setting_names_its_spelling(self):
        for key in ("paths", "paths-ignore", "trigger-events"):
            with self.subTest(key=key):
                self.assertEqual([f"The environment 'prod' sets '{key}-yml', which is not a setting: per environment "
                                  f"it is '{key}', a list written directly in the entry."],
                                 errors({"environment": "prod", f"{key}-yml": ["x"]}))

    def test_a_workflow_only_input_is_refused(self):
        # path-relevance-enabled keeps its own advice; trigger-events-yml gets the suffixed-setting message.
        for key in sorted(WORKFLOW_ONLY - {"path-relevance-enabled", "trigger-events-yml"}):
            with self.subTest(key=key):
                self.assertEqual([f"The environment 'prod' sets '{key}', which is a workflow input only: it applies to "
                                  "every environment at once. Set it in the calling workflow's 'with:'."],
                                 errors({"environment": "prod", key: "x"}))

    def test_path_relevance_enabled_keeps_its_own_advice(self):
        self.assertEqual(["The environment 'prod' sets 'path-relevance-enabled', which is a workflow input only; to run "
                          "it on every change, set its 'paths' to ['**']!"],
                         errors({"environment": "prod", "path-relevance-enabled": False}))

    def test_a_value_the_engine_sets_is_refused(self):
        for key in ("goals-granted", "caller-repo-default-branch", "caller-repo-calling-branch",
                    "caller-repo-is-on-default-branch"):
            with self.subTest(key=key):
                self.assertEqual([f"The environment 'prod' sets '{key}', which the workflow works out itself; remove it."],
                                 errors({"environment": "prod", key: "x"}))

    def test_a_near_miss_is_suggested(self):
        cases = [("github_environment", "github-environment"),   # distance 1
                 ("githubenvironment", "github-environment"),    # distance 1
                 ("Project-Dir", "project-dir"),                 # case only
                 ("goals-ymll", "goals-yml"),                    # distance 1
                 ("add-pr-coment", "add-pr-comment"),            # distance 1
                 ("url-s", "url")]                               # distance 2
        for written, meant in cases:
            with self.subTest(written=written):
                self.assertEqual([f"The environment 'prod' sets '{written}', which is not a setting; did you mean "
                                  f"'{meant}'? {DOC}"], errors({"environment": "prod", written: "x"}))

    def test_no_suggestion_when_nothing_is_near_or_two_are(self):
        for written in ("description", "zzzzzz", "paths-xyz"):
            with self.subTest(written=written):
                self.assertEqual([f"The environment 'prod' sets '{written}', which is not a setting. {DOC}"],
                                 errors({"environment": "prod", written: "x"}))

    def test_a_key_that_is_not_text(self):
        self.assertEqual([f"The environment 'prod' sets 7, which is not a setting. {DOC}"],
                         errors({"environment": "prod", 7: "x"}))

    def test_every_problem_of_every_environment_is_reported_in_key_order(self):
        self.assertEqual([f"The environment 'a' sets 'zeta', which is not a setting. {DOC}",
                          "The environment 'b' sets 'goals', which is not a setting: per environment it is 'goals-yml'. "
                          "Written like this it would have been ignored, and the environment would have run with the "
                          "global value.",
                          f"The environment 'b' sets 'other', which is not a setting. {DOC}"],
                         errors({"environment": "a", "zeta": 1}, {"environment": "b", "other": 1, "goals": ["plan"]}))

    def test_an_entry_without_a_valid_name_is_left_to_the_name_rule(self):
        self.assertEqual(["The environment name 'a b' must be 1 to 255 of the characters A-Z a-z 0-9 . _ - starting "
                          "with a letter or a digit!"], errors({"environment": "a b", "zeta": 1}))


class NearMissTest(unittest.TestCase):
    def test_near_miss(self):
        known = ("apply", "plan", "planx")
        self.assertEqual("apply", environments.near_miss("aply", known))
        self.assertEqual("apply", environments.near_miss("APPLY", known))
        self.assertIsNone(environments.near_miss("xyzzyq", known))
        self.assertIsNone(environments.near_miss("plany", known))   # one edit from both plan and planx
        self.assertEqual("plan", environments.near_miss("pl", ("plan",)))   # two edits
        self.assertIsNone(environments.near_miss("p", ("plan",)))   # three edits

    def test_the_distance_is_levenshtein_s(self):
        cases = {("", ""): 0, ("", "ab"): 2, ("abc", ""): 3, ("kitten", "sitting"): 3, ("flaw", "lawn"): 2,
                 ("goals", "goals"): 0}
        self.assertEqual(cases, {pair: environments._distance(*pair) for pair in cases})


if __name__ == "__main__":
    unittest.main()
