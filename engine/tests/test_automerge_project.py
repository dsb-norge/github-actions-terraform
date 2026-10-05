"""The project auto-merge evaluator's core: every reason and log line it writes (docs/Auto-merge.md §5, §14).

The golden cases (test_evaluator_port) pin the verdicts the bash evaluator gave; these tests pin the
engine's own log, whole, for representative runs, and the small readers one by one.
"""

import unittest

from dsb_tf_engine import automerge_project as ap

LIMITS = {"plan-max-count-add": 0, "plan-max-count-change": 0, "plan-max-count-destroy": 0,
          "plan-max-count-import": 0, "plan-max-count-move": -1, "plan-max-count-remove": 0}
ZERO = {c: "0" for c in ap.COUNT_TYPES}

def meta(name, goals=("init", "format", "validate", "lint", "plan"), counts=None, steps=None, source="json",
         complete="true", file=None, **variables):
    steps_ = {"init": {"outcome": "success"}, "plan": {"outcome": "success"},
              "parse-plan": {"outcome": "success",
                             "outputs": {**{f"count-{c}": v for c, v in (counts or ZERO).items()},
                                         "counts-source": source, "plan-complete": complete}}}
    steps_.update(steps or {})
    vars_ = {"pr-auto-merge-enabled": "true", "pr-auto-merge-limits": LIMITS,
             "pr-auto-merge-from-actors": ["example-bot[bot]"], "goals-granted": list(goals)}
    vars_.update(variables)
    return {"file": file or f"matrix-job-meta-{name}.json", "readable": True, "json": True,
            "content": {"metadata": {"environment": name}, "matrix_context": {"vars": vars_}, "steps": steps_}}

def entry(name, verdict, **extra):
    return {"environment": name, "github-environment": name, "verdict": verdict, "pr-auto-merge-enabled": "true",
            "pr-auto-merge-limits": LIMITS, "pr-auto-merge-from-actors": ["example-bot[bot]"], **extra}

def relevance(environments, exists=True, **content):
    return {"file": "relevance.json", "exists": exists, "readable": exists, "json": exists,
            "content": {"environments": environments, **content} if exists else None}

def facts(metadata, relevance_=None, tests=None, stages="", actor="example-bot[bot]",
          tests_pattern="terraform-test-meta-*.json"):
    return {"actor": actor, "metadata_pattern": "matrix-job-meta-*.json", "tests_pattern": tests_pattern,
            "metadata": metadata, "tests": tests or [], "relevance": relevance_, "stage_results": stages}

def render(verdict):
    out = []
    for e in verdict["log"].entries:
        if e[0] == "group":
            out.append(f"[{e[1]}]")
            out += ["  " + ("WARN: " if x[0] == "warn" else "") + x[1] for x in e[2]]
        else:
            out.append(("WARN: " if e[0] == "warn" else "") + e[1])
    return out

def test_job(file, status, allowed, lane="integration", environment=None):
    return {"file": f"terraform-test-meta-{file}.json", "readable": True, "json": True,
            "content": {"metadata": {"environment": environment or file},
                        "matrix_context": {"test": {"file": f"tests/{file}.tftest.hcl" if file else "",
                                                    "lane": lane, "allow-failing-terraform-tests": allowed}},
                        "steps": {"test": {"outputs": {"status": status}}}}}

SCENARIOS = {
  "a_limit_exceeded": facts([meta("prod", counts={**ZERO, "add": "2", "move": "3"})]),
  "relevance_mixed": facts(
      [meta("prod"), meta("dup", file="matrix-job-meta-dup-1.json"), meta("dup", file="matrix-job-meta-dup-2.json"),
       meta("ghost"), {"file": "matrix-job-meta-broken.json", "readable": True, "json": False, "content": None},
       meta("staging-ran")],
      relevance([entry("prod", "run"), entry("staging", "skip", relevant=False, reasons=["relevance: no changed file matches"]),
                 entry("nightly", "skip", relevant=True, reasons=["trigger-events: pull_request not in [push]"]),
                 entry("app", "run", stage=2), entry("spoke", "run"), entry("dup", "run"),
                 entry("staging-ran", "skip")],
                counts={"by_stage": {"1": 2, "2": 1}}),
      stages='{"1": "failure", "2": "skipped"}'),
  "an_unknown_goal_and_a_failed_operation": facts([meta("prod", goals="plan", steps={"fmt": {"outcome": "failure"}})]),
  "evidence_and_destroy_plan": facts([meta("prod", goals=("plan", "destroy-plan"), complete="false",
      steps={"destroy-plan": {"outcome": "success"},
             "parse-destroy-plan": {"outputs": {**{f"count-{c}": "0" for c in ap.COUNT_TYPES}, "counts-source": "console"}}})]),
  "applied_on_the_pull_request": facts([meta("prod", goals=("plan", "apply"), steps={"apply": {"outcome": "failure"}})]),
  "no_files": facts([]),
  "a_limits_mapping_that_cannot_be_judged": facts([meta("prod", **{"pr-auto-merge-limits": {"plan-max-count-add": "x", "plan-max-count-change": True, "plan-max-count-destroy": 0, "plan-max-count-import": 0, "plan-max-count-move": -1, "plan-max-count-remove": 0}})]),
  "tests": facts([meta("prod")], tests=[test_job("int-x", "fail", True), test_job("int-y", "error", "false"),
                                       test_job("unit-a", "pass", False),
                                       {"file": "terraform-test-meta-broken.json", "readable": True, "json": False, "content": None}]),
  "relevance_missing_on_disk": facts([meta("prod")], relevance([], exists=False), tests_pattern=""),
  "relevance_unusable": facts([meta("prod")], relevance([{"github-environment": "", "verdict": "run"}])),
  "relevance_empty": facts([], relevance([])),
}


