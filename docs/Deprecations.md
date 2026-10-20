# Deprecations

What v1 still accepts but no longer uses, what replaces it, and the version that removes it. A
deprecated input keeps being accepted, so a calling workflow that still sets it does not fail; a run
that sets it gets a warning naming where. Remove it from the calling workflow when you see the
warning.

Removing a declared input is a breaking change for every caller still passing it (GitHub fails a
call that passes an input the reusable workflow does not declare), so removals wait for the next
major version.

| Deprecated | Where | Since | Replaced by | Removed in |
|---|---|---|---|---|
| `terraform-init-additional-dirs-yml` | `terraform-ci-cd-default.yml`, as an input and as a key of an `environments-yml` entry | v1, the release after 1.15.1 | Nothing to set: the lint works out every local module directory from the environment's own modules manifest and lints each against the modules the environment installed, without an init of its own ([Linting.md](Linting.md)). | v2 |
| `additional-dirs-json` | the `terraform-init` and `terraform-module-cache` actions | the same release | Nothing: `terraform-init` initialises the working directory (and with `examples`, module examples); the cache covers the project directory. Declared still, so a workflow release that passes it gets no "Unexpected input" warning. | v2 |

## What a caller does

**`terraform-init-additional-dirs-yml`.** Delete the input from the calling workflow's `with:`, and
the key from every `environments-yml` entry that sets it. Nothing replaces it, and nothing else
changes: path relevance's `auto` already covers `main/**` and `modules/**`, and a directory listed
there that does not exist no longer fails the run.
