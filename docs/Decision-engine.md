# The decision engine

Authoritative spec for the one place that decides what a run of
[`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml) does: which
environments and test files take part, with which goals, why, and what the pull request, the run
summary and the conclusion are told about it. Today that logic is spread over bash and `jq` in
`create-tf-vars-matrix`, `create-tftest-matrix` and step conditions in the workflow. This spec
moves it into a single Python core with a JSON contract, a decision record as output, a set of
invariants, and a coverage gate at 100 percent.

Status: **the port (§9), relevance, the test matrix and the comment manifest are built** and are
what `create-tf-vars-matrix` runs, through the create-matrix adapter (§3): rules 1, 4 and 7 of §6,
the test rows of `tests.py`, the input and output documents of §4 and §5 in the shape they need,
the tests of §8 and both gates. Rules 2, 3, 5 and 6 and the `validate` and `render-summary`
commands are specified here and are built with the features that need them:
[Terraform-tests.md](Terraform-tests.md), [Path-relevance.md](Path-relevance.md),
[Dispatch-and-triggers.md](Dispatch-and-triggers.md) and
[Environment-ordering.md](Environment-ordering.md). §13 holds what implementation taught the spec.

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
| D1 | The engine is **Python 3.12 or later, standard library only**. No third-party runtime dependency. | Present on every GitHub-hosted image (ubuntu-24.04 carries 3.12, ubuntu-26.04 3.14) and on practically every Linux runner; no build step; nothing to install at run time. The floor is the oldest Python the callers' runners carry, and CI runs the suite on it and on the newest release. The alternatives were weighed: a TypeScript Node action needs no runtime at all but a committed bundle and Node deprecation churn; Go and Deno lose on distribution. |
| D2 | **JSON in, JSON out.** The core never reads YAML, the network, the filesystem, the clock or the environment; all of that is the adapter side's, which parses YAML with `yq` and calls APIs. | Purity is what makes every case a fixture. PyYAML is not guaranteed on self-hosted runners. |
| D13 | **The glue is Python too.** What an action does around the core (reading inputs, running `yq` and `gh`, publishing outputs) lives in adapter-side modules of the package, not in bash step scripts. | The glue is where the last faults were found, and bash cannot be held to the core's gates; in Python the adapter sits under the same 100 percent coverage and mutation gates, and large values stay in memory instead of reaching envp. The repository's modern bash layout is followed where nothing outweighs it; here the gates do. |
| D3 | **Port first.** The engine reproduces today's `create-tf-vars-matrix` output for every existing fixture and for the real input shapes of the calling repositories before any feature lands on it. | One reviewable migration with a hard safety net, instead of writing each feature's logic twice. |
| D4 | **100 percent line and branch coverage**, enforced by the suite, from the first commit of the core. | The core is small and every branch is a production decision. A branch nobody tested is a branch nobody intended. |
| D5 | **Invariants** are checked on every table case, every generated case and every random case. | Fixtures cover what someone thought of; invariants catch the rest. |
| D6 | The engine emits a **decision record**: per environment and test file, the verdict, the goals granted and the ordered rules that produced them. The run summary prints it. | A wrong decision is visible on the run page before it is visible in Azure. |
| D7 | The test matrix (lanes, environments, provider sets) and the relevance and dispatch decisions live in the same core as the environment matrix. | They share the event model, the fork rule, the glob matcher and the invariants; splitting them would split the guarantees. |
| D8 | The engine **never fails open silently and never fails closed silently**: every drop of an environment or file carries a reason, and validation errors stop the run with a message. | Reasons are the contract with the reader of the run summary. |
| D9 | Row variables have **the types the workflow's gates compare**: a workflow input is a string whether forwarded or set per environment (`"true"`/`"false"` for a boolean input), a per-environment key that is not an input keeps its YAML type, and only `allow-failing-terraform-operations` is a JSON boolean. Typed values live in `workflow_inputs` and in the engine's own decisions. | The workflow's gates compare strings (`== 'true'`), and GitHub's expression rules make `true == 'true'` false, so a per-environment YAML boolean left as a JSON boolean was silently dropped (P11). |
| D14 | **Names follow one rule and a github-environment belongs to one environment.** `environment` and `github-environment` are strings of 1 to 255 of `A-Z a-z 0-9 . _ -`, starting with a letter or a digit, and no two environments share a github-environment, compared without case. | A name reaches comment markers (`:`-separated, ended by `-->`), artifact names, concurrency groups and shell; the github-environment keys the markers, the metadata artifact and the concurrency group, so two environments sharing one overwrote each other's comments and lost one's metadata. Every calling repository's names already fit. |
| D10 | Granted goals reach the workflow through a new row variable **`goals-granted`** (the eight-goal vocabulary, no `all`, no `-on-pr`); `vars.goals` stays the raw list. | Three renderers read the raw list for `apply-on-pr`; the operation gates switch to `goals-granted` so a dispatch cap can remove `apply`, with their event and branch clauses kept as defence in depth. |
| D11 | The engine ships as the core of the **v1** major release; `v0` keeps the bash builder. | The features on top of it change defaults (relevance, tests, schedule); a rolling major tag cannot carry them. |
| D12 | **Every injected fault must fail a test.** A mutation gate beside the coverage gate: each small fault in the package (a comparison flipped, a condition forced, a statement deleted, a raise swallowed, a list element dropped, a copy aliased) is run against the suite, and one that survives fails it, unless it is listed as equivalent with the reason. | Coverage proves every branch ran, not that a test would notice it deciding wrongly. At 100 percent coverage the first mutation run left 44 faults nobody would have noticed, among them 40 of the 43 validation checks. |

## 3. Where it lives and how it is called

```
engine/
├── run.py                    # the entry for actions: python3 -I -B engine/run.py <command> …
├── dsb_tf_engine/            # the package; stdlib only
│   ├── __init__.py           # core: SCHEMA_VERSION
│   ├── model.py              # core: the input document's shape, checked first
│   ├── decide.py             # core: the decide command, input document in, output document out
│   ├── environments.py       # core: environment rows, rule 1 (the port's validation) and rule 7
│   ├── values.py             # core: jq-compatible rendering, merge and per-goal normalisation
│   ├── globs.py              # core: the one glob matcher (Terraform-tests.md §4.4)
│   ├── relevance.py          # core: rule 4, path relevance (Path-relevance.md §3-§5)
│   ├── comments.py           # core: the seed manifest, heads and tag purges (Path-relevance.md §6.3)
│   ├── tests.py              # core: the test rows: roots, lanes, environments, provider sets (Terraform-tests.md §3-§4)
│   ├── record.py             # core: the decision record
│   ├── __main__.py           # adapter side: the command line, decide and create-matrix
│   ├── adapter.py            # adapter side: create-matrix, inputs, yq, facts, document, publish
│   └── workflow.py           # adapter side: GitHub Actions I/O, groups, annotations, outputs
├── run_all_tests.sh          # the canonical suite entry (§8), at the depth discovery expects
└── tests/
    ├── run_tests.py          # coverage, the two gates, the canonical summary lines, printed once
    ├── unit_runner.py        # unittest discovery, run under coverage
    ├── mutation.py           # the mutation gate (D12); mutation_equivalents.json beside it
    ├── test_*.py             # unittest modules: port, generated and random cases, units, adapter
    ├── port/cases/<name>/    # case.json, expected.json (the bash builder's output), input.json
    ├── support.py            # the port cases and a minimal valid document
    └── invariants.py         # the checks of §7, importable by every test
```

**The core is pure**: its modules import nothing but `json`, `re`, `hashlib` and each other, and nothing from the
adapter side (`test_purity.py` checks the imports). **The adapter side** reads the environment,
the filesystem and the network, runs programs and writes the log, so that the core does not have
to; it sits under the same coverage and mutation gates.

The remaining features add their modules as their rules are built: on the core side `events.py`
(event kind, branch facts, the fork and Dependabot rules); `environments.py` gains goals, trigger
events, dispatch and stages, and `record.py` the rendering for the run summary. Their
fact-gathering joins the adapter side (§3.1).

Composite actions call it with the repository checked out at the action's ref, which is always the
case for an action referenced as `dsb-norge/github-actions-terraform/<action>@<ref>`: GitHub
downloads the whole repository at that ref, and a preview ref publishes the whole tree at one
commit, so action and engine are never at different versions. `create-tf-vars-matrix` is one
step:

```bash
# Resolve the terraform ci/cd variables of every environment into the job matrix
inputs_file="$(mktemp)"
cat >"${inputs_file}" <<'CREATE_TF_VARS_MATRIX_INPUTS_JSON'
${{ inputs.inputs-json }}
CREATE_TF_VARS_MATRIX_INPUTS_JSON
python3 -I -B "${{ github.action_path }}/../engine/run.py" create-matrix --inputs-file "${inputs_file}"
```

- **The inputs reach Python through a file**, never a variable or argv. GitHub pastes the
  expression into the script before bash parses it. The heredoc is quoted, so bash expands
  nothing in it, and `toJSON(inputs)` cannot contain the delimiter line, because JSON escapes a
  string's newlines; the delimiter is still unique to this action, and the adapter refuses
  anything that is not a JSON object (P22).
- **`-I` (isolated mode)** keeps the runner's `PYTHON*` variables, the user's site-packages and
  the working directory off the import path. The working directory is the caller's checkout:
  without `-I`, a caller's own `json.py` would be imported in place of the standard library
  (P21). `run.py` puts the engine's own directory on the path, checks the floor (D1) before
  importing anything, and runs the command line. `-B` keeps `__pycache__` out of the downloaded
  tree.
- The engine is the one thing in the tree an action reaches outside its own directory; the
  implementation guide says so.

**The adapter's job** (`adapter.py`) is everything the core must not do. It probes `yq` on a known
document, so a broken `yq` is reported as such and never as the caller's invalid YAML (P19). It
reads the inputs file, parses **every** `*-yml` workflow input and every `*-yml` key of every
environment with `yq`, and hands each over as a parse result `{"ok": <bool>, "value": <JSON>}`;
the engine decides which of them it reads and reports a failed parse in its own words. It reads
each value exactly as the bash builder did, because YAML parsing is sensitive to it: a workflow
input with null and `false` as the empty string, trailing newlines stripped and one added back
(the builder's `echo`); an environment's field with null as the empty string, trailing newlines
stripped and none added back (the builder's `printf '%s'`), `false` and other non-strings as their
JSON text. Several YAML documents in one value do not parse. It reports `project-dir` existence
for exactly the paths the engine will check, asking the engine for them
(`environments.project_dir_path`). It reads the default branch from the event payload file
(`GITHUB_EVENT_PATH`), which carries it on every event this workflow runs on, `schedule`
included, and falls back to `gh api`; a failed fallback stops the step with the API's answer
instead of guessing. It reads the payload once more for the change: a push's `created`, `forced`
and `deleted`, a pull request's action, number, head commit and whether it comes from a fork, and
the run's id and attempt from the runner; then it fetches the changed files (§3.1). Then it
decides in-process, logs the inputs, the changed files, the input document (with the file list
elided, since it is already in its own group), the decision record and the matrix in collapsed
groups printed verbatim (P20), turns each validation error into one escaped `::error` annotation
and each notice into one `::notice`, writes `relevance.json` (the output document without its
matrices) under `RUNNER_TEMP`, and appends `matrix-json`, the counts, the relevance mode, reason
and changed count, and the file's path to `$GITHUB_OUTPUT`, each under a random delimiter. Every external program sits behind one `Tools` object, so the tests stand in for
`yq` and `gh`.

### 3.1 Adapters

Adapters fetch facts and report them raw; they decide nothing. `adapter.py` is the first; the
features bring two more, as adapter-side modules under the same gates:

- fetching the changed files (in `adapter.py`) calls the pull request or compare endpoints and
  reports `{available, truncated, error, api_head_sha, count, files}`, the file list inline because
  the core reads no files; the engine turns that into a relevance mode and reason
  (Path-relevance.md §4.2-§4.3). Nothing is fetched when relevance is switched off, for an event
  other than a push or a pull request, or for a forced or deleting push, whose files the core
  would not read.
- gathering the test facts (in `adapter.py`, Terraform-tests.md D20) lists committed test files,
  the directories that hold `.tf` files, and the environments' lock files by `project-dir`, in the
  same step; the engine derives roots, lanes, environments and provider sets and validates them.
  `create-tftest-matrix` stays as it is, with its `all-tests` output, for the module CI workflow
  until that migrates.

An adapter that fails reports the failure in its fields and exits zero. The engine decides whether a failure is fail-open (relevance) or a validation error
(a lock file that cannot be parsed).

### 3.2 Commands

| Command | Input | Output | Used by |
|---|---|---|---|
| `decide` | the full input document | the full output document | the adapter, in-process; tests and debugging through the command line |
| `create-matrix` | `--inputs-file` holding `toJSON(inputs)`, and the runner's environment | `matrix-json` in `$GITHUB_OUTPUT`, the log | the `create-tf-vars-matrix` action |
| `validate` | the input document without the adapter sections | validation errors only, exit 2 when any | the same job, on a partial document built from the event and the inputs, before the adapters run, so a configuration error is reported before any API call |
| `render-summary` | an output document | Markdown for the run summary | `create-matrix` and the conclusion |

Exit codes: 0 success, 2 validation error, 1 anything that is not the caller's configuration: a
malformed input document, an unreadable file, a broken `yq`, an unanswerable API, a usage error
(P18) or a crash. `decide` writes its messages to stderr and the output document to `--output`,
and nothing to stdout; `create-matrix` writes the step's log to stdout.

## 4. The input document

The document the port reads:

```json
{
  "schema_version": 1,
  "caller": { "repository": "owner/repo", "default_branch": "main" },
  "event": { "name": "pull_request", "ref_name": "feature/x" },
  "workflow_inputs": { "environments-yml": "- environment: prod\n", "goals-yml": "[all]", "add-pr-comment": true, … },
  "yaml": {
    "inputs": { "environments-yml": { "ok": true, "value": [ { "environment": "prod" } ] }, "goals-yml": { "ok": true, "value": ["all"] }, … },
    "environments": [ { "goals-yml": { "ok": true, "value": ["plan"] } } ]
  },
  "directories_exist": { "./envs/prod": true }
}
```

- `workflow_inputs` is `toJSON(inputs)` exactly as GitHub delivers it: every declared input,
  booleans as JSON booleans, the `*-yml` inputs as their YAML text.
- `yaml.inputs` holds the parse result of every `*-yml` input, `yaml.environments` one map per
  entry of the parsed `environments-yml`, aligned by index, holding the parse result of every
  `*-yml` key of that entry (§3).
- `model.py` rejects unknown and missing top-level keys, a `schema_version` other than 1, and any
  section of the wrong shape, as a document error (exit 1): a malformed document is the adapter's
  fault, not the caller's configuration.

The features extend it; the full document, as they specify it:

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
    "push": { "created": false, "forced": false, "deleted": false },
    "pull_request": { "number": 87, "base_ref": "main", "head_sha": "…", "is_fork": false, "draft": false },
    "dispatch_inputs": { "environment": "", "goal": "", "reason": "" }
  },
  "workflow_inputs": { … },
  "yaml": { … },
  "directories_exist": { "./envs/prod": true, "./envs/staging": true },
  "changed_files": { "available": true, "truncated": false, "error": null, "api_head_sha": "…", "count": 3, "files": ["envs/prod/main.tf", "…"] },
  "tests": {
    "files": ["tests/unit-net.tftest.hcl", "modules/net/tests/unit-net.tftest.hcl"],
    "directories_with_tf": ["modules/net", "main", "envs/prod"],
    "environment_locks": { "envs/prod": { "hashicorp/azurerm": "4.30.0", … }, "envs/staging": null }
  }
}
```

- Row variables are typed separately from `workflow_inputs` (D9).
- `dispatch_inputs` are strings, as GitHub delivers them. When the caller declares no `inputs:`
  block the payload key is `null`, and a string input left empty is absent from the payload
  rather than `""`; the adapter passes all three keys, `""` for each that is missing.
- Only the sections a command needs must be present; an absent `tests` section means "no test
  stage", an absent `changed_files` means "relevance not computed" (mode `all`, reason
  `not-computed`). `run`, `event.action`, `event.push` and `event.pull_request` are optional too;
  when present they are checked whole. As built: `push` holds exactly its three booleans,
  `pull_request` its `number`, `head_sha` and `is_fork`, `changed_files` exactly its six facts;
  `base_ref`, `draft`, `actor` and `dispatch_inputs` arrive with the rules that read them.
