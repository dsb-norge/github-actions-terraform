#!/bin/env bash
#
# Test suite for rewrite-internal-refs.sh — docs/Preview-refs.md §9.
#
# Offline and fixture-based: builds a synthetic repo layout under mktemp, runs the script
# against it through REPO_ROOT and compares bytes. T-M9 additionally runs against the real
# workflow tree of this checkout, and F-guard greps pr-preview.yml for the contract the
# workflow must keep with the script (same file list, same regex). Emits the canonical
# `Tests run/passed/failed` lines.
#
# Runs as the first step of pr-preview.yml — a broken rewriter must not publish — and by hand:
#   bash .github/scripts/test-rewrite-internal-refs.sh
#

set -o nounset
set -o pipefail

_this_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SCRIPT="${_this_script_dir}/rewrite-internal-refs.sh"
REAL_REPO_ROOT="$(cd -- "${_this_script_dir}/../.." && pwd)"
WORKFLOW="${REAL_REPO_ROOT}/.github/workflows/pr-preview.yml"
NEW_REF='preview/pr-7-abc1234'

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

function section { echo -e "\n${BLUE}== ${1} ==${NC}"; }
function pass {
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1))
  echo -e "  ${GREEN}PASS${NC} ${1}"
}
function fail {
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
  echo -e "  ${RED}FAIL${NC} ${1}"
  [[ -n "${2:-}" ]] && printf '%s\n' "${2}" | sed 's/^/       /'
}
function assert_eq {
  local name="${1}" expected="${2}" actual="${3}"
  if [[ "${expected}" == "${actual}" ]]; then pass "${name}"; else fail "${name}" "expected: ${expected}"$'\n'"actual:   ${actual}"; fi
}
function assert_identical {
  local name="${1}" a="${2}" b="${3}"
  if cmp -s "${a}" "${b}"; then pass "${name}"; else fail "${name}" "$(diff "${a}" "${b}" | head -20)"; fi
}
function assert_contains {
  local name="${1}" haystack="${2}" needle="${3}"
  if [[ "${haystack}" == *"${needle}"* ]]; then pass "${name}"; else fail "${name}" "missing: ${needle}"$'\n'"in:"$'\n'"${haystack}"; fi
}
function tree_sum { (cd "${1}" && find . -type f | LC_ALL=C sort | xargs md5sum); }

