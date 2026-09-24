"""The input document's shape: a malformed document is the shim's fault and says where."""

import unittest

import support
from dsb_tf_engine import decide, model


class ModelTest(unittest.TestCase):
    def assertDocumentError(self, document, fragment):
        with self.assertRaises(model.DocumentError) as raised:
            decide.decide(document)
        self.assertIn(fragment, str(raised.exception))

    def test_a_valid_document_passes(self):
        model.check(support.document())

    def test_not_an_object(self):
        self.assertDocumentError([], "not a JSON object")

    def test_unknown_top_level_keys_are_rejected(self):
        document = support.document()
        document["secrets"] = {"TOKEN": "x"}
        self.assertDocumentError(document, "unknown key(s) ['secrets']")

    def test_missing_top_level_keys_are_named(self):
        document = support.document()
        del document["caller"], document["event"]
        self.assertDocumentError(document, "missing key(s) ['caller', 'event']")

    def test_schema_version_must_match(self):
        document = support.document()
        document["schema_version"] = 2
        self.assertDocumentError(document, "schema_version 2, expected 1")

    def test_caller_and_event_need_their_strings(self):
        for section, value in [("caller", {"repository": "o/r"}), ("caller", "o/r"),
                               ("event", {"name": "push", "ref_name": 1}), ("event", None)]:
            with self.subTest(section=section, value=value):
                document = support.document()
                document[section] = value
                self.assertDocumentError(document, f"'{section}' needs the strings")

    def test_workflow_inputs_must_be_an_object(self):
        document = support.document()
        document["workflow_inputs"] = []
        self.assertDocumentError(document, "'workflow_inputs' is not an object")

    def test_yaml_needs_exactly_inputs_and_environments(self):
        document = support.document()
        document["yaml"]["extra"] = {}
        self.assertDocumentError(document, "'yaml' needs exactly")
        document["yaml"] = []
        self.assertDocumentError(document, "'yaml' needs exactly")

    def test_parse_results_must_be_ok_and_value(self):
        for bad in [{"x-yml": {"ok": True}}, {"x-yml": {"ok": "yes", "value": 1}}, {"x-yml": []}, []]:
            with self.subTest(bad=bad):
                document = support.document()
                document["yaml"]["inputs"] = bad
                self.assertDocumentError(document, "'yaml.inputs' is not a map of parse results")

    def test_environment_parse_results_must_be_a_list_of_maps(self):
        for bad in [{}, [{"x-yml": {"ok": True}}]]:
            with self.subTest(bad=bad):
                document = support.document()
                document["yaml"]["environments"] = bad
                self.assertDocumentError(document, "'yaml.environments' is not a list of maps")

    def test_directories_must_map_to_booleans(self):
        for bad in [[], {"./envs/env-a": "yes"}]:
            with self.subTest(bad=bad):
                document = support.document()
                document["directories_exist"] = bad
                self.assertDocumentError(document, "'directories_exist' is not a map of booleans")


MESSAGE = ("input document: 'changed_files' needs exactly 'available', 'truncated', 'error', 'api_head_sha', 'count' "
           "and 'files', typed as the adapter reports them")
CHANGED = {"available": True, "truncated": False, "error": None, "api_head_sha": "abc", "count": 1, "files": ["a"]}


class RelevanceFactsTest(unittest.TestCase):
    """The optional sections the changed-file fetching adds: absent is fine, present must be whole."""

    assertDocumentError = ModelTest.assertDocumentError

    def test_the_sections_are_optional_and_pass_when_whole(self):
        document = support.document()
        document["event"]["push"] = {"created": True, "forced": False, "deleted": False}
        document["event"]["pull_request"] = {"number": 87, "head_sha": "abc"}
        document["changed_files"] = dict(CHANGED)
        model.check(document)
        model.check(support.document())

    def test_changed_files_needs_every_fact_with_its_type(self):
        for key, bad in (("available", "yes"), ("truncated", None), ("error", 5), ("api_head_sha", 1),
                         ("count", "3"), ("count", True), ("count", -1), ("files", "a"), ("files", [1])):
            with self.subTest(key=key, bad=bad):
                document = support.document()
                document["changed_files"] = {**CHANGED, key: bad}
                self.assertDocumentError(document, MESSAGE)
        for missing in CHANGED:
            with self.subTest(missing=missing):
                document = support.document()
                document["changed_files"] = {k: v for k, v in CHANGED.items() if k != missing}
                self.assertDocumentError(document, MESSAGE)
        document = support.document()
        document["changed_files"] = []
        self.assertDocumentError(document, MESSAGE)

    def test_the_facts_may_be_unknown(self):
        document = support.document()
        document["changed_files"] = {**CHANGED, "error": "HTTP 502", "api_head_sha": None, "count": 0}
        model.check(document)

    def test_the_push_facts_are_booleans(self):
        for bad in ({"created": "true", "forced": False, "deleted": False}, {"created": False, "forced": False},
                    {"created": False, "forced": None, "deleted": False}, []):
            with self.subTest(bad=bad):
                document = support.document()
                document["event"]["push"] = bad
                self.assertDocumentError(document, "'event.push' needs the booleans 'created', 'forced' and 'deleted'")

    def test_the_pull_request_needs_its_number_and_head(self):
        for bad in ({"number": "87", "head_sha": "abc"}, {"number": 87}, {"number": True, "head_sha": "a"},
                    {"number": 87, "head_sha": None}, None):
            with self.subTest(bad=bad):
                document = support.document()
                document["event"]["pull_request"] = bad
                self.assertDocumentError(document, "'event.pull_request' needs")


if __name__ == "__main__":
    unittest.main()
