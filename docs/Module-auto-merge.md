# Module auto-merge

Authoritative spec for auto-merge in
[`terraform-module-ci.yaml`](../.github/workflows/terraform-module-ci.yaml): which pull requests of
a module repository merge without review, from what evidence, and how the merge is tied to that
evidence. The project workflow's auto-merge is [Auto-merge.md](Auto-merge.md); this spec reuses its
merge, and differs where a module differs.

## 1. Why

A module repository's routine pull requests come from two bots. Dependabot bumps a module the
module calls at an exact version; with the
[Dependabot admission](Dependabot-admission.md) on, an admitted bump is validated, tested and gets
its regenerated README committed. release-please opens a release pull request after each change to
the default branch that warrants a release. Both then wait for a person to press merge, which is
routine work nobody should have to do: the evidence that would justify the merge, a green run, is
already there.

The project workflow's auto-merge cannot be reused as it stands, for three reasons:

1. Its evidence is plan counts per environment. A module has no environments and no plan; its
   evidence is validation and the tests.
2. It judges the run's actor, `github.actor`. On a Dependabot pull request whose README changed,
   the run that decides is the one the docs job's commit starts, and its actor is the CI App, not
   Dependabot. Listing the App as an actor would merge any person's pull request whose README the
   docs job regenerated.
3. The merge needs an App token. The module workflow already has one App, the organization's CI
   App, for the docs commit and the releases.

## 2. Decisions

