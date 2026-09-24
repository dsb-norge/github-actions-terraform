"""The fields of an environment: their types, their names, and what must be unique.

The port kept every per-environment value as YAML typed it, so a per-environment `true` for a
boolean input stayed a JSON boolean while the forwarded default was the string "true", and the
workflow's gates, which compare `== 'true'`, silently dropped it. Environment names reached comment
markers, artifact names, concurrency groups and shell with no rule on their characters, and two
environments could share a github-environment and overwrite each other's comments and metadata.
These tests hold the rules that end all three.
"""

import os
import re
import unittest

import support
from dsb_tf_engine import decide

WORKFLOW = os.path.join(os.path.dirname(os.path.dirname(support.TESTS_DIR)),
                        ".github", "workflows", "terraform-ci-cd-default.yml")

BOOLEAN_INPUTS = ("add-pr-comment", "apply-extract-include-outputs", "cache-terraform-modules",
                  "format-check-in-root-dir", "path-relevance-enabled", "pr-auto-merge-enabled", "verify-lock-file")
# Global only: an environment that sets it is an error of its own (test_relevance).
PER_ENVIRONMENT_BOOLEANS = tuple(name for name in BOOLEAN_INPUTS if name != "path-relevance-enabled")

NAME_RULE = "1 to 255 of the characters A-Z a-z 0-9 . _ - starting with a letter or a digit"


def decide_with(environment, inputs=None, environments=None):
    environments = [environment] if environments is None else environments
    directories = {f"./envs/{e['environment']}": True for e in environments
                   if isinstance(e, dict) and isinstance(e.get("environment"), str)}
    document = support.document(environments=environments, inputs=inputs, directories=directories)
    for name in BOOLEAN_INPUTS:
        document["workflow_inputs"].setdefault(name, False)
    return decide.decide(document)


def row(output, index=0):
    return output["matrices"]["1"]["include"][index]["vars"]


class BooleanInputsTest(unittest.TestCase):
    def test_the_engine_knows_every_boolean_input_the_workflow_declares(self):
        from dsb_tf_engine import environments
        with open(WORKFLOW, encoding="utf-8") as handle:
            text = handle.read()
        declared = set(re.findall(r"^      ([a-z0-9-]+):\n(?:        [^\n]*\n)*?        type: boolean$", text, re.M))
        self.assertEqual(set(BOOLEAN_INPUTS), declared)
        self.assertEqual(set(BOOLEAN_INPUTS), set(environments.BOOLEAN_INPUTS))

    def test_a_per_environment_boolean_takes_the_forwarded_type(self):
        for field in PER_ENVIRONMENT_BOOLEANS:
            for value, expected in ((True, "true"), (False, "false"), ("true", "true"), ("false", "false")):
                with self.subTest(field=field, value=value):
                    output = decide_with({"environment": "env-a", field: value})
                    self.assertEqual([], output["errors"])
                    self.assertEqual(expected, row(output)[field])

    def test_a_forwarded_boolean_is_the_string_the_gates_compare(self):
        for value, expected in ((True, "true"), (False, "false")):
            with self.subTest(value=value):
                output = decide_with({"environment": "env-a"}, inputs={"verify-lock-file": value})
                self.assertEqual(expected, row(output)["verify-lock-file"])

    def test_anything_else_for_a_boolean_is_an_error_naming_environment_field_and_value(self):
        for value, shown in (("yes", "'yes'"), ("True", "'True'"), ("", "''"), (1, "1"), (None, "null"),
                             ([], "[]"), ({"a": 1}, '{"a": 1}')):
            with self.subTest(value=value):
                output = decide_with({"environment": "env-a", "verify-lock-file": value})
                self.assertEqual([f"The environment 'env-a' sets 'verify-lock-file' to {shown}; it must be true or false!"],
                                 output["errors"])
                self.assertEqual({}, output["matrices"])


class AllowFailingTest(unittest.TestCase):
    FLAG = "allow-failing-terraform-operations"

    def test_true_and_false_as_booleans_or_strings(self):
        for value, expected in ((True, True), ("true", True), (False, False), ("false", False)):
            with self.subTest(value=value):
                output = decide_with({"environment": "env-a", self.FLAG: value})
                self.assertEqual([], output["errors"])
                self.assertIs(expected, row(output)[self.FLAG])

    def test_absent_is_false(self):
        self.assertIs(False, row(decide_with({"environment": "env-a"}))[self.FLAG])

    def test_anything_else_is_an_error_not_a_silent_false(self):
        for value, shown in (("yes", "'yes'"), ("True", "'True'"), (None, "null"), (1, "1"), ("", "''")):
            with self.subTest(value=value):
                output = decide_with({"environment": "env-a", self.FLAG: value})
                self.assertEqual([f"The environment 'env-a' sets '{self.FLAG}' to {shown}; it must be true or false!"],
                                 output["errors"])