# Fixture: a synthetic repo with every line shape the script must handle or leave alone.
function make_fixture {
  local root="${1}"
  mkdir -p "${root}/.github/workflows" "${root}/docs" "${root}/some-action" "${root}/expected"

  cat >"${root}/.github/workflows/terraform-ci-cd-default.yml" <<'YML'
name: fixture default workflow
# Calling repos pin dsb-norge/github-actions-terraform@v0 — prose in a comment, not a reference.
jobs:
  tf:
    steps:
      - name: "⬇ Checkout"
        uses: actions/checkout@v6
      - name: "⚙️ init — old-style manual swap with marker"
        # TODO revert to @v0
        uses: dsb-norge/github-actions-terraform/terraform-init@my-feature
      - uses: dsb-norge/github-actions-terraform/terraform-plan@v0   # trailing comment stays
      - name: "pinned minor, extra spaces after the colon"
        uses:   dsb-norge/github-actions-terraform/terraform-apply@v0.21
      - name: "pinned sha"
        uses: dsb-norge/github-actions-terraform/pr-comment@0123456789abcdef0123456789abcdef01234567
      - name: "other repo in the same org"
        uses: dsb-norge/github-actions/get-github-app-installation-token@v2
      - name: "lookalike repo name"
        uses: dsb-norge/github-actions-terraform-other/thing@v1
      - uses: hashicorp/setup-terraform@v4
YML

  cat >"${root}/expected/terraform-ci-cd-default.yml" <<'YML'
name: fixture default workflow
# Calling repos pin dsb-norge/github-actions-terraform@v0 — prose in a comment, not a reference.
jobs:
  tf:
    steps:
      - name: "⬇ Checkout"
        uses: actions/checkout@v6
      - name: "⚙️ init — old-style manual swap with marker"
        # TODO revert to @v0
        uses: dsb-norge/github-actions-terraform/terraform-init@preview/pr-7-abc1234
      - uses: dsb-norge/github-actions-terraform/terraform-plan@preview/pr-7-abc1234   # trailing comment stays
      - name: "pinned minor, extra spaces after the colon"
        uses:   dsb-norge/github-actions-terraform/terraform-apply@preview/pr-7-abc1234
      - name: "pinned sha"
        uses: dsb-norge/github-actions-terraform/pr-comment@preview/pr-7-abc1234
      - name: "other repo in the same org"
        uses: dsb-norge/github-actions/get-github-app-installation-token@v2
      - name: "lookalike repo name"
        uses: dsb-norge/github-actions-terraform-other/thing@v1
      - uses: hashicorp/setup-terraform@v4
YML

  # All-@v0, .yaml extension: the round-trip case (rewrite away, rewrite back, identical).
  cat >"${root}/.github/workflows/terraform-module-ci.yaml" <<'YML'
name: fixture module ci
jobs:
  ci:
    steps:
      - uses: dsb-norge/github-actions-terraform/terraform-init@v0
      - uses: dsb-norge/github-actions-terraform/terraform-validate@v0
      - uses: dsb-norge/github-actions-terraform/terraform-lint@v0
YML

  # In the set, zero self-refs: must be reported as 0 and left byte-identical.
  cat >"${root}/.github/workflows/terraform-module-release.yaml" <<'YML'
name: fixture module release
jobs:
  release:
    steps:
      - uses: actions/checkout@v6
YML

  # Excluded: the preview workflow's own comment template …
  cat >"${root}/.github/workflows/pr-preview.yml" <<'YML'
name: fixture preview workflow
run: |
  cat <<MD
  uses: dsb-norge/github-actions-terraform/.github/workflows/terraform-ci-cd-default.yml@${PREVIEW_REF}
  MD
YML
  # … and the test workflow, even when it holds a real-looking self-ref.
  cat >"${root}/.github/workflows/action-tests.yml" <<'YML'
name: fixture action tests
jobs:
  t:
    steps:
      - uses: dsb-norge/github-actions-terraform/verify-terraform-lock@v0
YML

  # Outside .github/workflows: examples that must keep saying @v0.
  echo 'uses: dsb-norge/github-actions-terraform/terraform-init@v0' >"${root}/README.md"
  echo 'uses: dsb-norge/github-actions-terraform/terraform-init@v0' >"${root}/docs/Foo.md"
  echo 'uses: dsb-norge/github-actions-terraform/terraform-init@v0' >"${root}/some-action/action.yml"
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

PRISTINE="${TMP}/pristine"; make_fixture "${PRISTINE}"
WORK="${TMP}/work";         make_fixture "${WORK}"

section "T-M6 --list-files: the set, sorted, and nothing modified"
before_sum="$(tree_sum "${WORK}")"
listed="$(REPO_ROOT="${WORK}" bash "${SCRIPT}" --list-files)"
assert_eq "file set" \
  $'.github/workflows/terraform-ci-cd-default.yml\n.github/workflows/terraform-module-ci.yaml\n.github/workflows/terraform-module-release.yaml' \
  "${listed}"
assert_eq "--list-files modifies nothing" "${before_sum}" "$(tree_sum "${WORK}")"

section "T-M1/M2/M3/M8 rewrite: every self-ref, any current ref; everything else untouched"
out="$(REPO_ROOT="${WORK}" bash "${SCRIPT}" "${NEW_REF}")"; rc=$?
assert_eq "exit 0" 0 "${rc}"
assert_identical "default workflow equals expected bytes" "${WORK}/.github/workflows/terraform-ci-cd-default.yml" "${WORK}/expected/terraform-ci-cd-default.yml"
assert_contains "per-file count (default)" "${out}" ".github/workflows/terraform-ci-cd-default.yml: 4 of 4 ref(s) rewritten"
assert_contains "per-file count (module-ci)" "${out}" ".github/workflows/terraform-module-ci.yaml: 3 of 3 ref(s) rewritten"

section "T-M4 exclusion list and files outside .github/workflows are untouched"
for rel in .github/workflows/pr-preview.yml .github/workflows/action-tests.yml README.md docs/Foo.md some-action/action.yml; do
  assert_identical "${rel} untouched" "${PRISTINE}/${rel}" "${WORK}/${rel}"
done

section "T-S1 a file in the set with zero refs"
assert_identical "module-release byte-identical" "${PRISTINE}/.github/workflows/terraform-module-release.yaml" "${WORK}/.github/workflows/terraform-module-release.yaml"
assert_contains "reported as 0 of 0" "${out}" ".github/workflows/terraform-module-release.yaml: 0 of 0 ref(s) rewritten"

section "T-S2 summary line"
assert_contains "totals" "${out}" "Rewrote 7 reference(s) in 3 file(s) to @${NEW_REF} (7 internal reference(s) in the set)."

section "T-M5 idempotent, and the revert path"
mid_sum="$(tree_sum "${WORK}")"
out2="$(REPO_ROOT="${WORK}" bash "${SCRIPT}" "${NEW_REF}")"
assert_contains "second run rewrites nothing" "${out2}" "Rewrote 0 reference(s) in 3 file(s) to @${NEW_REF} (7 internal reference(s) in the set)."
assert_eq "second run changes no bytes" "${mid_sum}" "$(tree_sum "${WORK}")"
REPO_ROOT="${WORK}" bash "${SCRIPT}" v0 >/dev/null
assert_identical "all-@v0 file restored by rewriting back to v0" "${PRISTINE}/.github/workflows/terraform-module-ci.yaml" "${WORK}/.github/workflows/terraform-module-ci.yaml"

section "T-M7 argument validation"
FRESH="${TMP}/fresh"; make_fixture "${FRESH}"
fresh_sum="$(tree_sum "${FRESH}")"
err="$(REPO_ROOT="${FRESH}" bash "${SCRIPT}" 2>&1 >/dev/null)"; rc=$?
assert_eq "missing ref → exit 2" 2 "${rc}"
assert_contains "missing ref → usage on stderr" "${err}" "usage"
err="$(REPO_ROOT="${FRESH}" bash "${SCRIPT}" 'pr|1' 2>&1 >/dev/null)"; rc=$?
assert_eq "ref with sed metacharacters → exit 2" 2 "${rc}"
assert_contains "ref with sed metacharacters → error names the character class" "${err}" "[A-Za-z0-9._/-]"
assert_eq "neither attempt modified anything" "${fresh_sum}" "$(tree_sum "${FRESH}")"

section "T-M9 the real workflow tree of this checkout"
REAL_COPY="${TMP}/real"; mkdir -p "${REAL_COPY}/.github"; cp -r "${REAL_REPO_ROOT}/.github/workflows" "${REAL_COPY}/.github/"
ref_pattern="$(grep -oP "^REF_PATTERN='\K[^']+" "${SCRIPT}")"
mapfile -t real_files < <(REPO_ROOT="${REAL_COPY}" bash "${SCRIPT}" --list-files)
real_before=0; orig_refs=""
for f in "${real_files[@]}"; do
  n="$(grep -cE "${ref_pattern}" "${REAL_COPY}/${f}" || true)"; real_before=$((real_before + n))
  orig_refs+="$(grep -oE "${ref_pattern}" "${REAL_COPY}/${f}" | sed 's/.*@//' || true)"$'\n'
