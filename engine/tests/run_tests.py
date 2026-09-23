#!/usr/bin/env python3
"""Suite entry for the decision engine: every test module under coverage, then the two gates.

Prints the three canonical summary lines of docs/Testing-in-ci.md §4 exactly once. The
coverage gate and the mutation gate count as one more test each, so a shortfall reads as a
failed test rather than an all-green suite with a red job. Coverage proves every line and branch
ran; mutation (tests/mutation.py) proves a test notices when one of them decides wrongly.

coverage is not preinstalled on the hosted runners, and `pip install --user` is refused there
(externally managed environment), so it runs through the preinstalled pipx at a pinned
version; `python3 -m coverage` is used where it is importable, such as a developer's venv.
A missing coverage fails the gate: the gate is part of the contract.
"""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

COVERAGE_PIN = "7.16.1"
PACKAGE = "dsb_tf_engine"
TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
ENGINE_DIR = os.path.dirname(TESTS_DIR)


def coverage_command():
    if importlib.util.find_spec("coverage"):
        return [sys.executable, "-m", "coverage"]
    if shutil.which("pipx"):
        return ["pipx", "run", "--spec", f"coverage=={COVERAGE_PIN}", "coverage"]
    return None


def run(command, env):
    return subprocess.run(command, cwd=ENGINE_DIR, env=env).returncode


def gate(report_file):
    """Every file of the package with no missing line and no missing branch."""
    with open(report_file, encoding="utf-8") as handle:
        report = json.load(handle)
    shortfalls = []
    for path, data in sorted(report["files"].items()):
        missing_lines = data["missing_lines"]
        missing_branches = data.get("missing_branches", [])
        if missing_lines or missing_branches:
            shortfalls.append(f"  {path}: lines {missing_lines}, branches {missing_branches}")
    if not report["meta"].get("branch_coverage"):
        shortfalls.append("  branch measurement was off")
    return shortfalls


def main():
    env = {**os.environ, "PYTHONPATH": ENGINE_DIR, "PYTHONDONTWRITEBYTECODE": "1"}
    with tempfile.TemporaryDirectory() as work:
        result_file = os.path.join(work, "result.json")
        unit_runner = [os.path.join(TESTS_DIR, "unit_runner.py"), "--result", result_file]
        coverage = coverage_command()

        if coverage:
            data_file = os.path.join(work, ".coverage")
            source = os.path.join(ENGINE_DIR, PACKAGE)
            run(coverage + ["run", "--branch", f"--source={source}", f"--data-file={data_file}"] + unit_runner, env)
            report_file = os.path.join(work, "coverage.json")
            if run(coverage + ["json", f"--data-file={data_file}", "-o", report_file], env) == 0:
                shortfalls = gate(report_file)
            else:
                shortfalls = ["  coverage could not write its report"]
            run(coverage + ["report", "--show-missing", f"--data-file={data_file}"], env)
        else:
            run([sys.executable] + unit_runner, env)
            shortfalls = [f"  coverage is not available: neither 'python3 -m coverage' nor pipx"]

        if os.path.exists(result_file):
            with open(result_file, encoding="utf-8") as handle:
                result = json.load(handle)
        else:
            result = {"run": 0, "failed": 0}
            shortfalls.append("  the unit runner did not report a result")

        mutation_failed = run([sys.executable, "-B", os.path.join(TESTS_DIR, "mutation.py")], env) != 0

    print("")
    if mutation_failed:
        print("MUTATION GATE FAILED: an injected fault went unnoticed by every test (listed above).")
    else:
        print("Mutation gate passed: every injected fault fails a test.")
    if shortfalls:
        print("COVERAGE GATE FAILED (100 percent of lines and branches is the contract):")
        print("\n".join(shortfalls))
    else:
        print("Coverage gate passed: 100 percent of lines and branches.")

    tests_run = result["run"] + 2
    tests_failed = result["failed"] + (1 if shortfalls else 0) + (1 if mutation_failed else 0)
    print("")
    print(f"Tests run:    {tests_run}")
    print(f"Tests passed: {tests_run - tests_failed}")
    print(f"Tests failed: {tests_failed}")
    return 1 if tests_failed else 0


if __name__ == "__main__":
    sys.exit(main())
