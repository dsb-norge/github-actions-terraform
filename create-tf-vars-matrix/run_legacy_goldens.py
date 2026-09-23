#!/usr/bin/env python3
"""Run the bash matrix builder against the port cases and compare with, or write, their goldens.

Each case is a directory under engine/tests/port/cases/ holding case.json:

  {
    "description": "...",
    "inputs_json": { ... what toJSON(inputs) delivers ... },
    "ref_name": "main",              # optional, default "main"
    "default_branch": "main",        # optional, default "main"
    "directories": ["envs/my-env"]   # optional, created in the workspace
  }

The three steps of action.yml run in sequence exactly as the runner runs them (the step
source is extracted by extract_step_source.py, a stub curl answers the default-branch
lookup), and the result is written to expected.json beside it:

  {"exit_code": 0, "matrix": { ... matrix-json ... }}
  {"exit_code": 1, "errors": ["<ERROR line>", ...]}

Usage:
  run_legacy_goldens.py check  <case-dir>...   exit 1 when any golden differs
  run_legacy_goldens.py update <case-dir>...   rewrite expected.json
"""

import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
# log-error prints "ERROR: <action>: <msg>"; a failed field check opens a group "<action>: ERROR: <msg>".
ERROR_LINE = re.compile(r"^(?:ERROR: create-tf-vars-matrix: |::group::create-tf-vars-matrix: ERROR: )(.*)$")


def extract(step_id, out_file, substitutions):
    subprocess.run(
        [sys.executable, os.path.join(HERE, "extract_step_source.py"),
         os.path.join(HERE, "action.yml"), step_id, out_file, *substitutions],
        check=True,
    )


def run_step(script, workspace, path_env, env):
    proc = subprocess.run(
        ["bash", "--noprofile", "--norc", "-eo", "pipefail", script],
        cwd=workspace, capture_output=True, text=True,
        env={**env, "PATH": path_env},
    )
    return proc.returncode, proc.stdout + proc.stderr


def read_multiline_output(path, name):
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    match = re.search(r'^%s<<"([^"]+)"\n(.*?)\n"\1"\s*$' % re.escape(name), text, re.S | re.M)
    return match.group(2) if match else None


def errors_from(log):
    return [m.group(1) for m in (ERROR_LINE.match(line) for line in log.splitlines()) if m]


def run_case(case_dir):
    with open(os.path.join(case_dir, "case.json"), encoding="utf-8") as handle:
        case = json.load(handle)

    with tempfile.TemporaryDirectory() as work:
        workspace = os.path.join(work, "ws")
        os.makedirs(workspace)
        for directory in case.get("directories", []):
            os.makedirs(os.path.join(workspace, directory), exist_ok=True)

        stub_bin = os.path.join(work, "stub-bin")
        os.makedirs(stub_bin)
        with open(os.path.join(stub_bin, "curl"), "w", encoding="utf-8") as handle:
            handle.write("#!/bin/env bash\necho %s\n"
                         % json.dumps(json.dumps({"default_branch": case.get("default_branch", "main")})))
        os.chmod(os.path.join(stub_bin, "curl"), 0o755)

        inputs_file = os.path.join(work, "inputs.json")
        with open(inputs_file, "w", encoding="utf-8") as handle:
            json.dump(case["inputs_json"], handle, indent=2)

        env = dict(os.environ)
        env["GITHUB_WORKSPACE"] = workspace
        env["GITHUB_ACTION_PATH"] = HERE
        path_env = stub_bin + os.pathsep + os.environ["PATH"]

        def step(step_id, substitutions):
            output = os.path.join(work, f"output-{step_id}.txt")
            open(output, "w").close()
            env["GITHUB_OUTPUT"] = output
            script = os.path.join(work, f"step-{step_id}.sh")
            extract(step_id, script, substitutions + [f"github.action_path={HERE}"])
            code, log = run_step(script, workspace, path_env, env)
            return code, log, output

        code, log, output = step("create-vars", [
            f"inputs.inputs-json=@{inputs_file}",
            "github.repository=example-org/example-repo",
            "github.token=fake-token",
            f"github.ref_name={case.get('ref_name', 'main')}",
        ])
        if code != 0:
            return {"exit_code": code, "errors": errors_from(log)}
        vars_file = os.path.join(work, "create-vars.json")
        with open(vars_file, "w", encoding="utf-8") as handle:
            handle.write(read_multiline_output(output, "json") + "\n")

        code, log, _ = step("validate", [f"steps.create-vars.outputs.json=@{vars_file}"])
        if code != 0:
            return {"exit_code": code, "errors": errors_from(log)}

        code, log, output = step("make-matrix-compatible", [f"steps.create-vars.outputs.json=@{vars_file}"])
        if code != 0:
            return {"exit_code": code, "errors": errors_from(log)}
        return {"exit_code": 0, "matrix": json.loads(read_multiline_output(output, "matrix-json"))}


def main():
    mode, case_dirs = sys.argv[1], sys.argv[2:]
    differing = 0
    for case_dir in case_dirs:
        actual = run_case(case_dir)
        expected_file = os.path.join(case_dir, "expected.json")
        if mode == "update":
            with open(expected_file, "w", encoding="utf-8") as handle:
                json.dump(actual, handle, indent=2, sort_keys=True)
                handle.write("\n")
            print(f"wrote {expected_file}")
            continue
        with open(expected_file, encoding="utf-8") as handle:
            expected = json.load(handle)
        if actual != expected:
            differing += 1
            print(f"DIFFERS: {case_dir}\n  expected: {json.dumps(expected, sort_keys=True)[:600]}\n"
                  f"  actual:   {json.dumps(actual, sort_keys=True)[:600]}")
    return 1 if differing else 0


if __name__ == "__main__":
    sys.exit(main())
