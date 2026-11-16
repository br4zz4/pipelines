#!/bin/sh
# run.sh — tests for actions/gate/gate.sh.
#
# Usage: sh tests/gate/run.sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
GATE="${ROOT}/actions/gate/gate.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0

run_gate() {
  scenario="${1}"
  expected="${2}"
  shift 2
  status=0
  if [ "$#" -gt 0 ]; then
    RESULTS="${1}" sh "${GATE}" >"${WORK}/out" 2>"${WORK}/err" || status=$?
  else
    env -u RESULTS sh "${GATE}" >"${WORK}/out" 2>"${WORK}/err" || status=$?
  fi
  if [ "${status}" -eq "${expected}" ]; then
    echo "PASS ${scenario}"
    PASSED=$(( PASSED + 1 ))
  else
    echo "FAIL ${scenario}: expected exit ${expected}, got ${status}"
    FAILED=$(( FAILED + 1 ))
  fi
}

expect_line() {
  scenario="${1}"
  line="${2}"
  if grep -qx "${line}" "${WORK}/out" 2>/dev/null; then
    echo "PASS ${scenario}"
    PASSED=$(( PASSED + 1 ))
  else
    echo "FAIL ${scenario}: missing line '${line}'"
    FAILED=$(( FAILED + 1 ))
  fi
}

run_gate "all success passes" 0 '{"conform":{"result":"success","outputs":{}},"detect":{"result":"success","outputs":{"changes":"{}"}},"core":{"result":"success","outputs":{}}}'
expect_line "prints one line per job" "core: success"
expect_line "prints conform line" "conform: success"

run_gate "skipped counts as success" 0 '{"conform":{"result":"success","outputs":{}},"core":{"result":"skipped","outputs":{}}}'
expect_line "prints skipped line" "core: skipped"

run_gate "failure fails" 1 '{"conform":{"result":"success","outputs":{}},"core":{"result":"failure","outputs":{}}}'
expect_line "prints failure line" "core: failure"

run_gate "cancelled fails" 1 '{"conform":{"result":"cancelled","outputs":{}},"core":{"result":"success","outputs":{}}}'
expect_line "prints cancelled line" "conform: cancelled"

run_gate "empty object passes" 0 '{}'

run_gate "missing RESULTS fails" 1

echo
echo "passed=${PASSED} failed=${FAILED}"
[ "${FAILED}" -eq 0 ] || exit 1