done
REPO_ROOT="${REAL_COPY}" bash "${SCRIPT}" "${NEW_REF}" >/dev/null
real_at_new=0; real_stray=0
for f in "${real_files[@]}"; do
  n="$(grep -cE "uses:[[:space:]]+dsb-norge/github-actions-terraform(/[^@[:space:]]*)?@${NEW_REF//./\\.}([[:space:]]|\$)" "${REAL_COPY}/${f}" || true)"; real_at_new=$((real_at_new + n))
  s="$(grep -E "${ref_pattern}" "${REAL_COPY}/${f}" | grep -vcE "@${NEW_REF//./\\.}([[:space:]]|\$)" || true)"; real_stray=$((real_stray + s))
done
assert_eq "real tree has self-refs to rewrite (sanity)" "true" "$([[ ${real_before} -gt 0 ]] && echo true || echo false)"
assert_eq "every self-ref now names the new ref" "${real_before}" "${real_at_new}"
assert_eq "no self-ref left at another ref" 0 "${real_stray}"
# Files with zero refs contribute an empty line — drop those before deciding uniformity.
uniform="$(printf '%s' "${orig_refs}" | grep . | sort -u | grep -c . || true)"
if [[ "${uniform}" == "1" ]]; then
  orig="$(printf '%s' "${orig_refs}" | grep . | sort -u)"
  REPO_ROOT="${REAL_COPY}" bash "${SCRIPT}" "${orig}" >/dev/null
  if diff -r "${REAL_REPO_ROOT}/.github/workflows" "${REAL_COPY}/.github/workflows" >/dev/null; then
    pass "round trip back to @${orig} is byte-identical"
  else
    fail "round trip back to @${orig} is byte-identical" "$(diff -r "${REAL_REPO_ROOT}/.github/workflows" "${REAL_COPY}/.github/workflows" | head -20)"
  fi
else
  echo "  (skip) real tree carries ${uniform} distinct self-ref targets — round trip not applicable"
fi

section "F-guard pr-preview.yml keeps the contract with the script"
if [[ -f "${WORKFLOW}" ]]; then
  wf="$(cat "${WORKFLOW}")"
  assert_contains "guard scopes its paths with --list-files" "${wf}" "rewrite-internal-refs.sh --list-files"
  assert_contains "guard greps the script's REF_PATTERN verbatim" "${wf}" "${ref_pattern}"
  assert_contains "publish job runs this suite before publishing" "${wf}" "test-rewrite-internal-refs.sh"
  # P33: the sweep addressed git/tags/<name> (the tag-object endpoint) instead of
  # git/refs/tags/<name>, 404'd on every call, and swallowed it — so it deleted
  # nothing for as long as it existed. Pin both halves of the fix.
  assert_contains "cleanup deletes through git/<full ref>, not the tag-object endpoint" "${wf}" 'gh api -X DELETE "repos/${REPO}/git/${ref}"'
  if [[ "${wf}" == *'git/${ref#refs/}'* ]]; then
    fail "cleanup must not strip the refs/ prefix (P33)" "found: git/\${ref#refs/}"
  else
    pass "cleanup must not strip the refs/ prefix (P33)"
  fi
  assert_contains "cleanup verifies that no preview ref survived the sweep" "${wf}" "preview refs survived the sweep"

  excl="$(grep -oP "^EXCLUDED_WORKFLOWS=\(\K[^)]+" "${SCRIPT}")"
  assert_contains "pr-preview.yml is excluded from the rewrite" "${excl}" "pr-preview.yml"
  assert_contains "action-tests.yml is excluded from the rewrite" "${excl}" "action-tests.yml"
else
  fail "pr-preview.yml exists" "${WORKFLOW} not found"
fi

echo ""
echo "========================================"
echo -e "Tests run:    ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo "========================================"
[[ "${TESTS_FAILED}" -eq 0 ]]
_main_exit_code=$?
exit ${_main_exit_code}
