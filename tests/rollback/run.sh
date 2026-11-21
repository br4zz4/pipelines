#!/bin/sh
# run.sh — fixture tests for actions/rollback/rollback.sh.
#
# Usage: sh tests/rollback/run.sh
#
# Runs the script with a fake `gh` on PATH that records its arguments and
# answers `gh run list` with a canned JSON. Exits 1 when any assertion fails.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="${ROOT}/actions/rollback/rollback.sh"
ACTION="${ROOT}/actions/rollback/action.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0
OUT="${WORK}/output"
LOG="${WORK}/log"
CALLS="${WORK}/calls"
RUNS="${WORK}/runs.json"
STATUS=0
SUMMARY="${WORK}/summary"

mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gh" <<'GH'
#!/bin/sh
printf '%s\n' "$*" >> "${GH_CALLS}"
case "${1:-} ${2:-}" in
  "run list") cat "${GH_RUNS}" ;;
  "workflow run") exit "${GH_WORKFLOW_EXIT:-0}" ;;
esac
GH
chmod 755 "${WORK}/bin/gh"

pass() {
  echo "PASS ${1}"
  PASSED=$(( PASSED + 1 ))
}

fail() {
  echo "FAIL ${1}"
  FAILED=$(( FAILED + 1 ))
}

run() {
  : > "${OUT}"
  : > "${LOG}"
  : > "${CALLS}"
  : > "${SUMMARY}"
  STATUS=0
  PATH="${WORK}/bin:${PATH}" GH_CALLS="${CALLS}" GH_RUNS="${RUNS}" GH_TOKEN=tok \
    GITHUB_OUTPUT="${OUT}" GITHUB_STEP_SUMMARY="${SUMMARY}" sh "${SCRIPT}" > "${LOG}" 2>&1 || STATUS=$?
  ENVIRONMENT=staging
  PREVIOUS=core.2026-11-20.002
  unset GH_WORKFLOW_EXIT
}

field() {
  grep "^${1}=" "${OUT}" | head -n 1 | cut -d= -f2-
}

expect_outputs() {
  scenario="${1}"
  if [ "${STATUS}" -ne 0 ]; then
    fail "${scenario}: exit ${STATUS}: $(cat "${LOG}")"
    return
  fi
  got="$(field status)|$(field target)|$(field detail)"
  if [ "${got}" = "${2}|${3}|${4}" ]; then
    pass "${scenario}"
  else
    fail "${scenario}: expected '${2}|${3}|${4}', got '${got}'"
  fi
}

expect_no_dispatch() {
  if grep -q '^workflow run' "${CALLS}"; then
    fail "${1}: dispatched: $(cat "${CALLS}")"
  else
    pass "${1}"
  fi
}

runs_with() {
  printf '[{"status":"%s","displayTitle":"%s","databaseId":%s}]\n' "${1}" "${2}" "${3:-1}" > "${RUNS}"
}

ENVIRONMENT=staging
MODULE=core
TAG_INPUT=core.2026-11-21.003
export ENVIRONMENT MODULE TAG_INPUT PREVIOUS
PREVIOUS=core.2026-11-20.002
export PREVIOUS
echo '[]' > "${RUNS}"

echo "# a: nothing to roll back to"
PREVIOUS="" run
expect_outputs "empty PREVIOUS" none "" "no earlier release to roll back to"
expect_no_dispatch "empty PREVIOUS does not dispatch"
PREVIOUS="${TAG_INPUT}" run
expect_outputs "PREVIOUS equal to TAG" none "" "no earlier release to roll back to"
expect_no_dispatch "PREVIOUS equal to TAG does not dispatch"

echo "# b: a newer release waiting for its deploy skips the rollback"
for waiting in queued pending waiting requested in_progress; do
  runs_with "${waiting}" "staging · core.2026-11-21.004"
  run
  expect_outputs "${waiting} run skips" skipped "" "rollback skipped: core.2026-11-21.004 is queued"
  expect_no_dispatch "${waiting} run does not dispatch"
done

