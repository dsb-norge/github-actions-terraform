#!/bin/env bash
#
# See test_action_source.sh
#

print_divider() {
  local message="${1-}"
  if [[ -n "${message}" ]]; then
    echo ""
    echo ""
    echo "${message}"
  fi
  echo "$(printf '=%.0s' {1..120})"
}

cleanup() {
  local script_dir clean_files
  script_dir="${1}"
  print_divider "cleanup of ${this_script_dir}"
  clean_files=$(find ${this_script_dir}/_* 2>/dev/null || :)
  for file in ${clean_files}; do
    echo $file
    rm $file
  done
  echo "done."
  exit 1
}

trap_exit_positive_test() {
  [ ! "$1" == "0" ] &&
    echo -e "\e[31mX\e[0m test fail for '${test_file}'" >$(tty) ||
    echo -e "\e[32m✓\e[0m test pass for '${test_file}'" >$(tty)
}

trap_exit_negative_test() {
  [ "$1" == "0" ] &&
    echo -e "\e[31mX\e[0m test fail for '${test_file}'" >$(tty) ||
    echo -e "\e[32m✓\e[0m test pass for '${test_file}'" >$(tty)
}

should_pass_test() {
  local script_dir test_file action_def_file test_data_file output_file
  test_file="${1}"
  action_def_file="${2}"
  script_dir="${3}"
  test_data_file="${script_dir}/test_data/${test_file}"
  output_file="${script_dir}/__${test_file}.stdout"

  (
    trap 'trap_exit_positive_test $?' EXIT

    # output only to to stdout
    # test_action "${action_def_file}" "${test_data_file}"

    # output only to file
    test_action "${action_def_file}" "${test_data_file}" > "${output_file}"

    # output to both
    # test_action "${action_def_file}" "${test_data_file}" | tee "${output_file}"
  )
  # echo "after should pass"
}

should_fail_test() {
  local script_dir test_file action_def_file test_data_file output_file
  test_file="${1}"
  action_def_file="${2}"
  script_dir="${3}"
  test_data_file="${script_dir}/test_data/${test_file}"
  output_file="${script_dir}/__${test_file}.stdout"

  (
    trap 'trap_exit_negative_test $?' EXIT

    # output only to to stdout
    # test_action "${action_def_file}" "${test_data_file}"

    # output only to file
    test_action "${action_def_file}" "${test_data_file}" > "${output_file}"

    # output to both
    # test_action "${action_def_file}" "${test_data_file}" | tee "${output_file}"
  )
  # echo "after should fail"
}

test_action() {
  local action_file input_file_prefix this_script_dir

  action_file="${1}"
  input_file_prefix="${2}"
  this_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

  # read github actions def with yq
  readarray action_steps < <(yq e -o=j -I=0 --expression='.runs.steps[]' "${action_file}")
  action_inputs=$(yq e -o=csv -I=0 --expression='.inputs | keys' "${action_file}")

  # count
  i=1

  # loop all steps in action
  for step in "${action_steps[@]}"; do
    step_id=$(echo "$step" | yq e '.id' -)
    step_src=$(echo "$step" | yq e '.run' -)

    print_divider "step id: $i $step_id"

    # the source code for the step will be written to this file
    step_src_file="${this_script_dir}/_${i}_${step_id}.sh"

    # add some init code
    cat <<EOF >"${step_src_file}"
#!/bin/env bash
set -euo pipefail
__dirname="${this_script_dir}"
GITHUB_WORKSPACE="$(mktemp -d)"
GITHUB_OUTPUT="${this_script_dir}/_${step_id}.sh.out"
echo "" > \$GITHUB_OUTPUT

# one of the steps test for existing directory
mkdir -p "\${GITHUB_WORKSPACE}/envs/my-tf-env"

EOF

    # write source from action step
    echo "${step_src}" >>"${step_src_file}"

    # insert input json
    for action_input in ${action_inputs//,/ }; do
      # echo "action_input: ${action_input}"
      input_file="${input_file_prefix}_${action_input}.json"
      # echo "input_file: ${input_file}"
      json_input=$(cat $input_file)
      json_input_escaped=$(printf '%s\n' "${json_input}" | sed 's,[\/&],\\&,g;s/$/\\/')
      json_input_escaped=${json_input_escaped%?}
      sed -i "s/\${{ inputs\.${action_input} }}/$json_input_escaped/g" "${step_src_file}"
    done

    # insert input json from steps
    for _step in "${action_steps[@]}"; do
      _step_id=$(echo "$_step" | yq e '.id' -)

      # if output file exists
      step_output_file="${this_script_dir}/_${_step_id}.sh.out"
      if [ -f "${step_output_file}" ]; then
        # read output and escape
        json=$(cat "${step_output_file}")
        json_escaped=$(printf '%s\n' "${json}" | sed 's,[\/&],\\&,g;s/$/\\/')
        json_escaped=${json_escaped%?}

        # replace github actions variable with json blob
        sed -i "s/\${{ steps\.${_step_id}\.outputs\.json }}/$json_escaped/g" "${step_src_file}"

      fi
    done

    # fix actions output in step source
    sed -i "s/echo 'json<</# echo 'json<</g" "${step_src_file}"
    sed -i "s/echo '\"\${{ github\.run_id/# echo '\"\${{ github\.run_id/g" "${step_src_file}"

    # replace github action vars
    sed -i "s/\${{ github\.action_path }}/\${__dirname}/g" "${step_src_file}"
    sed -i "s/\${{ github\.ref_name }}/refs\/tags\/my-tag/g" "${step_src_file}"
    sed -i "s/REPO_DEFAULT_BRANCH=/REPO_DEFAULT_BRANCH='random' #/g" "${step_src_file}"

    # debug
    # [ $i == 1 ] && break

    # execute
    # source "${step_src_file}" # DEBUG
    source "${step_src_file}" &&
      echo "SUCCESS: ${step_src_file}" ||
      echo "FAILURE: ${step_src_file}"

    # debug
    # [ $i == 2 ] && break

    ((i++))
  done
}
