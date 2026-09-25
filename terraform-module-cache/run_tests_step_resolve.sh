#!/bin/env bash
#
# Tests for step_resolve.sh — classification, the local-source walk, the key
# and the cache paths. Fixture ids map to docs/Terraform-module-cache.md §9.
#
# Sourced by run_all_tests.sh, which owns the counters and the summary.
#

# Run the local-source walk directly. Used by the fixtures that assert on
# dot-paths, which the step itself does not expose as an output.
run_walk() {
  (
    export GITHUB_ACTION_PATH="${_this_script_dir}"
    source "${_this_script_dir}/helpers.sh"
    reset-walk-state
    walk-remote-modules "${WORK_DIR}/${1}"
  ) >"${STEP_LOG}" 2>&1
}

# A single-directory fixture: project-dir only, contents from stdin.
one_dir_fixture() {
  setup_workspace
  write_tf "env/main.tf"
  export input_project_dir="env"
}

# ---------------------------------------------------------------------------
# Classification and inclusion
# ---------------------------------------------------------------------------

# t01 registry, exact pin
one_dir_fixture <<'TF'
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "0.4.2"
}
TF
run_resolve
assert_eq "t01 registry pinned is included" "true" "$(out_value cache-enabled)"
assert_eq "t01 emits the directory's module path" "env/.terraform/modules" "$(out_value cache-paths)"
T01_KEY="$(out_value cache-key)"

# t02 registry, range constraint
one_dir_fixture <<'TF'
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "~> 0.4"
}
TF
run_resolve
assert_eq "t02 registry range is excluded" "false" "$(out_value cache-enabled)"
assert_log_has "t02 emits a notice naming the directory" "::notice::terraform-module-cache: not caching env"

# t03 registry, no version
one_dir_fixture <<'TF'
module "naming" {
  source = "Azure/naming/azurerm"
}
TF
run_resolve
assert_eq "t03 unpinned registry is excluded" "false" "$(out_value cache-enabled)"

# t04 git, commit sha
one_dir_fixture <<'TF'
module "m" {
  source = "git::https://example.com/m.git?ref=0123456789abcdef0123456789abcdef01234567"
}
TF
run_resolve
assert_eq "t04 git sha ref is included" "true" "$(out_value cache-enabled)"

# t05 git, version tag
one_dir_fixture <<'TF'
module "m" {
  source = "git::https://example.com/m.git?ref=v1.2.3"
}
TF
run_resolve
assert_eq "t05 git tag ref is included" "true" "$(out_value cache-enabled)"

# t06 git, branch ref — the §3 hazard
one_dir_fixture <<'TF'
module "m" {
  source = "git::https://example.com/m.git?ref=main"
}
TF
run_resolve
assert_eq "t06 git branch ref is excluded" "false" "$(out_value cache-enabled)"
assert_log_has "t06 notice names the offending source" "?ref=main"

# t07 git, no ref at all
one_dir_fixture <<'TF'
module "m" {
  source = "git::https://example.com/m.git"
}
TF
run_resolve
assert_eq "t07 git without a ref is excluded" "false" "$(out_value cache-enabled)"

# t08 no module blocks
one_dir_fixture <<'TF'
resource "null_resource" "noop" {}
TF
run_resolve
assert_eq "t08 a directory with no modules is excluded" "false" "$(out_value cache-enabled)"
assert_log_has "t08 says why" "no remote modules reachable"

# t09 mixed: one cacheable directory, one that reaches a branch
setup_workspace
# Same declaration as t01, so the digest must come out identical once the
# branch-ref directory has been excluded from it.
write_tf "env/main.tf" <<'TF'
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "0.4.2"
}
TF
write_tf "floating/main.tf" <<'TF'
module "bad" {
  source = "git::https://example.com/m.git?ref=develop"
}
TF
export input_project_dir="env" input_additional_dirs_json='["floating"]'
run_resolve
assert_eq "t09 mixed dirs: only the safe one is cached" "env/.terraform/modules" "$(out_value cache-paths)"
assert_eq "t09 mixed dirs: caching stays enabled" "true" "$(out_value cache-enabled)"
assert_eq "t09 digest covers only the included dir" "${T01_KEY}" "$(out_value cache-key)"

# t10 an override file repoints a pinned module at a branch. Over-reading is
# safe: both blocks are read, so the mutable one is seen (§4.5.1).
setup_workspace
write_tf "env/main.tf" <<'TF'
module "m" {
  source = "git::https://example.com/m.git?ref=v1.0.0"
}
TF
write_tf "env/main_override.tf" <<'TF'
module "m" {
  source = "git::https://example.com/m.git?ref=main"
}
TF
export input_project_dir="env"
run_resolve
assert_eq "t10 an override file's branch ref is caught" "false" "$(out_value cache-enabled)"

