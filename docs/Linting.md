# Linting

How TFLint inspects a Terraform repository, in CI and through the dsb CLI
([`dsb-norge/terraform-helpers`](https://github.com/dsb-norge/terraform-helpers)). One contract,
two implementations: `lint-with-tflint` in this repository, and the CLI's lint commands. A person
linting locally gets the result CI gets.

## 1. Why

TFLint reports an issue inside a called module only when the issue traces back to a variable the
caller passed in. An environment lint therefore says nothing about `main/`'s own code, or about a
local module's: each local module directory has to be linted as a root of its own (P1). Linted as
its own root, a directory that calls a remote module needs that module installed, or TFLint stops
with *module is not found. Did you run "terraform init"?* (P2).

Before this contract, the calling workflow listed those directories in
`terraform-init-additional-dirs-yml`, and the init step ran a full `terraform init` in each. That
list repeated the repository's layout by hand, and the init resolved providers afresh in
directories without a lock file: a warning per directory on every run (*Incomplete lock file
information for providers*), and provider versions the environment had not locked (P3). TFLint
reads no provider, so none of that served it.

The lint now works the directories out from what the environment's own init records, and lints
each against exactly the modules the environment installed, without an init of its own. The input
is deprecated ([Deprecations.md](Deprecations.md)).

## 2. The contract

1. **The root** is the directory being linted: an environment directory, a module repository's
   root, or a module example. Whoever calls the contract has initialised the root: in CI the
   environment's init, in the CLI its own.
2. **Directories:** the root, then every local module directory its
   `.terraform/modules/modules.json` records (a `Dir` not under `.terraform/`), each linted as a
   root of its own with `--chdir`. A root without a modules file is linted alone. A directory
   reached through several keys (a module called from two places) is linted once. When a module
   repository is linted with its examples, the root's lint leaves out every directory under
   `examples/`, which is linted as a root of its own (§4); everything else the manifest records,
   test fixtures included, is linted from the root.
3. **Preparation:** none for the root. A module directory is linted with `TF_DATA_DIR` pointing at
   a temporary directory that holds a manifest derived from the root's: the entries at and below the
   directory's key, that prefix stripped, every `Dir` made absolute. A directory reached through
   several keys uses its shortest key. Nothing is written into the repository, nothing is
   downloaded, and the module versions are the root's. Where `call_module_type` is `local`, remote
   calls are not evaluated and the derived manifest is merely unused.
4. **Config:** `<root>/.tflint.hcl`, else the repository root's `.tflint.hcl`, used for every
   directory of the root. Configs live per root; a project repository keeps one per environment and
   nothing at its repository root. A module example is linted with the module root's config.
   When there is none, the CLI writes its default into the root and says to commit it. CI never
   supplies one, as that would mean CI writing to the repository: it fails, and its message names the
   CLI command that does.
5. **TFLint version:** CI uses the workflow's `tflint-version`. The CLI reads the same value from the
   repository's workflow.
6. **Plugins:** `tflint --init` with the config, with a GitHub token when one is available.
7. **Var files:** the root is linted once per `*.tfvars` directly in it other than
   `terraform.tfvars` and `*.auto.tfvars`, which TFLint loads by itself, passed as `--var-file`; once
   without, when there is none. A module directory never gets the root's var files (P4); the root's
   own lint already checks the values it passes into its modules, at the call site.
8. **Result:** one exit code per (directory, var file) run. The lint fails when any run fails, the
   remaining runs still taking place, and the summary lists every run.

## 3. In the default workflow

`🧹 Lint with TFLint` runs `lint-with-tflint` in the environment's `project-dir` after
`⚙️ Terraform Init`, which initialises that directory only. The module directories it then lints
are the ones the environment's init recorded; no list is kept anywhere.

An environment without explicit var files is linted once. In practice that is every environment:
explicit var files belong to directories applied by hand, such as a state bootstrap directory, which
the CLI lints and CI does not run.

`terraform-init-additional-dirs-yml`, globally or in an environment, is accepted, has no effect, and
produces a warning naming where it is set. Path relevance never needed it: `auto` already covers
`main/**` and `modules/**` ([Path-relevance.md](Path-relevance.md)).

## 4. In module repositories

The module workflow's validation job runs the same contract with the module repository's root as
the root: the root and its submodules (`modules/*`) are linted, a submodule with remote calls
prepared from the derived manifest like an environment's modules.

The examples are checked as the CLI checks them. Each `examples/*/` directory holding `.tf` files is:

- **initialised** by `terraform-init` with `examples: true`: `terraform init -backend=false`, after
  the root and into the same console file, never letting the plugin cache break its lock (P6);
- **validated** by `terraform-validate` with `examples: true`;
- **linted** by `lint-with-tflint` with `examples: true`: as a root of its own, with the module
  root's config, covering the example directory and the module directories inside it only. The
  module itself, which every example calls through `../..`, is linted once, by the root.

A module root's `terraform init` also installs the modules its test files' run blocks call, and its
manifest records them under keys such as `test.tests.<file>.<run>`: the examples the tests deploy,
and fixture directories such as `tests/fixtures/*`. With `examples: true` the root's lint leaves out
everything under `examples/`, so each example is linted once, as its own root, and keeps linting the
fixtures (P8). Without `examples`, the root lints everything its manifest records, examples
included.

Each example's result counts in the job's validate and lint outcomes, so a failing example blocks
auto-merge like a failing root.

## 5. The dsb CLI

The CLI implements the same contract: `tf-lint [env]` and `tf-lint-all` in a project repository,
`tf-lint`, `tf-lint-example` and `tf-lint-all-examples` in a module repository, and
`tf-lint-tfstate` for `envs/_terraform-state`, once per `env.<name>.tfvars`. It installs the
TFLint version the calling workflow names, and supplies a missing config (§2 item 4). Its
`tf-init` still initialises `main/` and `modules/*` with the environment's lock and providers,
for the language server in the editor; its lint does not depend on that.

## 6. A worked example

An environment `envs/dev` calls `../../main`, which calls the local `../modules/a` (which calls
`../b`) and the registry module `Azure/naming/azurerm`. After `terraform init` in `envs/dev`, its
manifest holds:

```json
{"Key":"","Dir":"."}
{"Key":"main","Dir":"../../main"}
{"Key":"main.a","Dir":"../../modules/a"}
{"Key":"main.a.b","Dir":"../../modules/b"}
{"Key":"main.naming","Dir":".terraform/modules/main.naming"}
```

`main/` has no `.terraform` of its own. The manifest it is linted against is derived from the one
above, the entries at and below `main`:

```json
{"Key":"","Dir":"/work/envs/dev/../../main"}
{"Key":"a","Dir":"/work/envs/dev/../../modules/a"}
{"Key":"a.b","Dir":"/work/envs/dev/../../modules/b"}
{"Key":"naming","Dir":"/work/envs/dev/.terraform/modules/main.naming"}
```

The registry module resolves to the copy the environment installed. The step's log:

```text
lint-with-tflint: directory 'envs/dev'
lint-with-tflint: directory 'main'
lint-with-tflint: linting against the modules 'main' reaches in the root's manifest ...
lint-with-tflint: directory 'modules/a'
lint-with-tflint: linting against the modules 'main.a' reaches in the root's manifest ...
lint-with-tflint: directory 'modules/b'
lint-with-tflint: linting against the modules 'main.a.b' reaches in the root's manifest ...
```

Afterwards `main/` still holds only its `.tf` files. Run with TFLint 0.61.0 and Terraform 1.16.2.

## 7. Pitfalls

| # | What | Effect | Handling |
|---|---|---|---|
| P1 | TFLint reports an issue inside a called module only when it traces to a variable the caller passed in. | An environment lint with `call_module_type = "all"` did not report an unused variable in `main/`. | Every local module directory is linted as a root of its own (§2 item 2). |
| P2 | A directory linted as a root needs its remote module calls installed. | *"naming" module is not found. Did you run "terraform init"?*; a directory calling only local modules lints without any init. | The derived manifest (§2 item 3). |
| P3 | A full `terraform init` in a directory without a lock file resolves providers afresh. | A warning per directory on every run, and the newest provider version a constraint allows, not the one the environment locked; TFLint reads neither. | No init in module directories at all. |
| P4 | TFLint matches a var file's values to variables by name. | Given the root's var file, a module linted as a root took the root's `vm_size` for its own `vm_size`, while the call passed it a different variable; the value it reported was the wrong one. | A module directory never gets the root's var files. |
| P5 | `$?` read in an argument list that also holds a command substitution is the substitution's exit code. | A failing var-file run was recorded as passed: the summary's `$(basename …)` ran after TFLint and reset `$?`. | Each run's exit code is taken on the line after the run (`step_lint.sh`). |
| P6 | An example has no lock file to start from. | With the plugin cache allowed to break the lock, its init records one platform's checksum and warns of an incomplete lock on every run; without it, no warning. | The example init unsets `TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE`. |
| P7 | A manifest records the root as `"."`. | Joined naively, the root is linted as `<root>/.`. | The root's entry resolves to the root itself. |
| P8 | A module root's manifest records the modules its test files' run blocks call (`test.<dir>.<file>.<run>`), the examples among them. | With `examples: true` each example was linted twice: by the root, through a derived manifest, and as a root of its own. | With `examples: true` the root's lint leaves out every directory under `examples/`. |

## 8. Testing

- `lint-with-tflint/run_tests_step_lint.sh`, with a stub TFLint that records each invocation's
  arguments and `TF_DATA_DIR`, and keeps a copy of each derived manifest: the derived manifest's
  keys and directories, the shortest key for a directory reached twice, the temporary directories
  removed, var-file runs for the root only, a failing var-file run, and module examples (an
  initialised one, one without a manifest, a directory without `.tf` files, and the module not
  linted again through an example), and a root manifest with run-block entries (each example
  linted once, as its own root, with `examples`; a test fixture still linted; without `examples`,
  everything from the root). The suite runs the step under `set -e -o pipefail`, as GitHub does.
  `run_tests_step_get_config.sh` checks the missing-config message names the CLI.
- `terraform-init/run_tests_step_init.sh`: the deprecated input ignored, example inits after the
  project into one console file, always `-backend=false`, never with the lock bypass.
- `terraform-validate/run_tests_step_validate.sh`: example validation and its failure.
- The engine: the deprecated input known, of no effect, never validated, warned about once per place
  it is set, and absent from relevance (`test_config.py`, `test_relevance.py`).