- A renamed file is in `files` under both its paths; `count` is what the API counted, one per
  changed file.
- Secrets never enter the document. Whether secrets are available is derived by the engine from
  `is_fork` and `actor == 'dependabot[bot]'`, one rule in one place; secret names appear only as
  names inside lane definitions.
- `environment_locks` is keyed by `project-dir`, normalised without a leading `./` or a trailing `/`
  (`.` for the repository root), because two environments may share one. Each value is the lock's
  providers and the versions it records, or null when the environment has no lock. The adapter
  lists the files with `git ls-files`, so only committed files count, and reads the locks from the
  checkout; the section is present only when the caller's `terraform-test-enabled` is on.
- `caller.workflow_name` (`GITHUB_WORKFLOW`) scopes the tests head per calling workflow, and
  `event.actor` (`GITHUB_ACTOR`) is how Dependabot runs are recognised; both are present only when
  the runner sets them.

## 5. The output document

What it emits as built, the port with relevance and the comment manifest:

```json
{
  "schema_version": 1,
  "errors": [],
  "notices": ["relevance diff (diff): 1 of 2 environments affected"],
  "relevance": { "mode": "diff", "reason": "diff", "changed_count": 3 },
  "environments": [
    { "environment": "prod", "verdict": "run", "reasons": ["relevance: envs/prod/**"],
      "github-environment": "prod", "add-pr-comment": "true", "pr-comment-group": "", "mutates-on-pr": [],
      "pr-auto-merge-enabled": "false", "pr-auto-merge-from-actors": [], "pr-auto-merge-limits": { … },
      "paths": ["envs/prod/**", "main/**", "modules/**", "/.tflint.hcl"], "paths-ignore": ["**/*.md"] },
    { "environment": "staging", "verdict": "skip", "reasons": ["relevance: no changed file matches"], … }
  ],
  "matrices": { "1": { "environment": ["prod"], "include": [ { "environment": "prod", "vars": { … } } ] } },
  "counts": { "affected": 1, "unaffected": 1 },
  "comments": {
    "heads": [ { "kind": "env", "key": "prod", "state": "placeholder", "title": "Terraform validation summary",
                 "marker": "<!-- tf:head:env:prod -->", "body": "### Terraform validation summary for environment: `prod`\n\n⏳ Awaiting results (run #4711 attempt #1)…" },
               { "kind": "env", "key": "staging", "state": "not-affected", … } ],
    "purge_tags_for": ["staging"],
    "gc": [ { "marker-prefix": "<!-- tf:tag:plan:staging:", "keep-marker-substring": "" }, … ]
  },
  "record": [ "prod: run — relevance: envs/prod/**", "staging: skip — relevance: no changed file matches" ]
}
```

