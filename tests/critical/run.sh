#!/bin/sh
# run.sh — fixture tests for actions/critical/critical.py.
#
# Usage: sh tests/critical/run.sh
#
# Runs the script with a fake `gh` on PATH that records its arguments and the
# issue bodies, and answers from canned JSON fixtures. Exits 1 on any failure.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="${ROOT}/actions/critical/critical.py"
FIX="${ROOT}/tests/critical/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0
OUT="${WORK}/output"
LOG="${WORK}/log"
CALLS="${WORK}/calls"
BODIES="${WORK}/bodies"
STATUS=0
TAG=core.2026-11-21.001
RUN_URL=https://github.com/o/r/actions/runs/99

mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gh" <<'GH'
#!/bin/sh
printf '%s\n' "$*" >> "${GH_CALLS}"
prev=""
for arg in "$@"; do
  case "${prev}" in
    --body) printf '%s\n' "${arg}" >> "${GH_BODIES}" ;;
    --body-file) if [ "${arg}" = "-" ]; then cat >> "${GH_BODIES}"; else cat "${arg}" >> "${GH_BODIES}"; fi ;;
  esac
  prev="${arg}"
done
case "${1:-} ${2:-}" in
  "issue list") cat "${GH_ISSUES}" ;;
  "issue create") echo "https://github.com/o/r/issues/42" ;;
  api\ repos/o/r/deployments*) cat "${GH_DEPLOYS}" ;;
  api\ repos/o/r/compare/*) cat "${GH_COMPARE}" ;;
  api\ repos/o/r/commits/*/pulls*)
    sha="${2#repos/o/r/commits/}"
    sha="${sha%%/*}"
    cat "${GH_PULLS_DIR}/${sha}.json" ;;
esac
exit 0
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

setup() {
  : > "${OUT}"
  : > "${LOG}"
  : > "${CALLS}"
  : > "${BODIES}"
  ISSUES="${FIX}/issues_none.json"
  DEPLOYS="${FIX}/deployments_core.json"
  PULLS="${WORK}/pulls"
  rm -rf "${PULLS}"
  mkdir -p "${PULLS}"
  cp "${FIX}/pulls_plain.json" "${PULLS}/aaa111.json"
  cp "${FIX}/pulls_plain.json" "${PULLS}/bbb222.json"
  FAILURES="${FIX}/failures.md"
}

run() {
  STATUS=0
  PATH="${WORK}/bin:${PATH}" GH_CALLS="${CALLS}" GH_BODIES="${BODIES}" GH_ISSUES="${ISSUES}" \
    GH_DEPLOYS="${DEPLOYS}" GH_COMPARE="${FIX}/compare.json" GH_PULLS_DIR="${PULLS}" \
    GITHUB_REPOSITORY=o/r GH_TOKEN=tok GITHUB_OUTPUT="${OUT}" \
    python3 "${SCRIPT}" "$@" > "${LOG}" 2>&1 || STATUS=$?
}

run_open() {
  run open --module core --hook "${1:-e2e}" --tag "${TAG}" --failures "${FAILURES}" --run-url "${RUN_URL}"
}

expect_ok() {
  if [ "${STATUS}" -ne 0 ]; then
    fail "${1}: exit ${STATUS}: $(cat "${LOG}")"
    return 1
  fi
  return 0
}

calls_have() {
  grep -qF -- "${2}" "${CALLS}" && pass "${1}" || fail "${1}: missing '${2}' in: $(cat "${CALLS}")"
}

calls_lack() {
  if grep -qF -- "${2}" "${CALLS}"; then
    fail "${1}: unexpected '${2}' in: $(cat "${CALLS}")"
  else
    pass "${1}"
  fi
}

body_have() {
  grep -qF -- "${2}" "${BODIES}" && pass "${1}" || fail "${1}: body lacks '${2}'"
}

body_lack() {
  if grep -qF -- "${2}" "${BODIES}"; then
    fail "${1}: body has '${2}'"
  else
    pass "${1}"
  fi
}

