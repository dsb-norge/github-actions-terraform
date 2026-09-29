# Development and release

Section below describes development, testing and release process for actions and workflows.

## Development and testing

Every same-repo pull request gets a **preview ref** — a tag a calling repo can consume with one `uses:` line, for the reusable workflows and the composite actions alike. [`pr-preview.yml`](../.github/workflows/pr-preview.yml) publishes it on every push and deletes it when the PR closes. The mechanism, its pitfalls and the one-time GitHub App bootstrap are in [Preview-refs.md](Preview-refs.md).

1. Open a PR (draft is fine) and wait for the `🏷️ Publish preview ref` check. A sticky comment `🧪 Preview refs for this PR` appears with two refs:
   - `preview/pr-<N>` — moves with every push to the PR;
   - `preview/pr-<N>-<sha7>` — immutable, one per push; every internal ref inside it names itself.
2. In the calling repo, point the calling workflow at the moving ref:

   ```yaml
   jobs:
     ci-cd:
       # TODO revert to '@v1'
       uses: dsb-norge/github-actions-terraform/.github/workflows/terraform-ci-cd-default.yml@preview/pr-<N>
   ```

   The same ref serves `terraform-module-ci.yaml`, `terraform-module-release.yaml` and every composite action. For a calling run longer than one job, pin `preview/pr-<N>-<sha7>` instead — a rebuild landing mid-run cannot change it under you.
3. Push to the PR as often as you like. Nothing to re-tag and nothing to revert: the PR branch keeps saying `@v1`; the rewrite exists only in a generated commit the tags point at.
4. Merge or close. The tags and the comment disappear. Revert the calling repo's line to the ref it used before.

