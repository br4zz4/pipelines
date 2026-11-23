#!/bin/sh
set -u

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="${ROOT}/actions/promote/promote.py"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0
OUT="${WORK}/output"
LOG="${WORK}/log"
CALLS="${WORK}/calls"
SUMMARY="${WORK}/summary"
STATUS=0
TAG=core.2026-11-21.010
MODULES='{"core":{"code":"modules/core/code","services":"postgres"}}'

mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gh" <<'GH'
#!/bin/sh
printf '%s\n' "$*" >> "${GH_CALLS}"
case "$*" in *"--input -"*) cat >> "${GH_CALLS}.stdin" ;; esac
case "$*" in
  *"POST"*"repos/o/r/deployments/"*"/statuses"*) echo '{"id":501}' ;;
  *"POST"*"repos/o/r/deployments"*) echo '{"id":500}' ;;
  *"api repos/o/r/deployments/"*"/statuses"*) echo '[{"state":"success"}]' ;;
  *"environment=staging"*) cat "${GH_STAGING}" ;;
  *"environment=production"*) cat "${GH_PRODUCTION}" ;;
  *"environment=promoted"*) cat "${GH_PROMOTED}" ;;
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

dep() {
  printf '{"id":%s,"payload":{"module":"core","tag":"%s"%s}}' "${1}" "${2}" "${3:-}"
}

setup() {
  : > "${OUT}"
  : > "${LOG}"
  : > "${CALLS}"
  : > "${CALLS}.stdin"
  : > "${SUMMARY}"
  STAGING="${WORK}/staging.json"
  PRODUCTION="${WORK}/production.json"
  PROMOTED="${WORK}/promoted.json"
  echo "[$(dep 20 "${TAG}" ',"release_url":"https://r.example.com/10"')]" > "${STAGING}"
  echo "[$(dep 10 core.2026-11-20.001)]" > "${PRODUCTION}"
  echo '[]' > "${PROMOTED}"
}

run() {
  STATUS=0
  PATH="${WORK}/bin:${PATH}" GH_CALLS="${CALLS}" GH_STAGING="${STAGING}" \
    GH_PRODUCTION="${PRODUCTION}" GH_PROMOTED="${PROMOTED}" \
    GITHUB_REPOSITORY=o/r GH_TOKEN=tok GITHUB_OUTPUT="${OUT}" GITHUB_STEP_SUMMARY="${SUMMARY}" \
    python3 "${SCRIPT}" "$@" > "${LOG}" 2>&1 || STATUS=$?
}

run_target() {
  run target --tag "${1}" --event "${2:-workflow_run}" --modules "${3:-${MODULES}}"
}

run_decide() {
  run decide --tag "${TAG}" --module core --max-per-day "${1:-0}"
}

expect_ok() {
  if [ "${STATUS}" -ne 0 ]; then
    fail "${1}: exit ${STATUS}: $(cat "${LOG}")"
    return 1
  fi
  return 0
}

expect_fail() {
  if [ "${STATUS}" -eq 0 ]; then
    fail "${1}: expected non-zero exit"
    return 1
  fi
  return 0
}

log_have() {
  grep -qF -- "${2}" "${LOG}" && pass "${1}" || fail "${1}: '${2}' not in: $(cat "${LOG}")"
}

out_have() {
  grep -qxF -- "${2}" "${OUT}" && pass "${1}" || fail "${1}: '${2}' not in output: $(cat "${OUT}")"
}

summary_have() {
  grep -qF -- "${2}" "${SUMMARY}" "${LOG}" && pass "${1}" || fail "${1}: '${2}' not in summary: $(cat "${SUMMARY}") / log: $(cat "${LOG}")"
}

calls_have() {
  grep -qF -- "${2}" "${CALLS}" && pass "${1}" || fail "${1}: missing '${2}' in: $(cat "${CALLS}")"
}

stdin_have() {
  if tr -d ' \n' < "${CALLS}.stdin" | grep -qF -- "$(printf '%s' "${2}" | tr -d ' ')"; then
    pass "${1}"
  else
    fail "${1}: missing '${2}' in: $(cat "${CALLS}.stdin")"
  fi
}

calls_lack() {
  if grep -qF -- "${2}" "${CALLS}"; then
    fail "${1}: unexpected '${2}' in: $(cat "${CALLS}")"
  else
    pass "${1}"
  fi
}

# target

