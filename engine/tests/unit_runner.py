#!/usr/bin/env python3
"""Discover and run every tests/test_*.py module; write the counts for run_tests.py.

Failures, errors and unexpected successes all count as failed. Nothing here prints the
canonical summary lines: run_tests.py prints them once, with the coverage gate included.
"""

import argparse
import json
import os
import sys
import unittest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
ENGINE_DIR = os.path.dirname(TESTS_DIR)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--result", required=True)
    args = parser.parse_args()

    # On sys.path directly, not through PYTHONPATH: `pipx run` does not pass PYTHONPATH on to
    # the interpreter it starts, so the package would not import on the hosted runners.
    sys.path[:0] = [ENGINE_DIR, TESTS_DIR]
    suite = unittest.defaultTestLoader.discover(TESTS_DIR, pattern="test_*.py", top_level_dir=TESTS_DIR)
    result = unittest.TextTestRunner(verbosity=1, stream=sys.stdout).run(suite)
    failed = len(result.failures) + len(result.errors) + len(result.unexpectedSuccesses)
    with open(args.result, "w", encoding="utf-8") as handle:
        json.dump({"run": result.testsRun, "failed": failed}, handle)


if __name__ == "__main__":
    main()