# ---------------------------------------------------------------------------
# The local-source walk
# ---------------------------------------------------------------------------

# t11 the wrapper shape: the env declares only a local source, the tree it
# points at pulls the remote modules (§2.3).
setup_workspace
write_tf "envs/dev/main.tf" <<'TF'
module "shared" {
  source = "../../main"
}
TF
write_tf "main/main.tf" <<'TF'
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "0.4.2"
}
TF
export input_project_dir="envs/dev"
run_resolve
assert_eq "t11 local-only env is INCLUDED, not excluded" "true" "$(out_value cache-enabled)"
assert_eq "t11 its own module path is cached" "envs/dev/.terraform/modules" "$(out_value cache-paths)"
T11_KEY="$(out_value cache-key)"

# t12 same shape, but the local tree reaches a branch ref
setup_workspace
write_tf "envs/dev/main.tf" <<'TF'
module "shared" {
  source = "../../main"
}
TF
write_tf "main/main.tf" <<'TF'
module "floating" {
  source = "git::https://example.com/m.git?ref=main"
}
TF
export input_project_dir="envs/dev"
run_resolve
assert_eq "t12 a transitive branch ref excludes the consuming dir" "false" "$(out_value cache-enabled)"
assert_log_has "t12 the notice names the transitive module by dot-path" "shared.floating"

# t13 two levels of local indirection
setup_workspace
write_tf "a/main.tf" <<'TF'
module "b" {
  source = "../b"
}
TF
write_tf "b/main.tf" <<'TF'
module "c" {
  source = "../c"
}
TF
write_tf "c/main.tf" <<'TF'
module "leaf" {
  source = "git::https://example.com/m.git?ref=v1.0.0"
}
TF
run_walk "a"
assert_log_has "t13 nested local sources produce a dot-path key" "b.c.leaf"

# t14 a diamond: two labels reaching the same local directory
setup_workspace
write_tf "root/main.tf" <<'TF'
module "one" {
  source = "../shared"
}

module "two" {
  source = "../shared"
}
TF
write_tf "shared/main.tf" <<'TF'
module "leaf" {
  source = "git::https://example.com/m.git?ref=v1.0.0"
}
TF
run_walk "root"
assert_log_has "t14 diamond yields the first path" "one.leaf"
assert_log_has "t14 diamond yields the second path" "two.leaf"

# t15 mutually-referencing local modules must terminate
setup_workspace
write_tf "x/main.tf" <<'TF'
module "toy" {
  source = "../y"
}
TF
write_tf "y/main.tf" <<'TF'
module "tox" {
  source = "../x"
}
TF
timeout 20 bash -c "true"
run_walk "x"
assert "t15 a local module cycle terminates" test $? -eq 0
assert_log_has "t15 the cycle is reported" "local module cycle"

# t16 a local source pointing outside the workspace
setup_workspace
write_tf "env/main.tf" <<'TF'
module "outside" {
  source = "../../../elsewhere"
}
TF
export input_project_dir="env"
run_resolve
assert_log_has "t16 an escaping local source is reported, not followed" "resolves outside the workspace"
assert_eq "t16 and the directory is excluded, not crashed" "false" "$(out_value cache-enabled)"

# t17 a pin bumped INSIDE the local module must move the consuming dir's key
setup_workspace
write_tf "envs/dev/main.tf" <<'TF'
module "shared" {
  source = "../../main"
}
TF
write_tf "main/main.tf" <<'TF'
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "0.4.3"
}
TF
export input_project_dir="envs/dev"
run_resolve
assert "t17 digest follows a pin bump inside a local module" \
  test "$(out_value cache-key)" != "${T11_KEY}"

# ---------------------------------------------------------------------------
# Key and paths
# ---------------------------------------------------------------------------

# t18 './main' and 'main' are one directory
setup_workspace
write_tf "env/main.tf" <<'TF'
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "0.4.2"
}
TF
write_tf "main/main.tf" <<'TF'
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "0.4.2"
}
TF
export input_project_dir="env" input_additional_dirs_json='["./main", "main", "./main/"]'
run_resolve
assert_eq "t18 duplicate spellings collapse to one path" \
  "env/.terraform/modules
main/.terraform/modules" "$(out_value cache-paths)"
T18_KEY="$(out_value cache-key)"
export input_additional_dirs_json='["main"]'
run_resolve
assert_eq "t18 and to one digest" "${T18_KEY}" "$(out_value cache-key)"