setup
run_open
if expect_ok "new issue"; then
  calls_have "new issue: create" "issue create"
  calls_have "new issue: title" "bug: core e2e failed on ${TAG}"
  calls_have "new issue: urgency label" "urgency:critical"
  calls_have "new issue: module label" "module:core"
  calls_have "new issue: label create force" "label create"
  calls_have "new issue: --force" "--force"
  calls_lack "new issue: no autofix:blocked" "autofix:blocked"
  body_have "new issue: run url" "${RUN_URL}"
  body_have "new issue: hook" "e2e"
  body_have "new issue: tag" "${TAG}"
  body_have "new issue: failures content" "enrollment flow broke"
  grep -qx 'issue=42' "${OUT}" && pass "new issue: output issue=42" || fail "new issue: output: $(cat "${OUT}")"
fi

setup
run_open regression
if expect_ok "regression hook"; then
  calls_have "regression hook: title" "bug: core regression failed on ${TAG}"
fi

setup
ISSUES="${FIX}/issues_open.json"
run_open
if expect_ok "dedup"; then
  calls_have "dedup: comment on existing" "issue comment 7"
  calls_lack "dedup: no new issue" "issue create"
  body_have "dedup: comment body has tag" "${TAG}"
  body_have "dedup: comment body has failures" "enrollment flow broke"
  grep -qx 'issue=7' "${OUT}" && pass "dedup: output issue=7" || fail "dedup: output: $(cat "${OUT}")"
fi

setup
ISSUES="${FIX}/issues_open.json"
run_open regression
if expect_ok "dedup per hook"; then
  calls_have "dedup per hook: comment on regression issue" "issue comment 8"
  calls_lack "dedup per hook: no new issue" "issue create"
fi

setup
cp "${FIX}/pulls_autofix.json" "${PULLS}/bbb222.json"
run_open
if expect_ok "autofix pr in range"; then
  calls_have "autofix pr in range: blocked label" "autofix:blocked"
  calls_have "autofix pr in range: urgency label" "urgency:critical"
  calls_have "autofix pr in range: compares from last promoted" "compare/core.2026-11-20.001...${TAG}"
fi

setup
run_open
if expect_ok "no autofix pr in range"; then
  calls_lack "no autofix pr in range: not blocked" "autofix:blocked"
fi

setup
DEPLOYS="${FIX}/deployments_none.json"
cp "${FIX}/pulls_autofix.json" "${PULLS}/bbb222.json"
run_open
if expect_ok "no previous promoted"; then
  calls_lack "no previous promoted: not blocked" "autofix:blocked"
  calls_have "no previous promoted: still created" "issue create"
fi

setup
{
  printf 'mail dev@example.com ip 10.20.30.40 and 2001:db8::1 token abcdefghijklmnopqrstuvwxyz0123456789ABCD end\n'
} > "${WORK}/secret.md"
FAILURES="${WORK}/secret.md"
run_open
if expect_ok "mask"; then
  body_have "mask: email" "<email>"
  body_have "mask: ip" "<ip>"
  body_have "mask: token" "<token>"
  body_lack "mask: raw email" "dev@example.com"
  body_lack "mask: raw ipv4" "10.20.30.40"
  body_lack "mask: raw ipv6" "2001:db8::1"
  body_lack "mask: raw token" "abcdefghijklmnopqrstuvwxyz0123456789ABCD"
fi

setup
python3 -c "print('x ' * 15000, end='')" > "${WORK}/big.md"
FAILURES="${WORK}/big.md"
run_open
if expect_ok "truncate"; then
  total="$(wc -c < "${BODIES}" | tr -d ' ')"
  if [ "${total}" -lt 21500 ] && [ "${total}" -gt 15000 ]; then
    pass "truncate: failures capped near 20000 (body ${total} bytes)"
  else
    fail "truncate: body is ${total} bytes"
  fi
fi