If the comment says **unavailable (bootstrap)**, the GitHub App that pushes the tags is not configured — [Preview-refs.md §5](Preview-refs.md#5-the-token--why-a-github-app-is-required).

Preview tags fetched into your clone are harmless; drop them with `git tag -l 'preview/*' | xargs -r git tag -d`. Orphans on the remote (a PR whose close event never ran): list with `gh api repos/dsb-norge/github-actions-terraform/git/matching-refs/tags/preview/ --jq '.[].ref'`, delete with `gh api -X DELETE repos/dsb-norge/github-actions-terraform/git/<ref as listed, refs/tags/…>`.

### Fallback: publishing by hand

For a fork PR, or before the App exists. The script `pr-preview.yml` uses rewrites the working tree; a developer's own credentials normally carry the `workflow` scope that the restriction in Preview-refs.md §5 is about, so the push works from a clone.

```bash
bash .github/scripts/rewrite-internal-refs.sh my-feature          # rewrite every internal uses-ref
git commit -am 'chore: swap internal refs to dev tag my-feature'   # on the feature branch
git tag -f my-feature && git push -f origin refs/tags/my-feature   # repeat both after every push
# … test from the calling repo with @my-feature — one ref serves the workflow and the actions …
bash .github/scripts/rewrite-internal-refs.sh v1                   # revert before merge
git commit -am 'chore: revert internal refs to @v1'
git push --delete origin my-feature
```

Both the swap commit and the revert commit sit on the branch when it merges, and the tag must be gone — the old dev-tag ritual, minus the regex and the markers.

### Test driving from a calling repo

Two things cost a round trip each if you learn them from CI instead of here:

- **Do not put a GitHub Actions expression in an `action.yml` input description.**
  It fails the whole job at `Set up job`, before any step runs, and no local check
  catches it. See
  [Action-implementation-guide.md](./Action-implementation-guide.md) →
  "Never write an Actions expression in an input `description`".
- **Test drive a module repo through a pull request, not `workflow_dispatch` on a
  branch.** The DSB module repos authenticate to Azure with workload identity
  federation, and the federated subjects are scoped (`refs/heads/main`,
  `pull_request`). A dispatch from an ad-hoc branch presents a subject nobody
  federated, so `azure/login` fails with `AADSTS7002131` and every `terraform
  test` job fails with it — for reasons that have nothing to do with the change
  under test. The validation job (init, fmt, validate, lint) still runs, so a
  dispatch is enough when that is all you need to see.

### Validating on a test-bed repository

A change is validated on a test-bed calling repository before it is handed over for review: the
test bed's calling workflow is switched to the pull request's preview ref for the verification and
back to `@v1` right after, so between verifications it runs what callers run. Compare every run with
what the change should have done; a green run is necessary, not sufficient. A round that needs no
new CI run of this repository can use a hand-published tag instead (above): pushing a tag starts no
workflow here. Delete the tag afterwards. What the test bed cannot reach, such as a re-run by a
second account, is recorded in the spec as covered by tests only.

### Keeping actions current

The actions the workflows use are kept on their latest major version, and a bump needs no separate
decision. The few pinned by commit carry their version in a comment and are bumped the same way.
After a bump, a test-bed run's logs are checked for deprecation warnings
([Testing-in-ci.md §12.2](Testing-in-ci.md)).

## Documentation

- **Every document is in the index.** [README.md](README.md) in this folder lists each document once,
  under its kind (user guide, migration, spec, contributor guide, tracking), with what it covers.
  A new document gets its row in the change that adds it; F22 in
  `evaluate-automerge-eligibility/run_all_tests.sh` fails on a document the index misses or a row
  whose document is gone.
- **A spec describes the system as built.** While its feature is unbuilt it carries a status line
  saying so and an open-questions section. When implementation and the test-bed run have closed
  those questions, the status line goes, the text stays in the present tense, the decisions
  section remains as the record of what was chosen and why, and a "what implementation taught the
  spec" section records what changed on the way. An open question that remains stays listed, with
  what it needs to be answered.
- **No progress markers.** Specs and code comments carry no pull request numbers, no delivery
  steps and no "done" or "pending"; they rot the moment the next change lands.
- **Public repository.** No internal repository, tenant, subscription or environment names and no
  App IDs anywhere in `docs/`, in commit messages or in pull requests. The test bed is "a test-bed
  repository"; a private caller's motivation is described generically.
- **Worked examples are produced, not written.** Each example of a message, a log line or a
  decision in the user guide is the output of running the code concerned (the create-matrix
  adapter, the auto-merge evaluator, the conclusion's run block) on the configuration shown, and
  every YAML example in the guides parses and is accepted by the adapter. Doing so found an engine
  gap the tests had missed ([Configuration-validation.md §13](Configuration-validation.md)).

## Release

v1 releases are made by [release-please](https://github.com/googleapis/release-please) from the
conventional commits on `main`; v0 fixes are released by hand. Every release is in
[CHANGELOG.md](../CHANGELOG.md).

### Release lines

`main` is the **v1** line: every internal `uses: dsb-norge/github-actions-terraform/…` ref in
its workflows says `@v1`, and every v1 release moves the `v1` tag. The **v0** line is frozen at
its last minor and takes fixes only. A v0 fix is made on the `release/v0` branch, cut from the
last v0 minor's commit (`git switch -c release/v0 v0.33`) when the first fix is needed, where
every internal ref still says `@v0`. It is released as a `v0.<n>` minor that moves `v0` ("v0 fix
release" below). The branch is not named `v0`: a branch and a tag of the same name make every
`v0` reference ambiguous to git. v0 takes no features, and its support ends when the last caller
has moved to v1.

A calling repository pins `@v1`, which follows every v1 release, or an exact release such as
`@v1.2.0`, which never moves.

### v1 release

`.github/workflows/release.yml` runs release-please on every push to `main`
(`release-please-config.json`, `.release-please-manifest.json`, release type `simple`):

1. **The release pull request.** release-please opens, and on each later push updates, one pull
   request, `chore(main): release 1.<minor>.<patch>`, that bumps the version in the manifest and
   `version.txt` and adds the release's entry to `CHANGELOG.md`. The version follows the commits
   since the last release: a `fix:` bumps the patch, a `feat:` the minor, and a breaking change
   (`feat!:`, or a `BREAKING CHANGE:` footer) the major, which is a new release line ("Major
   release" below). The entry lists the `feat:` and `fix:` commits (and `perf:`, `revert:` and
   breaking changes); `docs:`, `test:`, `refactor:`, `chore:` and `ci:` commits release nothing
   on their own and are not listed.
2. **Releasing.** Merging the release pull request, rebased like every pull request, is the
   release. release-please tags the merge `v1.<minor>.<patch>` and publishes its GitHub Release,
   and the workflow moves `v1` to it, annotated `v1 is v1.<minor>.<patch>`.

The release pull request is opened with the releaser App's token (`vars.RELEASER_APP_ID`,
`secrets.RELEASER_APP_PRIVATE_KEY`), so the Action tests run on it like on any pull request; a
pull request opened with `GITHUB_TOKEN` would start no workflow and never get its required
`tests-conclusion` check. The App needs read and write access to the repository's contents,
issues and pull requests, and is installed on this repository only. Without the variable the
release job is skipped.

Everything a caller needs to know goes in the commit subjects: they are the release notes.

#### Un-release (move `v1` back)

When a release breaks callers and the fix takes time, move `v1` back to the release before it;
the broken release's tag and GitHub Release stay, and the next release moves `v1` forward again:

```bash
git fetch origin --tags -f
git tag -f -a v1 -m "v1 is v1.2.0; v1.3.0 withdrawn" 'v1.2.0^{commit}'
git push -f origin refs/tags/v1
```

### Major release

A breaking change makes release-please propose `2.0.0`. Before merging that release pull request,
cut `release/v1` from the last v1 release for v1's fixes, and rewrite `main`'s internal refs to
the new line in a pull request of its own (`bash .github/scripts/rewrite-internal-refs.sh v2`).
The release then creates `v2.0.0`, and the workflow creates `v2`. A v1 fix on `release/v1` is
released by hand, as a v0 fix is.

### v0 fix release

A v0 fix is released by hand from `release/v0` (see "Release lines"): a new minor tag, and `v0`
moved to it. **`v0`'s annotation is an append-only changelog**, and every block already in it is
kept when the tag is force-recreated. `git tag -f -a v0` without `-m` opens an empty annotation,
and saving it replaces the whole changelog, so read the old annotation and append to it:

```bash
git switch release/v0
git pull origin release/v0
git fetch origin --tags -f
git log v0..HEAD --pretty=format:"%s"   # the changes since the last release
old=$(git for-each-ref --format='%(contents)' refs/tags/v0)
new_block="v0.34:
  - <commit subject>"
git tag -a "v0.34" -m "${new_block}"
git tag -f -a v0 -m "${old}
${new_block}"
git push origin "refs/tags/v0.34"
git push -f origin refs/tags/v0
```

A minor's block is `v0.<n>:` followed by the commit subjects since the previous minor, lightly
rephrased where a literal subject would be confusing as a release note. Add the same block to
`CHANGELOG.md`'s v0 section on `main`.

#### Un-release a v0 fix

Example: withdraw `v0.34` and move `v0` back to `v0.33`, keeping the changelog:

```bash
git fetch origin --tags -f
git tag -f -a v0 -m "$(git for-each-ref --format='%(contents)' refs/tags/v0)" 'v0.33^{commit}'
git push -f origin refs/tags/v0
```

**Note:** If pulling after a release fails on a moved tag, force-fetch the tags:
`git fetch --tags -f`.