# t19 digest stability
setup_workspace
write_tf "env/main.tf" <<'TF'
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "0.4.2"
}

resource "null_resource" "before" {}
TF
export input_project_dir="env"
run_resolve
T19_KEY="$(out_value cache-key)"
write_tf "env/main.tf" <<'TF'
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "0.4.2"
}

resource "null_resource" "after" {
  triggers = {
    changed = "yes"
  }
}
TF
run_resolve
assert_eq "t19 editing a resource block leaves the key alone" "${T19_KEY}" "$(out_value cache-key)"
write_tf "env/main.tf" <<'TF'
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "0.4.4"
}
TF
run_resolve
assert "t19 bumping a module version moves the key" \
  test "$(out_value cache-key)" != "${T19_KEY}"

# t20 environment names are sanitised into the key's character set
setup_workspace
write_tf "env/main.tf" <<'TF'
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "0.4.2"
}
TF
export input_project_dir="env" input_environment='dsb/prod.one,two'
run_resolve
assert "t20 the key contains only permitted characters" \
  bash -c '[[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]' _ "$(out_value cache-key)"

# t21 nothing anywhere emits restore-keys — guards invariant 8.2
assert "t21 the resolve step emits no restore-keys output" \
  bash -c '! grep -qi "restore-key" "$1"' _ "${GITHUB_OUTPUT}"
assert "t21 the action declares no restore-keys output" \
  bash -c 'python3 -c "