echo "# c: runs that do not block"
runs_with queued "staging · gateway.2026-11-21.004"
run
expect_outputs "queued run of another module" dispatched "${PREVIOUS}" "rolling back to ${PREVIOUS}"
runs_with queued "production · core.2026-11-21.004"
run
expect_outputs "queued run of another environment" dispatched "${PREVIOUS}" "rolling back to ${PREVIOUS}"
runs_with in_progress "staging · core.2026-11-21.003"
run
expect_outputs "in_progress run of the failed tag itself" dispatched "${PREVIOUS}" "rolling back to ${PREVIOUS}"
runs_with queued "staging · core.2026-11-21.003"
run
expect_outputs "queued run of the failed tag itself" dispatched "${PREVIOUS}" "rolling back to ${PREVIOUS}"
RUN_ID=777
export RUN_ID
runs_with in_progress "staging · core.2026-11-21.004" 777
run
expect_outputs "own RUN_ID is excluded" dispatched "${PREVIOUS}" "rolling back to ${PREVIOUS}"
runs_with in_progress "staging · core.2026-11-21.004" 778
run
expect_outputs "other RUN_ID still blocks" skipped "" "rollback skipped: core.2026-11-21.004 is queued"
unset RUN_ID
runs_with completed "staging · core.2026-11-21.004"
run
expect_outputs "completed run" dispatched "${PREVIOUS}" "rolling back to ${PREVIOUS}"

echo "# d: happy path"
echo '[]' > "${RUNS}"
run
expect_outputs "dispatched" dispatched "${PREVIOUS}" "rolling back to ${PREVIOUS}"
expected="workflow run deploy.yml --ref ${TAG_INPUT} -f environment=staging -f rollback_to=${PREVIOUS}"
if grep -qxF -- "${expected}" "${CALLS}"; then pass "dispatch arguments"; else fail "dispatch arguments: $(cat "${CALLS}")"; fi
ENVIRONMENT=production run
if grep -qxF -- "workflow run deploy.yml --ref ${TAG_INPUT} -f environment=production -f rollback_to=${PREVIOUS}" "${CALLS}"; then pass "dispatch passes the environment"; else fail "dispatch passes the environment: $(cat "${CALLS}")"; fi

echo "# e: dispatch error fails the script"
export GH_WORKFLOW_EXIT=1
run
if [ "${STATUS}" -ne 0 ]; then pass "gh workflow run failure fails"; else fail "gh workflow run failure fails: exit 0"; fi
if [ "$(field status)" = "dispatched" ]; then fail "failed dispatch is not reported as dispatched"; else pass "failed dispatch is not reported as dispatched"; fi

echo "# g: step summary"
expect_summary() {
  if [ "$(cat "${SUMMARY}")" = "↩️ rollback: ${2}" ]; then pass "${1}"; else fail "${1}: '$(cat "${SUMMARY}")'"; fi
}
PREVIOUS="" run
expect_summary "summary for none" "no earlier release to roll back to"
runs_with queued "staging · core.2026-11-21.004"
run
expect_summary "summary for skipped" "rollback skipped: core.2026-11-21.004 is queued"
echo '[]' > "${RUNS}"
run
expect_summary "summary for dispatched" "rolling back to ${PREVIOUS}"
: > "${OUT}"
STATUS=0
env -u GITHUB_STEP_SUMMARY PATH="${WORK}/bin:${PATH}" GH_CALLS="${CALLS}" GH_RUNS="${RUNS}" GH_TOKEN=tok \
  GITHUB_OUTPUT="${OUT}" sh "${SCRIPT}" > "${LOG}" 2>&1 || STATUS=$?
expect_outputs "no GITHUB_STEP_SUMMARY does not fail" dispatched "${PREVIOUS}" "rolling back to ${PREVIOUS}"

echo "# f: action contract"
DECLARED="$(python3 -I -c 'import sys, yaml
a = yaml.safe_load(open(sys.argv[1]))
for k in ("environment", "module", "tag", "previous", "token"):
    print("input_" + k + "=" + ("MISSING" if k not in a["inputs"] else "ok"))
print("run_id=" + ("ok" if "${{ github.run_id }}" in a["runs"]["steps"][0]["env"].get("RUN_ID", "") else "MISSING"))
for k in ("status", "target", "detail"):
    o = a["outputs"].get(k)
    print("output_" + k + "=" + ("MISSING" if o is None else o["value"]))' "${ACTION}" 2>&1 || true)"
for line in input_environment=ok input_module=ok input_tag=ok input_previous=ok input_token=ok run_id=ok \
  'output_status=${{ steps.rollback.outputs.status }}' \
  'output_target=${{ steps.rollback.outputs.target }}' \
  'output_detail=${{ steps.rollback.outputs.detail }}'; do
  if printf '%s\n' "${DECLARED}" | grep -qxF -- "${line}"; then pass "action declares ${line}"; else fail "action declares ${line}: ${DECLARED}"; fi
done

echo
echo "passed=${PASSED} failed=${FAILED}"
[ "${FAILED}" -eq 0 ] || exit 1