An output with errors carries no environments, no matrices, no `relevance` and no `comments`: a
configuration error never leaves a matrix to run. A decision with no affected environment carries
the empty matrix `{"environment": [], "include": []}`; the workflow's count gate keeps it from
GitHub. Each environment entry carries, besides its verdict, what the jobs after the matrix read
for it whether or not it runs: the row's `github-environment`, `add-pr-comment`,
`pr-comment-group` and resolved `pr-auto-merge-*` values, `mutates-on-pr` (the `apply-on-pr` and
`destroy-on-pr` goals it holds, read as the workflow's `contains()` reads them), and its resolved
`paths` and `paths-ignore`. The features extend it to the full document:

```json
{
  "schema_version": 1,
  "errors": [],
  "notices": ["relevance diff (diff): 1 of 3 environments affected"],
  "relevance": { "mode": "diff", "reason": "diff", "changed_count": 3 },
  "environments": [
    { "environment": "prod", "verdict": "run", "reasons": ["trigger-events: pull_request", "relevance: envs/prod/**", "ordering: stage 2"],
      "stage": 2, "depends_on": ["shared"],
      "goals": ["init","format","validate","lint","plan"] },
    { "environment": "staging", "verdict": "skip", "reasons": ["relevance: no changed file matches"], "goals": [] }
  ],
  "matrices": { "1": { "environment": ["shared"], "include": [ … ] }, "2": { "environment": ["prod"], "include": [ … ] }, "3": { "environment": [], "include": [] } },
  "counts": { "affected": 2, "unaffected": 1, "by_stage": { "1": 1, "2": 1, "3": 0 } },
  "ordering": { "enabled": true, "stages_used": 2, "cap": 3, "bypass": null },
  "tests": {
    "matrix": { "include": [ … ] },
    "count": 12, "active": true,
    "not_run": [ { "file": "…", "lane": "…", "reason": "secrets unavailable" } ],
    "provider_sets": [ { "id": "a1b2c3", "environments": ["prod","staging"], "lock": "envs/prod/.terraform.lock.hcl" } ]
  },
  "warnings": [ "test file 'docs/x.tftest.hcl' is misplaced: …" ],
  "comments": {
    "heads": [ { "kind": "env", "key": "prod", "state": "placeholder", "title": "Terraform validation summary" },
               { "kind": "env", "key": "staging", "state": "not-affected", "title": "Terraform validation summary" } ],
    "purge_tags_for": ["staging"]
  },
  "record": [ "prod: run — trigger-events: pull_request; relevance: envs/prod/**; goals: init, format, validate, lint, plan",
              "staging: skip — relevance: no changed file matches" ]
}
```

- Each per-stage matrix and every `vars` object is what the workflow consumed from the bash
  builder, unchanged in shape and in value types (D9); the port (§9) proves it. Until ordering
  assigns stages there is one matrix, named `"1"`. A row's `vars` travel in the matrix only;
  `environments[]` carries the verdict, the reasons and, as the rules arrive, the goals and the
  stage.
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
  travel in `relevance.json`, uploaded as the `relevance` artifact that the seed job, the
  aggregator, the run summary and the auto-merge evaluator download, never as job outputs: a job
  output enters every `needs.*.outputs` interpolation downstream, and nothing caps it (the ARG_MAX
  rule of CLAUDE.md).

The other specs name the same data under their own output names. The mapping is normative:

| Spec | Name there | Here |
|---|---|---|
| Path-relevance.md §5.2 | the environments of `relevance.json` | `environments[]`: `verdict` `run` is affected, the `relevance:` reason names the matched rule, the resolved `paths` and `paths-ignore` on the entry |
| Path-relevance.md §5.2 | `affected-count`, `unaffected-count` | `counts.affected`, `counts.unaffected` |
| Path-relevance.md §4.3 | `relevance-mode`, `relevance-reason`, `changed-count` | `relevance.mode`, `relevance.reason`, `relevance.changed_count` |
| Terraform-tests.md §4.5 | `tests-matrix-json`, `tests-count`, `tests-active`, the not-run list | `tests.matrix`, `tests.count`, `tests.active`, `tests.not_run` (in `relevance.json`, not a job output); a row is exactly the §4.5 row schema |
| Terraform-tests.md §5.3 | provider sets | `tests.provider_sets` |
| Path-relevance.md §6.3, Terraform-tests.md §6.3 | the seed manifest and `gc-yml` | `comments.heads[]` with `kind` `group`, `env` or `tests`, `key`, `state` `placeholder` or `not-affected`, `title`, `marker` and the rendered `body` (with the mode line for an environment that mutates on pull request); `comments.purge_tags_for` (github-environments) and `comments.gc`, their four reconcile rules each; all empty on non-pull-request events, forks, `closed`, `converted_to_draft` and a document without `run` |
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
even when the case's expected output matches. An invariant is checked from the commit that builds
the rule it constrains; the port checks I7, I8, I11 and I12, relevance I6, I13 and I14, the test
stage I4 and I9, and properties of their own: an output with errors carries no environments, no
matrices and no relevance block, the record has one line per environment, the affected and
unaffected counts sum to the environments decided, and the test count, the active flag and the
test rows agree, with every slug unique.

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
| I10 | `model.py` rejects unknown top-level keys, no schema field holds a secret value, and the action's suite plants a sentinel in the process environment and in secret-shaped variables and asserts it never appears in the input file or any output. |
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

1. **Port cases** (§9), 73 of them under `tests/port/cases/<name>/`: the bash suite's three
   fixtures, the workflow's full default `toJSON(inputs)` (every key present, booleans as JSON
   booleans, which the old fixtures were not), seventeen anonymised shapes of the real callers, and
   one case per edge of the bash builder's code. `case.json` holds the inputs, the ref, the default
   branch and the directories that exist; `expected.json` is the bash builder's own output, pinned
   while it still ran; `input.json` is the document the adapter builds for the case. Each must decide
   the `matrix-json` of `expected.json`, compared as parsed JSON with row order (nothing downstream
   reads key order), or its errors in order. A case whose `engine_expected` records a deliberate
   deviation, with its reason, is held to that instead. The bash suite's helper cases migrated to
   `test_values.py` and its malformed-input cases to port cases; the vestigial `*_secrets-json.json`
   fixtures are gone. With the bash builder gone the port cases are the engine's regression goldens:
   a change that alters rows on purpose regenerates the input documents with
   `UPDATE_ENGINE_INPUTS=1 bash create-tf-vars-matrix/run_all_tests.sh` and the goldens with
   `UPDATE_PORT_GOLDENS=1 bash engine/run_all_tests.sh`, and the diff is what gets reviewed: every
   changed golden is a changed matrix for some caller.
