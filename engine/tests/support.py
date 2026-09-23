"""Shared fixtures for the engine tests: the port cases and a minimal valid document."""

import copy
import json
import os

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PORT_CASES_DIR = os.path.join(TESTS_DIR, "port", "cases")


def port_cases():
    """(name, input document, expected result) for every port case, sorted by name.

    The expected result is the case's engine_expected when it records a deliberate deviation
    from the bash builder, else the bash builder's golden output.
    """
    cases = []
    for name in sorted(os.listdir(PORT_CASES_DIR)):
        case_dir = os.path.join(PORT_CASES_DIR, name)
        with open(os.path.join(case_dir, "case.json"), encoding="utf-8") as handle:
            case = json.load(handle)
        with open(os.path.join(case_dir, "input.json"), encoding="utf-8") as handle:
            document = json.load(handle)
        if "engine_expected" in case:
            expected = case["engine_expected"]
        else:
            with open(os.path.join(case_dir, "expected.json"), encoding="utf-8") as handle:
                expected = json.load(handle)
        cases.append((name, document, expected))
    return cases


def parsed(value, ok=True):
    return {"ok": ok, "value": value}


def document(environments=None, inputs=None, env_yaml=None, directories=None, ref_name="main", default_branch="main"):
    """A minimal valid input document: one environment, every required input present."""
    environments = [{"environment": "env-a"}] if environments is None else environments
    workflow_inputs = {
        "add-pr-comment": True, "apply-extract-include-outputs": False, "cache-terraform-modules": True,
        "pr-auto-merge-enabled": False, "pr-comment-group": "", "terraform-version": "latest",
        "tflint-version": "latest", "verify-lock-file": True,
    }
    workflow_inputs.update(inputs or {})
    return {
        "schema_version": 1,
        "caller": {"repository": "example-org/example-repo", "default_branch": default_branch},
        "event": {"name": "push", "ref_name": ref_name},
        "workflow_inputs": workflow_inputs,
        "yaml": {
            "inputs": {"environments-yml": parsed(copy.deepcopy(environments))},
            "environments": env_yaml if env_yaml is not None else [{} for _ in environments],
        },
        "directories_exist": directories if directories is not None else {
            f"./envs/{e['environment']}": True for e in environments if isinstance(e, dict) and "environment" in e
        },
    }
