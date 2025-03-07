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

on:
  push:
    branches:
      - main

jobs:
  release-plan:
    # TODO revert to @v0
    uses: dsb-norge/github-actions-terraform/.github/workflows/terraform-module-release.yaml@tfdocs-fix
    secrets: inherit
    permissions:
      contents: write  # required for release-please to create a release PR     
      pull-requests: write   # required for release-please to create a release PR
```