2. **Table cases**: one per scenario in the feature specs' example sections, plus every validation
   error with its message, added with each rule.
3. **Generated cases**, deterministic and written nowhere: every value shape the rules branch on
   (absent, null, booleans, numbers, strings, lists, objects, a null leaf), per environment against
   global, for every `*-yml` field, on and off the default branch, plus parse failures on either
   side; every one is also decided with every object's keys reversed and must give the same output
   (I12). The features extend the dimensions: event × goals × relevance mode × dispatch × fork ×
   trigger-events × lanes × `depends-on` graph shape (random acyclic graphs up to the cap, plus
   deliberate cycles and over-cap chains).
4. **Random cases**: a seeded random walk of 3,000 documents over the same shapes, adding malformed
   entries (non-mapping environments, missing names, failed parses), asserting the invariants and
   that the engine either produces an output document or a validation error, never a crash.
   A second walk of 3,000 covers relevance: rule shapes, project directories, the switch, the
   events, the push and pull request facts and random changed files, and must reach both verdicts.
5. **Negative tests, one check at a time** (`test_validation.py`): every required field removed on
   its own, every not-empty field emptied on its own, each producing exactly its one message; the
   required fields deliberately allowed empty pinned as such; what counts as empty; the reporting
   order; the directory check failing closed for a path the adapter did not report; every forwarded
   input missing or empty end to end; and a structural test that every `matrix.vars.*` key the
   workflow reads is guaranteed by the required list, except the two recorded in §9.
