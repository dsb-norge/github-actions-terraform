#!/usr/bin/env python3
"""Write a relevance.json exactly as create-matrix publishes it, for the actions that read it.

The aggregator, the run summary and the auto-merge evaluator test against their own hand-written
files; this is the contract test beside them. A key the engine renames or drops fails their
suites here instead of in production. Usage, from any directory:

    python3 -I -B engine/tests/relevance_fixture.py <scenario> <output file>

Every scenario has three environments, auto-merge enabled for all: `prod` ungrouped
(github-environment `prod-gh`, auto-merge only for `renovate[bot]`), `staging` and `sandbox` in the
group `platform`, any actor (`sandbox` applies on pull request). Pull request #87, run #4711
attempt #1.
"""

import json
import os
import sys
import tempfile

sys.path[:0] = [os.path.dirname(os.path.dirname(os.path.abspath(__file__)))]

from dsb_tf_engine import adapter, decide  # noqa: E402

ENVIRONMENTS = [
    {"environment": "prod", "github-environment": "prod-gh", "pr-auto-merge-enabled": True,
     "pr-auto-merge-from-actors-yml": ["renovate[bot]"]},
    {"environment": "staging", "pr-comment-group": "platform"},
    {"environment": "sandbox", "pr-comment-group": "platform", "goals-yml": ["all", "apply-on-pr"]},
]
LIMITS = {"plan-max-count-add": 0, "plan-max-count-change": 0, "plan-max-count-destroy": 0,
          "plan-max-count-import": -1, "plan-max-count-move": -1, "plan-max-count-remove": 0}
SCENARIOS = {
    "docs-only": ["README.md", "envs/prod/README.md"],
    "one-environment": ["envs/staging/main.tf"],
    "workflow-changed": [".github/workflows/ci.yml"],
}


def _parsed(value):
    return {"ok": True, "value": value}


def document(files):
    """The input document create-matrix builds for a pull request touching `files`."""
    inputs = {"environments-yml": json.dumps(ENVIRONMENTS), "add-pr-comment": True, "apply-extract-include-outputs": False,
              "cache-terraform-modules": True, "path-relevance-enabled": True, "pr-auto-merge-enabled": True,
              "pr-comment-group": "", "terraform-version": "latest", "tflint-version": "latest",
              "verify-lock-file": True, "goals-yml": "[all]", "pr-auto-merge-limits-yml": json.dumps(LIMITS)}
    return {
        "schema_version": 1,
        "caller": {"repository": "example-org/example-repo", "default_branch": "main"},
        "event": {"name": "pull_request", "ref_name": "feature/x", "action": "synchronize",
                  "pull_request": {"number": 87, "head_sha": "abc", "is_fork": False}},
        "workflow_inputs": inputs,
        "yaml": {
            "inputs": {"environments-yml": _parsed(ENVIRONMENTS), "goals-yml": _parsed(["all"]),
                       "pr-auto-merge-limits-yml": _parsed(LIMITS)},
            "environments": [{key: _parsed(value) for key, value in e.items() if key.endswith("-yml")}
                             for e in ENVIRONMENTS],
        },
        "directories_exist": {f"./envs/{e['environment']}": True for e in ENVIRONMENTS},
        "run": {"id": 4711, "attempt": 1},
        "changed_files": {"available": True, "truncated": False, "error": None, "api_head_sha": "abc",
                          "count": len(files), "files": files},
    }


def write(scenario, path):
    output = decide.decide(document(SCENARIOS[scenario]))
    if output["errors"]:
        raise SystemExit(f"relevance_fixture: scenario {scenario!r} does not decide: {output['errors']}")
    with tempfile.TemporaryDirectory() as temp:
        with open(adapter.write_relevance_file(temp, output), encoding="utf-8") as handle:
            text = handle.read()
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in SCENARIOS:
        raise SystemExit(f"usage: relevance_fixture.py <{'|'.join(SCENARIOS)}> <output file>")
    write(sys.argv[1], sys.argv[2])