import sys, yaml
outputs = yaml.safe_load(open(sys.argv[1]))[\"outputs\"]
sys.exit(1 if any(\"restore-key\" in name for name in outputs) else 0)
" "$1"' _ "${_this_script_dir}/action.yml"

# t22 empty and absent additional-dirs
setup_workspace
write_tf "env/main.tf" <<'TF'
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "0.4.2"
}
TF
export input_project_dir="env" input_additional_dirs_json='[]'
run_resolve
assert_eq "t22 an empty additional-dirs array is handled" "true" "$(out_value cache-enabled)"
export input_additional_dirs_json=''
run_resolve
assert_eq "t22 an empty additional-dirs string is handled" "true" "$(out_value cache-enabled)"

# t23 a declared directory that does not exist
setup_workspace
write_tf "env/main.tf" <<'TF'
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "0.4.2"
}
TF
export input_project_dir="env" input_additional_dirs_json='["nope"]'
run_resolve
assert_eq "t23 a missing directory does not crash the step" "0" "${LAST_EXIT}"
assert_log_has "t23 and is reported as excluded" "not caching nope"
assert_eq "t23 while the real directory is still cached" "env/.terraform/modules" "$(out_value cache-paths)"

# ---------------------------------------------------------------------------
# Source classification, the long tail
# ---------------------------------------------------------------------------

classify_r() {
  (
    export GITHUB_ACTION_PATH="${_this_script_dir}"
    source "${_this_script_dir}/helpers.sh" >/dev/null 2>&1
    classify-source "${@}"
  )
}

assert_eq "c01 scp-style git with a tag" "immutable" \
  "$(classify_r config 'git@github.com:org/repo.git?ref=v1.0.0')"
assert_eq "c02 scp-style git with a branch" "mutable" \
  "$(classify_r config 'git@github.com:org/repo.git?ref=develop')"
assert_eq "c03 mercurial is never pinned by the url" "mutable" \
  "$(classify_r config 'hg::https://example.com/repo')"
assert_eq "c04 gcs archive" "mutable" \
  "$(classify_r config 'gcs::https://www.googleapis.com/storage/v1/b/m.zip')"
assert_eq "c05 registry with an explicit host and exact pin" "immutable" \
  "$(classify_r config 'app.terraform.io/acme/vpc/aws' '1.2.3')"
assert_eq "c06 exact pin written without a space" "immutable" \
  "$(classify_r config 'acme/vpc/aws' '=1.2.3')"
assert_eq "c07 a prerelease is still an exact pin" "immutable" \
  "$(classify_r config 'acme/vpc/aws' '1.2.3-rc.1')"
assert_eq "c08 a lower bound is not a pin" "mutable" \
  "$(classify_r config 'acme/vpc/aws' '>= 1.2.3')"
assert_eq "c09 a compound constraint is not a pin" "mutable" \
  "$(classify_r config 'acme/vpc/aws' '>= 1.0.0, < 2.0.0')"
# 'depth' forces terraform to pass ref to 'git clone --branch', so a shallow
# clone cannot use a commit sha — tag refs are what callers combining the two
# will have. Both orderings of the query parameters must parse.
assert_eq "c10 ref before depth" "immutable" \
  "$(classify_r config 'git::https://example.com/m.git?ref=v1.0.0&depth=1')"
assert_eq "c11 depth before ref" "immutable" \
  "$(classify_r config 'git::https://example.com/m.git?depth=1&ref=v1.0.0')"
assert_eq "c12 depth before a branch ref is still mutable" "mutable" \
  "$(classify_r config 'git::https://example.com/m.git?depth=1&ref=main')"
assert_eq "c13 'ref=' appearing in the path does not fool the parser" "mutable" \
  "$(classify_r config 'git::https://example.com/myref=thing.git?ref=main')"
assert_eq "c14 an uppercase sha is still a sha" "immutable" \
  "$(classify_r config 'git::https://example.com/m.git?ref=0123456789ABCDEF0123456789abcdef01234567')"
assert_eq "c15 a 39-character hex string is not a sha" "mutable" \
  "$(classify_r config 'git::https://example.com/m.git?ref=0123456789abcdef0123456789abcdef0123456')"

# ---------------------------------------------------------------------------
# Reading configuration
# ---------------------------------------------------------------------------

# r01 several modules in one file, and several files in one directory
setup_workspace
write_tf "env/main.tf" <<'TF'
module "one" {
  source  = "acme/a/aws"
  version = "1.0.0"
}

module "two" {
  source  = "acme/b/aws"
  version = "2.0.0"
}
TF
write_tf "env/extra.tf" <<'TF'
module "three" {
  source  = "acme/c/aws"
  version = "3.0.0"
}
TF
export input_project_dir="env"
run_resolve
assert_eq "r01 modules across several files are all found" "true" "$(out_value cache-enabled)"
assert_log_has "r01 all three are counted" "3 reachable remote module(s)"

# r02 a wholly commented-out module block is not read — which is agreement with
# terraform, not an under-read: terraform does not declare it either.
setup_workspace
write_tf "env/main.tf" <<'TF'
module "live" {
  source  = "acme/a/aws"
  version = "1.0.0"
}

# module "old" {
#   source = "git::https://example.com/m.git?ref=main"
# }
TF
export input_project_dir="env"
run_resolve
assert_eq "r02 a fully commented-out module does not disqualify the directory" "true" "$(out_value cache-enabled)"

# r02b a commented source INSIDE a live block is read, because the parser takes
# the first source-looking line in the block. That is the over-read direction
# (§4.5.1) and it is safe: it can only make the audit more cautious.
setup_workspace
write_tf "env/main.tf" <<'TF'
module "live" {
  # source = "git::https://example.com/m.git?ref=main"
  source  = "acme/a/aws"
  version = "1.0.0"
}
TF
export input_project_dir="env"
run_resolve
assert_eq "r02b an over-read inside a live block errs toward excluding" "false" "$(out_value cache-enabled)"

# r03 modules declared in .tf.json are NOT read. This is the documented
# under-read (§4.5.1): the pre-init audit misses it, and only the post-init
# gate can catch a git source declared this way.
setup_workspace
write_tf "env/main.tf" <<'TF'
module "live" {
  source  = "acme/a/aws"
  version = "1.0.0"
}
TF
mkdir -p "${WORK_DIR}/env"
cat >"${WORK_DIR}/env/generated.tf.json" <<'JSON'
{"module":{"hidden":{"source":"git::https://example.com/m.git?ref=main"}}}
JSON
export input_project_dir="env"
run_resolve
assert_eq "r03 a .tf.json module is not seen by the pre-init audit" "true" "$(out_value cache-enabled)"

# ---------------------------------------------------------------------------
# Key composition
# ---------------------------------------------------------------------------

# k01 same inputs twice produce the same key
setup_workspace
write_tf "env/main.tf" <<'TF'
module "naming" {
  source  = "acme/a/aws"
  version = "1.0.0"
}
TF
export input_project_dir="env" input_environment="alpha"
run_resolve
K_ALPHA="$(out_value cache-key)"
run_resolve
assert_eq "k01 the key is deterministic across runs" "${K_ALPHA}" "$(out_value cache-key)"

# k02 a different environment gets a different key, since project-dir differs
export input_environment="beta"
run_resolve
assert "k02 a different environment gets a different key" \
  test "$(out_value cache-key)" != "${K_ALPHA}"
assert_log_has "k02 and the environment is visible in it" "tf-modules-linux-beta-"

# k03 a different runner OS gets a different key
export input_environment="alpha" RUNNER_OS="Windows"
run_resolve
assert "k03 a different runner OS gets a different key" \
  test "$(out_value cache-key)" != "${K_ALPHA}"
export RUNNER_OS="Linux"

# k04 project-dir leads the cache paths, then the additional dirs in order
setup_workspace
for d in env alpha beta; do
  write_tf "${d}/main.tf" <<'TF'
module "naming" {
  source  = "acme/a/aws"
  version = "1.0.0"
}
TF
done
export input_project_dir="env" input_additional_dirs_json='["beta","alpha"]'
run_resolve
assert_eq "k04 cache paths keep project-dir first, then declared order" \
  "env/.terraform/modules
beta/.terraform/modules
alpha/.terraform/modules" "$(out_value cache-paths)"

# ---------------------------------------------------------------------------
# Block boundaries
#
# A 'terraform' block's required_providers carries its own source and version.
# If a module block ran on until the next module header, an unpinned registry
# module followed by a provider version would look pinned and be cached — and
# an unpinned module resolves to the latest release, so that is the §3 hazard
# reached through the parser rather than through a git ref.
# ---------------------------------------------------------------------------

# b01 the classic real-world file: unpinned module, then required_providers
setup_workspace
write_tf "env/main.tf" <<'TF'
module "reg" {
  source = "acme/vpc/aws"
}

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.1.2"
    }
  }
}
TF
export input_project_dir="env"
run_resolve
assert_eq "b01 a provider version does not pin the module above it" "false" "$(out_value cache-enabled)"