6. **The checker checked** (`test_invariants.py`): each invariant fires on an output broken in
   exactly one way, so a checker that let everything through would fail.
7. **The contract with the readers** (`test_contract.py`, `relevance_fixture.py`): the
   aggregator, the run summary and the auto-merge evaluator test against hand-written
   `relevance.json` files, which a renamed key in the engine would leave green. The helper writes
   the file through the adapter's own `write_relevance_file` for three scenarios, each reader's
   suite runs its step on it, and `test_contract.py` pins the keys those readers read as literals
   and keeps the helper deciding.

Every table, port, generated and random case also asserts that `decide` leaves its input document
unchanged: the engine is a pure function of it.

**Suite entry and summary lines**: `engine/run_all_tests.sh` runs `tests/run_tests.py`, which runs
`tests/unit_runner.py` under coverage (the `unittest` modules, discovered), applies the gate and
prints exactly once, on stdout, the three lines of [Testing-in-ci.md](Testing-in-ci.md) §4
(`Tests run`, `Tests passed`, `Tests failed`) computed from the `TestResult` (failures, errors and
unexpected successes count as failed). The coverage gate and the mutation gate count as one more
test each, so a shortfall reads as a failed test in the pull request comment rather than an
all-green suite with a red job. Every port case is also decided in a subprocess under `PYTHONHASHSEED=0` and `=1` and the two
output files must be byte-identical (I12). The discovery script's second pass enrols a top-level
directory holding `run_all_tests.sh` without an `action.yml` (Testing-in-ci.md §2.1).

