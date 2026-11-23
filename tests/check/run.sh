#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
CHECK="${ROOT}/tasks/check.py"
FIXTURES="${ROOT}/tests/check/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

. "${ROOT}/tests/lib/python.sh"
ensure_python "${ROOT}" "${WORK}"

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
  "${PY}" "${CHECK}" --standard "${WORK}/dir" >"${WORK}/out" 2>"${WORK}/err" || status=$?
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
expect_ok green-needs-result-status
expect_ok green-needs-declared
expect_ok green-build
expect_ok green-promote
expect_ok green-autofix
expect_ok green-node24-actions
expect_ok green-checkout-v4-only
expect_ok green-node-above-limit

expect_violation bad-name-expr-job ci.yml 'ci.yml#core'
expect_violation bad-name-expr-step ci.yml 'ci.yml#core'
expect_violation bad-step-no-name ci.yml 'ci.yml#core'
expect_violation bad-job-no-name ci.yml 'ci.yml#core'
expect_violation bad-matrix ci.yml 'ci.yml#core'
expect_violation bad-job-environment ci.yml 'ci.yml#core'
expect_violation bad-deploy-environment-always deploy.yml 'deploy.yml#deploy'
expect_violation bad-restricted-other-file ci.yml 'ci.yml'
expect_violation bad-restricted-no-production deploy.yml 'deploy.yml'
expect_violation bad-restricted-caller-other-file build.yml 'build.yml'
expect_violation bad-gate-missing pr.yml 'pr.yml'
expect_violation bad-gate-no-always pr.yml 'pr.yml'
expect_violation bad-gate-needs-incomplete pr.yml 'pr.yml'
expect_violation bad-gate-wrong-name pr.yml 'pr.yml'
expect_violation bad-gate-uses pr.yml 'pr.yml'
expect_violation bad-invalid-yaml ci.yml 'ci.yml'
expect_violation bad-needs-result-no-status ci.yml 'ci.yml#tag'
expect_violation bad-needs-not-declared ci.yml 'ci.yml#use.*needs.detect'
expect_violation bad-build-environment build.yml 'build.yml#image'
expect_violation bad-build-step-no-name build.yml 'build.yml#image'
expect_violation bad-promote-token-in-e2e promote.yml 'promote.yml#e2e: job must not use GH_PIPELINES_TOKEN or secrets.ci.common'
expect_violation bad-promote-ci-common-in-regression promote.yml 'promote.yml#regression: job must not use GH_PIPELINES_TOKEN or secrets.ci.common'
expect_violation bad-promote-checkout-no-persist promote.yml 'promote.yml#regression: checkout step must set `persist-credentials: false`'
expect_violation bad-autofix-token-in-fix autofix.yml 'autofix.yml#fix: job must not use GH_PIPELINES_TOKEN, SENTRY_AUTH_TOKEN or secrets.ci.common'
expect_violation bad-autofix-step-exports-key autofix.yml "autofix.yml#verify: step green must set export-key: 'false'"
expect_violation bad-autofix-checkout-persist autofix.yml 'autofix.yml#verify: checkout step must set `persist-credentials: false`'
expect_violation bad-autofix-fix-write-permission autofix.yml 'autofix.yml#fix: permissions must be contents: read only'
expect_violation bad-node20-actions ci.yml 'ci.yml: action actions/cache@v4 targets Node 20; use actions/cache@v5$'
expect_violation bad-node20-actions ci.yml 'ci.yml: action jdx/mise-action@v2 targets Node 20; use jdx/mise-action@v4$'
expect_violation bad-node20-actions ci.yml 'ci.yml: action actions/upload-artifact@v4 targets Node 20; use actions/upload-artifact@v6$'
expect_violation bad-node20-actions ci.yml 'ci.yml: action actions/download-artifact@v4 targets Node 20; use actions/download-artifact@v7$'
expect_violation bad-node20-actions ci.yml 'ci.yml: action actions/setup-node@v4 targets Node 20; use actions/setup-node@v6$'

echo "${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ]
