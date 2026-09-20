# The decision engine

Authoritative spec for the one place that decides what a run of
[`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml) does: which
environments and test files take part, with which goals, why, and what the pull request, the run
summary and the conclusion are told about it. Today that logic is spread over bash and `jq` in
`create-tf-vars-matrix`, `create-tftest-matrix` and step conditions in the workflow. This spec
moves it into a single Python core with a JSON contract, a decision record as output, a set of
invariants, and a coverage gate at 100 percent.

Status: **specification, not yet implemented.** The port of today's behaviour (§9) comes before any
of the features that depend on the engine: [Terraform-tests.md](Terraform-tests.md),
[Path-relevance.md](Path-relevance.md) and [Dispatch-and-triggers.md](Dispatch-and-triggers.md).
§13 is reserved for what implementation teaches the spec.

## 1. Why

The matrix builder started as a loop that copied workflow inputs into per-environment rows. Three
specs now put real decisions in front of that loop: which environments a change is relevant to,
which test files run in which lane against which provider set, and which environment a dispatch
targets with which goal, and in which order those environments apply. Every one of those decisions can cause a
mutating Terraform operation to run, or not run, against a real tenant. The failure the maintainer
named is the right one to design against: a manual reconcile of a non-production environment that
ends up applying production.

Bash and `jq` cannot carry that responsibility. They cannot be measured for coverage in any
meaningful way, every branch is a string comparison in a step condition or a `jq` filter, and the
existing tests run the extracted step source against six fixtures. The decision core therefore
becomes a small Python program with one input document and one output document, tested by tables,
by generated combinations, and by invariants that hold over every case, with a coverage gate that
fails the suite below 100 percent of lines and branches.

## 2. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | The core is **Python 3.10 or later, standard library only**. No third-party runtime dependency. | Present on every GitHub-hosted image and on practically every Linux runner; no build step; nothing to install at run time. The alternatives were weighed: a TypeScript Node action needs no runtime at all but a committed bundle and Node deprecation churn; Go and Deno lose on distribution. |
| D2 | **JSON in, JSON out.** YAML parsing stays in the composite shims (`yq`), API calls stay in adapters; the core never reads the network, the clock or the environment. | Purity is what makes every case a fixture. PyYAML is not guaranteed on self-hosted runners. |
| D3 | **Port first.** The engine reproduces today's `create-tf-vars-matrix` output for every existing fixture and for the real input shapes of the calling repositories before any feature lands on it. | One reviewable migration with a hard safety net, instead of writing each feature's logic twice. |
| D4 | **100 percent line and branch coverage**, enforced by the suite, from the first commit of the core. | The core is small and every branch is a production decision. A branch nobody tested is a branch nobody intended. |
| D5 | **Invariants** are checked on every table case, every generated case and every random case. | Fixtures cover what someone thought of; invariants catch the rest. |
| D6 | The engine emits a **decision record**: per environment and test file, the verdict, the goals granted and the ordered rules that produced them. The run summary prints it. | A wrong decision is visible on the run page before it is visible in Azure. |
| D7 | The test matrix (lanes, environments, provider sets) and the relevance and dispatch decisions live in the same core as the environment matrix. | They share the event model, the fork rule, the glob matcher and the invariants; splitting them would split the guarantees. |
| D8 | The engine **never fails open silently and never fails closed silently**: every drop of an environment or file carries a reason, and validation errors stop the run with a message. | Reasons are the contract with the reader of the run summary. |
| D9 | Row variables keep **today's types**: a forwarded workflow input is a string (`"true"`, `"5"`), a per-environment YAML value keeps the type YAML gave it, and only `allow-failing-terraform-operations` is a JSON boolean. Typed values live in `workflow_inputs` and in the engine's own decisions. | The workflow's gates compare strings (`== 'true'`), and GitHub's expression rules make `true == 'true'` false. The port pins the current types; retyping is a separate, deliberate change (P11). |
| D10 | Granted goals reach the workflow through a new row variable **`goals-granted`** (the eight-goal vocabulary, no `all`, no `-on-pr`); `vars.goals` stays the raw list. | Three renderers read the raw list for `apply-on-pr`; the operation gates switch to `goals-granted` so a dispatch cap can remove `apply`, with their event and branch clauses kept as defence in depth. |
| D11 | The engine ships as the core of the **v1** major release; `v0` keeps the bash builder. | The features on top of it change defaults (relevance, tests, schedule); a rolling major tag cannot carry them. [Road-to-v1.md](Road-to-v1.md). |

## 3. Where it lives and how it is called

```
engine/
├── dsb_tf_engine/            # the package; stdlib only
│   ├── __init__.py
│   ├── __main__.py           # python3 -m dsb_tf_engine <command> --input <file> --output <file>
│   ├── model.py              # dataclasses for the input and output documents, validation
│   ├── events.py             # event kind, branch facts, fork and dependabot rules
│   ├── globs.py              # the one glob matcher (Terraform-tests.md §4.4 grammar)
│   ├── relevance.py          # Path-relevance.md §4-§5
│   ├── environments.py       # environment rows, goals, trigger events, dispatch
│   ├── tests.py              # test roots, lanes, environments, provider sets
│   ├── comments.py           # which heads and tags the seed job creates or purges
│   └── record.py             # the decision record and its rendering for the run summary
├── run_all_tests.sh          # the canonical suite entry (§8), at the depth discovery expects
└── tests/
    ├── run_tests.py          # unittest discovery; prints the canonical summary lines on stdout
    ├── test_*.py             # unittest modules
    ├── cases/<name>/input.json, expected.json     # table cases
    ├── generate_cases.py     # combinatorial generator, deterministic
    └── invariants.py         # the checks of §7, importable by every test
```

Composite actions call it with the repository checked out at the action's ref, which is always the
case for an action referenced as `dsb-norge/github-actions-terraform/<action>@<ref>`: GitHub
downloads the whole repository at that ref, and a preview ref publishes the whole tree at one
commit, so shim and engine are never at different versions.

```bash
# Decide the environment and test matrices for this run
PYTHONPATH="${{ github.action_path }}/../engine" \
  python3 -B -m dsb_tf_engine decide --input "${input_file}" --output "${output_file}"
```

`-B` keeps `__pycache__` out of the actions directory. The engine is the one thing in the tree that
an action reaches outside its own directory; the implementation guide's self-containment rule gets
a paragraph saying so.

The shim's job is everything the core must not do: parse the `*-yml` inputs with `yq` into JSON,
gather event facts from the `github` context, check that each `project-dir` exists, call adapters
for the network (§3.1), write the input document to a temp file, run the engine, and turn the output
document into `$GITHUB_OUTPUT` lines and artifacts. Large data, the changed-file list above all,
travels as a file path inside the input document, never inline (P5 of the relevance spec). The
shim never exports its input heredocs.

### 3.1 Adapters

Two adapters fetch facts and report them raw; they decide nothing:

- `resolve-changed-files` calls the pull request or compare endpoints and reports `{available,
  truncated, error, files_path}` plus the pull request's live head SHA; the engine turns that into a
  relevance mode and reason (Path-relevance.md §4.2).
- `create-tftest-matrix` lists committed test files, the directories that hold `.tf` files, and the
  environments' lock files by `project-dir`; the engine derives roots, lanes, environments and
  provider sets and validates them. Its existing `all-tests` output stays for the module CI
  workflow until that migrates.

The caller's default branch comes from `github.event.repository.default_branch` when the payload
carries it, with `gh api` through a temp file as the fallback (the current `curl` degrades to
`null` on error, P6 of the relevance spec). An adapter that fails reports the failure in its fields
and exits zero. The engine decides whether a failure is fail-open (relevance) or a validation error
(a lock file that cannot be parsed).

### 3.2 Commands

| Command | Input | Output | Used by |
|---|---|---|---|
| `decide` | the full input document | the full output document | `create-matrix` job |
| `validate` | the input document without the adapter sections | validation errors only, exit 2 when any | the same job, on a partial document built from the event and the inputs, before the adapters run, so a configuration error is reported before any API call |
| `render-summary` | an output document | Markdown for the run summary | `create-matrix` and the conclusion |

Exit codes: 0 success, 2 validation error (message on stderr, structured errors in the output
document), 1 crash. The engine writes nothing to stdout except when asked to print; logs go to
stderr.

## 4. The input document

```json
{
  "schema_version": 1,
  "caller": { "repository": "owner/repo", "workflow_name": "Terraform CI/CD", "default_branch": "main" },
  "run": { "id": 4711, "attempt": 1 },
  "event": {
    "name": "pull_request",
    "action": "synchronize",
    "ref_name": "feature/x",
    "actor": "octocat",
    "triggering_actor": "octocat",
    "push": { "before": "…", "after": "…", "created": false, "forced": false, "deleted": false },
    "pull_request": { "number": 87, "base_ref": "main", "head_sha": "…", "api_head_sha": "…", "is_fork": false, "changed_files_count": 3, "draft": false },
    "dispatch_inputs": { "environment": "", "goal": "", "reason": "" }
  },
  "workflow_inputs": { "goals-yml": ["all"], "environments-yml": [ … ], "path-relevance-enabled": true, … },
  "directories_exist": { "envs/prod": true, "envs/staging": true },
  "changed_files": { "available": true, "truncated": false, "error": null, "files_path": "/tmp/changed-files.txt" },
  "tests": {
    "files": ["tests/unit-net.tftest.hcl", "modules/net/tests/unit-net.tftest.hcl"],
    "directories_with_tf": ["modules/net", "main", "envs/prod"],
    "environment_locks": { "envs/prod": { "hashicorp/azurerm": "4.30.0", … }, "envs/staging": null }
  }
}
```

- `workflow_inputs` carries every workflow input, with the `*-yml` fields already parsed and
  booleans as booleans; the shim normalises the strings GitHub hands it. Row variables are typed
  separately (D9).
- `dispatch_inputs` are strings, as GitHub delivers them; when the caller declares no `inputs:`
  block the payload key is `null` and the shim passes an empty object.
- Only the sections a command needs must be present; an absent `tests` section means "no test
  stage", an absent `changed_files` means "relevance not computed".
- Secrets never enter the document. Whether secrets are available is derived by the engine from
  `is_fork` and `actor == 'dependabot[bot]'`, one rule in one place; secret names appear only as
  names inside lane definitions.
- `environment_locks` is keyed by `project-dir`, because two environments may share one.

## 5. The output document

```json
{
  "schema_version": 1,
  "errors": [],
  "notices": ["relevance diff (pull request #87, 3 changed files): 1 of 3 environments affected"],
  "relevance": { "mode": "diff", "reason": "diff", "changed_count": 3 },
  "environments": [
    { "environment": "prod", "verdict": "run", "reasons": ["trigger-events: pull_request", "relevance: envs/prod/**", "ordering: stage 2"],
      "stage": 2, "depends_on": ["shared"],
      "goals": ["init","format","validate","lint","plan"], "vars": { … the matrix row vars … } },
    { "environment": "staging", "verdict": "skip", "reasons": ["relevance: no changed file matches"], "goals": [], "vars": { … } }
  ],
  "matrices": { "1": { "environment": ["shared"], "include": [ … ] }, "2": { "environment": ["prod"], "include": [ … ] }, "3": { "environment": [], "include": [] } },
  "counts": { "affected": 2, "unaffected": 1, "by_stage": { "1": 1, "2": 1, "3": 0 } },
  "ordering": { "enabled": true, "stages_used": 2, "cap": 3, "bypass": null },
  "tests": {
    "matrix": { "include": [ … ] }, "env_matrix": { "include": [ … ] },
    "count": 12, "active": true, "env_active": false,
    "not_run": [ { "file": "…", "lane": "…", "reason": "secrets unavailable" } ],
    "provider_sets": [ { "id": "a1b2c3", "environments": ["prod","staging"], "lock": "envs/prod/.terraform.lock.hcl" } ]
  },
  "comments": {
    "heads": [ { "kind": "env", "key": "prod", "state": "placeholder", "title": "Terraform validation summary" },
               { "kind": "env", "key": "staging", "state": "not-affected", "title": "Terraform validation summary" } ],
    "purge_tags_for": ["staging"]
  },
  "record": [ "prod: run — trigger-events: pull_request; relevance: envs/prod/**; goals: init, format, validate, lint, plan",
              "staging: skip — relevance: no changed file matches" ]
}
```

- Each per-stage matrix and every `vars` object is what the workflow consumes today, unchanged in
  shape and in value types (D9); the port (§9) proves it. Before ordering ships there is one
  matrix, named `"1"`.
- **Held back is not an engine concept.** The engine assigns stages; whether a stage ran is a fact
  of the run graph it never sees. A held-back environment is composed downstream from its `stage`,
  the stage's row count and the stage job's result ([Environment-ordering.md](Environment-ordering.md) §7). The one addition is `vars.goals-granted` (D10), equal
  to the environment's `goals` in the decision record (I16).
- Row order is `environments-yml` order; list outputs are sorted where the input has no order;
  JSON is emitted with sorted keys. Two runs with the same input document produce byte-identical
  output documents (I12).
- `record` is prose for people; every line is derived from `reasons`, never written separately.
- What leaves the job as `$GITHUB_OUTPUT`: `matrix-json`, the test matrices, counts, flags and the
  relevance mode and reason, all small. `environments`, `tests.not_run`, `comments` and `record`
  travel as the `relevance` artifact and as files to the seed job, never as job outputs: a job
  output enters every `needs.*.outputs` interpolation downstream, and nothing caps it (the ARG_MAX
  rule of CLAUDE.md).

The other specs name the same data under their own output names. The mapping is normative:

| Spec | Name there | Here |
|---|---|---|
| Path-relevance.md §5.2 | `envs-json` rows with `relevance`, `matched-rule`, `paths`, `paths-ignore` | `environments[]`: `verdict` `run` is `affected`, the first `relevance:` reason is `matched-rule`, resolved rules in `vars` |
| Path-relevance.md §5.2 | `affected-count`, `unaffected-count` | `counts.affected`, `counts.unaffected` |
| Path-relevance.md §4.3 | `relevance-mode`, `relevance-reason`, `changed-count` | `relevance.mode`, `relevance.reason`, `relevance.changed_count` |
| Terraform-tests.md §4.5 | `tests-matrix-json`, `tests-env-matrix-json`, `tests-count`, `tests-active`, `tests-env-active`, `tests-not-run-json` | `tests.matrix`, `tests.env_matrix`, `tests.count`, `tests.active`, `tests.env_active`, `tests.not_run`; a row is exactly the §4.5 row schema |
| Terraform-tests.md §5.3 | provider sets | `tests.provider_sets` |
| Path-relevance.md §6.3, Terraform-tests.md §6.3 | the seed manifest and `gc-yml` | `comments.heads[]` with `kind` `group`, `env` or `tests`, `state` `placeholder` or `not-affected`, `title`, and the mode line for an environment that mutates on pull request; `comments.purge_tags_for`; both empty on non-pull-request events, forks, `closed` and `converted_to_draft` |
| Path-relevance.md §6.5, Dispatch-and-triggers.md §5 | the run notice | `notices[]`, one per decision kind, in the relevance spec's format |

## 6. The decision procedure

For each environment, in order; the first rule that drops it wins and is recorded, later rules are
not evaluated:

| # | Rule | Source spec | Reason recorded |
|---|---|---|---|
| 1 | Validation of the environment's fields: names, types, globs, lane keys, environment-name patterns and collisions. A failure is an error for the whole run, not a skip. | each spec's validation section | `error: …` |
| 2 | Trigger events: the current event is in the environment's resolved `trigger-events`. A run event outside the vocabulary (`merge_group`, `pull_request_target`, `release`, …) is an error for the whole run, never a quiet skip. | Dispatch-and-triggers.md | `trigger-events: <event> not enabled` |
| 3 | Dispatch filter: on `workflow_dispatch` with a named environment, only that environment continues. A name that matches nothing, or an environment that rule 2 already dropped, is an error. | Dispatch-and-triggers.md | `dispatch: not the requested environment` |
| 4 | Relevance: mode `all`, or at least one changed file matches. | Path-relevance.md | `relevance: <rule>` or `relevance: no changed file matches` |
| 5 | Goals: expand the environment's `goals` to the eight-goal vocabulary for this event, ref and branch as the workflow's gates do today (`apply` on push, dispatch and schedule on the default branch, `destroy` on push and dispatch on the default branch, the `-on-pr` goals on a pull request against it, `destroy-plan` anywhere); then apply the dispatch `goal` as a cap that only removes; then the errors of Dispatch-and-triggers.md §4.3. | Dispatch-and-triggers.md | `goals: …` |
| 6 | Ordering: validate the declared `depends-on` graph (unknown name, self-reference, cycle, depth over the cap are errors); assign each surviving environment one more stage than its highest dependency still in the run, 1 when it has none; move an environment with neither dependencies nor dependents to the last stage in use; collapse every environment to stage 1 when no environment is granted `apply` or `destroy`, and on a dispatch naming one environment. | Environment-ordering.md | `ordering: stage <n>` · `ordering: depends-on '<name>' not in this run (<their reason>)` · `ordering: single-environment dispatch, stage 1` · `error: …` |
| 7 | Row variables: the generic forwarding of every scalar input, per-environment overrides, normalised booleans, the `caller-repo-*` facts, `goals-granted`. | today's builder, D10 | none |

Secrets availability is not a rule for environments: a fork pull request's environments run and
fail on authentication, as today (Path-relevance.md §7.4). It is a rule for test rows, in `tests.py`,
which follows its own procedure: root derivation, misplacement, exclusion, lane match, secrets
availability, provider sets, environment naming, then rows. Comments are derived last, from the
environments' verdicts and the event.

## 7. Invariants

Checked by `invariants.py` on every case of every kind (§8). A violated invariant fails the suite
even when the case's expected output matches.

| # | Invariant |
|---|---|
| I1 | `apply` is granted only when (the event is `push`, `workflow_dispatch` or `schedule`, `ref_name` equals the default branch, and the goals hold `apply` or `all`) or (the event is `pull_request`, its action is not `closed` or `converted_to_draft`, `base_ref` equals the default branch, and the goals hold `apply-on-pr`). `destroy` likewise, with `push` and `workflow_dispatch` only and `destroy` or `destroy-on-pr`. The granted vocabulary is the eight goal keys; `all` and the `-on-pr` goals exist only in input. |
| I2 | On `workflow_dispatch` naming an environment, exactly one environment has verdict `run` and it is the named one, or the output carries an error. |
| I3 | On `workflow_dispatch`, the granted goals are a subset of what the same environment would be granted on a push to the same ref; the `goal` input only removes. |
| I4 | When secrets are unavailable (fork, Dependabot), no test row has a credentialed lane or a non-empty `github-environment`. Environment rows are unaffected. |
| I6 | Relevance mode `all` implies every environment that passed rules 2, 3 and 5 has verdict `run`. |
| I7 | When `errors` is empty, environments with verdict `run` plus verdict `skip` equal the environments declared, and no environment name appears twice. |
| I8 | The union of the per-stage matrices contains exactly the environments with verdict `run`; within a stage, rows are in `environments-yml` order; no environment appears in more than one matrix. |
| I9 | A test row's environment name matches `^tftest-[a-z0-9-]{1,40}$` and, compared case-insensitively, equals no environment's `github-environment`. |
| I10 | `model.py` rejects unknown top-level keys, no schema field holds a secret value, and the shim test plants a sentinel in the process environment and in secret-shaped variables and asserts it never appears in the input file or any output. |
| I11 | Every `skip` verdict and every `not_run` entry has a non-empty reason from the fixed vocabulary. |
| I12 | The output is byte-identical across runs with `PYTHONHASHSEED=0` and `=1`, and invariant under a permutation of the input document's key order. |
| I13 | With `path-relevance-enabled: false`, every environment's relevance reason is `all:disabled` and every environment that passed rules 2, 3 and 5 runs. |
| I14 | A `not-affected` head or a tag purge is emitted only on a `pull_request` event that is not from a fork and whose action is not `closed` or `converted_to_draft`, for an environment with verdict `skip` for a relevance reason and `add-pr-comment: true`; a grouped environment gets no per-environment head at all. |
| I15 | `destroy` is never granted on `schedule`; on `workflow_dispatch` it is granted only when the environment's own goals hold it and the ref is the default branch, never through the `goal` input. |
| I16 | `environments[].goals` equals `vars.goals-granted` for every `run` row. |
| I17 | A dispatch with a non-empty `environment` input yields at least one `run` verdict or an error, never a green empty matrix. On `schedule` the empty case is permitted, with the documented notice. |
| I18 | Every environment with verdict `run` carries exactly one integer `stage` between 1 and the cap, and appears in exactly one per-stage matrix. No environment with verdict `skip` carries a stage. `counts.by_stage[k]` equals the number of `run` environments with stage `k`, and the sum over all `k` equals `counts.affected`. |
| I19 | For every `run` environment and every name in its resolved `depends-on`: either that name is a `run` environment with a strictly lower stage, or it is not `run` in this decision and the dependent records `ordering: depends-on '<name>' not in this run (<the dependency's own reason>)`. A `depends-on` naming an environment that `environments-yml` does not declare is a validation error, never a trivially satisfied dependency. |
| I20 | The declared `depends-on` graph is acyclic, and no environment names itself. A violation is a validation error naming every environment on one cycle in `environments-yml` order, and such an output document carries no non-empty matrix. |
| I21 | An environment is assigned a stage above 1 only when at least one environment in the decision is granted `apply` or `destroy`. When none is, every `run` environment has stage 1 and `ordering.stages_used` is 1. |
| I22 | On `workflow_dispatch` with a non-empty `environment` input, every `run` environment has stage 1 whatever its `depends-on`, and `ordering.bypass` is `single-environment-dispatch`. The bypass appears in `record` and in `notices[]` only when the named environment declares at least one dependency. |
| I23 | The longest path of the **declared** graph never exceeds the cap; a deeper graph is a validation error naming the chain. The check is against the declared graph, not the graph restricted to this run, so a configuration's validity does not depend on which files changed. |
| I24 | `stage` is a pure function of the resolved `depends-on` graph restricted to the `run` set and of the last-stage rule for free-standing environments. With I12 this makes stage assignment byte-stable across runs of the same input document. |

I5 of the first draft restated rule 2 and is folded into it.

## 8. Tests

Four kinds, one suite, one `run_all_tests.sh` that prints the canonical `Tests run` /
`Tests passed` / `Tests failed` lines of [Testing-in-ci.md](Testing-in-ci.md) §4 and enrols in
`action-tests.yml` like every action.

1. **Port goldens** (§9): the six existing `create-tf-vars-matrix` fixtures, one fixture equal to
   the workflow's full default `toJSON(inputs)` (the six predate `runs-on` and the auto-merge app
   inputs, so they do not exercise every forwarded key), and one input document per real caller
   shape (collected from the calling repositories' workflow files, anonymised) must produce today's
   `matrix-json`, compared as parsed JSON with row order; nothing downstream reads key order. The
   sixty-nine helper and malformed-input cases of the current `create-tf-vars-matrix` suite migrate
   into this suite; the three `*_secrets-json.json` fixtures are vestigial (the action has no such
   input) and are removed.
2. **Table cases**: `cases/<name>/input.json` and `expected.json`, one per scenario in the three
   feature specs' example sections, plus every validation error with its message.
3. **Generated cases**: `generate_cases.py` enumerates event × branch × goals × relevance mode ×
   dispatch × fork × trigger-events × lanes × `depends-on` graph shape (random acyclic graphs up to
   the cap, plus deliberate cycles and over-cap chains), deterministically, writes nothing to disk,
   and asserts the invariants on each. Several thousand cases run in seconds.
4. **Random cases**: the same generator with a seeded random walk over field values, including
   malformed ones, asserting invariants and that the engine either produces a valid output document
   or a validation error, never a crash.

**Suite entry and summary lines**: `engine/run_all_tests.sh` runs `tests/run_tests.py`, which
discovers the `unittest` modules and prints exactly once, on stdout, the three lines of
[Testing-in-ci.md](Testing-in-ci.md) §4 (`Tests run`, `Tests passed`, `Tests failed`) computed
from the `TestResult` (failures, errors and unexpected successes count as failed). The coverage gate
counts as one more test, so a shortfall reads as one failed test in the pull request comment rather
than an all-green suite with a red job. Every case runs twice, with `PYTHONHASHSEED=0` and `=1`
(I12). The discovery script gains a second pass that enrols a top-level directory holding
`run_all_tests.sh` without an `action.yml`; Testing-in-ci.md §2.1, §3 and §8 say so.

**Coverage**: the suite runs under `coverage` with branch measurement and fails when any file of
`dsb_tf_engine/` has a missing line or branch, read from `coverage json` rather than a rounded
percentage. `coverage` is not preinstalled on the hosted images and `pip install --user` is
refused there by the externally-managed-environment rule, so the suite invokes it through the
preinstalled `pipx run coverage==<pinned>`, falling back to `python3 -m coverage` where it is
importable (developer machines). The pin is bumped like any other dependency. A missing or failing
install fails the suite, because the gate is part of the contract (P4).

**What tests cannot cover**: the shims. They are kept thin enough to be reviewed by eye and
covered by the workflow's structural tests and the preview-ref run on the test-bed repository.

## 9. The port

The first implementation commit changes no behaviour:

1. `engine/` with `decide` implementing today's `create-tf-vars-matrix` semantics, every one of
   them, as read from the action and its helpers:
   - every `*-yml` input parses as YAML, an empty string parses to `null`, an invalid one is the
     error `The specification for input '<name>' is not valid yaml!`;
   - every environment has `environment`, else "Missing property 'environment' in
     environments-yml specification!";
   - `project-dir` defaults to `./envs/<environment>`, with the `./` prefix;
   - generic forwarding: every non-`-yml` input key, in sorted order, is copied as a **string**
     into a row that lacks it (`"true"`, `"5"`, `""` for null); per-environment values keep their
     YAML types; arbitrary per-environment keys that are not inputs pass through untouched;
   - `github-environment` defaults to `environment`; `url` defaults to `""`;
   - `allow-failing-terraform-operations`: absent is JSON `false`, present is `true` only when the
     string is exactly `true`;
   - replace fields (`goals-yml`, `terraform-init-additional-dirs-yml`): per-environment value, as
     YAML text or a native list, else the global, else `[]` when the global is null; invalid is
     `the environment's '<field>' is not valid yaml!`; stored under the name without `-yml`;
   - merge fields (`extra-envs-yml`, `extra-envs-from-secrets-yml`, `extra-envs-per-goal-yml`,
     `extra-envs-from-secrets-per-goal-yml`, `pr-auto-merge-from-actors-yml`,
     `pr-auto-merge-limits-yml`): absent means the global value as is (a global `""` becomes
     `null`, not `{}`); present means a merge where null on either side yields the other, arrays
     concatenate with duplicates kept, objects deep-merge with the environment winning and null
     leaves preserved, and a shape mismatch is "unable to merge …";
   - per-goal maps: every key of `init, format, validate, lint, plan, apply, destroy-plan, destroy`
     defaulted to `{}`; empty or null input yields the full key set; unknown keys pass through; a
     non-object passes through unchanged;
   - every `-yml` key removed from the row; `pr-auto-merge-enabled` is not a `-yml` input and is
     forwarded generically; a per-environment key named like a stripped field is overwritten;
   - `caller-repo-default-branch`, `caller-repo-calling-branch` (`ref_name`) and
     `caller-repo-is-on-default-branch` as the strings `"true"` / `"false"`;
   - row order is `environments-yml` order;
   - validation: the result is a non-empty array; the twenty-four required fields exist (the
     current list lacks `runs-on` and `format-check-in-root-dir` although the workflow reads them;
     the port keeps the list and the gap is a recorded finding, not a silent fix); the not-empty
     fields are not the empty string (`[]`, `{}` and `null` pass); every `project-dir` exists,
     all checked before failing; errors are grouped per field and prefixed as today;
   - the shape `{"environment": [names], "include": [{"environment", "vars"}]}` with `vars` the
     whole row; the only output is `matrix-json`; the only input is `inputs-json`.
   Verdict `run` for every environment; reasons `port`. Two deliberate deviations, recorded:
   validation exits 2 instead of 1, and a duplicated environment name becomes an error (I7);
   today it is not checked.
2. The suite with the goldens of §8 and the invariants that already apply (I7, I8, I12).
3. `create-tf-vars-matrix/action.yml` rewritten as a shim around the engine; its own
   `run_all_tests.sh` becomes a thin check that the shim forwards inputs and outputs correctly and
   never exports its input heredocs. `extract_step_source.py` and the extracted-source harness are
   removed. The action-tests discovery script gains the second pass of §8.
4. A preview-ref run on the test-bed repository, and a comparison of the `matrix-json` job output
   between the last `v0` and the preview on every real caller shape, recorded in §13.

Only after that do relevance, tests and dispatch land, each as rules and cases in the engine and a
few lines in the shims and the workflow.

## 10. Pitfalls

| # | Pitfall | Consequence | Rule |
|---|---|---|---|
| P1 | An old self-hosted runner may carry Python 3.8. | Syntax errors at start-up in the `create-matrix` job. | The shim checks `python3 --version` first and fails with a message naming the floor; `create-matrix` runs on the workflow's `runs-on`, which defaults to `ubuntu-latest`. |
| P2 | PyYAML is not on every runner. | An import error on the one runner without it. | YAML never reaches the core; `yq` in the shim. |
| P3 | Dictionary and set iteration order leaks into output. | Non-deterministic outputs, flaky goldens, flapping comments. | Sorted where the input has no order; I12 checks it. |
| P4 | `coverage` is not preinstalled, and `pip install --user` is refused on the hosted images (externally managed environment). | The suite cannot install its gate the obvious way. | `pipx run coverage==<pin>` (preinstalled pipx), `python3 -m coverage` as the fallback; the network access is accepted for CI; the gate is not optional. |
| P5 | The changed-file list can be a quarter of a megabyte. | ARG_MAX through the steps context if it ever became an output. | Files by path in the input document; outputs carry counts. |
| P6 | GitHub hands every input as a string, including booleans and dispatch inputs. | `"false"` is truthy. | The shim normalises to JSON types; the model validates types and rejects the rest. |
| P7 | A crash in the engine is a `create-matrix` failure, which the conclusion reports red for every caller on the release. | A fleet-wide red on a bad minor of `v1`. | The random-case tests assert "never a crash"; the port's goldens; the preview-ref run before release. |
| P8 | The engine prints to stdout by habit. | Corrupts a command that expects the output document on stdout. | Output documents go to `--output` files; logging to stderr; a test asserts stdout is empty. |
| P9 | `capture-matrix-job-meta` strips keys that look like secrets. | A row field a summary must read back from metadata disappears (`fork-safe` was named for this). Today's rows already carry `pr-auto-merge-app-private-key-secret` and the `extra-envs-from-secrets*` maps, which are stripped and must stay so. | Only fields a downstream summary reads from metadata are validated against the filter; the port does not rename existing keys. |
| P10 | The decision record can grow long on a repository with many environments and files. | A run summary nobody reads. | One line per environment, one per test root, collapsed detail per file. |
| P11 | A per-environment YAML boolean stays a JSON boolean in `vars`, and the workflow's gates compare with `== 'true'`; GitHub casts a boolean to a number and a string to NaN, so `true == 'true'` is false. | A per-environment `format-check-in-root-dir: false` does not do what the author expects today. | Pre-existing; the port pins it in the goldens and records it. Retyping per-environment booleans to strings is a separate commit with its own release note. |
| P12 | The shim gathers adapter facts before the engine can validate the configuration. | A misconfigured caller pays for API calls before hearing about the typo. | `validate` on the partial document first (§3.2). |
| P13 | `github.event.repository.default_branch` is documented for push, pull request and dispatch payloads, not for `schedule`. | An unknown default branch on a scheduled run. | Fallback to the API through a temp file; verified on the test-bed. |

## 11. Open questions

1. **Python on the self-hosted runner pools** that callers might name in the workflow-level
   `runs-on`: confirm the version on each pool used for `create-matrix`; the floor is 3.10. The
   hosted images carry 3.10 (ubuntu-22.04, being retired) and 3.12 (ubuntu-24.04).
2. **`pipx run coverage`** on `ubuntu-24.04` under the runner's Python: confirm the pinned
   version runs and that `coverage json` reports branches.
3. **Default branch on `schedule`**: whether `github.event.repository.default_branch` is populated;
   the fallback covers it either way.
4. **`github.actor` on `schedule`**: undocumented; community reports the user who last edited the
   cron line. Record what the test-bed shows; the dispatch spec's record line uses whatever the
   context gives.

## 12. Implementation order

1. `docs:` this spec.
2. `feat(engine):` the package, the port of today's semantics, the suite with goldens and
   invariants, the coverage gate, enrolment in `action-tests.yml`.
3. `refactor(create-tf-vars-matrix):` the shim; remove the extracted-source harness.
4. `feat(ci):` the discovery script's second pass; Testing-in-ci.md; a paragraph in the
   implementation guide and CLAUDE.md on the shared engine.
5. Preview-ref comparison on the test-bed; findings into §13.
6. Then, in the order the maintainer chooses: relevance rules and cases; test rules and cases with
   the `create-tftest-matrix` adapter; dispatch and trigger-events rules and cases, with the
   `goals-granted` switch of the operation gates and its structural test.

AI-assistant configuration files are never in these commits.

## 13. What implementation taught the spec

Reserved.