EXPECTED = {'a_limit_exceeded': {'eligible': False,
                      'notices': [],
                      'fatal': None,
                      'log': ['Metadata files pattern: matrix-job-meta-*.json',
                              'Relevance file: <none>',
                              'Test metadata files pattern: terraform-test-meta-*.json',
                              '[Test Jobs]',
                              '  Found 0 test metadata file(s) matching: terraform-test-meta-*.json',
                              '  Tolerated failing or erroring tests: 0',
                              '[File Discovery]',
                              '  Found 1 metadata file(s):',
                              '    - matrix-job-meta-prod.json',
                              "[Environment 'prod']",
                              '  Actor: example-bot[bot]; auto-merge enabled: true',
                              '  Limits: '
                              '{"plan-max-count-add":0,"plan-max-count-change":0,"plan-max-count-destroy":0,"plan-max-count-import":0,"plan-max-count-move":-1,"plan-max-count-remove":0}; '
                              'actors: ["example-bot[bot]"]',
                              '  Configuration validation: PASS',
                              "[Checks of 'prod']",
                              '  PR automerge enabled: PASS',
                              "  Actor 'example-bot[bot]' found in allowed list",
                              '  Actor authorization: PASS',
                              '  Goals granted: ["init","format","validate","lint","plan"]; failed or cancelled '
                              'operations: <none>',
                              '  Plan creation: expected and succeeded - PASS',
                              '  Destroy plan creation: not expected - SKIPPED',
                              '  Apply on PR: not performed - SKIPPED',
                              '  Destroy on PR: not performed - SKIPPED',
                              '  Plan limits: INCLUDED',
                              '  Destroy plan limits: IGNORED (destroy plan was not supposed to be created)',
                              '  Count validation: PASS',
                              '  Add: 2 / 0 - FAIL',
                              '  WARN: Add count (2) exceeds limit (0) in environment',
                              '  Change: 0 / 0 - PASS',
                              '  Destroy: 0 / 0 - PASS',
                              '  Import: 0 / 0 - PASS',
                              '  Move: 3 / unlimited - PASS',
                              '  Remove: 0 / 0 - PASS',
                              '  No operation failed or was cancelled',
                              '  Operation outcomes: PASS',
                              '  Final eligibility: false',
                              "❌ Environment 'prod' is NOT eligible for automerge",
                              '[Final Summary]',
                              '  Files found: 1',
                              '  Environments processed: 1',
                              '  Environments eligible: 0',
                              '  Environments ineligible: 1',
                              '  Per-environment results:',
                              '    ❌ prod',
                              '  ❌ FINAL RESULT: Not all environments eligible - PR CANNOT be automerged',
                              '  Tolerated failing or erroring tests: 0']},
 'relevance_mixed': {'eligible': False,
                     'notices': [],
                     'fatal': None,
                     'log': ['Metadata files pattern: matrix-job-meta-*.json',
                             'Relevance file: relevance.json',
                             'Test metadata files pattern: terraform-test-meta-*.json',
                             '[Test Jobs]',
                             '  Found 0 test metadata file(s) matching: terraform-test-meta-*.json',
                             '  Tolerated failing or erroring tests: 0',
                             '[File Discovery]',
                             '  Found 6 metadata file(s):',
                             '    - matrix-job-meta-prod.json',
                             '    - matrix-job-meta-dup-1.json',
                             '    - matrix-job-meta-dup-2.json',
                             '    - matrix-job-meta-ghost.json',
                             '    - matrix-job-meta-broken.json',
                             '    - matrix-job-meta-staging-ran.json',
                             '[Relevance File]',
                             '  Relevance file lists 7 environment(s), 4 affected',
                             '[Metadata Matching]',
                             '    matrix-job-meta-prod.json -> prod',
                             '    matrix-job-meta-dup-1.json -> dup',
                             '    matrix-job-meta-dup-2.json -> dup',
                             "  WARN: Metadata file 'matrix-job-meta-ghost.json' is for environment 'ghost', which "
                             'the relevance file does not list, not eligible for PR auto merge',
                             "  WARN: Metadata file 'matrix-job-meta-broken.json' is not valid JSON",
                             '  WARN: Skipping invalid metadata file: matrix-job-meta-broken.json',
                             '    matrix-job-meta-staging-ran.json -> staging-ran',
                             "[Environment 'prod']",
                             '  Actor: example-bot[bot]; auto-merge enabled: true',
                             '  Limits: '
                             '{"plan-max-count-add":0,"plan-max-count-change":0,"plan-max-count-destroy":0,"plan-max-count-import":0,"plan-max-count-move":-1,"plan-max-count-remove":0}; '
                             'actors: ["example-bot[bot]"]',
                             '  Configuration validation: PASS',
                             "[Checks of 'prod']",
                             '  PR automerge enabled: PASS',
                             "  Actor 'example-bot[bot]' found in allowed list",
                             '  Actor authorization: PASS',
                             '  Goals granted: ["init","format","validate","lint","plan"]; failed or cancelled '
                             'operations: <none>',
                             '  Plan creation: expected and succeeded - PASS',
                             '  Destroy plan creation: not expected - SKIPPED',
                             '  Apply on PR: not performed - SKIPPED',
                             '  Destroy on PR: not performed - SKIPPED',
                             '  Plan limits: INCLUDED',
                             '  Destroy plan limits: IGNORED (destroy plan was not supposed to be created)',
                             '  Count validation: PASS',
                             '  Add: 0 / 0 - PASS',
                             '  Change: 0 / 0 - PASS',
                             '  Destroy: 0 / 0 - PASS',
                             '  Import: 0 / 0 - PASS',
                             '  Move: 0 / unlimited - PASS',
                             '  Remove: 0 / 0 - PASS',
                             '  No operation failed or was cancelled',
                             '  Operation outcomes: PASS',
                             '  Final eligibility: true',
                             "✅ Environment 'prod' is eligible for automerge",
                             "[Environment 'staging']",
                             '  Actor: example-bot[bot]; auto-merge enabled: true',
                             '  Limits: '
                             '{"plan-max-count-add":0,"plan-max-count-change":0,"plan-max-count-destroy":0,"plan-max-count-import":0,"plan-max-count-move":-1,"plan-max-count-remove":0}; '
                             'actors: ["example-bot[bot]"]',
                             '  Configuration validation: PASS',
                             "[Checks of 'staging']",
                             '  PR automerge enabled: PASS',
                             "  Actor 'example-bot[bot]' found in allowed list",
                             '  Actor authorization: PASS',
                             '  Environment is not affected by this change and no job ran for it',
                             '    Plan creation: NOT AFFECTED',
                             '    Destroy plan creation: NOT AFFECTED',
                             '    Apply on PR: NOT AFFECTED',
                             '    Destroy on PR: NOT AFFECTED',
                             '    Plan limits: NOT AFFECTED',
                             '    Destroy plan limits: NOT AFFECTED',
                             '    Operation outcomes: NOT AFFECTED',
                             '  Final eligibility: true',
                             "✅ Environment 'staging' is eligible for automerge",
                             "[Environment 'nightly']",
                             '  Actor: example-bot[bot]; auto-merge enabled: true',
                             '  Limits: '
                             '{"plan-max-count-add":0,"plan-max-count-change":0,"plan-max-count-destroy":0,"plan-max-count-import":0,"plan-max-count-move":-1,"plan-max-count-remove":0}; '
                             'actors: ["example-bot[bot]"]',
                             '  Configuration validation: PASS',
                             "[Checks of 'nightly']",
                             '  PR automerge enabled: PASS',
                             "  Actor 'example-bot[bot]' found in allowed list",
                             '  Actor authorization: PASS',
                             "  WARN: The change touches 'nightly', which takes no part in pull requests, so it was "
                             'never planned, environment is ineligible for PR auto merge',
                             '  No job ran for the environment, so nothing shows what the change does to it',
                             '    Plan creation: NOT PLANNED',
                             '    Destroy plan creation: NOT PLANNED',
                             '    Apply on PR: NOT PLANNED',
                             '    Destroy on PR: NOT PLANNED',
                             '    Plan limits: NOT PLANNED',
                             '    Destroy plan limits: NOT PLANNED',
                             '    Operation outcomes: NOT PLANNED',
                             '  Final eligibility: false',
                             "❌ Environment 'nightly' is NOT eligible for automerge",
                             "WARN: 'app' was held back: it is in stage 2 and stage 1 failed, so it was never "
                             'planned, environment is ineligible for PR auto merge',
                             "❌ Environment 'app' is NOT eligible for automerge",
                             "WARN: No metadata file for affected environment 'spoke': its job was cancelled or "
                             'failed before capturing metadata, environment is ineligible for PR auto merge',
                             "❌ Environment 'spoke' is NOT eligible for automerge",
                             "WARN: 2 metadata files for environment 'dup', expected exactly one, environment is "
                             'ineligible for PR auto merge',
                             "❌ Environment 'dup' is NOT eligible for automerge",
                             "WARN: Environment 'staging-ran' has a metadata file although the relevance file marks "
                             'it unaffected, judging it on its metadata',
                             "[Environment 'staging-ran']",
                             '  Actor: example-bot[bot]; auto-merge enabled: true',
                             '  Limits: '
                             '{"plan-max-count-add":0,"plan-max-count-change":0,"plan-max-count-destroy":0,"plan-max-count-import":0,"plan-max-count-move":-1,"plan-max-count-remove":0}; '
                             'actors: ["example-bot[bot]"]',
                             '  Configuration validation: PASS',
                             "[Checks of 'staging-ran']",
                             '  PR automerge enabled: PASS',
                             "  Actor 'example-bot[bot]' found in allowed list",
                             '  Actor authorization: PASS',
                             '  Goals granted: ["init","format","validate","lint","plan"]; failed or cancelled '
                             'operations: <none>',
                             '  Plan creation: expected and succeeded - PASS',
                             '  Destroy plan creation: not expected - SKIPPED',
                             '  Apply on PR: not performed - SKIPPED',
                             '  Destroy on PR: not performed - SKIPPED',
                             '  Plan limits: INCLUDED',
                             '  Destroy plan limits: IGNORED (destroy plan was not supposed to be created)',
                             '  Count validation: PASS',
                             '  Add: 0 / 0 - PASS',
                             '  Change: 0 / 0 - PASS',
                             '  Destroy: 0 / 0 - PASS',
                             '  Import: 0 / 0 - PASS',
                             '  Move: 0 / unlimited - PASS',
                             '  Remove: 0 / 0 - PASS',
                             '  No operation failed or was cancelled',
                             '  Operation outcomes: PASS',
                             '  Final eligibility: true',
                             "✅ Environment 'staging-ran' is eligible for automerge",
                             '[Final Summary]',
                             '  Files found: 6',
                             '  Environments in relevance file: 7 (4 affected)',
                             '  Environments processed: 7',
                             '  Environments eligible: 3',
                             '  Environments ineligible: 4',
                             '  Per-environment results:',
                             '    ❓ ghost (not in the relevance file)',
                             '    ⚠️  matrix-job-meta-broken.json (invalid file)',
                             '    ✅ prod',
                             '    ✅ staging (not affected)',
                             '    ❌ nightly (skipped, never planned)',
                             '    ❌ app (held back)',
                             '    ❌ spoke (affected, no metadata)',
                             '    ❌ dup (2 metadata files)',
                             '    ✅ staging-ran',
                             '  ❌ FINAL RESULT: Not all environments eligible - PR CANNOT be automerged',
                             '  Tolerated failing or erroring tests: 0']},
 'an_unknown_goal_and_a_failed_operation': {'eligible': False,
                                            'notices': [],
                                            'fatal': None,
                                            'log': ['Metadata files pattern: matrix-job-meta-*.json',
                                                    'Relevance file: <none>',
                                                    'Test metadata files pattern: terraform-test-meta-*.json',
                                                    '[Test Jobs]',
                                                    '  Found 0 test metadata file(s) matching: '
                                                    'terraform-test-meta-*.json',
                                                    '  Tolerated failing or erroring tests: 0',
                                                    '[File Discovery]',
                                                    '  Found 1 metadata file(s):',
                                                    '    - matrix-job-meta-prod.json',
                                                    "[Environment 'prod']",
                                                    '  Actor: example-bot[bot]; auto-merge enabled: true',
                                                    '  Limits: '
                                                    '{"plan-max-count-add":0,"plan-max-count-change":0,"plan-max-count-destroy":0,"plan-max-count-import":0,"plan-max-count-move":-1,"plan-max-count-remove":0}; '
                                                    'actors: ["example-bot[bot]"]',
                                                    '  Configuration validation: PASS',
                                                    "[Checks of 'prod']",
                                                    '  PR automerge enabled: PASS',
                                                    "  Actor 'example-bot[bot]' found in allowed list",
                                                    '  Actor authorization: PASS',
                                                    '  Goals granted: ["p","l","a","n"]; failed or cancelled '
                                                    'operations: fmt (failure)',
                                                    '  WARN: The metadata\'s goals-granted holds "p", which is not a '
                                                    'goal (init, format, validate, lint, plan, apply, destroy-plan, '
                                                    'destroy), so what the environment should have planned is '
                                                    'unknown, environment is ineligible for PR auto merge',
                                                    '  The goals this run granted are unknown, so no plan-based '
                                                    'check can be judged',
                                                    '    Plan creation: UNKNOWN',
                                                    '    Destroy plan creation: UNKNOWN',
                                                    '    Apply on PR: UNKNOWN',
                                                    '    Destroy on PR: UNKNOWN',
                                                    '    Plan limits: UNKNOWN',
                                                    '    Destroy plan limits: UNKNOWN',
                                                    '  WARN: Terraform operation(s) did not succeed: fmt (failure). '
                                                    'A failure allow-failing-terraform-operations tolerates still '
                                                    'blocks auto-merge, environment is ineligible for PR auto merge',
                                                    '  Operation outcomes: FAIL',
                                                    '  Final eligibility: false',
                                                    "❌ Environment 'prod' is NOT eligible for automerge",
                                                    '[Final Summary]',
                                                    '  Files found: 1',
                                                    '  Environments processed: 1',
                                                    '  Environments eligible: 0',
                                                    '  Environments ineligible: 1',
                                                    '  Per-environment results:',
                                                    '    ❌ prod',
                                                    '  ❌ FINAL RESULT: Not all environments eligible - PR CANNOT be '
                                                    'automerged',
                                                    '  Tolerated failing or erroring tests: 0']},
 'evidence_and_destroy_plan': {'eligible': False,
                               'notices': [],
                               'fatal': None,
                               'log': ['Metadata files pattern: matrix-job-meta-*.json',
                                       'Relevance file: <none>',
                                       'Test metadata files pattern: terraform-test-meta-*.json',
                                       '[Test Jobs]',
                                       '  Found 0 test metadata file(s) matching: terraform-test-meta-*.json',
                                       '  Tolerated failing or erroring tests: 0',
                                       '[File Discovery]',
                                       '  Found 1 metadata file(s):',
                                       '    - matrix-job-meta-prod.json',
                                       "[Environment 'prod']",
                                       '  Actor: example-bot[bot]; auto-merge enabled: true',
                                       '  Limits: '
                                       '{"plan-max-count-add":0,"plan-max-count-change":0,"plan-max-count-destroy":0,"plan-max-count-import":0,"plan-max-count-move":-1,"plan-max-count-remove":0}; '
                                       'actors: ["example-bot[bot]"]',
                                       '  Configuration validation: PASS',
                                       "[Checks of 'prod']",
                                       '  PR automerge enabled: PASS',
                                       "  Actor 'example-bot[bot]' found in allowed list",
                                       '  Actor authorization: PASS',
                                       '  Goals granted: ["plan","destroy-plan"]; failed or cancelled operations: '
                                       '<none>',
                                       '  Plan creation: expected and succeeded - PASS',
                                       '  Destroy plan creation: expected and succeeded - PASS',
                                       '  Apply on PR: not performed - SKIPPED',
                                       '  Destroy on PR: not performed - SKIPPED',
                                       '  Plan limits: INCLUDED',
                                       '  Destroy plan limits: INCLUDED',
                                       "  WARN: The plan of 'prod' is not complete (a -target plan, or changes "
                                       'deferred to a later plan), so its counts do not cover every change',
                                       "  WARN: The destroy plan of 'prod' was not counted from its JSON plan "
                                       '(counts-source: console), so its counts cannot be trusted for auto-merge',
                                       '  Count validation: FAIL',
                                       '  No operation failed or was cancelled',
                                       '  Operation outcomes: PASS',
                                       '  Final eligibility: false',
                                       "❌ Environment 'prod' is NOT eligible for automerge",
                                       '[Final Summary]',
                                       '  Files found: 1',
                                       '  Environments processed: 1',
                                       '  Environments eligible: 0',
                                       '  Environments ineligible: 1',
                                       '  Per-environment results:',
                                       '    ❌ prod',
                                       '  ❌ FINAL RESULT: Not all environments eligible - PR CANNOT be automerged',
                                       '  Tolerated failing or erroring tests: 0']},
 'applied_on_the_pull_request': {'eligible': False,
                                 'notices': [],
                                 'fatal': None,
                                 'log': ['Metadata files pattern: matrix-job-meta-*.json',
                                         'Relevance file: <none>',
                                         'Test metadata files pattern: terraform-test-meta-*.json',
                                         '[Test Jobs]',
                                         '  Found 0 test metadata file(s) matching: terraform-test-meta-*.json',
                                         '  Tolerated failing or erroring tests: 0',
                                         '[File Discovery]',
                                         '  Found 1 metadata file(s):',
                                         '    - matrix-job-meta-prod.json',
                                         "[Environment 'prod']",
                                         '  Actor: example-bot[bot]; auto-merge enabled: true',
                                         '  Limits: '
                                         '{"plan-max-count-add":0,"plan-max-count-change":0,"plan-max-count-destroy":0,"plan-max-count-import":0,"plan-max-count-move":-1,"plan-max-count-remove":0}; '
                                         'actors: ["example-bot[bot]"]',
                                         '  Configuration validation: PASS',
                                         "[Checks of 'prod']",
                                         '  PR automerge enabled: PASS',
                                         "  Actor 'example-bot[bot]' found in allowed list",
                                         '  Actor authorization: PASS',
                                         '  Goals granted: ["plan","apply"]; failed or cancelled operations: apply '
                                         '(failure)',
                                         '  Plan creation: expected and succeeded - PASS',
                                         '  Destroy plan creation: not expected - SKIPPED',
                                         '  WARN: Apply operation on PR was not expected to fail, environment is '
                                         'ineligible for PR auto merge',
                                         '  Destroy on PR: not performed - SKIPPED',
                                         '  Plan limits: IGNORED (apply is being performed on PR)',
                                         '  Destroy plan limits: IGNORED (destroy plan was not supposed to be '
                                         'created)',
                                         '  Skipping count validation and limit evaluation (all limits ignored)',
                                         '  WARN: Terraform operation(s) did not succeed: apply (failure). A failure '
                                         'allow-failing-terraform-operations tolerates still blocks auto-merge, '
                                         'environment is ineligible for PR auto merge',
                                         '  Operation outcomes: FAIL',
                                         '  Final eligibility: false',
                                         "❌ Environment 'prod' is NOT eligible for automerge",
                                         '[Final Summary]',
                                         '  Files found: 1',
                                         '  Environments processed: 1',
                                         '  Environments eligible: 0',
                                         '  Environments ineligible: 1',
                                         '  Per-environment results:',
                                         '    ❌ prod',
                                         '  ❌ FINAL RESULT: Not all environments eligible - PR CANNOT be automerged',
                                         '  Tolerated failing or erroring tests: 0']},
 'no_files': {'eligible': False,
              'notices': [],
              'fatal': None,
              'log': ['Metadata files pattern: matrix-job-meta-*.json',
                      'Relevance file: <none>',
                      'Test metadata files pattern: terraform-test-meta-*.json',
                      '[Test Jobs]',
                      '  Found 0 test metadata file(s) matching: terraform-test-meta-*.json',
                      '  Tolerated failing or erroring tests: 0',
                      '[File Discovery]',
                      '  WARN: No metadata files found matching pattern: matrix-job-meta-*.json',
                      '  Setting is-eligible=false (no files to process)']},
 'a_limits_mapping_that_cannot_be_judged': {'eligible': None,
                                            'notices': [],
                                            'fatal': ["Configuration error: 'plan-max-count-add' value 'x' is not a "
                                                      'valid integer',
                                                      "Configuration error: 'plan-max-count-change' value 'true' is "
                                                      'not a valid integer',
                                                      'Configuration validation failed'],
                                            'log': ['Metadata files pattern: matrix-job-meta-*.json',
                                                    'Relevance file: <none>',
                                                    'Test metadata files pattern: terraform-test-meta-*.json',
                                                    '[Test Jobs]',
                                                    '  Found 0 test metadata file(s) matching: '
                                                    'terraform-test-meta-*.json',
                                                    '  Tolerated failing or erroring tests: 0',
                                                    '[File Discovery]',
                                                    '  Found 1 metadata file(s):',
                                                    '    - matrix-job-meta-prod.json',
                                                    "[Environment 'prod']",
                                                    '  Actor: example-bot[bot]; auto-merge enabled: true',
                                                    '  Limits: '
                                                    '{"plan-max-count-add":"x","plan-max-count-change":true,"plan-max-count-destroy":0,"plan-max-count-import":0,"plan-max-count-move":-1,"plan-max-count-remove":0}; '
                                                    'actors: ["example-bot[bot]"]']},
 'tests': {'eligible': True,
           'notices': ['auto-merge eligible despite the tolerated failing test tests/int-x.tftest.hcl (lane '
                       'integration)'],
           'fatal': None,
           'log': ['Metadata files pattern: matrix-job-meta-*.json',
                   'Relevance file: <none>',
                   'Test metadata files pattern: terraform-test-meta-*.json',
                   '[Test Jobs]',
                   '  Found 4 test metadata file(s) matching: terraform-test-meta-*.json',
                   '    tests/int-x.tftest.hcl (lane integration): fail, tolerated by allow-failing-terraform-tests, '
                   'does not block auto-merge',
                   '  WARN:   tests/int-y.tftest.hcl (lane integration): error and not tolerated; the conclusion '
                   'judges the test jobs, not this step',
                   "  WARN: Test metadata file 'terraform-test-meta-broken.json' is not valid JSON, it names no test",
                   '  Tolerated failing or erroring tests: 1',
                   '[File Discovery]',
                   '  Found 1 metadata file(s):',
                   '    - matrix-job-meta-prod.json',
                   "[Environment 'prod']",
                   '  Actor: example-bot[bot]; auto-merge enabled: true',
                   '  Limits: '
                   '{"plan-max-count-add":0,"plan-max-count-change":0,"plan-max-count-destroy":0,"plan-max-count-import":0,"plan-max-count-move":-1,"plan-max-count-remove":0}; '
                   'actors: ["example-bot[bot]"]',
                   '  Configuration validation: PASS',
                   "[Checks of 'prod']",
                   '  PR automerge enabled: PASS',
                   "  Actor 'example-bot[bot]' found in allowed list",
                   '  Actor authorization: PASS',
                   '  Goals granted: ["init","format","validate","lint","plan"]; failed or cancelled operations: '
                   '<none>',
                   '  Plan creation: expected and succeeded - PASS',
                   '  Destroy plan creation: not expected - SKIPPED',
                   '  Apply on PR: not performed - SKIPPED',
                   '  Destroy on PR: not performed - SKIPPED',
                   '  Plan limits: INCLUDED',
                   '  Destroy plan limits: IGNORED (destroy plan was not supposed to be created)',
                   '  Count validation: PASS',
                   '  Add: 0 / 0 - PASS',
                   '  Change: 0 / 0 - PASS',
                   '  Destroy: 0 / 0 - PASS',
                   '  Import: 0 / 0 - PASS',
                   '  Move: 0 / unlimited - PASS',
                   '  Remove: 0 / 0 - PASS',
                   '  No operation failed or was cancelled',
                   '  Operation outcomes: PASS',
                   '  Final eligibility: true',
                   "✅ Environment 'prod' is eligible for automerge",
                   '[Final Summary]',
                   '  Files found: 1',
                   '  Environments processed: 1',
                   '  Environments eligible: 1',
                   '  Environments ineligible: 0',
                   '  Per-environment results:',
                   '    ✅ prod',
                   '  ✅ FINAL RESULT: All environments eligible - PR CAN be automerged',
                   '  Tolerated failing or erroring tests: 1']},
 'relevance_missing_on_disk': {'eligible': True,
                               'notices': [],
                               'fatal': None,
                               'log': ['Metadata files pattern: matrix-job-meta-*.json',
                                       'Relevance file: relevance.json',
                                       'Test metadata files pattern: <none>',
                                       "WARN: Relevance file 'relevance.json' does not exist, evaluating the "
                                       'metadata files alone',
                                       '[Test Jobs]',
                                       '  No test metadata files pattern, no test job is named',
                                       '[File Discovery]',
                                       '  Found 1 metadata file(s):',
                                       '    - matrix-job-meta-prod.json',
                                       "[Environment 'prod']",
                                       '  Actor: example-bot[bot]; auto-merge enabled: true',
                                       '  Limits: '
                                       '{"plan-max-count-add":0,"plan-max-count-change":0,"plan-max-count-destroy":0,"plan-max-count-import":0,"plan-max-count-move":-1,"plan-max-count-remove":0}; '
                                       'actors: ["example-bot[bot]"]',
                                       '  Configuration validation: PASS',
                                       "[Checks of 'prod']",
                                       '  PR automerge enabled: PASS',
                                       "  Actor 'example-bot[bot]' found in allowed list",
                                       '  Actor authorization: PASS',
                                       '  Goals granted: ["init","format","validate","lint","plan"]; failed or '
                                       'cancelled operations: <none>',
                                       '  Plan creation: expected and succeeded - PASS',
                                       '  Destroy plan creation: not expected - SKIPPED',
                                       '  Apply on PR: not performed - SKIPPED',
                                       '  Destroy on PR: not performed - SKIPPED',
                                       '  Plan limits: INCLUDED',
                                       '  Destroy plan limits: IGNORED (destroy plan was not supposed to be created)',
                                       '  Count validation: PASS',
                                       '  Add: 0 / 0 - PASS',
                                       '  Change: 0 / 0 - PASS',
                                       '  Destroy: 0 / 0 - PASS',
                                       '  Import: 0 / 0 - PASS',
                                       '  Move: 0 / unlimited - PASS',
                                       '  Remove: 0 / 0 - PASS',
                                       '  No operation failed or was cancelled',
                                       '  Operation outcomes: PASS',
                                       '  Final eligibility: true',
                                       "✅ Environment 'prod' is eligible for automerge",
                                       '[Final Summary]',
                                       '  Files found: 1',
                                       '  Environments processed: 1',
                                       '  Environments eligible: 1',
                                       '  Environments ineligible: 0',
                                       '  Per-environment results:',
                                       '    ✅ prod',
                                       '  ✅ FINAL RESULT: All environments eligible - PR CAN be automerged',
                                       '  Tolerated failing or erroring tests: 0']},
 'relevance_unusable': {'eligible': False,
                        'notices': [],
                        'fatal': None,
                        'log': ['Metadata files pattern: matrix-job-meta-*.json',
                                'Relevance file: relevance.json',
                                'Test metadata files pattern: terraform-test-meta-*.json',
                                '[Test Jobs]',
                                '  Found 0 test metadata file(s) matching: terraform-test-meta-*.json',
                                '  Tolerated failing or erroring tests: 0',
                                '[File Discovery]',
                                '  Found 1 metadata file(s):',
                                '    - matrix-job-meta-prod.json',
                                '[Relevance File]',
                                "  WARN: Relevance file 'relevance.json' has 1 malformed environment entr(y/ies): "
                                "each needs a non-empty 'github-environment' and a 'verdict' of 'run' or 'skip', and "
                                "'relevant' is a boolean, 'reasons' a list of text and 'trigger-events' a list where "
                                'given',
                                "  WARN: Relevance file 'relevance.json' is unusable, the environments of this run "
                                'are unknown, not eligible for PR auto merge',
                                '[Final Summary]',
                                '  Files found: 1',
                                '  Environments processed: 0',
                                '  Environments eligible: 0',
                                '  Environments ineligible: 0',
                                '  Per-environment results:',
                                '  ❌ FINAL RESULT: Not all environments eligible - PR CANNOT be automerged',
                                '  Tolerated failing or erroring tests: 0']},
 'relevance_empty': {'eligible': False,
                     'notices': [],
                     'fatal': None,
                     'log': ['Metadata files pattern: matrix-job-meta-*.json',
                             'Relevance file: relevance.json',
                             'Test metadata files pattern: terraform-test-meta-*.json',
                             '[Test Jobs]',
                             '  Found 0 test metadata file(s) matching: terraform-test-meta-*.json',
                             '  Tolerated failing or erroring tests: 0',
                             '[File Discovery]',
                             '  Found 0 metadata file(s):',
                             '[Relevance File]',
                             "  WARN: Relevance file 'relevance.json' lists no environments, nothing establishes "
                             'that auto-merge is permitted, not eligible for PR auto merge',
                             '[Final Summary]',
                             '  Files found: 0',
                             '  Environments in relevance file: 0 (0 affected)',
                             '  Environments processed: 0',
                             '  Environments eligible: 0',
                             '  Environments ineligible: 0',
                             '  Per-environment results:',
                             '  ❌ FINAL RESULT: Not all environments eligible - PR CANNOT be automerged',
                             '  Tolerated failing or erroring tests: 0']}}


