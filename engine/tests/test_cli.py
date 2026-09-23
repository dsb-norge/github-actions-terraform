"""The command line: exit codes, files, and nothing on stdout (P8)."""

import contextlib
import io
import json
import os
import runpy
import sys
import tempfile
import unittest
from unittest import mock

import support
from dsb_tf_engine import __main__ as cli


class CliTest(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.input = os.path.join(self.work.name, "input.json")
        self.output = os.path.join(self.work.name, "output.json")

    def write_input(self, content):
        with open(self.input, "w", encoding="utf-8") as handle:
            handle.write(content if isinstance(content, str) else json.dumps(content))

    def run_cli(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = cli.main(["decide", "--input", self.input, "--output", self.output])
        self.assertEqual("", stdout.getvalue(), "the engine must not write to stdout")
        return code, stderr.getvalue()

    def test_a_decision_exits_0_and_writes_sorted_json(self):
        self.write_input(support.document())
        code, stderr = self.run_cli()
        self.assertEqual((0, ""), (code, stderr))
        with open(self.output, encoding="utf-8") as handle:
            text = handle.read()
        self.assertEqual(json.dumps(json.loads(text), sort_keys=True, ensure_ascii=False) + "\n", text)

    def test_a_configuration_error_exits_2_with_messages_on_stderr_and_in_the_output(self):
        self.write_input(support.document(environments=[]))
        code, stderr = self.run_cli()
        self.assertEqual(2, code)
        self.assertEqual("The specification is an empty array!\n", stderr)
        with open(self.output, encoding="utf-8") as handle:
            self.assertEqual(["The specification is an empty array!"], json.load(handle)["errors"])

    def test_a_document_error_exits_1_and_writes_no_output(self):
        self.write_input({"schema_version": 1})
        code, stderr = self.run_cli()
        self.assertEqual(1, code)
        self.assertIn("cannot decide: input document: missing key(s)", stderr)
        self.assertFalse(os.path.exists(self.output))

    def test_unreadable_or_invalid_input_exits_1(self):
        code, stderr = self.run_cli()
        self.assertEqual(1, code)
        self.assertIn("cannot decide", stderr)
        self.write_input("{not json")
        self.assertEqual(1, self.run_cli()[0])

    def test_module_entry_point_exits_with_mains_code(self):
        self.write_input(support.document())
        argv = ["dsb_tf_engine", "decide", "--input", self.input, "--output", self.output]
        # Dropping the already-imported __main__ module keeps runpy from warning that it
        # executes a module it finds in sys.modules.
        with mock.patch.object(sys, "argv", argv), mock.patch.dict(sys.modules), \
                self.assertRaises(SystemExit) as raised:
            sys.modules.pop("dsb_tf_engine.__main__", None)
            runpy.run_module("dsb_tf_engine", run_name="__main__", alter_sys=True)
        self.assertEqual(0, raised.exception.code)


if __name__ == "__main__":
    unittest.main()