| # | Decision | Rationale |
|---|---|---|
| M1 | The **pull request's author** (`pull_request.user.login`) must be in the list, and the list names **bots only**. | Decided by the maintainer: the author survives the docs job's commit, which the run's actor does not. Bots only: a person in the list would have their own web-edited commits, which GitHub signs, merged unreviewed. |
| M2 | The **deciding run** is started by the author, or by the CI App's docs commit; **a person's run never merges**. A Dependabot pull request merges only in a run the admission admitted, or in the run its docs commit starts. | A person who reopens, labels or updates a refused Dependabot pull request starts a run nobody judges (Dependabot-admission.md D2); its commits are still Dependabot's. The review found it. |
| M3 | **Every commit** is the author's, signed by GitHub itself, except the docs commits at the head, in the run their push started (§3). | The commit check keeps a person's commit on a bot's pull request from merging, and the signature keeps a forged author from passing as the bot. |
| M4 | On a Dependabot pull request the docs job commits only in Dependabot's own admitted run: its App token is keyed on the pull request's author, not only on the run's actor. The rule accepts a docs commit on Dependabot's pull request only with the message the docs job writes in that run, `terraform-docs: automated action [dependabot skip]`. | Fixes Dependabot-admission.md D22: a person's run on a Dependabot pull request got a docs commit, and with it a run of the App's on a change nobody judged. The fix keeps that from happening again, but docs commits made before it remain on open pull requests, and on the test bed one merged a refused bump (P9). Every version that commits to a Dependabot pull request writes that message only in Dependabot's own run, and commits there only once the admission admitted it, so the message proves the head beneath. |
| M5 | **release-please's release pull requests merge too.** A pull request whose author is another bot than Dependabot must come from release-please's branch (`release-please--branches--<default branch>`) and change only `CHANGELOG.md` and `.release-please-manifest.json`. | Decided by the maintainer: a `fix(deps)` bump is released with no person involved, each bump its own release. The branch and the two files keep the CI App, whose key the docs job and the release workflow also hold, from merging anything else it authors: release-please's `terraform-module` type can also write `README.md`, `versions.tf`, `versions.tf.tmpl` and `metadata.yaml`, and a `versions.tf` can hold any Terraform. A release that touches them is merged by a person. |
| M6 | The inputs are the project workflow's names, **`pr-auto-merge-enabled`** (default `false`) and **`pr-auto-merge-from-actors-yml`**. The **CI App** (`ORG_TF_CICD_APP_ID`, `ORG_TF_CICD_APP_PRIVATE_KEY`) merges; there are no App inputs. | Decided by the maintainer: one way to configure auto-merge, and no second key to keep. |
| M7 | A list that names `dependabot[bot]` needs `dependabot-admission-enabled: true`; otherwise the configuration is refused. | Without the admission nothing judges a Dependabot run before it would merge. |
| M8 | The evidence is the run's: `Terraform conclusion` green, `Validate module` succeeded, or was skipped because the module is not affected by the change (Module-ci.md §5.1), and the docs job pushed nothing. A test tolerated by `allow-failing-terraform-tests` does not block. | The conclusion already judges validation, the tests and the admission. A release pull request changes only `CHANGELOG.md`, which nothing validates. A run whose docs job pushed is superseded by the run its commit starts. Tolerated tests: as the project workflow (Auto-merge.md D13). |
| M9 | The merge is the project workflow's `auto-merge-pr`, unchanged: pinned to the evaluated head and to the base the run saw, a rebase merge (Auto-merge.md §6). | Merge what was tested, and only that. |
| M10 | Only a pull request against the default branch, from the same repository (Auto-merge.md D9), judged by the engine (rule 1) and again in the merge job's condition. | A fork's run has no secrets, and its code is never merged unreviewed. In the rule, the notice says why such a pull request is not merged. |
| M11 | A commit listing that fails, is cut short, or does not end with the evaluated head makes the run **not eligible**, with a notice; it never fails the run. | Auto-merge is the run's last, optional step: failing closed costs a person's click, failing the run would turn a green change red. (The admission fails the run instead, D11 there, because it gates whether code runs at all.) |
| M12 | The rule is the decision engine's, in module mode; the adapter gathers the commits. The CI App's identity, which only the merge job's token knows, is confirmed there. | Every decision is a rule in the engine's pure core, under its coverage and mutation gates (Decision-engine.md D13); the App's slug is an output of its token step. |
| M13 | **Dependabot's pull request merges only within each dependency's major**: a provider or a called module whose version changes major, or, below 1.0, minor, is merged by a person. | Decided by the maintainer: people choose the majors a module supports (Module-dependencies.md). Dependabot's `ignore` of majors does not hold when it rewrites a provider range: a module repository got `~> 4.20` → `~> 5.7` despite it, which the admission would have admitted once old enough and auto-merge would have released as a patch that drops azurerm 4. Below 1.0 semver lets any minor break, and the Azure Verified Modules are all 0.x. |

The repositories also get a ruleset requiring `tf / Terraform conclusion` on the default branch,
without required reviews, so that a person cannot merge a pull request the run refused, and the
App's merge needs no bypass. That is the organization's configuration, not this workflow's.

## 3. The rule

The author is the pull request's `user.login`, the actor the run's `github.actor`, the head the
event's `pull_request.head.sha`; logins compare without case. A run is eligible when all of these
hold, and the notice names the first that does not:

