"""engine/run.py and the create-matrix command: the floor, isolation, dispatch."""

import contextlib
import io
import json
import os
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import support
from dsb_tf_engine import __main__ as cli
from dsb_tf_engine import adapter, automerge_evidence

ENGINE_DIR = os.path.dirname(support.TESTS_DIR)
RUN_PY = os.path.join(ENGINE_DIR, "run.py")


class EntryTest(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.input = os.path.join(self.work.name, "input.json")
        self.output = os.path.join(self.work.name, "output.json")
        with open(self.input, "w", encoding="utf-8") as handle:
            json.dump(support.document(), handle)

    def test_below_the_floor_it_exits_naming_the_floor_before_importing_anything(self):
        for version in ((3, 11, 9), (3, 10, 0), (2, 7, 18)):
            with self.subTest(version=version):
                with mock.patch.object(sys, "version_info", version), mock.patch.object(sys, "version", "3.11.9 (main)"), \
                        mock.patch.dict(sys.modules), self.assertRaises(SystemExit) as raised:
                    sys.modules.pop("dsb_tf_engine.__main__", None)
                    runpy.run_path(RUN_PY, run_name="__main__")
                self.assertEqual("dsb_tf_engine needs Python 3.12 or later on the runner, found 3.11.9", raised.exception.code)

    def test_at_the_floor_it_runs_the_command_line(self):
        with mock.patch.object(sys, "version_info", (3, 12, 0)), \
                mock.patch.object(sys, "argv", ["run.py", "decide", "--input", self.input, "--output", self.output]), \
                mock.patch.dict(sys.modules), self.assertRaises(SystemExit) as raised:
            sys.modules.pop("dsb_tf_engine.__main__", None)
            runpy.run_path(RUN_PY, run_name="__main__")
        self.assertEqual(0, raised.exception.code)
        self.assertTrue(os.path.exists(self.output))

    def test_isolated_it_ignores_the_working_directory_and_python_variables(self):
        shadow = os.path.join(self.work.name, "shadow")
        os.makedirs(shadow)
        for name in ("json.py", "argparse.py", "dsb_tf_engine.py"):
            with open(os.path.join(shadow, name), "w", encoding="utf-8") as handle:
                handle.write(f"raise SystemExit('{name} from the caller was imported')\n")
        completed = subprocess.run(
            [sys.executable, "-I", "-B", RUN_PY, "decide", "--input", self.input, "--output", self.output],
            cwd=shadow, capture_output=True, text=True,
            env={**os.environ, "PYTHONPATH": shadow, "PYTHONSTARTUP": os.path.join(shadow, "json.py")})
        self.assertEqual((0, ""), (completed.returncode, completed.stderr))

    def test_without_isolation_the_working_directory_would_shadow_the_standard_library(self):
        # The reason for -I, demonstrated: this is what the action's invocation prevents.
        shadow = os.path.join(self.work.name, "shadow")
        os.makedirs(shadow)
        with open(os.path.join(shadow, "json.py"), "w", encoding="utf-8") as handle:
            handle.write("raise SystemExit('caller json.py imported')\n")
        completed = subprocess.run([sys.executable, "-B", "-m", "dsb_tf_engine", "decide", "--input", self.input,
                                    "--output", self.output], cwd=shadow, capture_output=True, text=True,
                                   env={**os.environ, "PYTHONPATH": ENGINE_DIR})
        self.assertIn("caller json.py imported", completed.stderr)


class CreateMatrixCommandTest(unittest.TestCase):
    def test_the_command_runs_the_adapter_with_the_runners_environment(self):
        calls = []
        with mock.patch.object(adapter, "run", lambda *args: calls.append(args) or 7):
            self.assertEqual(7, cli.main(["create-matrix", "--inputs-file", "/tmp/inputs.json", "--mode", "project"]))
        inputs_file, environ, stream, tools, isdir, mode = calls[0]
        self.assertEqual("/tmp/inputs.json", inputs_file)
        self.assertIs(os.environ, environ)
        self.assertIs(sys.stdout, stream)
        self.assertIsInstance(tools, adapter.Tools)
        self.assertIs(os.path.isdir, isdir)
        self.assertIs(False, mode)
        with mock.patch.object(adapter, "run", lambda *args: calls.append(args) or 0):
            self.assertEqual(0, cli.main(["create-matrix", "--inputs-file", "/tmp/x.json", "--mode", "module"]))
        self.assertIs(True, calls[1][5])

    def test_the_mode_is_required_and_one_of_two(self):
        for argv in (["create-matrix", "--inputs-file", "/tmp/x.json"],
                     ["create-matrix", "--inputs-file", "/tmp/x.json", "--mode", "modules"]):
            with self.subTest(argv=argv):
                with contextlib.redirect_stderr(io.StringIO()) as stderr, self.assertRaises(SystemExit) as raised:
                    cli.main(argv)
                self.assertEqual(1, raised.exception.code)
                self.assertIn("--mode", stderr.getvalue())

    def test_the_help_describes_the_command(self):
        with contextlib.redirect_stdout(io.StringIO()) as stdout, self.assertRaises(SystemExit):
            cli.main(["--help"])
        self.assertIn("the create-tf-vars-matrix step, on a runner", stdout.getvalue())
        with contextlib.redirect_stdout(io.StringIO()) as stdout, self.assertRaises(SystemExit):
            cli.main(["create-matrix", "--help"])
        self.assertIn("path of the file holding toJSON(inputs)", stdout.getvalue())
        self.assertIn("the calling workflow's kind of repository", stdout.getvalue())

    def test_the_inputs_file_is_required(self):
        with contextlib.redirect_stderr(io.StringIO()) as stderr, self.assertRaises(SystemExit) as raised:
            cli.main(["create-matrix", "--mode", "project"])
        self.assertEqual(cli.EXIT_CRASH, raised.exception.code)
        self.assertIn("the following arguments are required: --inputs-file", stderr.getvalue())


class EvaluateAutomergeCommandTest(unittest.TestCase):
    ARGV = ["evaluate-automerge", "--metadata-files-pattern=m-*.json", "--relevance-file=/tmp/r.json",
            "--test-metadata-files-pattern=", "--stage-results-file=/tmp/stages"]

    def test_the_command_runs_the_evaluator_with_the_runners_environment(self):
        calls = []
        with mock.patch.object(automerge_evidence, "run", lambda *args: calls.append(args) or 5):
            self.assertEqual(5, cli.main(self.ARGV))
        metadata, relevance, tests, stages, environ, stream = calls[0]
        self.assertEqual(("m-*.json", "/tmp/r.json", "", "/tmp/stages"), (metadata, relevance, tests, stages))
        self.assertIs(os.environ, environ)
        self.assertIs(sys.stdout, stream)

    def test_every_argument_is_required(self):
        for index in range(1, len(self.ARGV)):
            argv = self.ARGV[:index] + self.ARGV[index + 1:]
            with self.subTest(missing=self.ARGV[index]):
                with contextlib.redirect_stderr(io.StringIO()) as stderr, self.assertRaises(SystemExit) as raised:
                    cli.main(argv)
                self.assertEqual(cli.EXIT_CRASH, raised.exception.code)
                self.assertIn(f"the following arguments are required: {self.ARGV[index].split('=')[0]}",
                              stderr.getvalue())

    def test_the_help_describes_the_command(self):
        with contextlib.redirect_stdout(io.StringIO()) as stdout, self.assertRaises(SystemExit):
            cli.main(["--help"])
        self.assertIn("the evaluate-automerge-eligibility step, on a runner", stdout.getvalue())
        with contextlib.redirect_stdout(io.StringIO()) as stdout, self.assertRaises(SystemExit):
            cli.main(["evaluate-automerge", "--help"])
        for fragment in ("glob of the environment jobs' metadata", "path of relevance.json; empty for none",
                         "glob of the test jobs' metadata; empty for none", "path of the file holding stage-results-json"):
            self.assertIn(fragment, " ".join(stdout.getvalue().split()))


if __name__ == "__main__":
    unittest.main()
