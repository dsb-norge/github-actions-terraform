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

Preview tags fetched into your clone are harmless; drop them with `git tag -l 'preview/*' | xargs -r git tag -d`. Orphans on the remote (a PR whose close event never ran): list with `gh api repos/dsb-norge/github-actions-terraform/git/matching-refs/tags/preview/ --jq '.[].ref'`, delete with `gh api -X DELETE repos/dsb-norge/github-actions-terraform/git/<ref without the refs/ prefix>`.

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
  under test. The `init`/`fmt`/`validate`/`lint` jobs still run, so a dispatch is
  enough when those are all you need to see.

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

After merge to main use tags to release.

### Release lines

`main` is the **v1** line: every internal `uses: dsb-norge/github-actions-terraform/…` ref in
its workflows says `@v1`, and a release moves the `v1` tag. The **v0** line is frozen at its
last minor and takes fixes only. A v0 fix is made on the `release/v0` branch, cut from the
last v0 minor's commit (`git switch -c release/v0 v0.33`) when the first fix is needed, where
every internal ref still says `@v0`. It is released as a `v0.<n>` minor that moves `v0`, in
the same way as below. The branch is not named `v0`: a branch and a tag of the same name make
every `v0` reference ambiguous to git. v0 takes no features, and its support ends when the last
caller has moved to v1.

**While v1 has no callers, only `v1` moves.** There are no `v1.<n>` minors or patches: after each
v1 pull request merges, `v1` is force-moved to the merge's tip on `main`, and one block for that
pull request is appended to its annotation, the pull request's number and title followed by its
commit subjects:

```bash
git fetch origin --tags -f
old=$(git for-each-ref --format='%(contents)' refs/tags/v1)   # empty the first time
new_block="#<PR>: <PR title>
  - <commit subject>
  - <commit subject>"
combined="${old:+${old}
}${new_block}"
# --cleanup=verbatim: the default cleanup drops every line that starts with '#', the block header too
git tag -f -a --cleanup=verbatim v1 -m "${combined}" origin/main
git push -f origin refs/tags/v1
```

Once callers move to v1, v1 releases follow the minor release procedure below, as v0 releases did.

**A major tag's annotation is an append-only changelog.** Every block already in it is kept when
the tag is force-recreated. `git tag -f -a <tag>` without `-m` opens an empty annotation, and
saving it replaces the whole changelog, so read the old annotation and append to it:

```bash
old=$(git for-each-ref --format='%(contents)' refs/tags/v0)
new_block="v0.<n>:
  - <commit subject>"
git tag -a "v0.<n>" -m "${new_block}"
git tag -f -a v0 -m "${old}
${new_block}"
git push origin "refs/tags/v0.<n>"
git push -f origin refs/tags/v0
```

A minor's block is `v<major>.<minor>:` followed by the commit subjects since the previous minor,
lightly rephrased where a literal subject would be confusing as a release note.

### Minor release

Ex. for smaller backwards compatible changes. Add a new minor version tag ex `v1.0` with a description of the changes and amend the description to the major version tag.

Example for release `v0.33`:

```bash
git checkout origin/main
git pull origin main
# review latest release tag to determine which is the next one
git tag --list 'v*' --sort=-creatordate | head -n 5   # 'v*' keeps preview/* tags out
# output changes since last release
git log v0..HEAD --pretty=format:"%s"
git tag -a 'v0.33'
# you are prompted for the tag annotation (change description)
git tag -f -a 'v0'
# you are prompted for the tag annotation: keep every earlier block (see "Release lines")
git push origin 'refs/tags/v0.33'
git push -f origin 'refs/tags/v0'
```

**Note:** If you are having problems pulling main after a release, try to force fetch the tags: `git fetch --tags -f`.

### Major release

Same as minor release except that the major version tag is a new one. I.e. we do not need to force tag/push.

Example for release `v1`:

```bash
git checkout origin/main
git pull origin main
# review latest release tag to determine which is the next one
git tag --list 'v*' --sort=-creatordate | head -n 5   # 'v*' keeps preview/* tags out
# output changes since last release
git log v0..HEAD --pretty=format:"%s"
git tag -a 'v1.0'
# you are prompted for the tag annotation (change description)
git tag -a 'v1'
# you are prompted for the tag annotation
git push -f origin 'refs/tags/v1.0'
git push -f origin 'refs/tags/v1'
```

**Note:** If you are having problems pulling main after a release, try to force fetch the tags: `git fetch --tags -f`.

#### Un-release (move major tag back)

In case of trouble where a fix takes long time to develop, this is how to rollback the major tag to the previous minor release.

Example un-release `v0.9` and revert to `v0.8`:

```bash
git checkout origin/main
git pull origin main

moveTag='v0'
moveToTag='v0.8'
moveToHash=$(git rev-parse --verify ${moveToTag})

git push origin "refs/tags/${moveTag}"      # delete the old tag remotely
git tag -fa ${moveTag} ${moveToHash}        # move tag locally
git push -f origin "refs/tags/${moveTag}"   # push the updated tag remotely

```

**Note:** If you are having problems pulling main after a release, try to force fetch the tags: `git fetch --tags -f`.
