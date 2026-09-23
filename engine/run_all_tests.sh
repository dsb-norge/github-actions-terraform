#!/bin/env bash
#
# Tests for the decision engine. docs/Decision-engine.md §8.
#
# Runs every unittest module under coverage and applies the 100 percent line and branch gate;
# prints the canonical Tests run / passed / failed lines once (docs/Testing-in-ci.md §4).
#

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

exec python3 "${_this_script_dir}/tests/run_tests.py"
