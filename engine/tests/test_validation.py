"""Validation of the rows, field by field: every check fires on its own, and nothing else fires.

The port cases exercise validation on whole documents, where most fields can never go missing
because the engine fills them itself. These tests take a valid decision's rows apart one field at
a time, so that dropping a field from REQUIRED_FIELDS or NOT_EMPTY_FIELDS, or loosening a check,
fails a test instead of passing silently.
"""

import os
import re
import unittest

import support
from dsb_tf_engine import decide, environments

WORKFLOW = os.path.join(os.path.dirname(os.path.dirname(support.TESTS_DIR)),
                        ".github", "workflows", "terraform-ci-cd-default.yml")

# Keys the workflow reads from a row that the required-field list does not name. A recorded
# finding (docs/Decision-engine.md §9): the port keeps the list as the bash builder had it.
READ_BUT_NOT_REQUIRED = {"runs-on", "format-check-in-root-dir"}

# Workflow inputs that reach a row only by generic forwarding, so they go missing when the
# input does. Every other required field is filled by the engine itself.
FORWARDED = ("add-pr-comment", "apply-extract-include-outputs", "cache-terraform-modules",
             "pr-auto-merge-enabled", "pr-comment-group", "terraform-version", "tflint-version",
             "verify-lock-file")


def valid_rows(count=1):
    names = [f"env-{index}" for index in range(count)]
    document = support.document(environments=[{"environment": name} for name in names])
    output = decide.decide(document)
    assert output["errors"] == [], output["errors"]
    return document, [entry["vars"] for entry in output["matrices"]["1"]["include"]]


def errors_of(document, rows):
    try:
        environments.validate_rows(document, rows)
    except environments.ConfigError as error:
        return error.messages
    return []


class RequiredFieldsTest(unittest.TestCase):
    def test_a_valid_row_passes(self):
        self.assertEqual([], errors_of(*valid_rows()))

    def test_each_required_field_is_enforced_on_its_own(self):
        for field in environments.REQUIRED_FIELDS:
            with self.subTest(field=field):
                document, rows = valid_rows()
                del rows[0][field]
                self.assertEqual([f"Missing property '{field}' in environment specification!"],
                                 errors_of(document, rows))

    def test_each_not_empty_field_is_enforced_on_its_own(self):
        for field in environments.NOT_EMPTY_FIELDS:
            with self.subTest(field=field):
                document, rows = valid_rows()
                rows[0][field] = ""
                # An empty project-dir also names a directory that does not exist; the not-empty
                # group stops validation before the directory check runs.
                self.assertEqual([f"Property '{field}' is empty in environment specification!"],
                                 errors_of(document, rows))

    def test_empty_means_only_the_empty_string_and_trailing_newlines(self):
        for value, empty in [("", True), ("\n\n", True), (" ", False), ("0", False), ("false", False),
                             (None, False), ([], False), ({}, False), (0, False), (False, False)]:
            with self.subTest(value=value):
                document, rows = valid_rows()
                rows[0]["terraform-version"] = value
                messages = errors_of(document, rows)
                self.assertEqual(empty, messages == ["Property 'terraform-version' is empty in environment specification!"])
                if not empty:
                    self.assertEqual([], messages)

    def test_required_fields_outside_the_not_empty_list_may_be_empty(self):
        allowed_empty = set(environments.REQUIRED_FIELDS) - set(environments.NOT_EMPTY_FIELDS)
        self.assertEqual({"extra-envs-from-secrets-per-goal", "extra-envs-per-goal", "pr-comment-group",
                          "terraform-init-additional-dirs", "url"}, allowed_empty)
        for field in sorted(allowed_empty):
            with self.subTest(field=field):
                document, rows = valid_rows()
                rows[0][field] = ""
                self.assertEqual([], errors_of(document, rows))

    def test_the_not_empty_list_is_a_subset_of_the_required_list(self):
        self.assertLessEqual(set(environments.NOT_EMPTY_FIELDS), set(environments.REQUIRED_FIELDS))

    def test_every_failure_of_every_row_is_reported_in_row_then_list_order(self):
        document, rows = valid_rows(2)
        del rows[0]["url"], rows[0]["goals"]
        rows[1]["tflint-version"] = ""
        del rows[1]["environment"]
        self.assertEqual([
            "Missing property 'goals' in environment specification!",
            "Missing property 'url' in environment specification!",
            "Missing property 'environment' in environment specification!",
            "Property 'tflint-version' is empty in environment specification!",
        ], errors_of(document, rows))

    def test_a_missing_field_stops_validation_before_the_directory_check(self):
        document, rows = valid_rows()
        del rows[0]["url"]
        document["directories_exist"] = {}
        self.assertEqual(["Missing property 'url' in environment specification!"], errors_of(document, rows))

    def test_a_forwarded_input_that_is_not_delivered_is_reported_end_to_end(self):
        for field in FORWARDED:
            with self.subTest(field=field):
                document = support.document()
                del document["workflow_inputs"][field]
                self.assertEqual([f"Missing property '{field}' in environment specification!"],
                                 decide.decide(document)["errors"])

    def test_a_forwarded_input_delivered_empty_is_reported_end_to_end_when_it_must_not_be(self):
        for field in FORWARDED:
            with self.subTest(field=field):
                document = support.document(inputs={field: ""})
                expected = ([f"Property '{field}' is empty in environment specification!"]
                            if field in environments.NOT_EMPTY_FIELDS else [])
                self.assertEqual(expected, decide.decide(document)["errors"])


