"""The bash auto-merge evaluator's behaviour, replayed through the engine (docs/Auto-merge.md §14).

Each case under evaluator_port/ was captured from the bash evaluator's suite: its files, the actor,
the stage results, and the exit code, is-eligible and reasons the bash evaluator gave. The engine
must give the same exit code and is-eligible, and log every reason the case asserted (a text
starting with '!' must be absent).
"""

import contextlib
import io
import json
import os
import tempfile
import unittest

import support
from dsb_tf_engine import automerge_evidence

CASES_DIR = os.path.join(support.TESTS_DIR, "evaluator_port")


def cases():
    found = []
    for name in sorted(os.listdir(CASES_DIR)):
        with open(os.path.join(CASES_DIR, name), encoding="utf-8") as handle:
            found.append((name[:-5], json.load(handle)))
    return found


@contextlib.contextmanager
def inside(directory):
    previous = os.getcwd()
    os.chdir(directory)
    try:
        yield
    finally:
        os.chdir(previous)


def replay(case):
    """(exit code, is-eligible or '', the step's stdout) of one case run through the engine."""
    with tempfile.TemporaryDirectory() as work:
        for name, content in case["files"].items():
            with open(os.path.join(work, name), "w", encoding="utf-8") as handle:
                handle.write(content["text"] if "text" in content else json.dumps(content["json"], indent=2))
        stages = os.path.join(work, "..stage-results")
        with open(stages, "w", encoding="utf-8") as handle:
            handle.write(case["stage_results_json"])
        output = os.path.join(work, "..output")
        open(output, "w").close()
        stream = io.StringIO()
        with inside(work):
            code = automerge_evidence.run(case["metadata_files_pattern"], case["relevance_file"],
                                          case["test_metadata_files_pattern"], stages,
                                          {"GITHUB_ACTOR": case["actor"], "GITHUB_OUTPUT": output}, stream)
        with open(output, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    eligible = lines[1] if lines and lines[0].startswith("is-eligible<<") else ""
    return code, eligible, stream.getvalue()


class PortTest(unittest.TestCase):
    def test_every_case_gives_the_bash_evaluators_verdict(self):
        for name, case in cases():
            with self.subTest(case=name):
                code, eligible, text = replay(case)
                self.assertEqual((case["expected"]["exit"], case["expected"]["is_eligible"]), (code, eligible), text)
                for expected in case["expected"]["texts"]:
                    if expected.startswith("!"):
                        self.assertNotIn(expected[1:], text)
                    else:
                        self.assertIn(expected, text)

    def test_there_are_cases(self):
        self.assertGreaterEqual(len(cases()), 140)


if __name__ == "__main__":
    unittest.main()