# b02 a provider source is never mistaken for a module source
setup_workspace
write_tf "env/main.tf" <<'TF'
module "pinned" {
  source  = "acme/vpc/aws"
  version = "1.0.0"
}

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4"
    }
  }
}
TF
export input_project_dir="env"
run_resolve
assert_eq "b02 a provider's range constraint does not disqualify the directory" "true" "$(out_value cache-enabled)"
assert_log_has "b02 and only the real module is counted" "1 reachable remote module(s)"

# b03 module blocks either side of a terraform block are both read
setup_workspace
write_tf "env/main.tf" <<'TF'
module "first" {
  source  = "acme/a/aws"
  version = "1.0.0"
}

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4"
    }
  }
}

module "second" {
  source  = "acme/b/aws"
  version = "2.0.0"
}
TF
export input_project_dir="env"
run_resolve
assert_log_has "b03 modules either side of a terraform block are both found" "2 reachable remote module(s)"

# b04 providers declared in their own file, with no module blocks at all
setup_workspace
write_tf "env/main.tf" <<'TF'
module "pinned" {
  source  = "acme/a/aws"
  version = "1.0.0"
}
TF
write_tf "env/versions.tf" <<'TF'
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4"
    }
  }
}
TF
export input_project_dir="env"
run_resolve
assert_log_has "b04 a providers-only file contributes nothing" "1 reachable remote module(s)"
assert_eq "b04 and the directory is still cacheable" "true" "$(out_value cache-enabled)"

# b05 a resource block between modules does not bleed either
setup_workspace
write_tf "env/main.tf" <<'TF'
module "pinned" {
  source  = "acme/a/aws"
  version = "1.0.0"
}

resource "azurerm_resource_group" "rg" {
  name     = "rg"
  location = "norwayeast"
}

module "also_pinned" {
  source  = "acme/b/aws"
  version = "2.0.0"
}
TF
export input_project_dir="env"
run_resolve
assert_log_has "b05 a resource block between modules is ignored" "2 reachable remote module(s)"
assert_eq "b05 and both modules are pinned, so the directory is cached" "true" "$(out_value cache-enabled)"

# ---------------------------------------------------------------------------
# Run-block modules of test files (test-directory)
#
# 'terraform init' in a root installs the module of every 'run' block of every
# test file it loads — '<root>/*.tftest.hcl' and '<root>/tests/*.tftest.hcl' —
# under '.terraform/modules/test.<file>.<run>', whatever '-filter' later names.
# Only local and registry sources are accepted there, so the exposures are a
# registry range (a restored tree keeps the old release) and a local source
# reaching a remote module (invisible to the .tf walk).
# ---------------------------------------------------------------------------

# Run the test-file walk directly, for the dot-path assertions.
run_test_walk() {
  (
    export GITHUB_ACTION_PATH="${_this_script_dir}"
    source "${_this_script_dir}/helpers.sh"
    reset-walk-state
    walk-test-run-modules "${WORK_DIR}/${1}" "${2}"
  ) >"${STEP_LOG}" 2>/dev/null
}

# A root holding one pinned module in its .tf, so there is always something to
# cache and the test files decide the verdict and the key.
pinned_root_fixture() {
  setup_workspace
  write_tf "root/main.tf" <<'TF'
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "0.4.2"
}
TF
  export input_project_dir="root"
}

