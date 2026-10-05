"""The evaluate-automerge step's adapter: what it reads, and how it publishes (docs/Auto-merge.md §14)."""

import io
import json
import os
import tempfile
import unittest

from dsb_tf_engine import automerge_evidence, automerge_project
from test_evaluator_port import inside


class ReadTest(unittest.TestCase):
    def test_a_file_is_read_or_is_a_fact(self):
        with tempfile.TemporaryDirectory() as work:
            good, broken, binary = (os.path.join(work, name) for name in ("good.json", "broken.json", "binary.json"))
            with open(good, "w", encoding="utf-8") as handle:
                handle.write('{"a": 1}')
            with open(broken, "w", encoding="utf-8") as handle:
                handle.write("{")
            with open(binary, "wb") as handle:
                handle.write(b"\xff\xfe")
            self.assertEqual({"file": good, "readable": True, "json": True, "content": {"a": 1}},
                             automerge_evidence.read_file(good))
            self.assertEqual({"file": broken, "readable": True, "json": False, "content": None},
                             automerge_evidence.read_file(broken))
            self.assertEqual({"file": binary, "readable": False, "json": False, "content": None},
                             automerge_evidence.read_file(binary))
            self.assertEqual({"file": work, "readable": False, "json": False, "content": None},
                             automerge_evidence.read_file(work))

    def test_a_pattern_matches_files_only_sorted(self):
        with tempfile.TemporaryDirectory() as work, inside(work):
            for name in ("m-b.json", "m-a.json", "other.json"):
                open(name, "w").close()
            os.mkdir("m-dir.json")
            self.assertEqual(["m-a.json", "m-b.json"], automerge_evidence.matches("m-*.json"))
            self.assertEqual([], automerge_evidence.matches(""))

    def test_the_facts(self):
        with tempfile.TemporaryDirectory() as work, inside(work):
            with open("matrix-job-meta-a.json", "w", encoding="utf-8") as handle:
                json.dump({"metadata": {"environment": "a"}}, handle)
            facts = automerge_evidence.gather("matrix-job-meta-*.json", "relevance.json", "", "{}", "octocat")
            self.assertEqual({"actor": "octocat", "metadata_pattern": "matrix-job-meta-*.json", "tests_pattern": "",
                              "metadata": [{"file": "matrix-job-meta-a.json", "readable": True, "json": True,
                                            "content": {"metadata": {"environment": "a"}}}],
                              "tests": [], "stage_results": "{}",
                              "relevance": {"file": "relevance.json", "readable": False, "json": False, "content": None,
                                            "exists": False}}, facts)
            self.assertIsNone(automerge_evidence.gather("x", "", "", "", "")["relevance"])


class LogTest(unittest.TestCase):
    def test_lines_and_groups(self):
        log = automerge_project.Log()
        log.line("one")
        log.warn("two")
        with log.group("G"):
            log.line("in")
            log.warn("careful")
        log.line("after")
        stream = io.StringIO()
        automerge_evidence.write_log(automerge_evidence.workflow.Log(stream, "T"), log.entries)
        lines = [line for line in stream.getvalue().splitlines() if not line.startswith("::stop-commands::")
                 and not (line.startswith("::") and line.endswith("::") and len(line) == 36)]
        self.assertEqual(["one", "WARN: two", "::group::T: G", "in", "WARN: careful", "::endgroup::", "after"], lines)

    def test_a_log_ending_in_a_group(self):
        log = automerge_project.Log()
        with log.group("G"):
            log.line("in")
        stream = io.StringIO()
        automerge_evidence.write_log(automerge_evidence.workflow.Log(stream, "T"), log.entries)
        self.assertTrue(stream.getvalue().startswith("::group::T: G\n"))
        self.assertTrue(stream.getvalue().endswith("::endgroup::\n"))


class RunTest(unittest.TestCase):
    def run_step(self, files, stage_results="", actor="dependabot[bot]", stages_file=True):
        with tempfile.TemporaryDirectory() as work, inside(work):
            for name, content in files.items():
                with open(name, "w", encoding="utf-8") as handle:
                    json.dump(content, handle)
            stages = os.path.join(work, "stages")
            if stages_file:
                with open(stages, "w", encoding="utf-8") as handle:
                    handle.write(stage_results)
            output = os.path.join(work, "output")
            open(output, "w").close()
            stream = io.StringIO()
            code = automerge_evidence.run("matrix-job-meta-*.json", "", "terraform-test-meta-*.json", stages,
                                          {"GITHUB_ACTOR": actor, "GITHUB_OUTPUT": output}, stream)
            with open(output, encoding="utf-8") as handle:
                return code, handle.read(), stream.getvalue()

    def test_a_missing_stage_results_file_is_a_fault(self):
        code, output, text = self.run_step({}, stages_file=False)
        self.assertEqual((1, ""), (code, output))
        self.assertIn("::error title=evaluate-automerge-eligibility::the stage results cannot be read: ", text)

    def test_no_metadata_publishes_false(self):
        code, output, _ = self.run_step({})
        self.assertEqual(0, code)
        self.assertEqual(["false"], output.splitlines()[1:2])
        self.assertTrue(output.startswith("is-eligible<<EOF_"))

    def test_a_limits_mapping_that_cannot_be_judged_fails_the_step(self):
        meta = {"metadata": {"environment": "prod"},
                "matrix_context": {"vars": {"pr-auto-merge-enabled": "true", "pr-auto-merge-limits": {}}}}
        code, output, text = self.run_step({"matrix-job-meta-prod.json": meta})
        self.assertEqual((1, ""), (code, output))
        self.assertIn("::error title=evaluate-automerge-eligibility::Configuration error: 'plan-max-count-add' is missing, "
                      "null, or empty", text)
        self.assertIn("::error title=evaluate-automerge-eligibility::Configuration validation failed", text)

    def test_a_tolerated_test_is_a_notice(self):
        test = {"matrix_context": {"test": {"file": "tests/x.tftest.hcl", "allow-failing-terraform-tests": True}},
                "steps": {"test": {"outputs": {"status": "fail"}}}}
        _, _, text = self.run_step({"terraform-test-meta-x.json": test})
        self.assertIn("::notice title=Auto-merge::The tolerated failing test tests/x.tftest.hcl does not block auto-merge; "
                      "the pull request is not eligible for other reasons", text)


if __name__ == "__main__":
    unittest.main()