setup
run_target "${TAG}"
if expect_ok "target ok"; then
  out_have "target: module" "module=core"
  out_have "target: tag" "tag=${TAG}"
  out_have "target: code_dir" "code_dir=modules/core/code"
  out_have "target: services" "services=postgres"
  out_have "target: release_url" "release_url=https://r.example.com/10"
  calls_have "target: reads staging record" "environment=staging"
fi

setup
run_target "${TAG}" workflow_dispatch
if expect_ok "target dispatch"; then
  out_have "target dispatch: tag" "tag=${TAG}"
  out_have "target dispatch: release_url" "release_url=https://r.example.com/10"
fi

setup
run_target "main"
if expect_fail "invalid tag: branch name"; then
  log_have "invalid tag: branch name message" "invalid release tag"
fi

setup
run_target "core.2026-11-21.01"
if expect_fail "invalid tag: short NNN"; then
  log_have "invalid tag: short NNN message" "invalid release tag"
fi

setup
run_target "core.21-11-2026.001"
if expect_fail "invalid tag: bad date"; then
  log_have "invalid tag: bad date message" "invalid release tag"
fi

setup
run_target ""
if expect_fail "invalid tag: empty"; then
  log_have "invalid tag: empty message" "invalid release tag"
fi

setup
echo "[$(dep 21 core.2026-11-21.1000 ',"release_url":"https://r.example.com/1000"')]" > "${STAGING}"
run_target core.2026-11-21.1000
if expect_ok "target four-digit NNN"; then
  out_have "target four-digit NNN: tag" "tag=core.2026-11-21.1000"
fi

setup
run_target "api.2026-11-21.001"
if expect_fail "unknown module"; then
  log_have "unknown module message" "unknown module"
fi

setup
echo "[$(dep 20 "${TAG}")]" > "${STAGING}"
run_target "${TAG}"
if expect_fail "no release_url"; then
  log_have "no release_url message" "verify wrote no release_url for ${TAG}"
fi

setup
echo '[]' > "${STAGING}"
run_target "${TAG}"
expect_fail "no staging record" && pass "no staging record: rejected"

# decide

setup
echo "[$(dep 22 core.2026-11-21.011)]" > "${STAGING}"
run_decide
if expect_ok "superseded staging"; then
  out_have "superseded staging: outcome" "outcome=superseded"
  calls_lack "superseded staging: no workflow run" "workflow run"
  calls_lack "superseded staging: no record" "POST"
fi

setup
echo '[]' > "${STAGING}"
run_decide
if expect_ok "superseded staging: nothing green in staging"; then
  out_have "superseded staging nothing green: outcome" "outcome=superseded"
  calls_lack "superseded staging nothing green: no workflow run" "workflow run"
fi

setup
echo "[$(dep 20 "${TAG}")]" > "${STAGING}"
echo "[$(dep 11 core.2026-11-21.011)]" > "${PRODUCTION}"
run_decide
if expect_ok "superseded production: NNN 011 > 010"; then
  out_have "superseded production: outcome" "outcome=superseded"
  calls_lack "superseded production: no workflow run" "workflow run"
  calls_lack "superseded production: no record" "POST"
fi

setup
TAG=core.2026-11-21.009
echo "[$(dep 20 "${TAG}")]" > "${STAGING}"
echo "[$(dep 11 core.2026-11-21.010)]" > "${PRODUCTION}"
run_decide
if expect_ok "superseded production: 010 > 009"; then
  out_have "superseded production 010>009: outcome" "outcome=superseded"
  calls_lack "superseded production 010>009: no workflow run" "workflow run"
fi
TAG=core.2026-11-21.010

setup
TAG=core.2026-11-21.999
echo "[$(dep 20 "${TAG}")]" > "${STAGING}"
echo "[$(dep 11 core.2026-11-21.1000)]" > "${PRODUCTION}"
run_decide
if expect_ok "superseded production: 1000 > 999"; then
  out_have "superseded production 1000>999: outcome" "outcome=superseded"
  calls_lack "superseded production 1000>999: no workflow run" "workflow run"
fi
TAG=core.2026-11-21.010

setup
echo "[$(dep 11 core.2026-11-20.999)]" > "${PRODUCTION}"
run_decide
if expect_ok "older production by date"; then
  out_have "older production by date: promoted" "outcome=promoted"
fi

setup
echo "[$(dep 11 core.2026-11-22.001)]" > "${PRODUCTION}"
run_decide
if expect_ok "superseded production: newer date"; then
  out_have "superseded production newer date: outcome" "outcome=superseded"
