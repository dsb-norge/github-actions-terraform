#!/bin/env bash
#
# Tests for step_prune.sh — the git-metadata prune that runs immediately before
# the cache save. Fixture ids map to docs/Terraform-module-cache.md §9.
#
# Sourced by run_all_tests.sh, which owns the counters and the summary.
#
# The properties worth holding onto here are that terraform keeps what it needs
# (the manifest and the module sources), and that an 'rm -rf' driven by a step
# input never reaches outside the cache paths it was given.
#

# A module tree shaped like the one terraform leaves behind: manifest, module
# sources, the clone's '.git' directory and the gitlink FILE that
# 'git submodule update --init --recursive' leaves for a nested checkout.
# make_module_tree <dir-relative-to-workspace>
make_module_tree() {
  local modules="${WORK_DIR}/${1}/.terraform/modules"
  mkdir -p "${modules}/naming/.git/objects" "${modules}/naming/vendored"
  cat >"${modules}/modules.json" <<'JSON'
{"Modules":[
  {"Key":"","Source":"","Dir":"."},
  {"Key":"naming","Source":"registry.terraform.io/Azure/naming/azurerm","Version":"0.4.2","Dir":".terraform/modules/naming"}
]}
JSON
  echo 'output "name" { value = "x" }' >"${modules}/naming/main.tf"
  # Big enough that the freed-KiB accounting has something to report.
  head -c 200000 /dev/zero >"${modules}/naming/.git/objects/pack"
  echo 'gitdir: ../../.git/modules/vendored' >"${modules}/naming/vendored/.git"
}

# The repository's own metadata. Terraform's tree sits inside the checkout, so
# every prune runs with this within reach — it must never be touched.
make_repo_metadata() {
  mkdir -p "${WORK_DIR}/.git/refs"
  echo 'ref: refs/heads/main' >"${WORK_DIR}/.git/HEAD"
}

count_git_entries() { find "${WORK_DIR}/${1}" -name .git 2>/dev/null | wc -l; }

# ---------------------------------------------------------------------------
# What gets removed, and what survives
# ---------------------------------------------------------------------------

# t35 the clone's .git directory goes, the module itself stays
setup_workspace
make_module_tree "env"
make_repo_metadata
export input_cache_paths="env/.terraform/modules"
run_prune
assert_eq "t35 step exits 0" "0" "${LAST_EXIT}"
assert "t35 the clone's .git directory is gone" \
  bash -c "[ ! -e '${WORK_DIR}/env/.terraform/modules/naming/.git' ]"
assert "t35 the manifest survives — terraform reconciles against it" \
  test -f "${WORK_DIR}/env/.terraform/modules/modules.json"
assert "t35 the module source survives" \
  test -f "${WORK_DIR}/env/.terraform/modules/naming/main.tf"
assert_eq "t35 both git entries are counted" "2" "$(out_value pruned-count)"
assert "t35 the freed size is reported" \
  bash -c "[ \"$(out_value freed-kib)\" -gt 100 ]"

# t36 the gitlink FILE a submodule checkout leaves is removed too
setup_workspace
make_module_tree "env"
export input_cache_paths="env/.terraform/modules"
run_prune
assert "t36 the gitlink file is gone" \
  bash -c "[ ! -e '${WORK_DIR}/env/.terraform/modules/naming/vendored/.git' ]"
assert "t36 but its directory is left in place" \
  test -d "${WORK_DIR}/env/.terraform/modules/naming/vendored"

# t37 metadata several levels down is reached
setup_workspace
make_module_tree "env"
mkdir -p "${WORK_DIR}/env/.terraform/modules/naming/modules/sub/deeper/.git"
export input_cache_paths="env/.terraform/modules"
run_prune
assert_eq "t37 nothing git-shaped is left anywhere under the path" \
  "0" "$(count_git_entries 'env/.terraform/modules')"

# t38 the repository's own metadata is out of scope
setup_workspace
make_module_tree "env"
make_repo_metadata
export input_cache_paths="env/.terraform/modules"
run_prune
assert "t38 the repository's .git is untouched" \
  test -f "${WORK_DIR}/.git/HEAD"

# t39 more than one cache path, counts summed
setup_workspace
make_module_tree "env/dev"
make_module_tree "env/prod"
export input_cache_paths="env/dev/.terraform/modules
env/prod/.terraform/modules"
run_prune
assert_eq "t39 every path is pruned and the counts add up" "4" "$(out_value pruned-count)"
assert_eq "t39 first path is clean" "0" "$(count_git_entries 'env/dev/.terraform/modules')"
assert_eq "t39 second path is clean" "0" "$(count_git_entries 'env/prod/.terraform/modules')"

# ---------------------------------------------------------------------------
# Nothing to do, and nothing to break
# ---------------------------------------------------------------------------

# t40 a tree with no git metadata at all (every module came from the registry
# as a tarball, or the cache was restored already pruned)
setup_workspace
mkdir -p "${WORK_DIR}/env/.terraform/modules"
echo '{"Modules":[]}' >"${WORK_DIR}/env/.terraform/modules/modules.json"
export input_cache_paths="env/.terraform/modules"
run_prune
assert_eq "t40 step exits 0" "0" "${LAST_EXIT}"
assert_eq "t40 nothing is reported as pruned" "0" "$(out_value pruned-count)"
assert_log_has "t40 and it says so" "holds no git metadata"

# t41 a cache path that does not exist — the prune must not be what fails a run
setup_workspace
export input_cache_paths="env/.terraform/modules"
run_prune
assert_eq "t41 step exits 0" "0" "${LAST_EXIT}"
assert_log_has "t41 the missing path is logged" "does not exist"

# t42 no cache paths at all
setup_workspace
export input_cache_paths=""
run_prune
assert_eq "t42 step exits 0" "0" "${LAST_EXIT}"
assert_eq "t42 pruned-count is published as zero" "0" "$(out_value pruned-count)"
assert_log_has "t42 and it says there was nothing to do" "nothing to prune"

# ---------------------------------------------------------------------------
# The 'rm -rf' stays where it was pointed
# ---------------------------------------------------------------------------

# t43 a path that climbs out of the workspace is refused. Without the guard this
# would delete the .git of whatever sits beside the checkout.
setup_workspace
outside="$(mktemp -d)"
mkdir -p "${outside}/.terraform/modules/.git"
export input_cache_paths="../$(basename "${outside}")/.terraform/modules"
# The escape only resolves when the two really are siblings, which mktemp -d
# gives us: both live directly under $TMPDIR.
run_prune
assert_eq "t43 step exits 0" "0" "${LAST_EXIT}"
assert "t43 the .git outside the workspace survives" test -d "${outside}/.terraform/modules/.git"
assert_log_has "t43 and the refusal is logged" "resolves outside the workspace"
rm -rf "${outside}"

# t44 a path that is not a module tree is refused, whatever it points at
setup_workspace
mkdir -p "${WORK_DIR}/src/.git"
export input_cache_paths="src"
run_prune
assert_eq "t44 step exits 0" "0" "${LAST_EXIT}"
assert "t44 the path is left alone" test -d "${WORK_DIR}/src/.git"
assert_log_has "t44 and the refusal is logged" "is not a '.terraform/modules' path"

# t45 a project at the repository root — the shape normalize-dir emits for it
setup_workspace
make_module_tree "."
make_repo_metadata
export input_cache_paths="./.terraform/modules"
run_prune
assert_eq "t45 the root-level module tree is pruned" \
  "0" "$(count_git_entries './.terraform/modules')"
assert "t45 and the repository's own .git still survives" \
  test -f "${WORK_DIR}/.git/HEAD"
