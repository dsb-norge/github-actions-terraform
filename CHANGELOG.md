# Changelog

Every release of `dsb-norge/github-actions-terraform`, newest first. Each entry after 1.0.0 is
written by release-please from the conventional commits merged since the release before it. A
calling repository pins `@v1`, which moves to every v1 release, or an exact `@v1.<minor>.<patch>`.
What changed from v0 to v1 as a whole, and how to move, is
[docs/V1-changes.md](docs/V1-changes.md) and the migration guides it links.

## [1.8.0](https://github.com/dsb-norge/github-actions-terraform/compare/v1.7.1...v1.8.0) (2026-10-06)


### Features

* the lock check warns on stale constraints instead of failing ([978e23f](https://github.com/dsb-norge/github-actions-terraform/commit/978e23fea5233fd9a3ce08a0dd36d980cd9311cb))

## [1.7.1](https://github.com/dsb-norge/github-actions-terraform/compare/v1.7.0...v1.7.1) (2026-10-06)


### Bug Fixes

* the admission judges a registry module named with a subdirectory ([9977a54](https://github.com/dsb-norge/github-actions-terraform/commit/9977a54afd3e3f50d58142dd3c97f6ae1c5b2dad))

## [1.7.0](https://github.com/dsb-norge/github-actions-terraform/compare/v1.6.1...v1.7.0) (2026-10-06)


### Features

* a project's dependabot pull request may move a 0.x minor ([b03e2fe](https://github.com/dsb-norge/github-actions-terraform/commit/b03e2feed2efbbf4bd2669858ea6721ab660659a))

## [1.6.1](https://github.com/dsb-norge/github-actions-terraform/compare/v1.6.0...v1.6.1) (2026-10-06)


### Bug Fixes

* auto-merge-pr says the run checked the pull request, not planned it ([23eeea7](https://github.com/dsb-norge/github-actions-terraform/commit/23eeea7fc118aa31ad1111f2d0c1b6383f482295))

## [1.6.0](https://github.com/dsb-norge/github-actions-terraform/compare/v1.5.0...v1.6.0) (2026-10-05)


### Features

* an environment test lane can name its own credentials ([64f4fc9](https://github.com/dsb-norge/github-actions-terraform/commit/64f4fc915322dd2a13d9158b2c773b0359c8361e))


### Bug Fixes

* the lock check names what differs instead of always missing hashes ([cba7298](https://github.com/dsb-norge/github-actions-terraform/commit/cba7298c6bb995f29ebab871e4d05c9d5583db70))

## [1.5.0](https://github.com/dsb-norge/github-actions-terraform/compare/v1.4.0...v1.5.0) (2026-10-05)


### Features

* a dependabot pull request auto-merges only within its majors ([47b4fff](https://github.com/dsb-norge/github-actions-terraform/commit/47b4fff83a05bbd33488d35c797d8c177fa0f470))

## [1.4.0](https://github.com/dsb-norge/github-actions-terraform/compare/v1.3.0...v1.4.0) (2026-10-05)


### Features

* a run summary for module runs ([78ecaf5](https://github.com/dsb-norge/github-actions-terraform/commit/78ecaf5ff1b537aa42a837bc94af670abb7f8a77))
* skip module validation and tests on documentation-only changes ([df23613](https://github.com/dsb-norge/github-actions-terraform/commit/df23613bf71543cbe8d4ba2a1c08375752c4e575))

## [1.3.0](https://github.com/dsb-norge/github-actions-terraform/compare/v1.2.0...v1.3.0) (2026-10-05)


### Features

* auto-merge a module repository's bot pull requests ([8fa727c](https://github.com/dsb-norge/github-actions-terraform/commit/8fa727ce465e621920a338dd993a45cae669a48a))
* module auto-merge keeps Dependabot within each major ([ff8c03e](https://github.com/dsb-norge/github-actions-terraform/commit/ff8c03e3e0a643619371066c672f70b70c8669d6))


### Bug Fixes

* commit module docs to Dependabot's PRs only when admitted ([81c3a1d](https://github.com/dsb-norge/github-actions-terraform/commit/81c3a1d2f03819128aa22370d1b4cead54282749))

## [1.2.0](https://github.com/dsb-norge/github-actions-terraform/compare/v1.1.0...v1.2.0) (2026-10-04)


### Features

* **comments:** show refused Dependabot pull requests in the summaries ([d7653f8](https://github.com/dsb-norge/github-actions-terraform/commit/d7653f866d097466335bf5593eb7c9b3015a2f5f))
* **engine:** gather the Dependabot admission's facts in the adapter ([cdb60f2](https://github.com/dsb-norge/github-actions-terraform/commit/cdb60f260c00cb8f88b2f7275aa9b5a16eef21b5))
* **engine:** judge Dependabot pull requests before they run Terraform ([5f1a9b7](https://github.com/dsb-norge/github-actions-terraform/commit/5f1a9b720dbff64723912bc9900ed29840cce6d6))
* **engine:** publish the module admission head and verdict ([440bf5a](https://github.com/dsb-norge/github-actions-terraform/commit/440bf5a6bc5f307009b6db118e16b225966c2128))
* **workflows:** commit the README on admitted Dependabot runs ([c769660](https://github.com/dsb-norge/github-actions-terraform/commit/c769660119ae3baeecc5d061d0903db628b97f65))
* **workflows:** post the admission head in the module workflow ([99c00f8](https://github.com/dsb-norge/github-actions-terraform/commit/99c00f8dbfdc25147e8615fb345d14a2ec324c08))
* **workflows:** run nothing for a refused Dependabot pull request ([fbf3016](https://github.com/dsb-norge/github-actions-terraform/commit/fbf301675a597e58306e4fa92b01a8eeeac367f2))

## [1.1.0](https://github.com/dsb-norge/github-actions-terraform/compare/v1.0.1...v1.1.0) (2026-10-02)


### Features

* **engine:** scheduled runs plan unless schedule-goal says otherwise ([758d73c](https://github.com/dsb-norge/github-actions-terraform/commit/758d73c8fa94b09396170384bc350397893ac1e6))

## [1.0.1](https://github.com/dsb-norge/github-actions-terraform/compare/v1.0.0...v1.0.1) (2026-10-01)


### Bug Fixes

* **module-ci:** name the App access a repository lacks ([f46c845](https://github.com/dsb-norge/github-actions-terraform/commit/f46c845cfced4b3d80f7cf2b3d97b2952890ed58))
* **verify-terraform-lock:** lock-only ignores re-padded version lines ([b0917c9](https://github.com/dsb-norge/github-actions-terraform/commit/b0917c992d9655547bf214f82b59ebd0d699ca0f))

## [1.0.0](https://github.com/dsb-norge/github-actions-terraform/tree/v1.0.0) (2026-09-29)

The first release of the v1 line: the decision engine, path relevance and the conclusion check,
the terraform test stage, dispatch and trigger events, configuration validation, environment
ordering, and module CI on the engine's module mode. The pull requests of the v1 line, each with
its commits:

### [#59](https://github.com/dsb-norge/github-actions-terraform/pull/59) feat: the decision engine, ported from the bash matrix builder (v1)

- test(create-tf-vars-matrix): pin the builder's output as port goldens
- feat(engine): the decision engine, ported from the bash matrix builder
- feat(ci): enrol top-level test suites that are not actions
- refactor(create-tf-vars-matrix): run the decision engine behind a thin shim
- refactor(workflow): internal refs name @v1
- docs: the engine spec as built; road to v1 tracked in V1-progress.md
- chore(ai): CLAUDE.md for the decision engine and the v1 line
- fix(engine): command-line usage errors exit 1, not the configuration code
- refactor(engine): render through json.dumps for every non-string
- test(engine): every rejection on its own, the invariant checker, purity
- test(engine): a mutation gate beside the coverage gate
- fix(create-tf-vars-matrix): name a broken yq; keep caller values out of workflow commands
- docs: the mutation gate, the negative tests and three new pitfalls
- chore(ai): CLAUDE.md on the mutation gate
- feat(engine): the create-matrix adapter, under both gates
- refactor(create-tf-vars-matrix): the action runs the adapter; the bash shim is gone
- ci: run the engine suite on Python 3.12 and the newest 3.x
- docs: the adapter, the isolated entry, the 3.12 floor, the layout convention
- chore(ai): CLAUDE.md on the adapter, python3 -I and the layout convention
- docs(progress): the adapter on the test bed and on both Pythons

### [#60](https://github.com/dsb-norge/github-actions-terraform/pull/60) fix: keep caller values out of shell source in heredoc captures

- fix(pr-comment): the inline body travels through env:, never the script
- fix: YAML and path lists reach their steps through env:, never a heredoc
- refactor: every JSON heredoc capture gets a delimiter unique to its input
- test: every heredoc capture holds JSON under a unique quoted delimiter
- docs: how a value reaches a step script
- chore(ai): CLAUDE.md on how a value reaches a step script
- docs(progress): record #60, its validation and the direct-interpolation finding
- fix(pr-comment): capture the inline body as toJSON, keep it out of envp
- fix: capture reconcile YAML and module-cache paths as toJSON, out of envp
- test: F9 accepts toJSON of an input and refuses raw free-text captures
- docs: free text is captured as toJSON; the envp history, so it is not reversed again
- chore(ai): CLAUDE.md on toJSON captures and checking the envp history
- docs(progress): the toJSON captures on the test bed
- docs(progress): #59 merged and in v1; #60 on main
- chore(ai): CLAUDE.md tags v1 with --cleanup=verbatim

### [#61](https://github.com/dsb-norge/github-actions-terraform/pull/61) fix(engine): field types, the name rule, one environment per github-environment

- fix(engine): per-environment values of workflow inputs take the inputs' types
- fix(engine): environment names follow one rule
- fix(engine): a github-environment belongs to one environment
- docs: the field types, the name rule and the unique github-environment
- chore(ai): CLAUDE.md on BOOLEAN_INPUTS and the name rule
- docs(progress): record #61
- docs(progress): #61 on the test bed, with an @v1 control

### [#62](https://github.com/dsb-norge/github-actions-terraform/pull/62) feat: path relevance and the conclusion rewrite

- docs(path-relevance): fetch in the adapter; diff a new branch against the default
- feat(engine): the one glob matcher
- feat(engine): path relevance rules
- feat(engine): the adapter fetches the changed files
- feat(engine): the seed manifest
- feat(create-tf-vars-matrix): publish the relevance decision
- feat(create-run-summary): relevance-file
- feat(evaluate-automerge-eligibility): relevance-file
- feat(aggregate-validation-summaries): relevance-file
- feat(workflow): path relevance and the conclusion rewrite
- docs: path relevance as built
- chore(ai): CLAUDE.md on path relevance
- docs(progress): step 2, path relevance, on the test bed
- feat(engine): a root anchor in the glob grammar
- test: the relevance.json contract between the engine and its readers
- test(workflow): F11, the relevance decision reaches its readers intact
- test(create-tf-vars-matrix): every fetch path end to end
- docs(progress): the root anchor and the coverage pass on #62
- docs(progress): the root anchor on the test bed

### [#64](https://github.com/dsb-norge/github-actions-terraform/pull/64) feat: the terraform test stage

- docs(terraform-tests): the open questions probed; one job, discovery in the engine
- docs(progress): #62 merged; step 3 paused on its open questions
- docs(terraform-tests): who sets environment secrets, the step anchor
- docs(terraform-tests): locks must cover the runner; the test job's own cache key
- docs(terraform-tests): isolation, a real lane and credential case, verified in Entra
- feat(terraform-init): backend, lockfile-mode and a plugin-cache opt-in
- feat(capture-matrix-job-meta): entity-name and artifact-name
- test(export-env-vars): pin the current behaviour as goldens
- refactor(export-env-vars): convert to the layout guide
- feat(export-env-vars): export secrets by name prefix
- feat(terraform-module-cache): audit the run-block modules of test files
- test(terraform-test): pin the current behaviour as goldens
- refactor(terraform-test): convert to the layout guide
- feat(terraform-test): the test stage's runner and classifier
- feat(create-test-summary): one structured summary of the test stage
- feat(engine): tests.py, the test stage's rows
- feat(engine): the adapter's test facts and the published test matrix
- feat(verify-terraform-lock): lock-only mode, before init
- feat(workflow): the terraform test stage
- docs: the terraform test stage as built
- chore(ai): CLAUDE.md on the terraform test stage
- docs(progress): step 3 in draft as #64, validated on the test bed
- feat(export-env-vars): lower-case copies of prefix-exported secrets
- feat(workflow): lower-case copies of an environment lane's TF_VAR_ secrets
- feat(terraform-test): Terraform 1.13 floor, published for the summary
- docs(progress): step 3 decisions, and a real OIDC lane before v1
- docs(progress): the decisions verified on the test bed
- docs(road): audit identities before a repository with tests moves

### [#65](https://github.com/dsb-norge/github-actions-terraform/pull/65) feat: dispatch and trigger events, the goals-granted gates

- docs(progress): #64 merged; step 4 begins
- docs(dispatch): schedule per environment only
- docs(progress): schedule per environment only, decided
- feat(engine): trigger events, the dispatch filter and granted goals
- feat(create-run-summary): the trigger lines of a dispatch or schedule
- feat(workflow): trigger-events-yml and the goals-granted gates
- docs: dispatch and trigger events as built
- chore(ai): CLAUDE.md on dispatch and trigger events
- docs(progress): step 4 in draft as #65
- docs(progress): step 4 on the test bed
- fix(engine): goals are a list of known names, a single one alone
- fix(engine): a dispatch's goal apply never brings the destroy goals
- docs: goals as known names, and apply as a dispatch cap
- docs(road): hardening of caller configuration and auto-merge as step 5
- docs(progress): the goals fixes on the test bed

### [#66](https://github.com/dsb-norge/github-actions-terraform/pull/66) feat: configuration validation and a hardened auto-merge

- docs(progress): #65 merged; step 5 begins, with a thorough docs refresh
- docs: configuration validation and auto-merge, specified
- docs(auto-merge): tolerated operations block, tolerated tests do not
- feat(engine): relevance published for every environment
- feat(engine): the keys an environment may hold
- feat(engine): goals need their prerequisites, in plain messages
- feat(engine): variable values as written, a null means not set
- feat(engine): auto-merge settings and init directories checked
- feat(engine): a tag is never the default branch; dispatch inputs named
- fix(terraform-init): an additional directory holding a space is one
- test(parse-terraform-plan): JSON plan fixtures, console counts pinned
- feat(terraform-plan): JSON plan kept on the runner, stderr apart
- feat(parse-terraform-plan): counts from the JSON plan when given
- test(contract-tests): count each plan from its JSON plan too
- feat(evaluate-automerge-eligibility): goals-granted, operations, actors
- fix(auto-merge-pr): pin the merge to the planned head and base
- feat(workflow): auto-merge evidence and pins wired, scope narrowed
- docs: configuration validation and auto-merge, as built
- docs: dispatch, relevance, contract tests and tests specs, as built
- docs(decision-engine): flow charts, and rule 1 as built
- chore(ai): a new input is classified, list settings are replaced
- docs(workflow): worked examples, each checked against the engine
- docs(auto-merge): the stale-head refusal, confirmed live
- docs(progress): step 5 built, validated on the test bed, handed off
- docs: flow charts for auto-merge and configuration validation

### [#67](https://github.com/dsb-norge/github-actions-terraform/pull/67) feat: environment ordering in up to three stages

- docs(progress): #66 merged; step 6 begins; four steps before the release
- docs(ordering): the contract between the engine, the workflow and the renderers
- feat(engine): environments ordered in up to three stages
- feat(create-run-summary): held-back environments
- feat(aggregate-validation-summaries): held-back environments
- feat(evaluate-automerge-eligibility): held-back reason
- feat(workflow): environments in up to three ordered stages
- test(workflow): hold the three stage jobs to one shape
- docs: environment ordering, as built
- docs(workflow): ordering in the user guide, and the stage jobs in its chart
- chore(ai): the three stage jobs and the ordering module
- docs(progress): step 6 built, validated on the test bed, handed off

### [#68](https://github.com/dsb-norge/github-actions-terraform/pull/68) feat: the open-questions pass, and the fixes it turned up

- docs(road): CI optimisation before module CI
- docs(progress): the open-questions pass, triaged
- fix(engine): nothing to run, not nothing to verify, where there is no change
- fix(engine): a missing lock is mentioned only when a test takes the locks
- fix(engine): runs-on and format-check-in-root-dir required, fields checked in key order
- docs: the engine's unbuilt commands dropped, and no cancel-in-progress advice
- fix: read run-block values from env instead of pasting them
- chore(workflow): download artifacts with actions/download-artifact@v8
- fix(create-validation-summary): name an on-PR goal only when granted
- fix(workflow): queue the test jobs instead of cancelling a pending one
- chore(auto-merge-pr): use a generic repository in the local runner
- fix(workflow): say "nothing to run" on a schedule or dispatch
- docs(progress): what the step-7 fixes turned up, and what is still to do
- fix(engine): mutates-on-pr lists only the on-PR goals the event grants
- fix(aggregate-validation-summaries): name an on-PR goal only when granted
- docs(apply-and-destroy-reporting): the Mode row reads what was granted
- docs(progress): the step-7 test-bed round and the mode-row fix
- chore: check out with actions/checkout@v7
- chore: cache with actions/cache@v6
- chore: mint App tokens with actions/create-github-app-token@v3
- docs(progress): the action bumps and their test-bed check
- docs: no private repository names in this public repository

### [#69](https://github.com/dsb-norge/github-actions-terraform/pull/69) ci: run the engine's mutation gate once, sharded and faster (road step 8)

- perf(engine): the mutation gate reaches a mutant's own tests first
- feat(engine): run the mutation gate in shards and merge them
- ci: run the engine's mutation gate once, in four shards
- test: every suite writes its step output to a file of its own
- chore(ai): the sharded mutation gate and per-suite output files
- ci: split the engine's mutation gate into eight shards
- chore(ai): the mutation gate runs in eight shards
- docs(progress): step 8, the CI optimisation, as measured
- ci: report the mutation gate in the PR comment like a suite
- chore(workflow): mint the auto-merge token as upstream documents it

### [#70](https://github.com/dsb-norge/github-actions-terraform/pull/70) feat: module CI on v1 (road step 9)

- fix(module-ci): plain spaces in the Azure secret expressions
- chore(module-release): release-please-action v5.0.0
- chore(terraform-docs): terraform-docs/gh-actions v1.4.1
- chore(ai): the legacy actions that are left
- docs(progress): step 9's analysis and the decisions it waits on
- docs: the module CI spec
- feat(engine): a module mode that decides the test stage alone
- feat(create-tf-vars-matrix): a mode input for the module workflow
- refactor(terraform-docs): move the action to the modern layout
- feat(terraform-docs): push only when asked, fail on a diff otherwise
- feat(create-validation-summary): a module's head, without lock or plan rows
- feat(module-ci): the module workflow on the project workflow's test stage
- feat(module-ci): the validation head names the module
- feat(module-release): the App token from actions/create-github-app-token@v3
- refactor: retire create-tftest-matrix and create-test-report
- chore(ai): terraform-docs is off the legacy list
- refactor(terraform-test): require working-directory, drop legacy shape
- refactor(terraform-test): drop the junit gate the floor covers
- docs(terraform-tests): the action without the legacy call shape
- docs: the module mode and the module test bed, as built
- chore(ai): module CI and the copied test jobs in CLAUDE.md
- docs(progress): step 9 built, and the test bed so far
- docs(workflow-terraform-module-ci): the v1 module CI guide, as built
- docs(workflow-terraform-module-release): the App token, as built
- fix(module-ci): no App token on a Dependabot run; contents: read is enough
- docs(module-ci): the spec where it disagreed with the workflow
- fix(module-ci): the tests summary waits for validation, and skips after a docs push
- docs: module CI validated on the test bed

### [#71](https://github.com/dsb-norge/github-actions-terraform/pull/71) docs: v1 docs finalisation (road step 10)

- docs(apply-and-destroy-reporting): drop the status line, as built
- docs(terraform-tests): as built, and the open OIDC lane login
- docs(decision-engine): the stage matrices and the port, as built
- docs(configuration-validation): drop the status line and road links
- docs(auto-merge): drop the status line
- docs(environment-ordering): drop the status line
- docs(per-goal-environment-variables): the matrix and secrets as built
- docs(dispatch-and-triggers): queue: max on the stage jobs, as built
- docs(path-relevance): the dispatch filter and test locks, as built
- docs(testing-in-ci): the extracted-step suites and the required check
- docs(preview-refs): consumption and cleanup observed, as built
- chore(ai): pitfall count, pinning and the required tests check
- docs: what changed in v1, for callers of the default workflow
- docs: a migration guide from v0 to v1
- docs: link the v1 changes and the migration guide
- docs(migration): what a caller without id-token sees, as observed
- docs(progress): step 10 under way
- docs(path-relevance): the conclusion's wiring as built
- docs(testing-in-ci): the untested actions in the comment example
- docs(development-and-release): the v1 tag and append-only changelogs
- docs(development-and-release): test-bed validation and doc conventions
- docs(action-implementation-guide): F16, F18, F19 and hand-broken rules
- docs(testing-in-ci): why eight shards, and suites on files of their own
- docs(path-relevance): the fail-open and docs-only cases seen on the test bed
- docs(environment-ordering): the queue interleaving as observed
- docs(dispatch-and-triggers): the §6 rows as run on the test bed
- docs(configuration-validation): the rules as run on the test bed
- docs(auto-merge): the merge through a real App, as observed
- docs(terraform-tests): when a lockless environment is named in a notice
- docs(workflow-terraform-ci-default): App bypass and test-lane advice
- chore(ai): F16, F19 and the doc conventions in CLAUDE.md
- docs(dispatch-and-triggers): the re-run by another account is test-only
- docs(development-and-release): the minor example's heading names its tag
- docs(path-relevance): the auto-merge wiring of §8 as built
- docs(progress): the road documents' content captured
- docs(terraform-tests): the OIDC lane login, as run on the test bed
- docs(progress): the OIDC lane closed
- docs: module repositories in the migration guide and the v1 changes
- docs(migration): contents: read for a module repository
- docs(progress): the maintainer's items for the step-10 pull request
- refactor(setup-terraform-plugin-cache): move the action to the modern layout
- docs(testing-in-ci): every action has a suite
- chore(ai): no legacy actions are left
- feat(ci): the Action tests comment shows how long the tests took
- docs: a migration guide of its own for module repositories
- docs(progress): the step-10 items done
- docs(readme): list every action and the workflows' real file names
- chore(ai): the retired create-test-report and five ARG_MAX patterns
- docs(decision-engine): the engine as built, not as first planned
- docs(workflow-terraform-module-ci): the tests summary job's needs
- docs(module-ci): permissions, needs and suites as the workflow has them
- docs(configuration-validation): three input classes, v0 dirs, yq tags
- docs(dispatch-and-triggers): the adapter, all's goals and invariants
- docs(environment-ordering): references, examples and reasons as built
- docs(development-and-release): the delete commands and module validation
- docs(path-relevance): gates, readers and lines as the workflow has them
- docs(workflow-terraform-module-ci): Dependabot, test roots and the template
- docs(workflow-terraform-module-release): v0 used an App token from v0.9
- docs(development-and-release): release examples that fit the release lines
- docs(module-ci): the validate job's init is a plain init
- docs(action-implementation-guide): every action is converted; F9 and F16
- docs(terraform-tests): steps, gates and outputs as the workflow has them
- docs(workflow-terraform-ci-default): stages, the lock gate and key hints
- docs(workflow-terraform-ci-default): a schedule example that parses
- docs(testing-in-ci): the engine jobs where the spec left them out
- docs(preview-refs): the spec as built, without the delivery plan
- test(preview): no local outside a function in the refs suite
- test(structure): F12 names the lock check's step as numbered
- docs(workflows): a switched-off test stage keeps its head
- docs(module-ci): D9's reason without a template claim
- docs(migration-v0-to-v1-modules): the lint pitfall is in §8
- docs(terraform-module-cache): the input wiring and messages as built
- docs(auto-merge): the merger's stops and the counts' input as built
- docs(migration-v0-to-v1): no HTTP(S) proxy for the App token step
- docs(v1-changes): five test inputs, no proxy, module test events
- docs(per-goal-environment-variables): the conversions and wiring as built
- docs(workflow-pr-comments): heads, bodies and permissions as built
- docs(plan-warnings): the parser, annotations and budget as built
- docs(apply-and-destroy-reporting): the reporting as built
- docs(pr-comment): drop the unchanged-body short-circuit claim
- docs(comments): point section references at the sections as built
- docs(comments): name the terraform-plan action without a @v0 ref
- docs(terraform-tests): the disabled stage's head as its own lifecycle step
- docs(aggregate-validation-summaries): describe the upsert and guards
- docs(progress): steps 7 to 9 merged, the as-built pass done
- docs: an index of the documentation by kind
- test(structure): F22, the index lists every document
- chore(ai): point at the documentation index

### [#72](https://github.com/dsb-norge/github-actions-terraform/pull/72) refactor: every step script ends with exit

- refactor: six step scripts end with exit, as the guide says
- refactor(setup-terraform-plugin-cache): helpers from the action path
- test(structure): F23, every step script ends with exit
- chore(ai): F23 enforces the step script ending
- docs(progress): step 10 merged; the step script endings

## v0

The v0 line, frozen at 0.33; it takes fixes only, on the `release/v0` branch. Each entry is its
tag's annotation.

## [0.33](https://github.com/dsb-norge/github-actions-terraform/tree/v0.33) (2026-09-22)

- Apply, destroy plan and destroy now report the way plan always has: one pull
  request comment per operation, status, counts, timing and warnings in the
  per-environment and grouped heads, a per-environment block on the run page,
  and a run-level table covering every environment on push, schedule and
  dispatch runs where there are no comments at all.
- A finished apply is never reported as failed. The outcome follows the step's
  exit code, and counts that cannot be read render as '?' with a warning asking
  for the console, instead of a red "infrastructure may be partially applied".
- Plan and apply summaries name every kind of change, imports, moves and
  removals included. An apply that only adopted existing objects no longer
  reads as "no changes".
- Runs against the same environment queue instead of cancelling. A third run
  entering the group no longer cancels the one already waiting, which used to
  surface as a failed check indistinguishable from a real failure.
- Warnings from destroy plan, apply and destroy are counted and shown
  separately from plan warnings.
- Two workflows calling this one on the same pull request no longer delete each
  other's comments.
- Comment bodies travel as files rather than step outputs, so a large plan or a
  long comment thread can no longer fail a job with "argument list too long".
- The head's title now follows what the run actually did rather than what its
  goals allowed, and an operation's comment can no longer contradict the status
  row above it.
- Testing an unreleased change uses preview refs: every pull request publishes a
  moving preview/pr-<N> and an immutable preview/pr-<N>-<sha7>, both pointing at
  a commit whose internal refs are rewritten. The dev-tag swap procedure is gone.
- Both output parsers are pinned against real Terraform console output for every
  summary shape, and a weekly contract test runs them against the newest six
  Terraform minors, so a wording change in a new release is caught here rather
  than in a calling repository.
- The module CI test report posts through the shared comment primitive, and the
  test-report action is converted to the modern action layout behind golden
  fixtures.
- Specifications for the v1 workflow: the decision engine, terraform test as a
  stage with credential lanes, per-environment path relevance and the conclusion
  check, dispatch and trigger events, ordering between environments, and the road
  to v1. Documentation only, nothing behaves differently on v0.

## [0.32](https://github.com/dsb-norge/github-actions-terraform/tree/v0.32) (2026-09-07)

- fix(parse-terraform-plan): detect output-only plans with data reads

## [0.31](https://github.com/dsb-norge/github-actions-terraform/tree/v0.31) (2026-09-02)

- fix: run every local step runner in a subshell
- docs: record three traps that each cost a CI round trip
- perf(terraform-module-cache): drop git metadata before saving the cache
- feat(terraform-init): name a module clone refused for want of credentials
- feat(terraform-init): authenticate github.com module clones

## [0.30](https://github.com/dsb-norge/github-actions-terraform/tree/v0.30) (2026-09-02)

- fix: parse per-environment yml overrides before handing them to jq
- docs: reconcile the spec with the last round of fixes
- fix: bound module blocks so a provider version cannot pin a module
- fix: stop a module-cache step from being able to fail a terraform run
- refactor: explain the module cache steps for a reader who has not read the spec
- docs: reconcile the spec with the implementation
- feat: cache terraform modules in the default workflow
- feat: add the cache-terraform-modules workflow input
- feat(terraform-module-cache): add the module cache action
- docs: spec the terraform module cache
- refactor: label every action run block for the actions log
- docs: require every run block to open with a description comment

## [0.29](https://github.com/dsb-norge/github-actions-terraform/tree/v0.29) (2026-08-18)

- fix: detect a jq too old for --raw-output0 instead of applying nothing
- test: assert the goal vocabulary agrees across its three copies
- test(create-tf-vars-matrix): cover the failure paths
- test(export-env-vars): add a suite covering the export paths
- fix(resolve-goal-envs): accept an empty goal block
- fix: fail the step when the working directory cannot be entered
- fix(terraform-fmt,lint-with-tflint): fail when no directories are found
- fix: fail loudly when a per-goal environment file is unusable
- docs: document per-goal environment variables for callers
- feat(terraform-ci-cd-default): wire per-goal environment variables
- feat: apply per-goal environment variables in the goal actions
- fix(export-env-vars): fail on secret names missing from the secrets bag
- feat(resolve-goal-envs): new action resolving per-goal environment variables
- feat(create-tf-vars-matrix): add per-goal extra-envs inputs
- refactor(terraform-plan): build the terraform invocation as an array
- refactor(lint-with-tflint): convert to modern step-script layout
- refactor(terraform-fmt): convert to modern step-script layout
- refactor(terraform-apply): convert to modern step-script layout
- docs: add spec for per-goal environment variables

## [0.28](https://github.com/dsb-norge/github-actions-terraform/tree/v0.28) (2026-06-01)

- docs: add Plan-warnings spec for surfacing terraform warnings on PRs
- refactor(terraform-init): convert to modern step_*.sh layout + tee console
- refactor(terraform-validate): convert to modern step_*.sh layout + tee console
- feat(parse-terraform-warnings): new action — surface Warning: blocks on PRs
- feat(create-validation-summary): render warnings row + collapser, fix UTF-8 cut
- feat(aggregate-validation-summaries): render Warnings row in grouped table
- feat(ci-cd-default): wire parse-terraform-warnings into the matrix
- fix(auto-merge-pr): stop exporting heredoc-captured github.event JSON
- docs: document ARG_MAX / heredoc-export anti-pattern
- feat(aggregate-validation-summaries): omit Warnings/Plan-details rows when empty
- refactor(create-validation-summary): sync per-env head with grouped head
- docs: convert ASCII-art diagrams to Mermaid

## [0.27](https://github.com/dsb-norge/github-actions-terraform/tree/v0.27) (2026-05-25)

- fix(ci-cd-default): unblock matrix on non-PR events when seed skips
  - v0.26 introduced a new seed-pr-comments job correctly guarded by github.event_name == 'pull_request'. On push / workflow_dispatch / schedule events that job skipped — but terraform-ci-cd had 'needs: [create-matrix, seed-pr-comments]' with no explicit 'if:'. GitHub Actions' implicit 'if: success()' requires every needs dep to be 'success', so a 'skipped' dep made the matrix skip too, and everything downstream (pr-comment-aggregator, pr-auto-merger) cascaded. Symptom on calling repos was a push-to-main run that 'succeeded' without actually running terraform. Adds an explicit 'if:' on terraform-ci-cd that tolerates seed-pr-comments being either 'success' (PR events) or 'skipped' (everything else), still requires create-matrix to have succeeded, and propagates upstream cancellation via !cancelled(). Reproduced cleanly on a calling repository's push run on main.

## [0.26](https://github.com/dsb-norge/github-actions-terraform/tree/v0.26) (2026-05-25)

- feat: PR comments overhaul — heads + tags model
  - Per-env comment split into a long-lived 'head' (PATCHed in place across runs, holds its position in the PR conversation, validation table + Links row) and a run-scoped 'plan tag' (carries the plan extract, re-POSTed each run). Heads pre-allocated by a new seed-pr-comments job at the top of the workflow in deterministic order, so per-env + per-group comment ordering never flips between runs. Plan tags are purged as the first post-checkout step in each matrix job — stale plan output vanishes within seconds of a re-run starting, and the per-env cleanup survives 'Re-run failed jobs' paths where the seed job doesn't re-fire. Marker namespace unified under '<!-- tf:head:* -->' and '<!-- tf:tag:* -->'; plan-tag markers embed run-id + attempt so re-runs don't collide with prior attempts. Grouped envs (pr-comment-group set) no longer get a standalone per-env head — they're represented in the per-group head's rolled-up table only.
- feat: new action pr-comment — single-comment primitive (upsert/delete by HTML marker, self-heals duplicates, degraded-mode fallback). Terraform-agnostic; usable from any workflow. 17 tests.
- feat: new action pr-comments-reconcile — bulk seed + GC for ordered head manifests + tag pruning. 15 tests.
- refactor(create-validation-summary): split into head-summary + plan-extract outputs; new plan-tag-comment-id input renders a Links row inside the per-env head's table anchored at the just-POSTed plan tag. Legacy summary + prefix outputs retained as deprecated shims for terraform-module-ci.yaml. 57 tests.
- refactor(aggregate-validation-summaries): per-group marker renamed to '<!-- tf:head:group:* -->'; Links-column [log extract] anchor retargeted from the per-env head to the env's plan tag with run-id scoping (fixes a silent bug where the [log extract] line never rendered post-v0.23); footer relabelled from [Job log] to [Workflow log] (URL was always the run page; label was wrong). 38 tests.
- fix(capture-matrix-job-meta): keep large inputs out of envp and argv to avoid E2BIG on the env with the largest plan output. Two execve thresholds along the same data path: shim no longer exports the matrix/github/steps JSON inputs (envp stays clean) and the final jq -n switched from --argjson to --slurpfile (argv stays clean). Symptom before the fix was that env's column silently dropped from the per-group summary table; aggregator received fewer matrix-job-meta-*.json artifacts than expected (reproduced on a calling repository). 18 tests.
- docs: full rewrite of docs/Workflow-pr-comments.md as the desired-state spec for the heads + tags model. README and docs/Workflow-terraform-ci-default.md updated for the new actions.
- operational note: existing per-group PR comments on in-flight PRs from v0.23/v0.24/v0.25 become orphans on rollout — the new code can't see them via the new '<!-- tf:head:group:* -->' marker. Operators delete them by hand. Documented no-migration policy in docs/Workflow-pr-comments.md.

## [0.25](https://github.com/dsb-norge/github-actions-terraform/tree/v0.25) (2026-05-22)

- feat: Plan time row (mm:ss) in PR comment validation tables
  - terraform-plan now publishes a 'plan-time' output with the wall-clock duration of the plan invocation (always populated, even on failure). create-validation-summary renders a trailing '⏱ | Plan time | mm:ss' row in the ungrouped per-env table; aggregate-validation-summaries renders the same row in the per-group table (between Plan details and Links). Cells carry a 'mm:ss (minutes:seconds)' hover tooltip; missing values render as 'N/A' (ungrouped) / '—' (grouped).
- refactor: terraform-plan converted to modern step_*.sh layout (per docs/Action-implementation-guide.md) with PATH-shadowed mock terraform test harness — 45 tests, no real terraform binary invoked.
- fix(aggregate-validation-summaries): upsert by HTML marker; self-heal duplicates
  - Per-group PR comments now upsert by an invisible HTML marker on body line 1 (PATCH-in-place when an existing marker is found, POST fresh when not). Multiple marker comments for the same group are collapsed to one — oldest is patched, rest are deleted. Replaces the prior delete-by-prefix + post-fresh reconcile, which suffered from a bash associative-array overwrite bug that let stale group comments accumulate (reproduced on a calling repository). Legacy pre-marker comments are intentionally ignored to avoid a transitional shim — operators clean those up by hand.
- feat: action-tests PR workflow with annotated summary
  - Discovers every '*/run_all_tests.sh' suite, fans out via matrix, aggregates into a single PR comment + run-page step summary + headline annotation. Drift in canonical summary lines fails the suite. Exposes 'tests-conclusion' as the branch-protection gate.
- chore: align auto-merge-pr summary lines with canonical format
- docs: point CLAUDE.md at the action-tests workflow + canonical format
- fix: address Copilot review feedback on PR #39

## [0.24](https://github.com/dsb-norge/github-actions-terraform/tree/v0.24) (2026-05-20)

- feat: PR comment condensation
  - Per-env footer reduces to a single [Job log](url) line (pusher/action/workflow data dropped — already in the PR conversation header and on the linked job page). Same condensation applied to per-group aggregator footer.
  - Grouped-mode per-env comments drop the 'Part of group <name> — see the grouped summary below.' pointer (grouped summary already anchor-links back to per-env comments).
  - Plan extract block becomes count-aware: 'Plan: no changes ✅' for zero-change plans, '<details><summary>Plan: N changes ℹ️</summary>' for N>0, '<details><summary>Plan: output-only changes ℹ️</summary>' for Terraform's output-only-changes path, legacy 'Show Plan (last 65k characters)' fallback when count parsing fails.
- feat: parse-terraform-plan emits new outputs count-total and has-output-only-changes
- fix: per-env PR comments always refresh, even when an early infrastructure step (setup-tflint, azure/login, plugin-cache, ...) fails. create-validation-summary and comment-on-pr now run under always(). No more stale per-env comments after a transient setup failure.
- refactor: setup-tflint converted to modern action layout (5 step_*.sh files, helpers, local runners) per docs/Action-implementation-guide.md
- feat: setup-tflint short-circuits the GitHub Releases API call for specific tflint versions. Tag-name from input, download-url constructed deterministically from the stable tflint_linux_amd64.zip asset pattern. Cache hits become fully offline. Eliminates the curl-exit-92 / HTTP/2-stream-error failure class (reproduced on a calling repository).
- test: new hermetic setup-tflint test suite (19 tests with fake curl/unzip on PATH)
- docs: docs/Workflow-pr-comments.md updated for v0.24 plan-block rendering modes and footer shape

## [0.23](https://github.com/dsb-norge/github-actions-terraform/tree/v0.23) (2026-05-18)

- feat: PR comment grouping via per-env pr-comment-group field
  - New optional 'pr-comment-group' field in environments-yml. Envs sharing a non-empty group value get a combined validation-summary PR comment (one column per env) posted by a new pr-comment-aggregator job. Their per-env comments drop the validation table and keep only the plan extract. Default behavior unchanged when no env declares a group.
  - New action: aggregate-validation-summaries. Reconciles per-group comments every PR run (handles orphan sweep after group rename/disable).
- docs: add Workflow-pr-comments.md spec and CLAUDE.md project guide
- test: lock down ungrouped per-env comment output (15 byte-level backwards-compat tests in create-validation-summary)

## [0.22](https://github.com/dsb-norge/github-actions-terraform/tree/v0.22) (2026-05-13)

- chore: bump bundled github/hashicorp/azure actions to LTS running Node.js 24

## [0.21](https://github.com/dsb-norge/github-actions-terraform/tree/v0.21) (2026-05-13)

- feat: add verify-lock-file toggle to disable lock file verification

## [0.20](https://github.com/dsb-norge/github-actions-terraform/tree/v0.20) (2026-05-06)

- feat: wire verify-terraform-lock into ci/cd workflow
- feat: add lock file row to validation summary
- feat: add verify-terraform-lock action

## [0.19](https://github.com/dsb-norge/github-actions-terraform/tree/v0.19) (2026-03-08)

- fix: handle output-only changes in plan parser

## [0.18](https://github.com/dsb-norge/github-actions-terraform/tree/v0.18) (2026-03-03)

- feat: make auto-merge GitHub App credentials configurable
- fixup feat: add auto-merge-pr action
- feat: integrate auto-merge workflow
- feat: add PR auto-merge configuration inputs
- feat: add auto-merge-pr action
- feat: add evaluate-automerge-eligibility action
- feat: add capture-matrix-job-meta action
- feat: skip operations when PR closed or draft
- feat: add global runs-on input to workflow
- refactor: reorder input fields in create-tf-vars-matrix
- docs: reorder environment settings alphabetically
- docs: fix typos and field references in workflow

## [0.17](https://github.com/dsb-norge/github-actions-terraform/tree/v0.17) (2026-03-02)

- fix: avoid E2BIG error when plan output exceeds ARG_MAX
- refactor: extract create-validation-summary inline bash to step script
- test: add tests for parse-terraform-plan action
- refactor: extract parse-terraform-plan logic to step script
- docs: add action implementation guide
- feat: add job logs link to validation summary
- fix: improve move and remove count parsing in plan parser

## [0.16](https://github.com/dsb-norge/github-actions-terraform/tree/v0.16) (2026-02-13)

- feat(terraform plan): add JSON output support for terraform plan

## [0.15](https://github.com/dsb-norge/github-actions-terraform/tree/v0.15) (2025-11-21)

- fix(parse-terraform-plan): account for more moved scenarios in the log

## [0.14](https://github.com/dsb-norge/github-actions-terraform/tree/v0.14) (2025-09-22)

- chore(create-tf-vars-matrix): default runner type to `ubuntu-latest`
- chore: module ci wf - hardcode runner type to `ubuntu-latest`

## [0.13](https://github.com/dsb-norge/github-actions-terraform/tree/v0.13) (2025-09-04)

- chore(module workflow): unused optional input to validation-summary
- feat(ci workflow): include terraform plan on pr in more scenarios
- feat(validation-summary): support multiple terraform plan sources
- chore: vscode settings - add some color

## [0.12](https://github.com/dsb-norge/github-actions-terraform/tree/v0.12) (2025-09-02)

- feat: ci workflow: add plan details to pr comment when possible
- feat: new action for parsing terraform plan files

## [0.11.0](https://github.com/dsb-norge/github-actions-terraform/tree/v0.11.0) (2025-04-23)

- fix: ci workflow - concurrency, do not cancel running jobs

## [0.11](https://github.com/dsb-norge/github-actions-terraform/tree/v0.11) (2025-04-23)

- fix: ci workflow - concurrency, do not cancel running jobs

## [0.10](https://github.com/dsb-norge/github-actions-terraform/tree/v0.10) (2025-04-07)

- feat: add az login step to ci workflow. Step is conditional and executed when variables for tenant subscription and client id are submited.

## [0.9.1](https://github.com/dsb-norge/github-actions-terraform/tree/v0.9.1) (2025-03-26)

- fix: ci workflow: conclusion step run on github hosted runner

## [0.9](https://github.com/dsb-norge/github-actions-terraform/tree/v0.9) (2025-03-26)

- fix: module release wf - ensure module ci trigger release PRs
- docs: module ci wf - sort secrets and variables correctly
- docs: improved steps for releasing

## [0.8](https://github.com/dsb-norge/github-actions-terraform/tree/v0.8) (2025-03-20)

- chore: module release wf - bump `release-please-action`
- feat: module ci wf - parallelize and fail on updated docs
- fix: module ci wf - ensure wf re-trigger on push to PR branch

## [0.7.1](https://github.com/dsb-norge/github-actions-terraform/tree/v0.7.1) (2025-03-14)

- fix: terraform-docs action revursive caused root README.md recreation.
fix: .terraform-docs.yml presence check in examples folder failed due to wrong path.

## [0.7](https://github.com/dsb-norge/github-actions-terraform/tree/v0.7) (2025-01-20)

- feat: support parametrization of 'runs-on' for terraform default CICD job, with default value set to 'dsb-terraformer' ( current self-hosted runners, hardcoded before).
docs: updated examples with new parameters.
chore: Changed default runner for matrix creation to GitHub-hosted ubuntu-latest
fix: tf-run-matrix action project path changed to relativ from full to support usage of GitHub hosted runners.

## [0.6.1](https://github.com/dsb-norge/github-actions-terraform/tree/v0.6.1) (2024-12-04)

- fix: remove mode from terraform-docs action and file to pass in default "inject"

## [0.6](https://github.com/dsb-norge/github-actions-terraform/tree/v0.6) (2024-12-03)

- feat: terraform docs action inject default config to repo root.
It checks also if 'examples' folder is in repo and inject config there.
Then README.md added with main.tf per example.

## [0.5](https://github.com/dsb-norge/github-actions-terraform/tree/v0.5) (2024-11-20)

- feat: new workflow for terraform module tag and release based on google release-please action.
docs: REAMDME.md documentation of new workflow

## [0.4](https://github.com/dsb-norge/github-actions-terraform/tree/v0.4) (2024-11-11)

- feat: new terraform docs action to for module ci, that automatically inject tf-docs to README.md. .
- feat: terraform-module-ci updated with generate-docs step.

## [0.3.1](https://github.com/dsb-norge/github-actions-terraform/tree/v0.3.1) (2024-10-31)

- feat: allow apply to run on event ```schedule```.

## [0.3.0](https://github.com/dsb-norge/github-actions-terraform/tree/v0.3.0) (2024-10-25)

- feat: terraform test action.
feat: terraform module ci workflow.
feat: create-tftest-matrix action.
feat: create-test-report action.
feat: setup-terraform-plugin-cache monthly roling key output to support repos without lock.hcl.

## [0.2.1](https://github.com/dsb-norge/github-actions-terraform/tree/v0.2.1) (2024-09-27)

- chore: reference update for directore-recreate

## [0.2](https://github.com/dsb-norge/github-actions-terraform/tree/v0.2) (2024-02-23)

- chore: terraform-plan - bump actions/upload-artifact action to node20 - compatible version `v4`
- feat: setup-tflint - cache plugins
- feat: setup-tflint - make github api calls authenticated to prevent rate limiting
- fix: workflow: prevent tf provider cache from growing infinitely

## [0.1.1](https://github.com/dsb-norge/github-actions-terraform/tree/v0.1.1) (2024-01-31)

- Bumped dependencies

## [0.1](https://github.com/dsb-norge/github-actions-terraform/tree/v0.1) (2024-01-17)

- fix(terraform-fmt): skip modules in `.terraform` directory
- fix(lint-with-tflint): skip modules in `.terraform` directory

## 0.0 (the first v0)

- feat: `v0` of DSBs GitHub actions and reusable workflows for terraform projects
- feat: separate into more actions and add common `helpers.sh` script
- fix: do not install tf wrapper script, causes noise in tf output
- feat: allow failing operations for environment
  - A new optional flag `allow-failing-terraform-operations` is introduced in the workflow input `environments-yml`. The flag is specified on a per environment basis. Default value is `false`.
  - If the flag is set to `true` for an environment the workflow will not terminate upon failing terraform operations. Failing steps will also be ignored in the workflows conclusion step.
- feat: workflow: install TFLint only when needed
- fix: apply: help GitHub with control characters from apply command
- feat: setup-tflint: introduce caching of the binary
- feat: introduce caching of terraform provider plugins
- fix: terraform-plan: action output `exitcode` now returns a vaule
- feat: setup-tflint: introduce caching of the binary
- feat(terraform-init): support input `plugin-cache-directory`
- chore: workflow: use plugin cache during init of additional dirs