class StringInputsTest(unittest.TestCase):
    def test_a_per_environment_string_is_kept_verbatim(self):
        for field, value in (("terraform-version", "1.10.0"), ("tflint-version", "v0.55.0"), ("pr-comment-group", "grp"),
                             ("terraform-version", "latest\n")):
            with self.subTest(field=field, value=value):
                output = decide_with({"environment": "env-a", field: value})
                self.assertEqual([], output["errors"])
                self.assertEqual(value, row(output)[field])

    def test_a_non_string_for_a_string_input_is_an_error_asking_to_quote_it(self):
        for value, shown in ((1.1, "1.1"), (1, "1"), (True, "true"), (None, "null"), (["a"], '["a"]'), (["ø"], '["ø"]')):
            with self.subTest(value=value):
                output = decide_with({"environment": "env-a", "terraform-version": value})
                self.assertEqual([f"The environment 'env-a' sets 'terraform-version' to {shown}, which is not a string; "
                                  "quote it!"], output["errors"])

    def test_keys_that_are_not_inputs_keep_their_yaml_types(self):
        output = decide_with({"environment": "env-a", "runs-on": ["self-hosted", "x"], "my-key": {"a": 1}})
        self.assertEqual([], output["errors"])
        self.assertEqual((["self-hosted", "x"], {"a": 1}), (row(output)["runs-on"], row(output)["my-key"]))


class NamesTest(unittest.TestCase):
    def test_valid_environment_names(self):
        for name in ("env-a", "A", "0", "a.b_c-1", "tenant.example.com", "x" * 255):
            with self.subTest(name=name):
                self.assertEqual([], decide_with({"environment": name})["errors"])

    def test_invalid_environment_names_are_errors(self):
        for name, shown in (("has space", "'has space'"), ("a:b", "'a:b'"), ("a/b", "'a/b'"), ("-lead", "'-lead'"),
                            (".lead", "'.lead'"), ("", "''"), ("a\nb", "'a\\nb'"), ("ø", "'ø'"), ("a-->", "'a-->'"),
                            ("x" * 256, repr("x" * 256)), (123, "123"), (None, "null"), (["a"], '["a"]')):
            with self.subTest(name=name):
                output = decide_with({"environment": name, "project-dir": "."}, environments=None)
                self.assertEqual([f"The environment name {shown} must be {NAME_RULE}!"], output["errors"])

    def test_an_explicit_github_environment_follows_the_same_rule(self):
        output = decide_with({"environment": "env-a", "github-environment": "Prod env"})
        self.assertEqual([f"The github-environment 'Prod env' of environment 'env-a' must be {NAME_RULE}!"],
                         output["errors"])
        self.assertEqual([], decide_with({"environment": "env-a", "github-environment": "prod.env-1"})["errors"])

    def test_a_non_string_github_environment_is_an_error(self):
        output = decide_with({"environment": "env-a", "github-environment": 7})
        self.assertEqual([f"The github-environment 7 of environment 'env-a' must be {NAME_RULE}!"], output["errors"])


class UniqueGithubEnvironmentTest(unittest.TestCase):
    def test_two_environments_may_not_share_a_github_environment(self):
        output = decide_with(None, environments=[{"environment": "env-a", "github-environment": "shared"},
                                                 {"environment": "env-b", "github-environment": "shared"}])
        self.assertEqual(["The environments 'env-a' and 'env-b' share the github-environment 'shared'; it names their "
                          "comments, metadata and concurrency group, so each needs its own!"], output["errors"])

    def test_the_comparison_ignores_case_as_github_does(self):
        output = decide_with(None, environments=[{"environment": "Prod"}, {"environment": "prod"}])
        self.assertEqual(["The environments 'Prod' and 'prod' share the github-environment 'prod'; it names their "
                          "comments, metadata and concurrency group, so each needs its own!"], output["errors"])

    def test_a_github_environment_equal_to_another_environments_default(self):
        output = decide_with(None, environments=[{"environment": "env-a"},
                                                 {"environment": "env-b", "github-environment": "env-a"}])
        self.assertEqual(["The environments 'env-a' and 'env-b' share the github-environment 'env-a'; it names their "
                          "comments, metadata and concurrency group, so each needs its own!"], output["errors"])

    def test_distinct_github_environments_pass(self):
        output = decide_with(None, environments=[{"environment": "env-a"}, {"environment": "env-b"},
                                                 {"environment": "env-c", "github-environment": "other"}])
        self.assertEqual([], output["errors"])


if __name__ == "__main__":
    unittest.main()
