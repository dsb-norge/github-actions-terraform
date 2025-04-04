# Workflow [`terraform-module-release`](../.github/workflows/terraform-module-release.yaml)

Usually runs on merge to main branch.
Action will create release plan PR based on conventional commit messages.
Tag and release based on pinned version of [google release-please-action](https://github.com/googleapis/release-please-action).
IMPORTANT: ```chore:``` will not generate release.  Refer to [release-please documentation](https://github.com/googleapis/release-please?tab=readme-ov-file#release-please) for more information about it's behavior.

When merged action create tag + release in github.

## Prerequisites

The section below contains prereqs overview, to run workflow.

### Permissions

```text
   permissions:
     contents: write  # required for release-please to create a release PR
     pull-requests: write   # required for release-please to create a release PR
```

### Secrets

Action is using GITHUB_TOKEN that is passed in workflow already.

### Jobs

  1. release-pr
    - Steps:
      - release-please

### Examples

```yaml
name: Release please workflow
#
# note:
#   for this workflow to work from a new repo in the organization the following must be done:
#     - allow the repo access to the organization secret ORG_TF_CICD_APP_PRIVATE_KEY here: https://github.com/organizations/dsb-norge/settings/secrets/actions
#     - allow the repo access to the organization variables ORG_TF_CICD_APP_ID and ORG_TF_CICD_APP_INSTALLATION_ID here: https://github.com/organizations/dsb-norge/settings/variables/actions
#     - allow the app 'dsb-norge-terraform-cicd-access' access to this repo by "configuring" the app from here: https://github.com/organizations/dsb-norge/settings/installations
#
on:
  push:
    branches:
      - main

jobs:
  release-plan:
    # TODO revert to @v2
    uses: dsb-norge/github-actions-terraform/.github/workflows/terraform-module-release.yaml@login
    secrets: inherit
```
