"""The fields of an environment: the types of the values it sets for workflow inputs.

The port kept every per-environment value as YAML typed it, so a per-environment `true` for a
boolean input stayed a JSON boolean while the forwarded default was the string "true", and the
workflow's gates, which compare `== 'true'`, silently dropped it. These tests hold the rule that
ends it.
"""

import os
import re
import unittest

import support
from dsb_tf_engine import decide

WORKFLOW = os.path.join(os.path.dirname(os.path.dirname(support.TESTS_DIR)),
                        ".github", "workflows", "terraform-ci-cd-default.yml")

BOOLEAN_INPUTS = ("add-pr-comment", "apply-extract-include-outputs", "cache-terraform-modules",
                  "format-check-in-root-dir", "pr-auto-merge-enabled", "verify-lock-file")

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
        for field in BOOLEAN_INPUTS:
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


if __name__ == "__main__":
    unittest.main()
