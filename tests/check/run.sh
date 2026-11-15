#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
CHECK="${ROOT}/tasks/check.py"
FIXTURES="${ROOT}/tests/check/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0

pass() {
  echo "PASS ${1}"
  PASSED=$(( PASSED + 1 ))
}

fail() {
  echo "FAIL ${1}"
  FAILED=$(( FAILED + 1 ))
}

run_case() {
  name="${1}"
  rm -rf "${WORK}/dir"
  mkdir -p "${WORK}/dir"
  cp "${FIXTURES}/${name}"/*.yml "${WORK}/dir/"
  status=0
  python3 "${CHECK}" --standard "${WORK}/dir" >"${WORK}/out" 2>"${WORK}/err" || status=$?
}

expect_ok() {
  name="${1}"
  run_case "${name}"
  if [ "${status}" -eq 0 ] && grep -q '^ok:' "${WORK}/out" && ! grep -q '::error::' "${WORK}/out"; then
    pass "${name}"
  else
    fail "${name}: expected exit 0 with ok line, got ${status}"
    cat "${WORK}/out" "${WORK}/err"
  fi
}

expect_violation() {
  name="${1}"
  file="${2}"
  pattern="${3}"
  run_case "${name}"
  if [ "${status}" -eq 1 ] \
    && grep -q "^::error::${pattern}" "${WORK}/out" \
    && ! grep -q 'Traceback' "${WORK}/out" "${WORK}/err"; then
    pass "${name}"
  else
    fail "${name}: expected exit 1 with ::error::${pattern}, got ${status}"
    cat "${WORK}/out" "${WORK}/err"
  fi
  if grep '^::error::' "${WORK}/out" | grep -vq "^::error::${file}"; then
    fail "${name}: every message must cite ${file}"
  fi
}

expect_ok green-pr
expect_ok green-deploy-reusable
expect_ok green-consumer-deploy
expect_ok green-reusable-pr-no-gate
expect_ok green-main-no-gate
expect_ok green-with-environment

expect_violation bad-name-expr-job ci.yml 'ci.yml#core'
expect_violation bad-name-expr-step ci.yml 'ci.yml#core'
expect_violation bad-step-no-name ci.yml 'ci.yml#core'
expect_violation bad-job-no-name ci.yml 'ci.yml#core'
expect_violation bad-matrix ci.yml 'ci.yml#core'
expect_violation bad-job-environment ci.yml 'ci.yml#core'
expect_violation bad-restricted-other-file ci.yml 'ci.yml'
expect_violation bad-restricted-no-production deploy.yml 'deploy.yml'
expect_violation bad-gate-missing pr.yml 'pr.yml'
expect_violation bad-gate-no-always pr.yml 'pr.yml'
expect_violation bad-gate-needs-incomplete pr.yml 'pr.yml'
expect_violation bad-gate-wrong-name pr.yml 'pr.yml'
expect_violation bad-gate-uses pr.yml 'pr.yml'
expect_violation bad-invalid-yaml ci.yml 'ci.yml'

echo "${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ]