setup
FAILURES="${WORK}/missing.md"
run_open
if expect_ok "missing failures"; then
  body_have "missing failures: placeholder" "no failures.md was written; see the run"
  calls_have "missing failures: still created" "issue create"
fi

run_open_output() {
  run open --module core --hook e2e --tag "${TAG}" --failures "${FAILURES}" --output "${OUTPUT_FILE}" --run-url "${RUN_URL}"
}

setup
FAILURES="${WORK}/missing.md"
OUTPUT_FILE="${WORK}/output.log"
python3 -c "print('\n'.join('line-%04d' % i for i in range(1, 1001)))" > "${OUTPUT_FILE}"
run_open_output
if expect_ok "output tail"; then
  body_have "output tail: section" "## output"
  body_have "output tail: last line" "line-1000"
  body_have "output tail: first kept line" "line-0701"
  body_lack "output tail: drops older line" "line-0700"
  body_lack "output tail: drops first line" "line-0001"
  body_lack "output tail: no placeholder" "no failures.md was written; see the run"
  calls_have "output tail: still created" "issue create"
fi

setup
FAILURES="${WORK}/missing.md"
OUTPUT_FILE="${WORK}/output.log"
printf 'mail dev@example.com ip 10.20.30.40 token abcdefghijklmnopqrstuvwxyz0123456789ABCD end\n' > "${OUTPUT_FILE}"
run_open_output
if expect_ok "output mask"; then
  body_have "output mask: section" "## output"
  body_have "output mask: email" "<email>"
  body_have "output mask: ip" "<ip>"
  body_have "output mask: token" "<token>"
  body_lack "output mask: raw email" "dev@example.com"
  body_lack "output mask: raw ip" "10.20.30.40"
  body_lack "output mask: raw token" "abcdefghijklmnopqrstuvwxyz0123456789ABCD"
fi

setup
FAILURES="${WORK}/missing.md"
OUTPUT_FILE="${WORK}/big-output.log"
python3 -c "print('x ' * 15000, end='')" > "${OUTPUT_FILE}"
run_open_output
if expect_ok "output truncate"; then
  total="$(wc -c < "${BODIES}" | tr -d ' ')"
  body_have "output truncate: section" "## output"
  if [ "${total}" -lt 21500 ] && [ "${total}" -gt 15000 ]; then
    pass "output truncate: capped near 20000 (body ${total} bytes)"
  else
    fail "output truncate: body is ${total} bytes"
  fi
fi

setup
OUTPUT_FILE="${WORK}/output.log"
printf 'output-only-marker\n' > "${OUTPUT_FILE}"
run_open_output
if expect_ok "failures priority"; then
  body_have "failures priority: failures content" "enrollment flow broke"
  body_lack "failures priority: no output section" "## output"
  body_lack "failures priority: no output content" "output-only-marker"
fi

setup
FAILURES="${WORK}/missing.md"
OUTPUT_FILE="${WORK}/absent-output.log"
run_open_output
if expect_ok "neither failures nor output"; then
  body_have "neither: placeholder" "no failures.md was written; see the run"
  body_lack "neither: no output section" "## output"
fi

setup
FAILURES="${WORK}/missing.md"
OUTPUT_FILE="${WORK}/empty-output.log"
: > "${OUTPUT_FILE}"
run_open_output
if expect_ok "empty output"; then
  body_have "empty output: placeholder" "no failures.md was written; see the run"
fi

setup
run incident --module core --tag "${TAG}" --run-url "${RUN_URL}"
if expect_ok "incident"; then
  calls_have "incident: title" "bug: core production deploy failed on ${TAG}"
  calls_have "incident: urgency label" "urgency:critical"
  calls_have "incident: module label" "module:core"
  calls_have "incident: always blocked" "autofix:blocked"
  body_have "incident: run url" "${RUN_URL}"
  grep -qx 'issue=42' "${OUT}" && pass "incident: output issue=42" || fail "incident: output: $(cat "${OUT}")"
fi

echo "${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ]
