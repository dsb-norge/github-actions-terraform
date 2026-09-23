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

    def test_usage_errors_exit_1_never_the_configuration_code_2(self):
        for argv in ([], ["decide"], ["decide", "--input", "x"], ["decide", "--output", "y"],
                     ["nonsense", "--input", "x", "--output", "y"], ["decide", "--input", "x", "--output", "y", "--extra"]):
            with self.subTest(argv=argv):
                stderr = io.StringIO()
                with contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(io.StringIO()), \
                        self.assertRaises(SystemExit) as raised:
                    cli.main(argv)
                self.assertEqual(cli.EXIT_CRASH, raised.exception.code)
                self.assertIn("usage: dsb_tf_engine", stderr.getvalue())
                self.assertIn("error:", stderr.getvalue())

    def test_usage_errors_name_what_is_missing(self):
        for argv, fragment in (([], "required: command"), (["decide"], "required: --input, --output")):
            with self.subTest(argv=argv):
                stderr = io.StringIO()
                with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit):
                    cli.main(argv)
                self.assertIn(fragment, stderr.getvalue())

    def test_help_describes_the_command_and_its_arguments(self):
        for argv, fragments in ((["--help"], ["decide the run from an input document"]),
                                (["decide", "--help"], ["path of the input document", "path to write the output document to"])):
            with self.subTest(argv=argv):
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout), self.assertRaises(SystemExit) as raised:
                    cli.main(argv)
                self.assertEqual(0, raised.exception.code)
                for fragment in fragments:
                    self.assertIn(fragment, stdout.getvalue())

    def test_argv_defaults_to_the_process_arguments(self):
        self.write_input(support.document())
        with mock.patch.object(sys, "argv", ["dsb_tf_engine", "decide", "--input", self.input, "--output", self.output]), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, cli.main())
        self.assertTrue(os.path.exists(self.output))

    def test_the_exit_codes_are_distinct(self):
        self.assertEqual((0, 1, 2), (cli.EXIT_OK, cli.EXIT_CRASH, cli.EXIT_INVALID))

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