fi

setup
echo '[]' > "${PRODUCTION}"
run_decide
if expect_ok "no production record"; then
  out_have "no production record: promoted" "outcome=promoted"
fi

setup
RECENT="$(python3 -c "import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(hours=2)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
OLD="$(python3 -c "import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(hours=30)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
echo "[{\"id\":31,\"created_at\":\"${RECENT}\",\"payload\":{\"module\":\"core\",\"tag\":\"core.2026-11-21.005\"}},{\"id\":32,\"created_at\":\"${RECENT}\",\"payload\":{\"module\":\"api\",\"tag\":\"api.2026-11-21.001\"}},{\"id\":33,\"created_at\":\"${OLD}\",\"payload\":{\"module\":\"core\",\"tag\":\"core.2026-11-20.001\"}}]" > "${PROMOTED}"
run_decide 2
if expect_ok "capped"; then
  out_have "capped: outcome" "outcome=capped"
  summary_have "capped: summary" "promote capped (2/2)"
  calls_lack "capped: no workflow run" "workflow run"
  calls_lack "capped: no record" "POST"
fi

setup
echo "[{\"id\":31,\"created_at\":\"${RECENT}\",\"payload\":{\"module\":\"core\",\"tag\":\"core.2026-11-21.005\"}},{\"id\":33,\"created_at\":\"${OLD}\",\"payload\":{\"module\":\"core\",\"tag\":\"core.2026-11-20.001\"}}]" > "${PROMOTED}"
run_decide 2
if expect_ok "under cap: old record ignored"; then
  out_have "under cap: promoted" "outcome=promoted"
  calls_have "under cap: workflow run" "workflow run"
fi

setup
echo "[{\"id\":31,\"created_at\":\"${RECENT}\",\"payload\":{\"module\":\"core\",\"tag\":\"core.2026-11-21.005\"}},{\"id\":32,\"created_at\":\"${RECENT}\",\"payload\":{\"module\":\"api\",\"tag\":\"api.2026-11-21.001\"}},{\"id\":34,\"created_at\":\"${RECENT}\",\"payload\":{\"module\":\"core\",\"tag\":\"core.2026-11-21.006\"}}]" > "${PROMOTED}"
run_decide 0
if expect_ok "no cap"; then
  out_have "no cap: promoted" "outcome=promoted"
fi

setup
run_decide 3
if expect_ok "promoted"; then
  out_have "promoted: outcome" "outcome=promoted"
  calls_have "promoted: creates record" "repos/o/r/deployments"
  calls_have "promoted: record environment" "environment=promoted"
  calls_have "promoted: record tag" "${TAG}"
  calls_have "promoted: record module" "core"
  calls_have "promoted: record status" "state=success"
  calls_have "promoted: record goes by --input" "api -X POST repos/o/r/deployments --input -"
  calls_lack "promoted: record is not sent with -f" "-f ref="
  stdin_have "promoted: record ref" '"ref":"'"${TAG}"'"'
  stdin_have "promoted: record environment promoted" '"environment":"promoted"'
  stdin_have "promoted: record required_contexts empty" '"required_contexts":[]'
  stdin_have "promoted: record auto_merge false" '"auto_merge":false'
  stdin_have "promoted: record not transient" '"transient_environment":false'
  stdin_have "promoted: record not production" '"production_environment":false'
  stdin_have "promoted: record description" '"description":"core '"${TAG}"'"'
  stdin_have "promoted: record payload is a JSON string" '"payload":"{\"module\":\"core\",\"tag\":\"'"${TAG}"'\"}"'
  calls_have "promoted: status endpoint uses created id" "repos/o/r/deployments/500/statuses"
  calls_have "promoted: workflow run" "workflow run deploy.yml"
  calls_have "promoted: ref" "--ref ${TAG}"
  calls_have "promoted: environment production" "environment=production"
fi

setup
run_decide 3
if expect_ok "promoted order"; then
  rec="$(grep -n 'POST' "${CALLS}" | head -1 | cut -d: -f1)"
  run_line="$(grep -n 'workflow run' "${CALLS}" | head -1 | cut -d: -f1)"
  if [ -n "${rec}" ] && [ -n "${run_line}" ] && [ "${rec}" -lt "${run_line}" ]; then
    pass "promoted: record written before dispatch"
  else
    fail "promoted: record (${rec}) not before dispatch (${run_line})"
  fi
fi

echo "${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ]
