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
        "format-check-in-root-dir": False, "path-relevance-enabled": True, "runs-on": "ubuntu-latest",
        "pr-auto-merge-enabled": False, "pr-comment-group": "", "terraform-version": "latest",
        "tflint-version": "latest", "verify-lock-file": True,
    }
    workflow_inputs.update(inputs or {})
    return {
        "schema_version": 1,
        "caller": {"repository": "example-org/example-repo", "default_branch": default_branch},
        "event": {"name": "push", "ref_name": ref_name, "ref_type": "branch"},
        "workflow_inputs": workflow_inputs,
        "yaml": {
            "inputs": {"environments-yml": parsed(copy.deepcopy(environments))},
            "environments": env_yaml if env_yaml is not None else [{} for _ in environments],
        },
        "directories_exist": directories if directories is not None else {
            f"./envs/{e['environment']}": True for e in environments if isinstance(e, dict) and "environment" in e
        },
    }


# The Dependabot admission's facts (docs/Dependabot-admission.md §8), valid and admitted unless a test changes them.
NOW = 1790000000
DAY = 86400


def provider_dependency(address="registry.terraform.io/hashicorp/azurerm", old="4.41.0", new="4.42.0", files=None,
                        published=NOW - 10 * DAY, keys_from=("34365D9472D7468F",), keys_to=("34365D9472D7468F",),
                        vouched=True, class_from="signed by HashiCorp", class_to="signed by HashiCorp",
                        zh=("aa",), shasums=("aa", "bb"), locked=True):
    return {"kind": "provider", "address": address, "from": old, "to": new,
            "files": list(files or ["envs/env-a/.terraform.lock.hcl"]), "locked": locked,
            "facts": {"published": published, "keys_from": list(keys_from), "keys_to": list(keys_to),
                      "vouched": vouched, "class_from": class_from, "class_to": class_to, "zh": list(zh),
                      "shasums": list(shasums)}}


def module_dependency(address="Azure/naming/azurerm", old="0.4.3", new="0.4.4", source_kind="registry",
                      namespace="Azure", name="naming", published=NOW - 10 * DAY, files=None):
    return {"kind": "module", "address": address, "from": old, "to": new, "files": list(files or ["main/naming.tf"]),
            "source_kind": source_kind, "namespace": namespace, "name": name, "facts": {"published": published}}


def admission_facts(dependencies=None, files=None, locks=None, now=NOW):
    """Admission facts: by default one provider bump in env-a's lock, every listed directory locked."""
    return {"now": now, "files": [] if files is None else files,
            "dependencies": [provider_dependency()] if dependencies is None else dependencies,
            "locks": {"envs/env-a": True} if locks is None else locks}


def dependabot_pull_request(doc, facts=None, author="dependabot[bot]"):
    """Make a document Dependabot's pull request run, with admission facts (admitted by default)."""
    doc["event"].update({"name": "pull_request", "actor": "dependabot[bot]", "base_ref": doc["caller"]["default_branch"]})
    doc["event"]["pull_request"] = {"number": 87, "head_sha": "abc", "is_fork": False, "author": author}
    doc["event"].pop("push", None)
    doc["admission"] = admission_facts() if facts is None else facts
    return doc