class ScenarioTest(unittest.TestCase):
    def test_every_scenario_logs_exactly_what_it_should(self):
        for name, scenario in SCENARIOS.items():
            with self.subTest(scenario=name):
                verdict = ap.evaluate(scenario)
                self.assertEqual(EXPECTED[name], {"eligible": verdict["eligible"], "notices": verdict["notices"],
                                                  "fatal": verdict["fatal"], "log": render(verdict)})



class ReaderTest(unittest.TestCase):
    """The small readers, as the bash evaluator's jq read the same values."""

    def test_the_log_is_data(self):
        log = ap.Log()
        log.line("a")
        with log.group("G"):
            log.warn("b")
        log.line("c")
        with self.assertRaises(ValueError):
            with log.group("H"):
                raise ValueError
        log.warn("d")
        self.assertEqual([("line", "a"), ("group", "G", [("warn", "b")]), ("line", "c"), ("group", "H", []),
                          ("warn", "d")], log.entries)

    def test_raw_is_jq_r_of_a_path_or_empty(self):
        cases = [(None, ""), (False, ""), (True, "true"), ("x", "x"), (5, "5"), (1.5, "1.5"), ([1, "a"], '[1,"a"]'),
                 ({"a": 1}, '{"a":1}'), ("ä", "ä"), ({"ä": "ø"}, '{"ä":"ø"}')]
        for value, text in cases:
            with self.subTest(value=value):
                self.assertEqual(text, ap.raw(value))

    def test_failed_operations(self):
        cases = [({"steps": "x"}, "steps (unreadable)"), ({"steps": [1]}, "steps (unreadable)"), ([1], ""),
                 ({"steps": None}, ""), ({"steps": False}, ""), ({"steps": {"init": {"outcome": 7}}}, ""),
                 ({"steps": {"init": {"outcome": ["failure"]}}}, ""), ({"steps": {"init": "failure"}}, ""),
                 ({"steps": {"init": {"outcome": False}}}, ""),
                 ({"steps": {"fmt": {"outcome": "failure"}, "lint": {"outcome": "cancelled"}, "plan": {"outcome": "skipped"},
                             "destroy": {"outcome": "failure"}, "custom": {"outcome": "failure"}}},
                  "fmt (failure), lint (cancelled), destroy (failure)")]
        for content, text in cases:
            with self.subTest(content=content):
                self.assertEqual(text, ap.environment_facts(content)["failed"] if isinstance(content, dict)
                                 else ap.environment_facts(content)["failed"])

    def test_the_goals(self):
        cases = [({}, "The metadata has no goals-granted"), ({"goals-granted": "plan"}, 'goals-granted is "plan", not a list'),
                 ({"goals-granted": ["plan", 7]}, "goals-granted holds 7, which is not a goal"),
                 ({"goals-granted": ["plan", "all"]}, 'goals-granted holds "all", which is not a goal'),
                 ({"goals-granted": ["plan", "apply"]}, "")]
        for variables, problem in cases:
            with self.subTest(variables=variables):
                facts = ap.environment_facts({"matrix_context": {"vars": variables}})
                self.assertEqual(problem == "", facts["goals_problem"] == "")
                self.assertIn(problem, facts["goals_problem"])
        self.assertIn("has no goals-granted", ap.environment_facts({"matrix_context": {"vars": "x"}})["goals_problem"])
        self.assertEqual((True, True), (ap.environment_facts({"matrix_context": {"vars": {"goals-granted": ["plan", "apply"]}}})[
            "plan"]["expected"], ap.environment_facts({"matrix_context": {"vars": {"goals-granted": ["plan", "apply"]}}})[
            "plan"]["on_pr"]))
        self.assertFalse(ap.environment_facts({"matrix_context": {"vars": {"goals-granted": "plan"}}})["plan"]["expected"])

    def test_the_settings(self):
        facts = ap.environment_facts({"matrix_context": {"vars": {"pr-auto-merge-enabled": True,
                                                                  "pr-auto-merge-limits": None,
                                                                  "pr-auto-merge-from-actors": False}}})
        self.assertEqual(("true", {}, False), (facts["enabled"], facts["limits"], facts["actors"]))
        self.assertEqual(("false", {}, None), (ap.environment_facts({})["enabled"], ap.environment_facts({})["limits"],
                                               ap.environment_facts({})["actors"]))
        self.assertEqual({}, ap.environment_facts({"matrix_context": {"vars": {"pr-auto-merge-limits": False}}})["limits"])

    def test_the_metadata_files(self):
        def entry(content, readable=True, valid=True):
            return {"file": "m.json", "readable": readable, "json": valid, "content": content}
        cases = [(entry(None, readable=False, valid=False), "Metadata file 'm.json' does not exist or is not readable"),
                 (entry(None, valid=False), "Metadata file 'm.json' is not valid JSON"),
                 (entry([1]), "Metadata file 'm.json' is missing .metadata.environment field"),
                 (entry({"metadata": {"environment": False}}), "Metadata file 'm.json' is missing .metadata.environment field"),
                 (entry({"metadata": {"environment": "a"}}), "Metadata file 'm.json' is missing .matrix_context.vars field"),
                 (entry({"metadata": {"environment": "a"}, "matrix_context": [1]}),
                  "Metadata file 'm.json' is missing .matrix_context.vars field"),
                 (entry({"metadata": {"environment": "a"}, "matrix_context": {"vars": False}}),
                  "Metadata file 'm.json' is missing .matrix_context.vars field"),
                 (entry({"metadata": {"environment": 5}, "matrix_context": {"vars": 0}}), None),
                 (entry({"metadata": {"environment": "a"}, "matrix_context": {"vars": {}}}), None)]
        for item, problem in cases:
            with self.subTest(item=item):
                self.assertEqual(problem, ap.metadata_problem(item))

    def test_the_relevance_file(self):
        def entry(content, readable=True, valid=True):
            return {"file": "r.json", "readable": readable, "json": valid, "content": content}
        good = {"github-environment": "a", "verdict": "run"}
        malformed = [7, {**good, "github-environment": ""}, {**good, "github-environment": 1}, {**good, "verdict": "go"},
                     {**good, "relevant": "yes"}, {**good, "reasons": "x"}, {**good, "reasons": ["x", 1]},
                     {**good, "trigger-events": "push"}]
        for item in malformed:
            with self.subTest(item=item):
                self.assertIn("has 1 malformed environment entr(y/ies)", ap.relevance_problem(entry({"environments": [item]})))
        self.assertEqual("Relevance file 'r.json' is not readable", ap.relevance_problem(entry(None, readable=False)))
        self.assertEqual("Relevance file 'r.json' is not valid JSON", ap.relevance_problem(entry(None, valid=False)))
        self.assertEqual("Relevance file 'r.json' has no 'environments' list", ap.relevance_problem(entry([1])))
        self.assertEqual("Relevance file 'r.json' has no 'environments' list", ap.relevance_problem(entry({"environments": {}})))
        duplicated = {"environments": [good, {**good, "github-environment": "b"}, good, {**good, "github-environment": "b"}]}
        self.assertEqual("Relevance file 'r.json' lists these github-environments more than once: a, b",
                         ap.relevance_problem(entry(duplicated)))
        valid = {"environments": [{**good, "relevant": False, "reasons": ["x"], "trigger-events": ["push"]}]}
        self.assertIsNone(ap.relevance_problem(entry(valid)))

    def test_why_a_skip_was_never_planned(self):
        base = {"environment": "nightly", "github-environment": "nightly-gh", "verdict": "skip"}
        cases = [({**base, "relevant": True, "trigger-events": ["push"]},
                  "The change touches 'nightly', which takes no part in pull requests, so it was never planned, "
                  "environment is ineligible for PR auto merge"),
                 ({**base, "relevant": True, "reasons": ["trigger-events: pull_request not in [push]"]},
                  "The change touches 'nightly', which takes no part in pull requests, so it was never planned, "
                  "environment is ineligible for PR auto merge"),
                 ({**base, "relevant": True, "reasons": ["dispatch: not the requested environment"]},
                  "The change touches 'nightly', which was skipped (dispatch: not the requested environment), so it was "
                  "never planned, environment is ineligible for PR auto merge"),
                 ({**base, "trigger-events": ["push"]},
                  "'nightly' takes no part in pull requests and the relevance file does not say whether the change touches "
                  "it, so it may never have been planned, environment is ineligible for PR auto merge"),
                 ({**base, "relevant": False, "trigger-events": ["push"]}, ""),
                 ({**base, "trigger-events": ["push", "pull_request"]}, ""),
                 ({**base}, "")]
        for item, reason in cases:
            with self.subTest(item=item):
                self.assertEqual(reason, ap.unplanned_reason(item))
        self.assertIn("'nightly-gh' takes no part", ap.unplanned_reason({**base, "environment": None, "trigger-events": []}))
        self.assertIn("'7' takes no part", ap.unplanned_reason({**base, "environment": 7, "trigger-events": []}))
        self.assertIn("'[\"x\"]' takes no part", ap.unplanned_reason({**base, "environment": ["x"], "trigger-events": []}))
        self.assertIn("'nightly-gh' takes no part", ap.unplanned_reason({**base, "environment": "", "trigger-events": []}))

    def test_the_stage_results(self):
        cases = [("", None), ("  \n", None), ("x", False), ("[1]", False),
                 ('{"1": "success", "2": 3, "3": "skipped"}', {"1": "success", "3": "skipped"})]
        for text, value in cases:
            with self.subTest(text=text):
                self.assertEqual(value, ap.stage_results(text))

    def test_the_environments_a_failed_stage_held_back(self):
        def content(*environments, by_stage=None):
            return {"environments": list(environments), "counts": {"by_stage": by_stage if by_stage is not None
                                                                   else {"2": 1, "3": 1}}}
        app = {"github-environment": "app", "verdict": "run", "stage": 2}
        self.assertEqual({"app": "'app' was held back: it is in stage 2 and stage 1 failed, so it was never planned, "
                                 "environment is ineligible for PR auto merge"},
                         ap.held_back(content(app), {"1": "failure", "2": "skipped"}))
        self.assertEqual({"app": "'app' was held back: it is in stage 3 and stage 2 was cancelled, so it was never "
                                 "planned, environment is ineligible for PR auto merge"},
                         ap.held_back(content({**app, "stage": "3"}), {"1": "success", "2": "cancelled", "3": "skipped"}))
        self.assertEqual({"app": "'app' was held back: it is in stage 2, which did not run, so it was never planned, "
                                 "environment is ineligible for PR auto merge"},
                         ap.held_back(content(app), {"1": "success", "2": "skipped"}))
        for item, results, by_stage in ((app, {"2": "success"}, None), (app, {"1": "failure", "2": "skipped"}, {"2": 0}),
                                        ({**app, "verdict": "skip"}, {"1": "failure", "2": "skipped"}, None),
                                        ({**app, "stage": 1}, {"1": "skipped"}, {"1": 1}),
                                        ({**app, "stage": "x"}, {"1": "skipped"}, {"1": 1}),
                                        ({**app, "stage": None}, {"1": "skipped"}, {"1": 1})):
            with self.subTest(item=item, results=results):
                self.assertEqual({}, ap.held_back(content(item, by_stage=by_stage), results))
        self.assertEqual({}, ap.held_back({"environments": [app], "counts": []}, {"1": "failure", "2": "skipped"}))
        self.assertIn("app", ap.held_back(content(app, by_stage={"2": "1.5"}), {"1": "failure", "2": "skipped"}))
        # As jq: a stage of 2.0 reads "2.0", which names no stage result.
        self.assertEqual({}, ap.held_back(content({**app, "stage": 2.0}), {"1": "failure", "2": "skipped"}))
        self.assertEqual({"app": "'app' was held back: it is in stage 2.0 and stage 1 failed, so it was never planned, "
                                 "environment is ineligible for PR auto merge"},
                         ap.held_back(content({**app, "stage": 2.0}, by_stage={"2.0": 1}),
                                      {"1": "failure", "2.0": "skipped"}))
        # Without a stage an environment is in the first; a stage the counts do not list held nothing back.
        stageless = {"github-environment": "app", "verdict": "run"}
        self.assertEqual({}, ap.held_back(content(stageless, by_stage={"1": 1, "2": 1}), {"1": "skipped", "2": "skipped"}))
        self.assertEqual({}, ap.held_back(content(app, by_stage={}), {"1": "failure", "2": "skipped"}))
        # Only the stages before it can have held an environment back.
        self.assertEqual({"app": "'app' was held back: it is in stage 2, which did not run, so it was never planned, "
                                 "environment is ineligible for PR auto merge"},
                         ap.held_back(content(app), {"0": "failure", "1": "success", "2": "skipped"}))

    def test_jq_tonumber(self):
        cases = [(True, 9), (None, 9), (3, 3), (2.5, 2.5), ("2", 2), ("2.5", 2.5), ("x", 9), ([1], 9), ("1.x", 9)]
        for value, number in cases:
            with self.subTest(value=value):
                self.assertEqual(number, ap._number(value, 9))
        self.assertEqual((float, "1e+20"), (type(ap._number(1e20, 9)), str(ap._number(1e20, 9))))

    def test_the_failing_tests(self):
        def job(status, test=None, environment=None):
            return {"content": {"metadata": {"environment": environment} if environment is not None else {},
                                "matrix_context": {"test": test} if test is not None else {},
                                "steps": {"test": {"outputs": {"status": status}}}}}
        cases = [(job("pass", {"file": "a"}), []), (job(None), []), (job(["fail"]), []),
                 (job("fail", {"file": "t.hcl", "lane": "unit", "allow-failing-terraform-tests": True}),
                  [(True, "fail", "t.hcl", "unit")]),
                 (job("error", {"file": "t.hcl", "allow-failing-terraform-tests": "true"}), [(True, "error", "t.hcl", "")]),
                 (job("fail", {"file": "", "lane": 5}, environment="root--int"), [(False, "fail", "root--int", "5")]),
                 (job("fail", {}, environment=7), [(False, "fail", "7", "")]),
                 (job("fail", {"file": False}), [(False, "fail", "unknown test", "")]),
                 (job("fail", {"file": {"a": 1}}), [(False, "fail", '{"a":1}', "")]),
                 (job("fail", environment="root--int"), [(False, "fail", "root--int", "")]),
                 (job("fail", [1], environment=["e"]), [(False, "fail", '["e"]', "")]),
                 ({"content": [1]}, [])]
        for item, found in cases:
            with self.subTest(item=item):
                self.assertEqual(found, ap.failing_tests([item]))

    def test_a_count_that_is_not_a_number_judges_nothing(self):
        verdict = ap.evaluate(facts([meta("prod", counts={**ZERO, "add": "", "move": "null"})]))
        self.assertIn("  WARN: Required plan counts are missing or invalid. Plan parsing may have failed, environment is "
                      "ineligible for PR auto merge", render(verdict))
        self.assertNotIn("  Add: 0 / 0 - PASS", render(verdict))

    def test_counts_that_cannot_be_trusted_judge_no_limit(self):
        for metadata in (meta("prod", source=""), meta("prod", complete=""), meta("prod", complete="false")):
            with self.subTest(metadata=metadata["content"]["steps"]["parse-plan"]["outputs"]):
                log = render(ap.evaluate(facts([metadata])))
                self.assertIn("  Count validation: FAIL", log)
                self.assertNotIn("  Add: 0 / 0 - PASS", log)
        self.assertIn("  Count validation: PASS", render(ap.evaluate(facts([meta("prod")]))))

    def test_actors_that_admit_nobody(self):
        cases = [(None, "is null, not a list of logins"), (False, "is false, not a list of logins"),
                 ("example-bot[bot]", 'is "example-bot[bot]", not a list of logins'), ([], "names nobody"),
                 ([7, ""], "names nobody"), (["octocat"], "Actor 'example-bot[bot]' is not authorized for PR automerge")]
        for actors, reason in cases:
            with self.subTest(actors=actors):
                verdict = ap.evaluate(facts([meta("prod", **{"pr-auto-merge-from-actors": actors})]))
                self.assertFalse(verdict["eligible"])
                self.assertTrue(any(reason in line for line in render(verdict)))
        self.assertTrue(ap.evaluate(facts([meta("prod", **{"pr-auto-merge-from-actors": ["Example-Bot[BOT]"]})]))["eligible"])

    def test_disabled_and_a_destroy_on_the_pull_request(self):
        verdict = ap.evaluate(facts([meta("prod", goals=("destroy-plan", "destroy"), **{"pr-auto-merge-enabled": False},
                                         steps={"destroy-plan": {"outcome": "failure"}, "destroy": {"outcome": "success"}})]))
        log = render(verdict)
        for line in ("  WARN: PR automerge is disabled for this environment",
                     "  WARN: Destroy plan was expected to have been created but was not, environment is ineligible for PR "
                     "auto merge", "  Destroy on PR: performed and succeeded - PASS",
                     "  Plan limits: IGNORED (plan was not supposed to be created)",
                     "  Destroy plan limits: IGNORED (destroy is being performed on PR)"):
            with self.subTest(line=line):
                self.assertIn(line, log)
        destroyed = render(ap.evaluate(facts([meta("prod", goals=("destroy-plan", "destroy"),
                                                    steps={"destroy-plan": {"outcome": "success"},
                                                           "destroy": {"outcome": "failure"}})])))
        self.assertIn("  WARN: Destroy operation on PR was not expected to fail, environment is ineligible for PR auto merge",
                      destroyed)
        missing = render(ap.evaluate(facts([meta("prod", steps={"plan": {"outcome": "failure"}})])))
        self.assertIn("  WARN: Plan was expected to have been created but was not, environment is ineligible for PR auto "
                      "merge", missing)
        self.assertIn("  WARN: The plan of 'prod' does not say it is complete (no plan-complete), so its counts may not "
                      "cover every change", render(ap.evaluate(facts([meta("prod", complete="")]))))
        self.assertIn("  WARN: The plan of 'prod' was not counted from its JSON plan (no counts-source), so its counts "
                      "cannot be trusted for auto-merge", render(ap.evaluate(facts([meta("prod", source="")]))))
        limits = {**LIMITS, "plan-max-count-add": "5"}
        self.assertIn("  Add: 0 / 5 - PASS", render(ap.evaluate(facts([meta("prod", **{"pr-auto-merge-limits": limits})]))))
        self.assertIn("Configuration error: 'plan-max-count-add' is missing, null, or empty",
                      ap.evaluate(facts([meta("prod", **{"pr-auto-merge-limits": "x"})]))["fatal"])
        self.assertIn("Configuration error: 'plan-max-count-add' is missing, null, or empty",
                      ap.evaluate(facts([meta("prod", **{"pr-auto-merge-limits": {**LIMITS, "plan-max-count-add": "null"}})]))[
                          "fatal"])

    def test_an_invalid_file_without_relevance(self):
        verdict = ap.evaluate(facts([{"file": "matrix-job-meta-x.json", "readable": True, "json": False, "content": None},
                                     meta("prod")]))
        self.assertFalse(verdict["eligible"])
        self.assertIn("WARN: Metadata file 'matrix-job-meta-x.json' is not valid JSON", render(verdict))
        self.assertIn("WARN: Skipping invalid metadata file: matrix-job-meta-x.json", render(verdict))
        self.assertIn("    ⚠️  matrix-job-meta-x.json (invalid file)", render(verdict))

    def test_the_notices(self):
        refused = ap.evaluate(facts([meta("prod", **{"pr-auto-merge-enabled": False})],
                                    tests=[test_job("int-x", "error", True, lane="")]))
        self.assertEqual(["The tolerated erroring test tests/int-x.tftest.hcl does not block auto-merge; the pull request "
                          "is not eligible for other reasons"], refused["notices"])
        none = ap.evaluate(facts([], tests=[test_job("int-x", "fail", True)]))
        self.assertEqual(["The tolerated failing test tests/int-x.tftest.hcl (lane integration) does not block auto-merge; "
                          "the pull request is not eligible for other reasons"], none["notices"])
