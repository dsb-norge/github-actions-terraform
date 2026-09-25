#!/bin/env bash
#
# Stand-in for the terraform binary in run_all_tests.sh. The suite copies it
# to <tmp>/bin/terraform and puts that directory first on PATH.
#
# Every invocation appends one line to FAKE_TF_LOG:
#   cwd=<working directory> TF_IN_AUTOMATION=<value> args=<arg> <arg> ...
#
# Behaviour, driven by environment variables the suite sets per test:
#   terraform version -json  prints FAKE_TF_VERSION_JSON (a file), or a
#                            1.16.2 document when unset
#   terraform version        prints 'Terraform v<version>'
#   terraform test ...       prints FAKE_TF_OUTPUT (a file) to stdout, copies
#                            FAKE_TF_JUNIT (a file, optional) to the path of
#                            -junit-xml=, prints FAKE_TF_STDERR (text,
#                            optional) to stderr, exits FAKE_TF_EXIT (default 0)
#

echo "cwd=${PWD} TF_IN_AUTOMATION=${TF_IN_AUTOMATION:-} args=${*}" >>"${FAKE_TF_LOG:-/dev/null}"

_version_json() {
  if [ -n "${FAKE_TF_VERSION_JSON:-}" ]; then
    cat "${FAKE_TF_VERSION_JSON}"
  else
    printf '{\n  "terraform_version": "1.16.2",\n  "platform": "linux_amd64",\n  "provider_selections": {},\n  "terraform_outdated": false\n}\n'
  fi
}

case "${1:-}" in
  version)
    if [ "${2:-}" == "-json" ]; then
      _version_json
    else
      echo "Terraform v$(_version_json | jq -r '.terraform_version')"
      echo "on linux_amd64"
    fi
    exit 0
    ;;
  test)
    for arg in "$@"; do
      case "${arg}" in
        -junit-xml=*)
          if [ -n "${FAKE_TF_JUNIT:-}" ]; then
            cp "${FAKE_TF_JUNIT}" "${arg#-junit-xml=}"
          fi
          ;;
      esac
    done
    if [ -n "${FAKE_TF_OUTPUT:-}" ]; then
      cat "${FAKE_TF_OUTPUT}"
    fi
    if [ -n "${FAKE_TF_STDERR:-}" ]; then
      echo "${FAKE_TF_STDERR}" >&2
    fi
    exit "${FAKE_TF_EXIT:-0}"
    ;;
  *)
    echo "fake terraform: unsupported command '${*}'" >&2
    exit 64
    ;;
esac
