#!/bin/env bash

function getSeparator { printf '=%.0s' {1..100}; }
function printSection { echo -e "\n\n${1}\n$(getSeparator)\n"; }
function queryStatus {
  local test_run=$1
  local json_file=$2
  jq --arg test_run "$test_run" '. | select(.type == "test_run") | select(.test_run.run == $test_run) | select(.test_run.progress == "complete") | .test_run.status' ${json_file}
}