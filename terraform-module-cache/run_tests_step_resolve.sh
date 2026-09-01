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