class DirectoryCheckTest(unittest.TestCase):
    def test_a_directory_the_shim_did_not_report_does_not_exist(self):
        document, rows = valid_rows()
        document["directories_exist"] = {}
        self.assertEqual(["The directory './envs/env-0' does not exist, make sure 'project-dir' points to an existing directory!"],
                         errors_of(document, rows))

    def test_a_directory_reported_missing_does_not_exist(self):
        document, rows = valid_rows()
        document["directories_exist"] = {"./envs/env-0": False}
        self.assertEqual(1, len(errors_of(document, rows)))

    def test_every_missing_directory_is_reported(self):
        document, rows = valid_rows(3)
        document["directories_exist"] = {"./envs/env-1": True}
        self.assertEqual(["./envs/env-0", "./envs/env-2"],
                         [re.search(r"'([^']+)'", message).group(1) for message in errors_of(document, rows)])

    def test_the_path_checked_is_the_rendered_project_dir(self):
        for value, path in [(None, "null"), (5, "5"), ("dir\n", "dir"), ("./x", "./x")]:
            with self.subTest(value=value):
                document, rows = valid_rows()
                rows[0]["project-dir"] = value
                document["directories_exist"] = {path: True}
                self.assertEqual([], errors_of(document, rows))


class WorkflowContractTest(unittest.TestCase):
    """Every row variable the workflow reads is guaranteed by the validation, or knowingly not."""

    def read_keys(self):
        with open(WORKFLOW, encoding="utf-8") as handle:
            text = handle.read()
        dotted = re.findall(r"matrix\.vars\.([A-Za-z0-9_-]+)", text)
        indexed = re.findall(r"""\.vars\[["']([A-Za-z0-9_-]+)["']\]""", text)
        return set(dotted) | set(indexed)

    def test_the_workflow_reads_only_required_or_known_unlisted_keys(self):
        keys = self.read_keys()
        self.assertGreater(len(keys), 15, "the workflow scan found too little to be trusted")
        self.assertEqual(set(), keys - set(environments.REQUIRED_FIELDS) - READ_BUT_NOT_REQUIRED)

    def test_the_known_unlisted_keys_are_still_read_and_still_unlisted(self):
        # When the gap is closed, this list must shrink with it.
        self.assertEqual(set(), READ_BUT_NOT_REQUIRED & set(environments.REQUIRED_FIELDS))
        self.assertLessEqual(READ_BUT_NOT_REQUIRED, self.read_keys())


if __name__ == "__main__":
    unittest.main()
