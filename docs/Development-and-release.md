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

## Release

After merge to main use tags to release.

### Release lines

`main` is the **v1** line: every internal `uses: dsb-norge/github-actions-terraform/…` ref in
its workflows says `@v1`, and a release moves the `v1` tag. The **v0** line is frozen at its
last minor and takes fixes only. A v0 fix is made on the `release/v0` branch, cut from the
last v0 minor's commit (`git switch -c release/v0 v0.33`) when the first fix is needed, where
every internal ref still says `@v0`. It is released as a `v0.<n>` minor that moves `v0`, in
the same way as below. The branch is not named `v0`: a branch and a tag of the same name make
every `v0` reference ambiguous to git.

### Minor release

Ex. for smaller backwards compatible changes. Add a new minor version tag ex `v1.0` with a description of the changes and amend the description to the major version tag.

Example for release `v0.9`:

```bash
git checkout origin/main
git pull origin main
# review latest release tag to determine which is the next one
git tag --list 'v*' --sort=-creatordate | head -n 5   # 'v*' keeps preview/* tags out
# output changes since last release
git log v0..HEAD --pretty=format:"%s"
git tag -a 'v0.33'
# you are prompted for the tag annotation (change description)
git tag -f -a 'v0.33'
# you are prompted for the tag annotation
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