# rb01 no test-directory: a test file with a range is not read, and the key is
# the one the root had before the file existed — existing callers see no change.
pinned_root_fixture
run_resolve
RB01_KEY_BEFORE="$(out_value cache-key)"
write_tf "root/tests/unit.tftest.hcl" <<'HCL'
run "basic" {
  module {
    source  = "cloudposse/label/null"
    version = "~> 0.25"
  }
}
HCL
run_resolve
assert_eq "rb01 without test-directory the root stays cached" "true" "$(out_value cache-enabled)"
assert_eq "rb01 and its key does not see the test file" "${RB01_KEY_BEFORE}" "$(out_value cache-key)"
assert_log_lacks "rb01 and test files are not mentioned" "test files"

# rb02 a registry run-block source with a range keeps the root uncached
export input_test_directory="tests"
run_resolve
assert_eq "rb02 a run-block registry range excludes the root" "false" "$(out_value cache-enabled)"
assert_log_has "rb02 the notice names terraform's module key and the range" \
  "test.tests.unit.basic (cloudposse/label/null ~> 0.25)"

# rb03 an exact version is cached, with the declaration in the key
write_tf "root/tests/unit.tftest.hcl" <<'HCL'
run "basic" {
  command = plan
  module {
    source  = "cloudposse/label/null"
    version = "0.25.0"
  }
}
HCL
run_resolve
assert_eq "rb03 a run-block exact pin keeps the root cached" "true" "$(out_value cache-enabled)"
assert_eq "rb03 the cache path is the root's own tree, where terraform installs it" \
  "root/.terraform/modules" "$(out_value cache-paths)"
assert_log_has "rb03 the run-block module is counted" "2 reachable remote module(s)"
RB03_KEY="$(out_value cache-key)"
assert "rb03 the declaration moves the key" test "${RB03_KEY}" != "${RB01_KEY_BEFORE}"
assert "rb03 the key keeps the caller's environment, not a file slug" \
  bash -c "[[ '${RB03_KEY}' == tf-modules-linux-test-env-* ]]"

# rb04 bumping the run-block pin moves the key again
sed -i 's/0.25.0/0.25.1/' "${WORK_DIR}/root/tests/unit.tftest.hcl"
run_resolve
assert "rb04 a bumped run-block pin moves the key" test "$(out_value cache-key)" != "${RB03_KEY}"

# rb05 same declaration, same key; renaming the run block moves it, since the
# module key terraform installs under is test.<file>.<run>
sed -i 's/0.25.1/0.25.0/' "${WORK_DIR}/root/tests/unit.tftest.hcl"
run_resolve
assert_eq "rb05 the same declarations give the same key" "${RB03_KEY}" "$(out_value cache-key)"
sed -i 's/run "basic"/run "renamed"/' "${WORK_DIR}/root/tests/unit.tftest.hcl"
run_resolve
assert "rb05 a renamed run block moves the key" test "$(out_value cache-key)" != "${RB03_KEY}"

# rb06 test files with run blocks but no module blocks leave the key alone
pinned_root_fixture
run_resolve
RB06_KEY="$(out_value cache-key)"
write_tf "root/tests/unit.tftest.hcl" <<'HCL'
variables {
  version = "1.0.0"
}

run "plain" {
  command = plan
  assert {
    condition     = true
    error_message = "never"
  }
}
HCL
export input_test_directory="tests"
run_resolve
assert_eq "rb06 run blocks without a module leave the key unchanged" "${RB06_KEY}" "$(out_value cache-key)"

# rb07 an empty root whose test reaches a registry module through a local
# source: walked, relative to the ROOT and not the test file, keyed as
# terraform keys it.
setup_workspace
write_tf "mods/wrap/main.tf" <<'TF'
module "label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"
}
TF
write_tf "tests/unit-net.tftest.hcl" <<'HCL'
run "wrapped" {
  command = plan
  module {
    source = "./mods/wrap"
  }
}
HCL
export input_project_dir="."
export input_test_directory="tests"
run_resolve
assert_eq "rb07 a local run-block source reaching a registry module is cached" "true" "$(out_value cache-enabled)"
assert_eq "rb07 the cache path is the root's tree" "./.terraform/modules" "$(out_value cache-paths)"
assert_log_has "rb07 only the remote module counts" "1 reachable remote module(s)"
run_test_walk "." "tests"
assert_log_has "rb07 the local declaration is emitted under terraform's key" \
  "$(printf 'test.tests.unit-net.wrapped\t./mods/wrap\t')"
