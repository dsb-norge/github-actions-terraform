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
        self.assertEqual([("env-a", "run", ["relevance: all:not-computed"]), ("env-7", "run", ["relevance: all:not-computed"])],
                         [(e["environment"], e["verdict"], e["reasons"]) for e in output["environments"]])
        self.assertEqual(["env-a: run — relevance: all:not-computed", "env-7: run — relevance: all:not-computed"],
                         output["record"])
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
        keys = {"schema_version", "errors", "notices", "environments", "matrices", "counts", "record"}
        output = decide.decide(support.document())
        self.assertEqual(keys | {"relevance", "comments"}, set(output))
        self.assertEqual(1, output["schema_version"])
        self.assertEqual(["relevance all (not-computed): 1 of 1 environment affected"], output["notices"])
        output = decide.decide(support.document(environments=[]))
        self.assertEqual(keys, set(output))
        self.assertEqual((1, [], [], {}, {"affected": 0, "unaffected": 0}, []),
                         (output["schema_version"], output["notices"], output["environments"], output["matrices"],
                          output["counts"], output["record"]))

    def test_a_configuration_error_reads_as_its_messages_joined(self):
        self.assertEqual("first; second", str(environments.ConfigError(["first", "second"])))

    def test_a_duplicated_name_is_an_error(self):
        document = support.document(environments=[{"environment": "env-a"}, {"environment": "env-a", "url": "x"}])
        self.assertEqual(["Duplicate environment 'env-a' in environments-yml specification!"],
                         decide.decide(document)["errors"])


if __name__ == "__main__":
    unittest.main()
