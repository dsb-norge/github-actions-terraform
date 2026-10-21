# Re-run attempts

Authoritative spec for how the workflows hand files from one job to another across the attempts of
one run, so a job re-run by hand ("Re-run failed jobs", "Re-run all jobs" or a single job) reports,
merges and notifies on what was actually done, not on what an earlier attempt did.

It covers [`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml),
[`terraform-module-ci.yaml`](../.github/workflows/terraform-module-ci.yaml) and
[`terraform-notify.yml`](../.github/workflows/terraform-notify.yml). The rule is the
[decision engine](Decision-engine.md)'s; the action that applies it is
[`download-newest-attempt`](../download-newest-attempt/action.yml).

## 1. Why

A job hands another job a file through an artifact. The attempts of a run share their artifacts: a
re-run keeps every earlier attempt's artifacts, and a re-run job uploads its own under the name it
used before. `actions/download-artifact` lists the run's artifacts across all attempts and keeps
one per name, the one with the highest artifact ID, whether it downloads by pattern, by name or by
ID (P1). Artifact IDs are not in the order the artifacts were made (P2), so which attempt a job
read was chance.

Seen on a calling repository: an apply failed; "Re-run failed jobs" applied it; the notification
said *Apply failed again* and the incident stayed open, although a re-run apply must close it
([Notifications.md](Notifications.md) D8). The decide job of the second attempt had read the
environment's metadata from the first. In the same run, the decide job's events and the relay's
answer happened to be read from the right attempt. The same chance decided the pull-request
comments, the run summary, the test summary and the auto-merge verdict, which acts on what it reads.

## 2. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Every artifact one job uploads for another is named `<name>-attempt-<run attempt>`, and so is the file in it when one job of a matrix uploads it (`<name>-attempt-<n>.json`). | A name of its own per attempt, so no download drops one, and the files of different attempts land side by side in one directory (P3). |
| D2 | A job reads the **newest** attempt of each file, not its own attempt's. | "Re-run failed jobs" re-runs the failed jobs and those that need them; the jobs it does not re-run keep their earlier attempt's artifact, and that artifact is still this run's result for them. |
| D3 | The rule is a core rule of the engine (`attempts.py`) with an adapter that writes the chosen files (`attempt_files.py`), run as the command `newest-attempt` by the action `download-newest-attempt`. The action downloads by pattern and writes each chosen file under its name without the attempt, so the readers are unchanged. | The rule decides what auto-merge acts on and what Teams is told; in the engine it sits under the coverage and mutation gates ([Decision-engine.md](Decision-engine.md) D13). One action, so no reader can forget the rule. |
| D4 | An artifact that one job uploads (`relevance`, `notify-events`) is read by its exact name. The uploading job publishes that name, or its attempt, as a job output, and the readers, which all need that job, download the name. | Exact, with no rule to apply, and the artifact may hold a directory tree. A job that is not re-run keeps its outputs in the re-run: that is how the stage jobs of a partial re-run still get their matrices. |
| D5 | The names are written in the workflow files, never by an action. `capture-matrix-job-meta` keeps its contract; the workflows pass it the name. | An action referenced by a moving tag is downloaded again each time a job starts, so a re-run job can run a newer action than its first attempt; a workflow keeps its first attempt's version in a partial re-run (P4). Producer and reader of one name are always the same version. |
| D6 | A file name without an attempt is attempt 0. | An artifact from an attempt that ran before this change: read when no newer attempt of it exists, never in place of one. After a "Re-run all jobs" across a release, every job of the new attempt names its artifacts, so attempt 0 only fills what nothing replaced. |
| D7 | The record job reads only the answers to its own decide job's events: `min-attempt` is the decide job's attempt. | Event IDs start at `e1` in every decide job. An answer left by an earlier decide job's deliver job, about another message, must never be read as the answer to this one's `e1` (P5). |
| D8 | Artifacts only people read keep their names: `terraform-test-log-<slug>` and `<environment>-terraform-plan-console-output`. | No job reads them, and a person picks the attempt on the run page. |

## 3. The artifacts

| Artifact | Uploaded by | Read by | How it is read |
|---|---|---|---|
| `relevance-attempt-<n>` (`relevance.json`) | `create-matrix`, project and module | `seed-pr-comments`, `pr-comment-aggregator`, `run-summary`, `terraform-test-summary`, `automerge`, and the notify workflow's `decide` | by name: `create-matrix`'s output `relevance-artifact`, passed to the notify workflow as its input `relevance-artifact` |
| `matrix-job-meta-<github-environment>-attempt-<n>` | every stage job, through `capture-matrix-job-meta` | `pr-comment-aggregator`, `run-summary`, `automerge`, the notify workflow's `decide` | `download-newest-attempt`, pattern `matrix-job-meta-*` |
| `terraform-test-meta-<slug>-attempt-<n>` | every `terraform-test` job, project and module, through `capture-matrix-job-meta` | `terraform-test-summary`, project and module; `automerge` | `download-newest-attempt`, pattern `terraform-test-meta-*` |
| `notify-events-attempt-<n>` (a tree: `events/`, `observations.json`, `summary.md`) | the notify workflow's `decide` | `deliver`, `record` | by name: `decide`'s output `run-attempt` |
| `notify-result-<event id>-attempt-<n>` | every `deliver` job | `record` | `download-newest-attempt`, pattern `notify-result-*`, `min-attempt` the decide job's `run-attempt` (D7) |

`<n>` is `${{ github.run_attempt }}` of the uploading job. Each file is written back without the
attempt, `matrix-job-meta-<github-environment>.json` and so on, where the readers' patterns have
always looked.

## 4. The rule

`attempts.py` reads file names. A name that ends in `-attempt-<n>`, before an extension of its own if
it has one, with `<n>` a whole number from 1 without leading zeros, is attempt `<n>` of the name
without that part; any other name is attempt 0 of itself (D6):

| File | Name | Attempt |
|---|---|---|
| `matrix-job-meta-prod-attempt-2.json` | `matrix-job-meta-prod.json` | 2 |
| `matrix-job-meta-prod.json` | `matrix-job-meta-prod.json` | 0 |
| `matrix-job-meta-eu.west-attempt-12.json` | `matrix-job-meta-eu.west.json` | 12 |
| `notes-attempt-3` | `notes` | 3 |
| `matrix-job-meta-prod-attempt-02.json` | itself | 0 |
| `report-attempt-2.tar.gz` | itself | 0 |

Of each name, the file of the newest attempt is kept, provided that attempt is at least
`min-attempt` (0 when not given); the others are left out. Each kept file is written under its name.

A partial re-run of a run with two environments, `prod` failed in the first attempt and re-run:

```text
downloaded                               written
matrix-job-meta-prod-attempt-1.json      matrix-job-meta-prod.json  (from attempt 2)
matrix-job-meta-prod-attempt-2.json      matrix-job-meta-test.json  (from attempt 1)
matrix-job-meta-test-attempt-1.json
```

The step's log names, for each written file, the attempt it came from and the attempts found, and
each file left out below `min-attempt`.

## 5. The action

[`download-newest-attempt`](../download-newest-attempt/action.yml) takes `pattern`, `path` (the
workspace when not given) and `min-attempt` (empty for none). It makes an empty directory under
`RUNNER_TEMP`, downloads every artifact the pattern matches into it with `merge-multiple: true`, and
runs `python3 -I -B engine/run.py newest-attempt` from it into `path`.

- No artifact matches: nothing is written, and the step succeeds; every reader accepts no input.
- A download that fails fails the action, as `actions/download-artifact` did; the readers keep their
  `continue-on-error` as before.
- A directory among the downloaded files is left out with a warning: the action reads artifacts of
  plain files, named per D1. A tree is read by name (D4).
- A file that already exists in `path` is replaced.

Structural test F33 holds the workflows to it: every artifact a job reads is uploaded under a name
that ends in `-attempt-${{ github.run_attempt }}`, no workflow downloads by pattern but through the
action, and every download by name names an attempt from the uploading job's output.

## 6. Pitfalls

| # | Pitfall | Seen as | Answer |
|---|---|---|---|
| P1 | `actions/download-artifact` lists the run's artifacts with `latest: true`, which keeps one artifact per name, the highest ID (`filterLatest` in `@actions/artifact`). A download by name picks the highest ID the same way, and a download by `artifact-ids` filters that deduplicated list, so the ID of an older duplicate is not found. | A re-run job's report built from another attempt. | Names of their own per attempt (D1). |
| P2 | Artifact IDs are not in creation order, across attempts or within one. | Seen: the second attempt's metadata had a lower ID than the first's; within one attempt, an artifact made later than another had a lower ID. | The attempt is read from the name, never inferred from an ID or a time. |
| P3 | With `merge-multiple: false`, each artifact gets a directory of its name, except when exactly one matches: its files then go straight into `path`. A reader cannot tell the two layouts apart. | A rule that reads directory names sees a file instead. | The attempt is in the file's name too, and the action merges (D1). |
| P4 | Re-running failed jobs or one job uses the reusable workflow at the first attempt's commit; re-running all jobs resolves its reference again ([GitHub: reusing workflow configurations](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations)). Actions are downloaded at each job's start. | One run whose attempts ran different versions. | Names in the workflows (D5), unnamed files as attempt 0 (D6). |
| P5 | Event IDs restart at `e1` in every decide job. | An earlier decide job's answer for `e1` read as this one's. | `min-attempt` (D7). |
| P6 | A re-run job that stops before its upload (a lost runner, a cancelled run) leaves its earlier attempt's file as the newest. | A report or verdict from the earlier attempt for that job. | Accepted: the metadata and the answers are uploaded under `always()`, so only a job that never reaches its last steps leaves none; its stage result still says it did not succeed. |

## 7. Tests

- **Engine** (`test_attempts`, `test_attempt_files`, `test_cli`), at 100 percent coverage and through
  the mutation gate. Must: the names of §4's table; the newest attempt of each name; attempt 0 kept
  alone and lost to any numbered attempt; `min-attempt` leaving out older attempts and attempt 0;
  **a two-attempt run in which only some environments re-ran** (the §4 example); the files written
  under their names with the chosen attempt's content; a directory left out with a warning; an
  empty or missing download directory writing nothing; a file in `path` replaced; the log's lines as
  literals. Should: a name with dots; an extension-less name.
- **Action** (`download-newest-attempt/run_all_tests.sh`): the run block of the select step, end to
  end, on downloaded files laid out as `merge-multiple` lays them out, with and without
  `min-attempt`, and with a caller's `json.py` in the working directory; the download step's
  `pattern`, `merge-multiple` and `path`.
- **Workflows** (F33 in `structural-tests/run_all_tests.sh`): the names and reads of §3 in all three
  workflows; fails on the workflows before this change.
- **What tests cannot cover:** GitHub's listing (P1, P2) and its re-runs (P4). Test-bed runs
  checked them (§8): a pull request whose plan failed in the first attempt and a push whose apply
  did, each re-run with "Re-run failed jobs" and read back from every reader that ran.

## 8. What implementation taught the spec

Observed on a test-bed repository, one environment made to fail its first attempt by a deadline in
its configuration, so the re-run of the same commit succeeded:

- **P2 again.** On the pull request, the first attempt's metadata of the re-run environment had the
  higher artifact ID. Under one name per environment, the second attempt would have read the failed
  plan again. Named per attempt, the aggregator and the run summary read that environment at
  attempt 2 (`found 1, 2`) and the five others at attempt 1, and the run went green.
- **A job's output survives its partial re-run (D4).** The second attempt read `relevance-attempt-1`
  by the output of a `create-matrix` job that did not run again.
- **D8 holds.** On the push, the second attempt's decide job read the re-run environment at attempt 2
  and resolved its incident and the held-back one's. The record job read `notify-events-attempt-2`
  and left out the first attempt's answers to `e1` and `e2`, which were about the opening messages
  (D7).
- **No match is no failure.** The tests summary of a run without test files downloaded nothing, wrote
  nothing and succeeded (§5).