1. **The pull request is one auto-merge considers**: it is from the repository itself, against
   the default branch (the runner's `github.base_ref`), and its author is listed. A run of a
   pull request that is closing or converted to a draft is not judged at all.
2. **The commits are known**: the listing succeeded, holds fewer than 250 commits and as many as
   the event's `pull_request.commits`, no commit lists 3000 files or more, and its last commit is
   the head.
3. **Every commit has one parent**: no merge commit, such as GitHub's "Update branch" makes.
4. **Every commit is the author's, or a trailing docs commit.** The author's: its author login
   (the account GitHub resolved for it; a commit GitHub resolved to none is no one's) equals the
   author, `commit.verification.verified` is `true`, and its committer is GitHub itself
   (`web-flow`). A docs commit modifies, and only modifies, files the docs job writes:
   `<readme-file-path>/README.md` and `examples/<example>/README.md`; it may add or modify
   `.terraform-docs.yml` and `examples/.terraform-docs.yml`, the default configs the docs job
   commits where a repository has none. No rename, no deletion, no empty commit. Docs commits may
   only follow the author's: the docs job pushes up to two, one for the examples and one for the
   module.
5. **The run is the right one.** With docs commits at the head, the actor is a bot other than
   `dependabot[bot]`, and the merge job confirms it is the CI App (§6); on Dependabot's pull
   request, each docs commit's subject is also `terraform-docs: automated action [dependabot skip]`,
   the message the docs job writes only in Dependabot's own run, which commits only once the
   admission admitted it (M4). Without docs commits, the actor is the author, and for
   `dependabot[bot]` the admission admitted this run.
6. **Another bot's pull request is a release**: when the author is not `dependabot[bot]`, the
   pull request's head branch is `release-please--branches--<default branch>`, and the author's
   commits change only `CHANGELOG.md` and `.release-please-manifest.json`.
7. **Dependabot's pull request stays within each dependency's major** (M13): for every
   dependency the change touches, as the admission reads it (a provider's newest version its
   constraint allows, before and after; a module's selected version or ref), the major stays the
   same, and below 1.0 the minor too. A version that cannot be read, facts that were not
   gathered, and a change with no dependency the admission recognised are not eligible. The
   project workflow's auto-merge applies the same rule, through the same function
   (`automerge.leaves_major`, [Auto-merge.md](Auto-merge.md) D15).

Why a signature, and why GitHub's: a commit's author is whatever its maker says, so anyone with
write access can author a commit as `dependabot[bot]`. Dependabot's commits are signed by GitHub
with `web-flow` as committer, and so are the commits release-please makes through the API with the
App's token (seen on the module repositories). A forged one is not: verified on the test bed, a
commit made through the contents API with a person's token and `dependabot[bot]` as author, or as
author and committer, is `unsigned`. `verified` alone is not enough, because it vouches for the
committer: a person who signs with their own key and names `dependabot[bot]` as author gets a
verified commit whose committer is the person. A docs commit is unsigned (the docs job commits with
git); it is accepted only at the head, only in the run its push started, only from the CI App, and
on a Dependabot pull request only with the message of Dependabot's own run, which commits only on
top of an admitted head (M4, and the docs job's pin, Dependabot-admission.md P23). The message is
not a signature: anyone with write access can write it, but their push starts their own run, which
rule 5 refuses, and only the docs job pushes with the App's token. Its content is the docs job's: terraform-docs rewrites the section
between `BEGIN_TF_DOCS` and `END_TF_DOCS`, and the rest of the file is as the author's commits left
it.

What the rule protects: auto-merge merges the bots' own changes and the generated docs, and nothing
else. It does not protect a repository from a person who holds write access; where no review is
required, such a person can merge their own pull request without forging anything. An App
installed with write access that writes commits through the API, which GitHub signs, could forge an
author; such an App is trusted that far already (R3).

| Pull request | The deciding run | Eligible |
|---|---|---|
| Dependabot's, README unchanged | Dependabot's own, admitted | yes |
| Dependabot's, README regenerated | the one the docs commit starts, actor the CI App | yes |
| Dependabot's, refused, then reopened or labelled by a person | the person's | no: rule 5 |
| Dependabot's, refused, with a docs commit a person's run made before M4 | the one that docs commit started | no: rule 5 |
| Dependabot's, a person pushed or pressed "Update branch" | the person's | no: rules 3 to 5 |
| Dependabot's, a provider's major, or a 0.x module's minor | any | no: rule 7 |
| release-please's | the App's own push | yes |
| a person's | the person's | no: rule 1 |
| from a fork, or against another branch | any | no: rule 1 |

## 4. Facts

Only on a `pull_request` run with `pr-auto-merge-enabled: true`, the adapter lists the pull
request's commits and each commit's files:

- `gh api repos/<repo>/pulls/<number>/commits?per_page=100&page=<n>`: each commit's SHA, parent
  count, author login (or none), committer login, subject (the message's first line) and
  `commit.verification.verified`. GitHub returns at most 250 commits.
- `gh api repos/<repo>/commits/<sha>?per_page=300&page=<n>` (at most 3000 files) for every
  commit's files: each file's name, `status` and, for a rename, `previous_filename`; the pages'
  lists are joined. Every commit's, so that which commits need them stays the rule's alone; a bot's
  pull request has a few.
- From the event: the head SHA, the head branch and the commit count.

Only when rule 1 holds: an unlisted author, a fork or another base is ruled out without a call.

For Dependabot's pull request, rule 7 reads the admission's facts (Dependabot-admission.md §8):
each dependency the change touches, with its version before and after. Dependabot's own run
gathers them for the admission; in the run the docs commit starts, which the admission does not
judge, the adapter gathers them for rule 7 alone. A fact it cannot gather there leaves them out,
and the run is not eligible (M11), where the admission would fail Dependabot's own run (D11
there).

A failing call gives the fact `{"available": false, "reason": …}`; the engine then rules the run
not eligible (M11). The step needs `pull-requests: read`, which `create-matrix` gains.

## 5. The engine

Module mode, on a `pull_request` run with the switch on:

- **Validation**, on every event: `pr-auto-merge-enabled` must be true or false, and
  `pr-auto-merge-from-actors-yml` is checked as the project workflow's global input
  (Configuration-validation.md §3.6): its shape and the bots-only rule always, the rest when the
  switch is on. Two messages are the module's own:
  - `pr-auto-merge-from-actors-yml names octocat, which is not a bot; the module workflow merges bots' pull requests only (their commits are signed by GitHub, a person's web edits are too).`
  - `Auto-merge may merge Dependabot's pull requests (pr-auto-merge-from-actors-yml names dependabot[bot]), but the Dependabot admission is off, so nothing judges them before they run. Switch dependabot-admission-enabled on, or remove dependabot[bot] from the list.`
  With the switch on, an empty list is the message naming the input. The default is `"[]"`, as
  in the project workflow.
- **The rule**: §3, over the facts, the event and the admission's verdict.
- **Output**: `automerge` in the module output and `relevance.json`: `{"applies": false}`, or
  `applies`, `author`, `actor`, `eligible`, `reason`, `confirm_app` (true when docs commits are at
  the head) and `commits[]` (each with `sha`, `author`, `kind`: `author`, `docs` or `other`).
- **Step outputs**: `automerge-eligible`, `true` only when the rule says so, and
  `automerge-confirm-app`.
- **Notice**: `auto-merge: eligible: dependabot[bot]'s pull request, 2 commits (1 the author's, 1 docs)`, or the reason it is not, such as `auto-merge: not eligible: the run was started by octocat, neither the author (dependabot[bot]) nor the CI App's docs commit`.

## 6. The workflow

- Inputs `pr-auto-merge-enabled` (boolean, default `false`) and `pr-auto-merge-from-actors-yml`
  (string, default `"[]"`), described as in the project workflow, with the module's meaning: the
  list names the bots whose pull requests may merge.
- `create-matrix`: `pull-requests: read`, and the outputs `automerge-eligible` and
  `automerge-confirm-app`.
- The docs job's App token on a Dependabot pull request (M4): requested when
  `pull_request.user.login` is not `dependabot[bot]` and the actor is not either, or when the
  admission admitted the run.
- A job `automerge`, `PR auto merger`, `permissions: {}`, after `create-matrix`, `generate-docs`,
  `validate` and `conclusion`, when all of them succeeded (`validate` also when skipped because
  `affected-count` is `0`), `automerge-eligible` is `true`, the docs
  job pushed nothing, the switch is on, and the run is a `pull_request` that is not closing, not a
  draft, against the default branch, from the same repository. Its steps:
  1. the App check and the App token, as in the docs job (the variable and the secret named when
     missing, the Dependabot secret on a Dependabot run), with contents and pull requests write;
  2. with `automerge-confirm-app`, the actor confirmed as the App: `github.actor` must equal the
     token step's `app-slug` followed by `[bot]`, or the job stops with an error annotation;
  3. `auto-merge-pr` with the token, `toJSON(github.event)`, `head-sha` and `merge-sha`.
- On a Dependabot run the App's key is the Dependabot secret the docs commit already needs
  (Dependabot-admission.md D22); on the App's own runs, the Actions secret.
- A caller lists, for example, `["dependabot[bot]", "<the CI App's slug>[bot]"]`: Dependabot's
  pull requests, and release-please's, which the CI App opens.

## 7. Releases

A merged `fix(deps)` bump makes release-please update its release pull request, a push by the CI
App, whose run is the App's own. That run validates and tests the module as any other, and its
merge tags the version and publishes the release. The docs commit's message, `terraform-docs:
automated action [dependabot skip]`, is not a conventional commit, so it adds nothing to the
changelog.

## 8. Pitfalls

| # | Pitfall | Consequence | Handling |
|---|---|---|---|
| P1 | The deciding run after a docs commit is the CI App's, not Dependabot's. | Judging `github.actor` would either never merge such a pull request or, with the App listed, merge a person's. | M1, M2: the author, and the run. |
| P2 | A commit's author can be set to any name. | A forged `dependabot[bot]` commit would pass as Dependabot's. | GitHub's signature (§3). |
| P3 | A person's run on a Dependabot pull request (reopened, labelled, updated) is judged by nobody, and the docs job committed in it. | A refused bump would merge, its docs commit included. | M2 and M4. |
| P4 | The docs job commits a default `.terraform-docs.yml` where a repository has none, and pushes up to two commits. | A docs commit holds more than READMEs, and there can be two. | The configs count as docs files; trailing docs commits are accepted. |
| P5 | A rename into `README.md` is listed under its new name. | Code could leave the repository in a "docs" commit. | A docs commit only modifies; `previous_filename` is not docs. |
| P6 | Dependabot rebases a pull request only to resolve a conflict. | In a burst, the second bump's base moved, the base pin refuses it, and it waits for Dependabot's next update of it, or a person's `@dependabot rebase`. | Accepted, as in the project workflow (Auto-merge.md, examples). |
| P7 | A caller that triggers `push` on every branch gets a second `Terraform conclusion` on the same commit (Dependabot-admission.md P5). | A merge while the push run is still going is refused by the ruleset. | The module callers trigger `pull_request`, `schedule` and `workflow_dispatch` only. |
| P8 | A module that reads its README through `file()` or `templatefile()`. | A docs commit changes what the module does. | Not detected; such a module should not list the bots. |
| P9 | A docs commit made on a Dependabot pull request before M4, in a person's run, sits on a head nobody admitted. Seen on the test bed: a person reopened a refused bump, the run used the merge commit GitHub had not yet recomputed, and with it the docs job from before the fix, which committed; the App's run that followed, on the new workflow, ruled the pull request eligible and merged it. | A refused bump merges. | Rule 5: on Dependabot's pull request a docs commit counts only with the message of Dependabot's own, admitted run. |
| P10 | Dependabot's `ignore` with `update-types: ["version-update:semver-major"]` did not hold for a provider range: a module repository got `~> 4.20` → `~> 5.7`. | A provider major merges and is released as a patch. | Rule 7; the module repositories' Dependabot updates modules only (Module-dependencies.md). |

## 9. Tests

- Engine: every rule of §3 failing alone, and the table's rows; a forged unsigned author's commit; a
  person's signed commit with a forged author; a commit with no resolved author; a merge commit; a
  docs commit with a non-docs file, a rename, a deletion and no file; two trailing docs commits and
  a docs commit before an author's; a docs commit on Dependabot's pull request without the
  admitted run's message, and one on a release without it; the configs; author case; a listing
  that fails, is capped, is short of the event's count or ends elsewhere; a release on another
  branch or with another file; a provider and a module within and past their major, a 0.x minor,
  an unreadable version, missing and empty dependency facts;
  the switch off; a non-`pull_request` event, a closing one, a fork and another base; the
  validation messages; the notice and the step outputs. The mutation gate over the new code.
- Adapter: the commit and file listings answered, paginated, failing and capped, and the calls made
  only for an author on the list; the admission's facts gathered in the App's run on Dependabot's
  pull request, once in Dependabot's own, never for another bot, and a gathering that fails; the
  create-matrix suite runs the action's shim with a stub `gh`.
- Workflows: F27 holds the `automerge` job's needs, condition, permissions, steps, the App check
  (the docs job's), the App confirmation, run for the App, another bot and a missing slug, the
  pins, and the engine's docs message equal to the docs job's on a Dependabot run; F24 counts a
  third token step; F26 checks the docs job's token keyed on the pull request's
  author.
- On the test bed: an admitted Dependabot pull request with a docs commit merges; one refused and
  then reopened by a person does not; one a person pushed to does not; a release pull request
  merges and releases.

## 10. Residual risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | A release that passes the admission but is malicious is merged and released without a person. | The admission's residual risk (Dependabot-admission.md R1), one step further: the module's callers receive it through their own Dependabot pull requests, which their own admission judges again. |
| R2 | The CI App's key is in every admitted Dependabot run (Dependabot-admission.md R7), and now merges pull requests. | Whoever holds the key can write to the repository directly; the rule adds nothing to that. The App is installed on the module repositories alone. |
| R3 | An App installed with contents write can write a commit through the API that GitHub signs, with any author. | Installing such an App is trusting it with the repository's contents. |
| R4 | No review is required on the default branch, so a person's unreviewed change there reaches the next release, which now merges by itself; a test that `allow-failing-terraform-tests` tolerates does not stop it either. | The release is what was already on the default branch; requiring reviews is the repository's choice. |

## 11. What implementation taught the spec

- **Dependabot's configuration is not a gate.** The module repositories' Dependabot ignores
  majors, and still proposed azurerm 5 by rewriting the range (P10). The rule now checks every
  dependency's major itself (M13).

- **A docs commit is only as good as the run that made it.** The first rule accepted any trailing
  docs commit once the run was the App's, relying on M4 for where docs commits come from. On the
  test bed a docs commit from before M4 sat on a refused bump, and the rule merged it (P9). The
  rule now reads the docs commit's subject, which only Dependabot's own, admitted run writes.

- **The scope belongs in the rule, not only in the job's condition.** A fork, another base branch
  and a closing pull request were first excluded by the merge job's condition alone; the engine
  then judged such a run on its listing, or said "not gathered". Rule 1 now names them, the notice
  says why, and no listing is made for them (M10).
- **A docs commit before the author's needs its own reason.** It is a docs commit, so "neither the
  author's nor a docs commit" was wrong; the notice now says that docs commits come last.
- **A listing of the wrong shape must fail closed, not crash.** A commit entry that was not an
  object raised in the adapter and would have failed `create-matrix`; it is `available: false` now
  (M11).
- **The switch is validated as a boolean**, as every other boolean input of the engine is; a value
  such as `1` read as off without a word.
- **The first mutation run on the new modules found thirteen survivors.** Three were missing
  assertions: the kind of each commit in a refused verdict, the admission's switch left out, and
  `readme-file-path` left out. Most of the rest were redundant code: a cap of 250 commits that a
  page of 100 never reaches at a full page (the listing is capped in pages now), `while True`
  loops, a commit's files set by one function and overwritten by the next, and early
  `return False`s whose `None` mutants no caller could tell apart (the docs-file check is one
  expression now, and the adapter's "gather nothing" has a test of its identity).
