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
