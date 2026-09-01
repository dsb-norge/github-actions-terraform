#!/bin/env bash
#
# Tests for step_snapshot.sh and step_verify.sh — the digest completeness check
# and the save gate. Fixture ids map to docs/Terraform-module-cache.md §9.
#
# Sourced by run_all_tests.sh, which owns the counters and the summary.
#

# Call the shared classifier directly.
classify() {
  (
    export GITHUB_ACTION_PATH="${_this_script_dir}"
    source "${_this_script_dir}/helpers.sh" >/dev/null 2>&1
    classify-source "${@}"
  )
}

PINNED_MANIFEST='{"Modules":[
  {"Key":"","Source":"","Dir":"."},
  {"Key":"a","Source":"registry.terraform.io/x/y/az","Version":"1.0.0","Dir":".terraform/modules/a"},
  {"Key":"b","Source":"git::https://example.com/b.git?ref=v2.0.0","Dir":".terraform/modules/b"}
]}'

# Fixture with one cached directory whose restored manifest is $1.
hit_fixture() {
  setup_workspace
  write_manifest "env" <<<"${1}"
  export input_cache_paths="env/.terraform/modules"
  export input_cache_hit="true"
  run_snapshot
}

# ---------------------------------------------------------------------------
# Digest completeness (§4.4.2)
# ---------------------------------------------------------------------------

# t24 nothing changed
hit_fixture "${PINNED_MANIFEST}"
run_verify
assert_log_lacks "t24 an unchanged module set produces no warning" "digest is incomplete"
assert_eq "t24 and the entry is still safe to save" "true" "$(out_value safe-to-save)"

# t25 the module set gained an entry under an unchanged key
hit_fixture "${PINNED_MANIFEST}"
write_manifest "env" <<'JSON'
{"Modules":[
  {"Key":"","Source":"","Dir":"."},
  {"Key":"a","Source":"registry.terraform.io/x/y/az","Version":"1.0.0","Dir":".terraform/modules/a"},
  {"Key":"b","Source":"git::https://example.com/b.git?ref=v2.0.0","Dir":".terraform/modules/b"},
  {"Key":"c","Source":"registry.terraform.io/n/e/w","Version":"3.0.0","Dir":".terraform/modules/c"}
]}
JSON
run_verify
assert_log_has "t25 drift on an exact hit warns" "digest is incomplete for 'env'"

# t26 same modules, different array order
hit_fixture "${PINNED_MANIFEST}"
write_manifest "env" <<'JSON'
{"Modules":[
  {"Key":"b","Source":"git::https://example.com/b.git?ref=v2.0.0","Dir":".terraform/modules/b"},
  {"Key":"a","Source":"registry.terraform.io/x/y/az","Version":"1.0.0","Dir":".terraform/modules/a"},
  {"Key":"","Source":"","Dir":"."}
]}
JSON
run_verify
assert_log_lacks "t26 a reordered manifest is normalised, not reported" "digest is incomplete"

# t27 a directory outside cache-paths is never checked, however much it changes
hit_fixture "${PINNED_MANIFEST}"
write_manifest "excluded" <<'JSON'
{"Modules":[{"Key":"z","Source":"registry.terraform.io/q/r/s","Version":"9.9.9","Dir":".terraform/modules/z"}]}
JSON
run_verify
assert_log_lacks "t27 an excluded directory never trips the check" "excluded"

# t28 no before-image, because the cache missed
setup_workspace
write_manifest "env" <<<"${PINNED_MANIFEST}"
export input_cache_paths="env/.terraform/modules"
export input_cache_hit="false"
run_snapshot
assert_log_has "t28 the snapshot is a no-op on a miss" "nothing to snapshot"
export input_cache_hit="true"
run_verify
assert_log_has "t28 and the check is skipped rather than reporting a phantom change" "no before-image"
assert_log_lacks "t28 no drift warning without a before-image" "digest is incomplete"

# ---------------------------------------------------------------------------
# The save gate (§4.5.2)
# ---------------------------------------------------------------------------

# t29 everything resolved is immutable
hit_fixture "${PINNED_MANIFEST}"
run_verify
assert_eq "t29 an all-pinned graph is safe to save" "true" "$(out_value safe-to-save)"

# t30 a branch ref inside a remote module — invisible to the pre-init audit
hit_fixture "${PINNED_MANIFEST}"
write_manifest "env" <<'JSON'
{"Modules":[
  {"Key":"parent","Source":"git::https://example.com/p.git?ref=v1.0.0","Dir":".terraform/modules/parent"},
  {"Key":"parent.child","Source":"git::https://example.com/c.git?ref=main","Dir":".terraform/modules/parent.child"}
]}
JSON
run_verify
assert_eq "t30 a transitive branch ref refuses the save" "false" "$(out_value safe-to-save)"
assert_log_has "t30 and the warning names the module" "parent.child"

# t31 one offending directory suppresses the whole entry
setup_workspace
write_manifest "good" <<<"${PINNED_MANIFEST}"
write_manifest "bad" <<'JSON'
{"Modules":[{"Key":"floating","Source":"git::https://example.com/f.git?ref=develop","Dir":".terraform/modules/floating"}]}
JSON
export input_cache_paths="good/.terraform/modules
bad/.terraform/modules"
export input_cache_hit="false"
run_verify
assert_eq "t31 the gate is all-or-nothing across the entry" "false" "$(out_value safe-to-save)"

# t32 a range and an exact pin are indistinguishable post-init (§2.7). Both
# pass. This asserts the documented blindness so it reads as intended rather
# than as a bug.
hit_fixture "${PINNED_MANIFEST}"
write_manifest "env" <<'JSON'
{"Modules":[{"Key":"r","Source":"registry.terraform.io/Azure/naming/azurerm","Version":"0.4.3","Dir":".terraform/modules/r"}]}
JSON
run_verify
assert_eq "t32 a resolved registry version passes the gate" "true" "$(out_value safe-to-save)"

# t33 the classifier's verdict depends on which input it was given
assert_eq "t33 config: a range constraint is mutable" \
  "mutable" "$(classify config 'Azure/naming/azurerm' '~> 0.4')"
assert_eq "t33 manifest: the same module cannot be shown mutable" \
  "immutable" "$(classify manifest 'registry.terraform.io/Azure/naming/azurerm' '0.4.3')"
assert_eq "t33 both inputs agree that a branch ref is mutable" \
  "mutable-mutable" "$(classify config 'git::https://e.com/m.git?ref=main')-$(classify manifest 'git::https://e.com/m.git?ref=main')"
assert_eq "t33 both inputs agree that a local source is local" \
  "local-local" "$(classify config '../../main')-$(classify manifest '../../main')"

# t34 init failed or was interrupted, so the manifest is missing or unreadable
setup_workspace
mkdir -p "${WORK_DIR}/env/.terraform/modules"
export input_cache_paths="env/.terraform/modules"
export input_cache_hit="false"
run_verify
assert_eq "t34 a missing manifest does not crash the step" "0" "${LAST_EXIT}"
assert_eq "t34 and fails closed rather than saving unverified" "false" "$(out_value safe-to-save)"
write_manifest "env" <<'JSON'
not json at all {{{
JSON
run_verify
assert_eq "t34 an unparseable manifest also fails closed" "false" "$(out_value safe-to-save)"
assert_eq "t34 without crashing" "0" "${LAST_EXIT}"

# t34b nothing to verify at all
setup_workspace
export input_cache_paths=""
run_verify
assert_eq "t34 an empty cache-paths refuses the save" "false" "$(out_value safe-to-save)"