assert_log_has "rb07 the module it reaches is keyed beneath it" \
  "$(printf 'test.tests.unit-net.wrapped.label\tcloudposse/label/null\t0.25.0')"

# rb08 the same source resolved relative to the test file would be
# 'tests/mods/wrap', which is not what terraform reads; it must not be walked.
setup_workspace
write_tf "tests/mods/wrap/main.tf" <<'TF'
module "label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"
}
TF
write_tf "tests/unit.tftest.hcl" <<'HCL'
run "wrapped" {
  module {
    source = "./mods/wrap"
  }
}
HCL
export input_project_dir="."
export input_test_directory="tests"
run_resolve
assert_eq "rb08 a source is not resolved relative to the test file" "false" "$(out_value cache-enabled)"
assert_log_has "rb08 and the missing root-relative path is reported" "does not exist"

# rb09 a local run-block source reaching a branch ref excludes the root
setup_workspace
write_tf "mods/wrap/main.tf" <<'TF'
module "floating" {
  source = "git::https://example.com/m.git?ref=main"
}
TF
write_tf "root/tests/unit.tftest.hcl" <<'HCL'
run "wrapped" {
  module {
    source = "../mods/wrap"
  }
}
HCL
export input_project_dir="root"
export input_test_directory="tests"
run_resolve
assert_eq "rb09 a branch ref reached from a run block excludes the root" "false" "$(out_value cache-enabled)"
assert_log_has "rb09 the notice names the walked module key" "test.tests.unit.wrapped.floating"

# rb10 local sources that reach nothing remote: not cached, and nothing to key
setup_workspace
write_tf "mods/plain/main.tf" <<'TF'
resource "terraform_data" "x" {}
TF
write_tf "tests/unit.tftest.hcl" <<'HCL'
run "plain" {
  module {
    source = "./mods/plain"
  }
}
HCL
export input_project_dir="."
export input_test_directory="tests"
run_resolve
assert_eq "rb10 run blocks reaching nothing remote are not cached" "false" "$(out_value cache-enabled)"
assert_log_has "rb10 says why" "no remote modules reachable"

# rb11 a local run-block declaration enters the key even when it reaches
# nothing remote: its manifest entry still appears under an unchanged key
# otherwise, and the completeness check would warn on every exact hit.
pinned_root_fixture
write_tf "mods/plain/main.tf" <<'TF'
resource "terraform_data" "x" {}
TF
export input_test_directory="tests"
run_resolve
RB11_KEY="$(out_value cache-key)"
write_tf "root/tests/unit.tftest.hcl" <<'HCL'
run "plain" {
  module {
    source = "../mods/plain"
  }
}
HCL
run_resolve
assert_eq "rb11 the root stays cached" "true" "$(out_value cache-enabled)"
assert_log_has "rb11 the local declaration is not counted as remote" "1 reachable remote module(s)"
assert "rb11 but it moves the key" test "$(out_value cache-key)" != "${RB11_KEY}"

# rb12 root-level test files are read too; a nested directory under tests/ is
# not, because terraform does not load it either
pinned_root_fixture
write_tf "root/top.tftest.hcl" <<'HCL'
run "x" {
  module {
    source  = "cloudposse/label/null"
    version = ">= 0.25"
  }
}
HCL
export input_test_directory="tests"
run_resolve
assert_eq "rb12 a root-level test file's range excludes the root" "false" "$(out_value cache-enabled)"
assert_log_has "rb12 keyed test.<file>.<run> for a root-level file" "test.top.x"
rm "${WORK_DIR}/root/top.tftest.hcl"
write_tf "root/tests/nested/deep.tftest.hcl" <<'HCL'
run "x" {
  module {
    source  = "cloudposse/label/null"
    version = ">= 0.25"
  }
}
HCL
run_resolve
assert_eq "rb12 a file nested under tests/ is not read" "true" "$(out_value cache-enabled)"

# rb13 test-directory names the directory read; 'tests' is then not read
pinned_root_fixture
write_tf "root/tests/unit.tftest.hcl" <<'HCL'
run "x" {
  module {
    source  = "cloudposse/label/null"
    version = "~> 0.25"
  }
}
HCL
write_tf "root/spec/unit.tftest.hcl" <<'HCL'
run "y" {
  module {
    source  = "cloudposse/label/null"
    version = "0.25.0"
  }
}
HCL
export input_test_directory="./spec/"
run_resolve
assert_eq "rb13 a custom test directory replaces tests/" "true" "$(out_value cache-enabled)"
assert_log_has "rb13 the directory is normalised" "test directory 'spec'"
run_test_walk "root" "spec"
assert_log_has "rb13 keyed under the custom directory" "test.spec.unit.y"

