#!/usr/bin/env python3
"""Extract one step's `run:` block from action.yml into a runnable script.

Used by run_all_tests.sh so the tests exercise the action's real inline bash
rather than a copy of it. GitHub Actions expressions are substituted with
literal text (no shell escaping involved, unlike a sed-based approach — the
inputs are JSON blobs full of quotes and slashes).

Usage:
  extract_step_source.py <action.yml> <step-id> <out-file> [KEY=path-or-value ...]

Each trailing argument replaces one expression:
  inputs.inputs-json=@/path/to/file    -> contents of the file
  github.ref_name=main                 -> the literal value
"""

import sys
import yaml


def main() -> int:
    action_file, step_id, out_file = sys.argv[1:4]
    substitutions = sys.argv[4:]

    with open(action_file, encoding="utf-8") as handle:
        action = yaml.safe_load(handle)

    steps = action["runs"]["steps"]
    matches = [step for step in steps if step.get("id") == step_id]
    if not matches:
        available = ", ".join(str(step.get("id")) for step in steps)
        print(f"no step with id '{step_id}' (have: {available})", file=sys.stderr)
        return 1

    source = matches[0]["run"]

    for substitution in substitutions:
        key, _, value = substitution.partition("=")
        if value.startswith("@"):
            with open(value[1:], encoding="utf-8") as handle:
                value = handle.read()
        # Both spacing variants occur in this repo's action definitions.
        for expression in (f"${{{{ {key} }}}}", f"${{{{{key}}}}}"):
            source = source.replace(expression, value)

    with open(out_file, "w", encoding="utf-8") as handle:
        handle.write("#!/bin/env bash\n")
        handle.write(source)
        if not source.endswith("\n"):
            handle.write("\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
