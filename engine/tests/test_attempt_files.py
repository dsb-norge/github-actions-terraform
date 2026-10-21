"""The newest-attempt step on a runner (docs/Re-run-attempts.md §5): the downloaded files in, the newest
attempt of each written under its name."""

import io
import os
import tempfile
import unittest
from unittest import mock

from dsb_tf_engine import attempt_files


class RunTest(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.from_dir = os.path.join(work.name, "download")
        self.to_dir = os.path.join(work.name, "out", "here")
        os.makedirs(self.from_dir)
        self.log = io.StringIO()

    def download(self, **files):
        for name, content in files.items():
            with open(os.path.join(self.from_dir, name), "w", encoding="utf-8") as handle:
                handle.write(content)

    def run_step(self, min_attempt=""):
        return attempt_files.run(self.from_dir, self.to_dir, min_attempt, self.log)

    def written(self):
        found = {}
        for name in sorted(os.listdir(self.to_dir)):
            with open(os.path.join(self.to_dir, name), encoding="utf-8") as handle:
                found[name] = handle.read()
        return found

    def test_a_partial_re_run_writes_each_environment_from_its_newest_attempt(self):
        self.download(**{"matrix-job-meta-prod-attempt-1.json": "prod 1", "matrix-job-meta-prod-attempt-2.json": "prod 2",
                         "matrix-job-meta-test-attempt-1.json": "test 1"})
        self.assertEqual(0, self.run_step())
        self.assertEqual({"matrix-job-meta-prod.json": "prod 2", "matrix-job-meta-test.json": "test 1"}, self.written())
        self.assertEqual("::stop-commands::TOKEN\n"
                         "matrix-job-meta-prod.json: attempt 2 (found 1, 2)\n"
                         "matrix-job-meta-test.json: attempt 1 (found 1)\n"
                         "::TOKEN::\n", self.log.getvalue().replace(self.token(), "TOKEN"))

    def token(self):
        return self.log.getvalue().split("\n", 1)[0].removeprefix("::stop-commands::")

    def test_the_minimum_leaves_out_older_attempts_and_says_so(self):
        self.download(**{"notify-result-e1-attempt-1.json": "old", "notify-result-e1-attempt-2.json": "new",
                         "notify-result-e2.json": "unnamed"})
        self.assertEqual(0, self.run_step("2"))
        self.assertEqual({"notify-result-e1.json": "new"}, self.written())
        self.assertEqual("::stop-commands::TOKEN\n"
                         "notify-result-e1.json: attempt 2 (found 2)\n"
                         "notify-result-e1-attempt-1.json: left out, attempt 1 is before attempt 2\n"
                         "notify-result-e2.json: left out, attempt 0 is before attempt 2\n"
                         "::TOKEN::\n", self.log.getvalue().replace(self.token(), "TOKEN"))

    def test_an_empty_minimum_is_no_minimum(self):
        self.download(**{"m.json": "unnamed"})
        self.assertEqual(0, self.run_step(""))
        self.assertEqual({"m.json": "unnamed"}, self.written())

    def test_a_minimum_that_is_not_a_number_is_a_fault(self):
        self.download(**{"m-attempt-1.json": "x"})
        for value in ("two", "-1", "1.5", " 1", "²"):
            with self.subTest(value=value):
                self.log = io.StringIO()
                self.assertEqual(1, self.run_step(value))
                self.assertEqual(f"::error title=download-newest-attempt::min-attempt is '{value}', not an attempt number\n",
                                 self.log.getvalue())
                self.assertFalse(os.path.exists(self.to_dir))

    def test_a_file_already_there_is_replaced(self):
        os.makedirs(self.to_dir)
        with open(os.path.join(self.to_dir, "m.json"), "w", encoding="utf-8") as handle:
            handle.write("stale")
        self.download(**{"m-attempt-1.json": "fresh"})
        self.assertEqual(0, self.run_step())
        self.assertEqual({"m.json": "fresh"}, self.written())

    def test_a_directory_is_left_out_with_a_warning(self):
        os.makedirs(os.path.join(self.from_dir, "events", "deeper"))
        self.download(**{"m-attempt-1.json": "x"})
        self.assertEqual(0, self.run_step())
        self.assertEqual({"m.json": "x"}, self.written())
        self.assertTrue(self.log.getvalue().startswith(
            "::warning title=download-newest-attempt::events is a directory, not an artifact's file; it is left out "
            "(docs/Re-run-attempts.md §5)\n"))

    def test_no_download_writes_nothing_and_says_so(self):
        for remove in (False, True):
            with self.subTest(missing=remove):
                if remove:
                    os.rmdir(self.from_dir)
                self.log = io.StringIO()
                self.assertEqual(0, self.run_step())
                self.assertEqual({}, self.written())
                self.assertEqual("No artifact file was downloaded.\n", self.log.getvalue())

    def test_a_download_directory_that_cannot_be_read_is_a_fault(self):
        with mock.patch.object(os, "listdir", side_effect=PermissionError("denied")):
            self.assertEqual(1, self.run_step())
        self.assertEqual("::error title=download-newest-attempt::the downloaded files cannot be listed: denied\n",
                         self.log.getvalue())

    def test_a_file_that_cannot_be_written_is_a_fault(self):
        self.download(**{"m-attempt-1.json": "x"})
        os.makedirs(os.path.join(self.to_dir, "m.json"))
        self.assertEqual(1, self.run_step())
        self.assertIn("::error title=download-newest-attempt::m.json cannot be written: ", self.log.getvalue())


if __name__ == "__main__":
    unittest.main()