**Coverage**: the suite runs under `coverage` with branch measurement and fails when any file of
`dsb_tf_engine/` has a missing line or branch, read from `coverage json` rather than a rounded
percentage, naming the file, the lines and the branches. `coverage` is not preinstalled on the
hosted images and `pip install --user` is refused there by the externally-managed-environment
rule, so the suite invokes it through the preinstalled pipx, `pipx run --spec coverage==7.16.1
coverage`, and uses `python3 -m coverage` instead where it is importable (a developer's venv). The
pin, `COVERAGE_PIN` in `run_tests.py`, is bumped like any other dependency. A missing or failing
install fails the gate, because the gate is part of the contract (P4). The package carries no
`# pragma: no cover`; the module entry point is covered by running it through `runpy`.

**Mutation** (D12): `tests/mutation.py` rewrites the package's syntax tree one fault at a time,
never touching docstrings, and runs the suite against each mutant in its own copy of `engine/`, in
parallel, fast modules first, stopping at the first failure. Operators: comparisons flipped
(`==`/`!=`, `<`/`<=`/`>=`, `is`/`is not`, `in`/`not in`), `and`/`or` swapped, `not` dropped,
booleans inverted, integers nudged, strings emptied, one element dropped from a constant tuple or
list, `if`, conditional-expression, `while` and comprehension conditions forced both ways, a return
value replaced by `None`, a statement deleted, a `raise` replaced by `pass`, an exception type
dropped from an `except` tuple, a defensive copy (`dict`, `list`, `copy.deepcopy`) replaced by its
argument. The unmutated copy must pass first, or no mutant is judged, since a copy that fails for
its own reasons would count every mutant as killed. A surviving mutant that cannot change
behaviour is listed in `tests/mutation_equivalents.json` with the reason; the gate fails on an
unlisted survivor, on a listed key that no longer exists and on a listed mutant that is killed, so
the list cannot go stale. The package has no equivalent mutants today: the first run's
equivalents were redundant branches, and the code lost them instead. About twenty seconds on a
developer machine, all cores.

**The adapter** is tested like the core, under both gates: `test_adapter.py` stands in for `yq` and
`gh` and covers how each value is read before parsing, parse results, the `yq` probe and every way
it fails, the default branch from the payload and every way the payload and the API can fail,
the directory facts, a non-JSON or non-object inputs file, missing runner variables, the exact log
groups, escaped annotations, verbatim blocks and the published output; `test_workflow.py` covers
escaping, verbatim blocks and step outputs; `test_entry.py` covers `run.py`'s floor, its isolation
from the working directory and `PYTHON*` variables, and demonstrates the shadowing isolation
prevents; `test_purity.py` holds the core to its imports. Tests compare against literal values,
never the module's own constants: a test that reads the constant it checks passes whatever the
constant says.

**The action's suite**, `create-tf-vars-matrix/run_all_tests.sh`, runs the run block of
`action.yml` itself, extracted with `yq` and its expressions substituted as the runner pastes
them, with real `yq` underneath: every port case end to end against its golden, and every case's
logged input document against its `input.json`, so the engine is never tested against a document
the adapter would not build. It also covers the run block's shape, the default-branch fallback and
its failure, a broken `yq`, inputs that are not a JSON object, a JSON value holding the delimiter
line and shell syntax, caller values in the log, sentinels proving that neither the inputs nor
secret-shaped variables reach the adapter's environment or its documents (I10), and a caller's
`json.py` and `PYTHONPATH` failing to replace the standard library. CI also runs the engine suite
on Python 3.12 and the newest 3.x (Testing-in-ci.md).

**What tests cannot cover**: the action on a real runner. The run block is two commands, checked by
its structural test, the workflow's structural tests and the preview-ref run on
the test-bed repository.

## 9. The port

The engine decides exactly what the bash `create-tf-vars-matrix` decided, every semantic of it,
as read from that action and its helpers:

- every `*-yml` input parses as YAML, an empty string parses to `null`, an invalid one is the
  error `The specification for input '<name>' is not valid yaml!`, reported for the first such
  input in sorted order;
- every environment has `environment`, else "Missing property 'environment' in
  environments-yml specification!";
- `project-dir` defaults to `./envs/<environment>`, with the `./` prefix;
- generic forwarding: every workflow input that is not one of the nine `*-yml` inputs, in sorted
  order, is copied as a **string** into a row that lacks it (`"true"`, `"5"`, `""` for null, with
  trailing newlines stripped as the builder's command substitution stripped them); a
  per-environment value of a boolean input is normalised to `"true"`/`"false"` and must be true or
  false, as a boolean or a string; a per-environment value of any other input must be a string,
  kept verbatim (an unquoted `1.10` is a number YAML reads as `1.1`, so it is refused with "quote
  it"); arbitrary per-environment keys that are not inputs pass through untouched, a key ending in
  `-yml` included;
- `environment`, and `github-environment` when given, follow the name rule of D14;
  `github-environment` defaults to `environment`; `url` defaults to `""`;
- `allow-failing-terraform-operations`: absent is JSON `false`; present, it must be true or false,
  as a boolean or a string, and anything else (`yes`, `null`, a quoted `True`) is an error, never
  a silent false;
- replace fields (`goals-yml`, `terraform-init-additional-dirs-yml`): per-environment value, as
  YAML text or a native value, else the global, else `[]` when the global is null; invalid is
  `the environment's '<field>' is not valid yaml!`; stored under the name without `-yml`;
- merge fields (`extra-envs-yml`, `extra-envs-from-secrets-yml`, `extra-envs-per-goal-yml`,
  `extra-envs-from-secrets-per-goal-yml`, `pr-auto-merge-from-actors-yml`,
  `pr-auto-merge-limits-yml`): absent means the global value as is (a global `""` becomes
  `null`, not `{}`); present means a merge where null on either side yields the other, arrays
  concatenate with duplicates kept, objects deep-merge with the environment winning and null
  leaves preserved, and any other pairing is "unable to merge …";
- per-goal maps: every key of `init, format, validate, lint, plan, apply, destroy-plan, destroy`
  defaulted to `{}`; null or `false` yields the full key set; unknown keys pass through; a
  non-object other than a string passes through unchanged;
- the nine `*-yml` keys are removed from the row; `pr-auto-merge-enabled` is not a `-yml` input
  and is forwarded generically; a per-environment key named like a stripped field (`goals`,
  `extra-envs`, …) is overwritten;
- `caller-repo-default-branch`, `caller-repo-calling-branch` (`ref_name`) and
  `caller-repo-is-on-default-branch` as the strings `"true"` / `"false"`, overwriting any
  per-environment value;
- row order is `environments-yml` order;
- validation: the result is a non-empty array; the twenty-four required fields exist (the list
  lacks `runs-on` and `format-check-in-root-dir` although the workflow reads them; the port keeps
  the list, and the gap is a recorded finding, not a silent fix); the not-empty fields are not the
  empty string (`[]`, `{}` and `null` pass), every failure of every environment reported before
  stopping; then every `project-dir` exists, likewise all reported;
- the shape `{"environment": [names], "include": [{"environment", "vars"}]}` with `vars` the
  whole row; the action's only output is `matrix-json`, its only input `inputs-json`.

A port case is a dispatch, which fetches no changed files: every environment has verdict `run`
with the reason `relevance: all:event`, as before relevance. The deliberate deviations, each
pinned by a port case with its reason:

| Case | Bash builder | Engine |
|---|---|---|
| any configuration error | exit 1, messages as log lines or group titles | exit 2, each message a `::error` annotation |
| a duplicated environment name | accepted | an error (I7) |
| a per-environment boolean input, as a YAML boolean | kept a JSON boolean, which the gates' `== 'true'` silently dropped | normalised to the gates' `"true"`/`"false"` (D9) |
| a per-environment boolean input or allow-failing that is neither true nor false (`yes`, `null`) | silently false, or passed through | an error naming the environment, the field and the value |
| a per-environment value of a string input that is not a string | passed through, an unquoted `1.10` as `1.1` | an error asking to quote it |
| an environment name outside the name rule (a space, `:`, `/`, a number) | accepted | an error (D14) |
| two environments sharing a github-environment | accepted; comments overwritten, one metadata upload failed | an error (D14) |
| an empty `environments-yml` | a jq crash, no message | "The specification for input 'environments-yml' must be a list of environments!" |
| `environments-yml` a mapping | its values iterated as environments | the same error |
| an environment entry that is not a mapping | a jq crash, no message | "Missing property 'environment' …" |
| a per-goal map that is a string | a jq crash, no message | "the environment's '<field>' must be a mapping of goal names, not a string!" |
| malformed YAML in a per-environment field | exit 1 with no message: `log-error` ran inside a command substitution and its text became the captured value | "the environment's '<field>' is not valid yaml!" |
| two numbers in a merge field | multiplied by jq's `*` | "unable to merge …" |
| a failed default-branch lookup | the string `null` as the default branch | the step fails with the API's answer |

The port was built in this order, each step reviewable on its own: the goldens pinned while the
bash still ran and verified against it in CI; the engine and its suite; the discovery pass that
enrols the suite; the shim, whose suite runs every golden end to end; the internal refs moved to
`@v1`; then the bash shim was replaced by the adapter (D13) with every golden unchanged. A
preview-ref run on the test-bed repository closes it (§13).

## 10. Pitfalls

| # | Pitfall | Consequence | Rule |
|---|---|---|---|
| P1 | An old self-hosted runner may carry an older Python. | Syntax or import errors at start-up in the `create-matrix` job. | `run.py` checks the version before importing anything and exits naming the floor; `create-matrix` runs on the workflow's `runs-on`, which defaults to `ubuntu-latest`. |
| P2 | PyYAML is not on every runner. | An import error on the one runner without it. | YAML never reaches the core; the adapter runs `yq`. |
| P3 | Dictionary and set iteration order leaks into output. | Non-deterministic outputs, flaky goldens, flapping comments. | Sorted where the input has no order; I12 checks it. |
| P4 | `coverage` is not preinstalled, and `pip install --user` is refused on the hosted images (externally managed environment). | The suite cannot install its gate the obvious way. | `pipx run coverage==<pin>` (preinstalled pipx), `python3 -m coverage` as the fallback; the network access is accepted for CI; the gate is not optional. |
| P5 | The changed-file list can be a quarter of a megabyte. | ARG_MAX through the steps context if it ever became an output. | Files by path in the input document; outputs carry counts. |
| P6 | A step's `env:` and a dispatch payload hand every value over as a string. | `"false"` is truthy. | `workflow_inputs` is `toJSON(inputs)`, which keeps the declared types; the adapter normalises dispatch inputs to strings with `""` for an absent key; the model validates types and rejects the rest. |
| P7 | A crash in the engine is a `create-matrix` failure, which the conclusion reports red for every caller on the release. | A fleet-wide red on a bad minor of `v1`. | The random-case tests assert "never a crash"; the port's goldens; the preview-ref run before release. |
| P8 | The engine prints to stdout by habit. | Corrupts a command that expects the output document on stdout. | Output documents go to `--output` files; logging to stderr; a test asserts stdout is empty. |
| P9 | `capture-matrix-job-meta` strips keys that look like secrets. | A row field a summary must read back from metadata disappears (`fork-safe` was named for this). Today's rows already carry `pr-auto-merge-app-private-key-secret` and the `extra-envs-from-secrets*` maps, which are stripped and must stay so. | Only fields a downstream summary reads from metadata are validated against the filter; the port does not rename existing keys. |
| P10 | The decision record can grow long on a repository with many environments and files. | A run summary nobody reads. | One line per environment, one per test root, collapsed detail per file. |
| P11 | A per-environment YAML boolean stayed a JSON boolean in `vars`, and the workflow's gates compare with `== 'true'`; GitHub casts a boolean to a number and a string to NaN, so `true == 'true'` is false. | A per-environment `verify-lock-file: true` skipped the lock check; `add-pr-comment: true` left the seed job's placeholder head never updated. | A per-environment value of a boolean input is normalised to the gates' string (D9); `BOOLEAN_INPUTS` is held to the workflow's declared boolean inputs by a test. |
| P12 | The adapter gathers facts before the engine can validate the configuration. | A misconfigured caller pays for API calls before hearing about the typo. | `validate` on the partial document first (§3.2). |
| P13 | `github.event.repository.default_branch` is documented for push, pull request and dispatch payloads, not for `schedule`. | An unknown default branch on a scheduled run. | Verified on the test bed: the `schedule` payload carries it too, inside a called workflow as well. The API fallback stays, and fails the step loudly. |
| P14 | Retired: the runner's `bash -e` swallowing a step's exit code applied to the bash shim, which the adapter replaced. | | |
| P15 | `jq -r` prints null as `null`, but the builder read most fields through `select(. != null)`, which prints nothing. | Two renderings of null; mixing them changes the not-empty and directory checks. | `values.render` (the check's view) and `values.get_val` (the read's view), each used where the builder used it. |
| P16 | Command substitution strips trailing newlines, and a `log-error` inside `$(…)` writes into the captured value, not the log. | Forwarded strings lose trailing newlines; a per-environment YAML error failed with no message at all. | The port strips the same newlines and prints the message; the goldens pin both. |
| P17 | `pipx run` does not hand `PYTHONPATH` to the interpreter it starts. | The suite's modules cannot import the package on the hosted runners, though they do locally. | The unit runner puts the engine on `sys.path` itself; coverage takes the package by path; subprocesses run from `engine/`, where `-m` finds it. |
| P18 | argparse exits 2 on a usage error. | 2 is the engine's code for an invalid caller configuration: a caller misusing the command would read an output document that was never written and blame the caller. | The parser's usage errors exit 1; a test pins every usage error to 1. |
| P19 | Treating any `yq` failure as a failed parse. | A missing or broken `yq` reports every input as the caller's invalid YAML. | The adapter probes `yq` on a known document before parsing and fails naming `yq` and its own message. |
| P20 | A caller's value reaches the log: an environment name in the decision record, an error message, an API's answer. | A newline followed by `::warning::…` or `::add-mask::…` becomes a workflow command; a newline in an error message splits its annotation. | `workflow.py` prints logged values between `::stop-commands::` markers and escapes annotation data (`%25`, `%0D`, `%0A`; a title's `:` and `,` too). Only the caller's own configuration can do this, so it is hygiene, not a boundary, and the bash builder logged names raw as well. |
| P21 | `python3 -m` puts the working directory first on the import path, and an action's working directory is the caller's checkout. | A caller repository with a `json.py` or `argparse.py` at its root has it imported in place of the standard library; `PYTHONPATH` in the job's environment does the same. | Isolated mode: `python3 -I -B engine/run.py`, which adds only the engine's own directory; a test demonstrates the shadowing and one proves the isolation. |
| P22 | GitHub pastes an expression's value into the script text before bash parses it. | A value holding the heredoc's delimiter line ends it early and the rest runs as shell. | Only `toJSON` output is captured this way, which cannot hold a delimiter line; the delimiter is unique to the action; the adapter refuses anything that is not a JSON object. Free text never goes through a heredoc. |

## 11. Open questions

None for the port. What the first draft left open was answered by a survey of the calling
repositories and by the test bed, and the answers are in the text: no caller names a
workflow-level `runs-on`, so `create-matrix` runs on `ubuntu-latest` (ubuntu-24.04, Python 3.12;
ubuntu-26.04 ships 3.14, and the engine uses nothing beyond the standard library); `pipx run
coverage` runs on the hosted image under its Python and reports branches (§8, P17); the default
branch is in the `schedule` payload (P13); on `schedule`, `github.actor` and
`github.triggering_actor` are the account that last pushed the workflow file carrying the cron
line, which the dispatch spec's record line prints as it comes.

## 12. How the engine grows

Each feature lands as rules and table cases in the engine, its fact-gathering on the adapter side,
a few lines in the workflow, and the invariants of §7 that constrain its rules, in the order the maintainer chooses:
relevance rules and cases; test rules and cases with the adapter's test facts; dispatch
and trigger-events rules and cases, with the `goals-granted` switch of the operation gates and its
structural test; stage assignment. The port cases stay: a feature's default must leave every one
of them deciding as before, or say in its spec why not.

AI-assistant configuration files are never in these commits.

## 13. What implementation taught the spec

- **The parse boundary.** The first draft had the shim hand over the `*-yml` fields already
  parsed and let the engine parse per-environment YAML text. The engine cannot parse YAML (D2), so
  the adapter parses every `*-yml` input and every environment's `*-yml` keys and passes parse results
  (§3, §4); the engine picks what it reads and reports a failed parse in the builder's words. How
  each value is read before parsing is part of the contract, because YAML is sensitive to it:
  `echo` added a newline where `printf '%s'` did not.
- **`directories_exist` is spelled like the engine renders the path.** The bash shim re-derived the
  rule in jq; the adapter asks the engine (`environments.project_dir_path`), so the two cannot
  drift. It reports the directory each environment names, or `./envs/<environment>`; a null
  `project-dir` is the path `null`, which does not exist, as it never did.
- **Rows travel once.** The draft had every row's `vars` in `environments[]` as well as in the
  matrix. The port keeps them in the matrix only (§5); the decision record is what a reader needs
  from `environments[]`.
- **The bash builder's edges were real and are pinned.** Trailing newlines stripped from forwarded
  strings, null read two ways (P15), `false` treated as absent by jq's `//`, a per-environment key
  named like a stripped field overwritten, `caller-repo-*` overwriting per-environment values, the
  validation groups reported whole before stopping. The deviations are few and each is a case
  (§9).
- **Real callers' fixtures differ from the old ones.** GitHub delivers every declared input, with
  booleans as JSON booleans; the old fixtures had strings and left keys out. The default fixture
  and the seventeen caller shapes carry the real form; the old fixtures stay as they were, since
  strings are still handled.
- **The default branch is in every payload the workflow runs on**, `schedule` included, so the API
  call is a fallback that normally never runs (P13).
- **100 percent coverage was not enough.** The first mutation run, at full line and branch
  coverage, left 44 faults unnoticed: 40 of the 43 required and not-empty checks could be deleted
  one by one, a path missing from `directories_exist` could be read as existing, and CLI usage
  errors could exit with the configuration code. Each got a test, the gate (D12) keeps it so, and
  the redundant branches that made equivalent mutants were removed from the code.
- **The shim became Python, and the gates found what review had not.** The bash shim was the part
  the gates could not reach, and the one where the last faults were found: a broken `yq` blamed on
  the caller, caller values reaching the log as workflow commands, the working directory shadowing
  the standard library. Rewritten as the adapter (D13), it rebuilt all 73 input documents byte for
  byte. Its first mutation run, at full coverage, left 33 faults: most because the tests compared
  against the module's own constants (the `yq` arguments, the exit codes, the required variables),
  so a wrong constant passed. The tests now compare against literals.
- **Byte-identical preserved the builder's defects too.** Reviewed after the port for what should
  change, the engine still carried three: per-environment booleans the gates silently dropped (P11),
  environment names without a rule although they reach markers, artifact names and shell, and a
  github-environment two environments could share. Each was fixed test first: the tests were
  written and shown failing before the rule existed. Five port cases now record the old behaviour
  as a deviation, and three `-v1` cases hold the paths the old ones covered.
- **On the test bed the port is invisible.** Through a preview ref, a seven-environment
  configuration covering apply on pull request, destroy, outputs, allow-failing and a failing
  apply produced the same matrix as `@v0` on `workflow_dispatch`, apart from the calling branch;
  the `pull_request` and `push` runs built the matrix the same way and ran their whole graph as
  `@v0` does. No run needed the API for the default branch.
- **Relevance joined without moving a row.** The port cases are dispatches, which fetch nothing
  and run everything with the reason `relevance: all:event`; every golden changed only by the
  forwarded `path-relevance-enabled`. A document without changed files is mode `all` with the
  reason `not-computed`, so a caller of `decide` that builds no facts keeps its rows. The seed
  manifest in mode `all` was compared with the seed job's own jq on 300 random configurations and
  matched every one, which pinned a detail the draft had wrong: group heads are sorted, as jq's
  `unique` sorts them, not in first-seen order. The first mutation run on the new modules found
  seven survivors, each redundant code (a defensive copy, an early return whose value nobody read)
  or an untested literal; the code was removed or the literal tested.
