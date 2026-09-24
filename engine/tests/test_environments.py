"""Environment rows: behaviour the port cases do not reach on their own."""

import unittest

import support
from dsb_tf_engine import decide, environments, model, record


def vars_of(output, index=0):
    return output["matrices"]["1"]["include"][index]["vars"]


class EnvironmentsTest(unittest.TestCase):
    def test_a_per_environment_yml_field_the_shim_did_not_parse_is_a_document_error(self):
        document = support.document(environments=[{"environment": "env-a", "goals-yml": ["plan"]}])
        with self.assertRaises(model.DocumentError) as raised:
            decide.decide(document)
        self.assertIn("'yaml.environments[0]' lacks 'goals-yml'", str(raised.exception))

    def test_parse_results_shorter_than_the_environments_are_a_document_error(self):
        document = support.document(environments=[{"environment": "env-a", "goals-yml": ["plan"]}], env_yaml=[])
        with self.assertRaises(model.DocumentError):
            decide.decide(document)

    def test_an_absent_yml_input_parses_as_null(self):
        output = decide.decide(support.document())
        self.assertEqual([], output["errors"])
        self.assertEqual([], vars_of(output)["goals"])
        self.assertIsNone(vars_of(output)["extra-envs"])

    def test_a_row_carries_the_run_verdict_and_the_record(self):
        output = decide.decide(support.document(environments=[{"environment": "env-a"}, {"environment": "env-7"}],
                                                directories={"./envs/env-a": True, "./envs/env-7": True}))
        self.assertEqual([{"environment": "env-a", "verdict": "run", "reasons": ["port"]},
                          {"environment": "env-7", "verdict": "run", "reasons": ["port"]}], output["environments"])
        self.assertEqual(["env-a: run — port", "env-7: run — port"], output["record"])
        self.assertEqual({"affected": 2, "unaffected": 0}, output["counts"])

    def test_the_record_joins_every_reason_in_order(self):
        self.assertEqual(["prod: skip — relevance: none; ordering: stage 2", "7: run — port"],
                         record.lines([{"environment": "prod", "verdict": "skip", "reasons": ["relevance: none", "ordering: stage 2"]},
                                       {"environment": 7, "verdict": "run", "reasons": ["port"]}]))

    def test_errors_leave_no_matrix(self):
        output = decide.decide(support.document(environments=[]))
        self.assertEqual(["The specification is an empty array!"], output["errors"])
        self.assertEqual({}, output["matrices"])
        self.assertEqual([], output["environments"])

    def test_the_output_document_has_exactly_its_keys(self):
        for document in (support.document(), support.document(environments=[])):
            with self.subTest(errors=not document["yaml"]["inputs"]["environments-yml"]["value"]):
                output = decide.decide(document)
                self.assertEqual({"schema_version", "errors", "notices", "environments", "matrices", "counts", "record"},
                                 set(output))
                self.assertEqual(1, output["schema_version"])
                self.assertEqual([], output["notices"])

    def test_a_configuration_error_reads_as_its_messages_joined(self):
        self.assertEqual("first; second", str(environments.ConfigError(["first", "second"])))

    def test_a_duplicated_name_is_an_error(self):
        document = support.document(environments=[{"environment": "env-a"}, {"environment": "env-a", "url": "x"}])
        self.assertEqual(["Duplicate environment 'env-a' in environments-yml specification!"],
                         decide.decide(document)["errors"])


if __name__ == "__main__":
    unittest.main()
