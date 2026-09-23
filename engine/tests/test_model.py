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


if __name__ == "__main__":
    unittest.main()
