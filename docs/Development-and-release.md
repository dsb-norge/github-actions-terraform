# Development and release  

Section below describes development, testing and release process for actions and workflows.  

## Development and testing

1. Replace version-tag of all dsb-actions in this repo with a temporary tag, ex. `@v2` becomes `@my-feature`.

    Replace regex pattern for vscode:
    - Find: `(^\s*)((- ){0,1}uses: dsb-norge/github-actions-terraform/.*@)v2`
    - Replace: `$1# TODO revert to @v2\n$1$2my-feature`

2. Make your changes and commit your changes on a branch, for example `my-feature-branch`.
3. Tag latest commit on you branch:

   ```bash
   git tag -f -a 'my-feature'
   git push -f origin 'refs/tags/my-feature'
   ```

4. To try out your changes, in the calling repo change the calling workflow to call using your **branch name**. Ex. with a dev branch named `my-feature-branch`:

   ```yaml
    jobs:
        ci-cd:
          # TODO revert to '@v2'
          uses: dsb-norge/github-actions-terraform/.github/workflows/terraform-ci-cd-default.yml@my-feature-branch
   ```

5. Test your changes from the calling repo. Make changes and remember to always move your tag `my-feature` to the latest commit.
6. When ready remove your temporary tag:

   ```bash
   git tag --delete 'my-feature'
   git push --delete origin 'my-feature'
   ```

    and revert from using the temporary tag to the version-tag for your release in actions, i.e. `@my-feature` becomes `@v2` or `@v3` or whatever.

    Replace regex pattern for vscode:
    - Find: `(^\s*# TODO revert to @v2\n)(^\s*)((- )?uses: dsb-norge/github-actions-terraform/.*@)my-feature`
    - Replace: `$2$3v2`
7. Create PR and merge to main.

## Release

After merge to main use tags to release.

### Minor release

Ex. for smaller backwards compatible changes. Add a new minor version tag ex `v1.0` with a description of the changes and amend the description to the major version tag.

Example for release `v1.1`:

```bash
git checkout origin/main
git pull origin main
git tag -a 'v1.1'
# you are prompted for the tag annotation (change description)
git tag -f -a 'v1'
# you are prompted for the tag annotation, amend the change description
git push -f origin 'refs/tags/v1.1'
git push -f origin 'refs/tags/v1'
```

**Note:** If you are having problems pulling main after a release, try to force fetch the tags: `git fetch --tags -f`.

### Major release

Same as minor release except that the major version tag is a new one. I.e. we do not need to force tag/push.

Example for release `v1`:

```bash
git checkout origin/main
git pull origin main
git tag -a 'v1.0'
# you are prompted for the tag annotation (change description)
git tag -a 'v1'
# you are prompted for the tag annotation
git push -f origin 'refs/tags/v1.0'
git push -f origin 'refs/tags/v1'
```

**Note:** If you are having problems pulling main after a release, try to force fetch the tags: `git fetch --tags -f`.
