"""The port: every case decides what the bash builder decided, or its recorded deviation.

The cases hold the bash builder's own output for the fixtures it was tested with, the
workflow's full default inputs, anonymised shapes of the real callers, and every edge its
code had. docs/Decision-engine.md §9.
"""

import json
import os
import unittest

import invariants
import support
from dsb_tf_engine import decide


def update_goldens():
    """UPDATE_PORT_GOLDENS=1 rewrites expected.json from the engine, for a change that alters rows
    on purpose. Review the diff: every changed golden is a changed matrix for some caller. A case
    recording a deviation keeps its engine_expected, which is edited by hand."""
    for name, document, _ in support.port_cases():
        case_dir = os.path.join(support.PORT_CASES_DIR, name)
        with open(os.path.join(case_dir, "case.json"), encoding="utf-8") as handle:
            if "engine_expected" in json.load(handle):
                continue
        output = decide.decide(document)
        golden = ({"exit_code": 0, "matrix": output["matrices"]["1"]} if not output["errors"]
                  else {"exit_code": 1, "errors": output["errors"]})
        with open(os.path.join(case_dir, "expected.json"), "w", encoding="utf-8") as handle:
            json.dump(golden, handle, indent=2, sort_keys=True)
            handle.write("\n")


class PortTest(unittest.TestCase):
    def test_every_case_matches_its_golden(self):
        if os.environ.get("UPDATE_PORT_GOLDENS") == "1":
            update_goldens()
        cases = support.port_cases()
        self.assertGreater(len(cases), 50)
        for name, document, expected in cases:
            with self.subTest(case=name):
                original = json.loads(json.dumps(document))
                output = decide.decide(document)
                self.assertEqual(original, document, "decide modified its input document")
                self.assertEqual([], invariants.check(document, output))
                if expected["exit_code"] == 0:
                    self.assertEqual([], output["errors"])
                    self.assertEqual(expected["matrix"], output["matrices"]["1"])
                    # A port case is a dispatch: every environment runs, as it did before relevance.
                    self.assertEqual(["relevance: all:event"] * len(output["environments"]),
                                     [reason for e in output["environments"] for reason in e["reasons"]])
                else:
                    self.assertEqual(expected["errors"], output["errors"])

    def test_deviations_are_recorded_with_a_reason(self):
        for name, _, expected in support.port_cases():
            if expected.get("exit_code") == 2:
                with self.subTest(case=name):
                    self.assertTrue(expected.get("deviation"), "an engine_expected needs a 'deviation' reason")


if __name__ == "__main__":
    unittest.main()