# rb14 a '*.tftest.json' file is not parsed, so the root is not cached
pinned_root_fixture
write_tf "root/tests/unit.tftest.json" <<'JSON'
{"run": {"basic": {"module": {"source": "cloudposse/label/null", "version": "0.25.0"}}}}
JSON
export input_test_directory="tests"
run_resolve
assert_eq "rb14 a JSON test file keeps the root uncached" "false" "$(out_value cache-enabled)"
assert_log_has "rb14 the notice says it could not be read" \
  "test-file module declaration 'test.tests.unit' could not be read"

# rb15 a module block with no literal source is not guessed at
pinned_root_fixture
write_tf "root/tests/unit.tftest.hcl" <<'HCL'
run "basic" {
  module {
    version = "0.25.0"
  }
}
HCL
export input_test_directory="tests"
run_resolve
assert_eq "rb15 a module block without a source keeps the root uncached" "false" "$(out_value cache-enabled)"
assert_log_has "rb15 the notice names the run block" "'test.tests.unit.basic' could not be read"

# rb16 only the module sub-block is read: a pinned 'version' in the run's
# variables block, before or after, never makes a range look pinned
pinned_root_fixture
write_tf "root/tests/unit.tftest.hcl" <<'HCL'
run "basic" {
  variables {
    source  = "acme/other/aws"
    version = "9.9.9"
  }

  module {
    source  = "cloudposse/label/null"
    version = "~> 0.25"
  }

  variables {
    version = "1.0.0"
  }
}
HCL
export input_test_directory="tests"
run_resolve
assert_eq "rb16 a variables block does not lend the module its version" "false" "$(out_value cache-enabled)"
assert_log_has "rb16 the module's own range is what is reported" "(cloudposse/label/null ~> 0.25)"

# rb17 a module block with no version stays unpinned even when a later block
# of the same run carries one
write_tf "root/tests/unit.tftest.hcl" <<'HCL'
run "basic" {
  module {
    source = "cloudposse/label/null"
  }
  variables {
    version = "1.0.0"
  }
}
HCL
run_resolve
assert_eq "rb17 an unpinned run-block module is not pinned by a later block" "false" "$(out_value cache-enabled)"

# rb18 a commented-out pin ahead of a live range: terraform reads the range,
# and so must the reader
write_tf "root/tests/unit.tftest.hcl" <<'HCL'
run "basic" {
  module {
    source = "cloudposse/label/null"
    # version = "0.25.0"
    // version = "0.25.0"
    /*
    version = "0.25.0"
    */
    version = "~> 0.25"
  }
}
HCL
run_resolve
assert_eq "rb18 commented pins do not hide a live range" "false" "$(out_value cache-enabled)"

# rb19 single-line and unformatted module blocks, several run blocks per file
pinned_root_fixture
write_tf "mods/wrap/main.tf" <<'TF'
module "label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"
}
TF
write_tf "root/tests/unit.tftest.hcl" <<'HCL'
run "one" {
  module { source = "../mods/wrap" }
}
run "two" {
module {
source="cloudposse/label/null"
version="0.25.0"
}
}
run "three" {
  command = plan
}
HCL
export input_test_directory="tests"
run_test_walk "root" "tests"
assert_log_has "rb19 a single-line module block is read" "$(printf 'test.tests.unit.one\t../mods/wrap\t')"
assert_log_has "rb19 an unformatted module block is read" \
  "$(printf 'test.tests.unit.two\tcloudposse/label/null\t0.25.0')"
assert_eq "rb19 a run block without a module contributes nothing" "3" "$(grep -c '^test\.' "${STEP_LOG}")"
run_resolve
assert_eq "rb19 and the root is cached" "true" "$(out_value cache-enabled)"
assert_log_has "rb19 with the .tf, the run-block and the walked module counted" "3 reachable remote module(s)"

# rb20 a local run-block source escaping the workspace is not walked
setup_workspace
write_tf "tests/unit.tftest.hcl" <<'HCL'
run "escape" {
  module {
    source = "../../../../../../../../elsewhere"
  }
}
HCL
export input_project_dir="."
export input_test_directory="tests"
run_resolve
assert_eq "rb20 an escaping run-block source is not cached" "false" "$(out_value cache-enabled)"
assert_log_has "rb20 and is reported" "resolves outside the workspace"

# rb21 the step still exits 0 and emits every output with test files read
assert_eq "rb21 step exits 0" "0" "${LAST_EXIT}"
