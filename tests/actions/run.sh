#!/bin/sh
set -u

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0

ok() {
  echo "PASS ${1}"
  PASSED=$(( PASSED + 1 ))
}

ko() {
  echo "FAIL ${1}"
  FAILED=$(( FAILED + 1 ))
}

check_status() {
  if [ "${2}" -eq "${3}" ]; then ok "${1}"; else ko "${1}: expected exit ${3}, got ${2}"; fi
}

check_nonzero() {
  if [ "${2}" -ne 0 ]; then ok "${1}"; else ko "${1}: expected non-zero exit"; fi
}

check_has() {
  if grep -qF -- "${3}" "${2}" 2>/dev/null; then ok "${1}"; else ko "${1}: '${3}' not found in ${2##*/}"; fi
}

check_lacks() {
  if grep -qF -- "${3}" "${2}" 2>/dev/null; then ko "${1}: '${3}' unexpectedly in ${2##*/}"; else ok "${1}"; fi
}

new_dir() {
  d="${WORK}/${1}"
  rm -rf "${d}"
  mkdir -p "${d}"
  echo "${d}"
}

HOOK="${ROOT}/actions/hook/hook.sh"

mkmodule() {
  m="$(new_dir "${1}")"
  mkdir -p "${m}/ci"
  echo "${m}"
}

hook_runs_script() {
  # arrange
  m="$(mkmodule hook-run)"
  printf '#!/bin/sh\necho ran-build\n' > "${m}/ci/build.sh"
  # act
  status=0
  (cd "${m}" && env STEP=build sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  # assert
  check_status "hook runs existing script" "${status}" 0
  check_has "hook script output" "${WORK}/out" "ran-build"
}

hook_runs_non_executable() {
  # arrange
  m="$(mkmodule hook-noexec)"
  printf 'echo plain\n' > "${m}/ci/test.sh"
  chmod 644 "${m}/ci/test.sh"
  # act
  status=0
  (cd "${m}" && env STEP=test sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  # assert
  check_status "hook runs non-executable script" "${status}" 0
  check_has "hook non-executable output" "${WORK}/out" "plain"
}

hook_runs_executable() {
  # arrange
  m="$(mkmodule hook-exec)"
  printf '#!/bin/sh\necho direct\n' > "${m}/ci/lint.sh"
  chmod 755 "${m}/ci/lint.sh"
  # act
  status=0
  (cd "${m}" && env STEP=lint sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  # assert
  check_status "hook runs executable script" "${status}" 0
  check_has "hook executable output" "${WORK}/out" "direct"
}

hook_propagates_exit() {
  # arrange
  m="$(mkmodule hook-fail)"
  printf '#!/bin/sh\nexit 7\n' > "${m}/ci/build.sh"
  # act
  status=0
  (cd "${m}" && env STEP=build sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  # assert
  check_status "hook propagates script exit code" "${status}" 7
}

hook_exports_cache_dir() {
  # arrange
  m="$(mkmodule hook-cache)"
  printf '#!/bin/sh\necho "$CI_CACHE_DIR"\n' > "${m}/ci/build.sh"
  # act
  status=0
  (cd "${m}" && env STEP=build sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  expected="$(cd "${m}" && pwd)/.ci-cache"
  # assert
  check_status "hook cache dir run" "${status}" 0
  if grep -qxF -- "${expected}" "${WORK}/out"; then ok "hook exports CI_CACHE_DIR"; else ko "hook exports CI_CACHE_DIR: want '${expected}' got '$(cat "${WORK}/out")'"; fi
}

hook_missing_script() {
  # arrange
  m="$(mkmodule hook-missing)"
  # act
  status=0
  (cd "${m}" && env STEP=deploy sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  # assert
  check_status "hook missing script fails" "${status}" 1
  cat "${WORK}/out" "${WORK}/err" > "${WORK}/both"
  check_has "hook missing script error" "${WORK}/both" "::error::missing ci/deploy.sh"
}

hook_step_unset() {
  # arrange
  m="$(mkmodule hook-unset)"
  # act
  status=0
  (cd "${m}" && env -u STEP sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  # assert
  check_nonzero "hook without STEP fails" "${status}"
}

RECORD="${ROOT}/actions/record/record.sh"

mkgh() {
  g="$(new_dir "${1}")"
  cat > "${g}/gh" <<'GH'
#!/bin/sh
n=0
[ -f "${GH_LOG_DIR}/count" ] && n="$(cat "${GH_LOG_DIR}/count")"
n=$(( n + 1 ))
echo "${n}" > "${GH_LOG_DIR}/count"
printf '%s\n' "$*" > "${GH_LOG_DIR}/args.${n}"
if [ ! -t 0 ]; then cat > "${GH_LOG_DIR}/stdin.${n}" 2>/dev/null; fi
case "$*" in
  *"/deployments --input"*) echo 42 ;;
esac
exit 0
GH
  chmod 755 "${g}/gh"
  echo "${g}"
}

run_record() {
  rdir="${1}"
  shift
  mkdir -p "${rdir}/logs"
  status=0
  env -u STATE -u APP_URL GH_LOG_DIR="${rdir}/logs" PATH="${rdir}/bin:${PATH}" \
    GITHUB_REPOSITORY="acme/app" MODULE="api" TAG_INPUT="api-v1.2.3" \
    "$@" sh "${RECORD}" >"${rdir}/out" 2>"${rdir}/err" || status=$?
  echo "${status}" > "${rdir}/status"
}

record_success() {
  # arrange
  r="$(new_dir record-ok)"
  mkdir -p "${r}"
  mv "$(mkgh record-ok-bin)" "${r}/bin"
  # act
  run_record "${r}" ENVIRONMENT=staging STATE=success APP_URL=https://app.example.com
  # assert
  check_status "record success exit" "$(cat "${r}/status")" 0
  check_has "record creates deployment" "${r}/logs/args.1" "api -X POST repos/acme/app/deployments --input - --jq .id"
  check_has "record deployment ref" "${r}/logs/stdin.1" '"ref"'
  check_has "record deployment ref value" "${r}/logs/stdin.1" 'api-v1.2.3'
  check_has "record deployment environment" "${r}/logs/stdin.1" 'staging'
  check_has "record payload module" "${r}/logs/stdin.1" '"module"'
  check_has "record payload tag key" "${r}/logs/stdin.1" '"tag"'
  compact="$(tr -d ' \n\t' < "${r}/logs/stdin.1")"
  case "${compact}" in *'"production_environment":false'*) ok "record production_environment false";; *) ko "record production_environment false: ${compact}";; esac
  case "${compact}" in *'"auto_merge":false'*) ok "record auto_merge false";; *) ko "record auto_merge false: ${compact}";; esac
  case "${compact}" in *'"required_contexts":[]'*) ok "record required_contexts empty";; *) ko "record required_contexts empty: ${compact}";; esac
  case "${compact}" in *'"module":"api"'*) ok "record payload module value";; *) ko "record payload module value: ${compact}";; esac
  case "${compact}" in *'"tag":"api-v1.2.3"'*) ok "record payload tag value";; *) ko "record payload tag value: ${compact}";; esac
  check_has "record status endpoint" "${r}/logs/args.2" "api -X POST repos/acme/app/deployments/42/statuses"
  check_has "record status state" "${r}/logs/args.2" "state=success"
  check_has "record status environment" "${r}/logs/args.2" "environment=staging"
  check_has "record status url" "${r}/logs/args.2" "environment_url=https://app.example.com"
}

record_production() {
  # arrange
  r="$(new_dir record-prod)"
  mv "$(mkgh record-prod-bin)" "${r}/bin"
  # act
  run_record "${r}" ENVIRONMENT=production STATE=success
  # assert
  check_status "record production exit" "$(cat "${r}/status")" 0
  compact="$(tr -d ' \n\t' < "${r}/logs/stdin.1" 2>/dev/null)"
  case "${compact}" in *'"production_environment":true'*) ok "record production_environment true";; *) ko "record production_environment true: ${compact}";; esac
  case "${compact}" in *'"environment":"production"'*) ok "record environment production";; *) ko "record environment production: ${compact}";; esac
}

record_failure_state() {
  # arrange
  r="$(new_dir record-fail)"
  mv "$(mkgh record-fail-bin)" "${r}/bin"
  # act
  run_record "${r}" ENVIRONMENT=staging STATE=failure
  # assert
  check_status "record failure exit" "$(cat "${r}/status")" 0
  check_has "record failure state" "${r}/logs/args.2" "state=failure"
}

record_invalid_state() {
  # arrange
  r="$(new_dir record-bad)"
  mv "$(mkgh record-bad-bin)" "${r}/bin"
  # act
  run_record "${r}" ENVIRONMENT=staging STATE=ok
  # assert
  check_status "record invalid state exit" "$(cat "${r}/status")" 1
  if [ ! -e "${r}/logs/count" ]; then ok "record invalid state does not call gh"; else ko "record invalid state called gh"; fi
}

record_missing_state() {
  # arrange
  r="$(new_dir record-nostate)"
  mv "$(mkgh record-nostate-bin)" "${r}/bin"
  # act
  run_record "${r}" ENVIRONMENT=staging
  # assert
  check_status "record missing state exit" "$(cat "${r}/status")" 1
  if [ ! -e "${r}/logs/count" ]; then ok "record missing state does not call gh"; else ko "record missing state called gh"; fi
}

NOTIFY="${ROOT}/actions/notify/notify.sh"

mkcurl() {
  c="$(new_dir "${1}")"
  cat > "${c}/curl" <<'CURL'
#!/bin/sh
echo x >> "${CURL_LOG_DIR}/count"
printf '%s\n' "$@" > "${CURL_LOG_DIR}/args"
exit "${CURL_EXIT:-0}"
CURL
  chmod 755 "${c}/curl"
  echo "${c}"
}

run_notify() {
  ndir="${1}"
  shift
  mkdir -p "${ndir}/logs"
  : > "${ndir}/summary"
  status=0
  env -u STATUS -u NOTIFY_WEBHOOK_URL -u APP_URL CURL_LOG_DIR="${ndir}/logs" PATH="${ndir}/bin:${PATH}" \
    ENVIRONMENT="staging" MODULE="api" TAG_INPUT="api-v1.2.3" \
    RUN_URL="https://github.com/acme/app/actions/runs/1" \
    GITHUB_STEP_SUMMARY="${ndir}/summary" \
    "$@" sh "${NOTIFY}" >"${ndir}/out" 2>"${ndir}/err" || status=$?
  echo "${status}" > "${ndir}/status"
}

notify_status_case() {
  label="${1}"
  status_value="${2}"
  marker="${3}"
  # arrange
  n="$(new_dir "notify-${label}")"
  mv "$(mkcurl "notify-${label}-bin")" "${n}/bin"
  # act
  run_notify "${n}" "STATUS=${status_value}"
  # assert
  check_status "notify ${label} exit" "$(cat "${n}/status")" 0
  for f in out summary; do
    check_has "notify ${label} ${f} module" "${n}/${f}" "api"
    check_has "notify ${label} ${f} tag" "${n}/${f}" "api-v1.2.3"
    check_has "notify ${label} ${f} environment" "${n}/${f}" "staging"
    check_has "notify ${label} ${f} marker" "${n}/${f}" "${marker}"
  done
  if [ ! -e "${n}/logs/count" ]; then ok "notify ${label} no webhook skips curl"; else ko "notify ${label} called curl without webhook"; fi
}

notify_distinct_markers() {
  # arrange
  n="$(new_dir notify-markers)"
  mv "$(mkcurl notify-markers-bin)" "${n}/bin"
  # act
  run_notify "${n}" "STATUS=ok"
  # assert
  check_lacks "notify ok has no failed marker" "${n}/out" "❌"
  check_lacks "notify ok has no rollback marker" "${n}/out" "↩️"
  run_notify "${n}" "STATUS=failed"
  check_lacks "notify failed has no ok marker" "${n}/out" "✅"
  check_lacks "notify failed has no rollback marker" "${n}/out" "↩️"
  run_notify "${n}" "STATUS=rolled back"
  check_has "notify rolled back text" "${n}/out" "rolled back"
  check_lacks "notify rolled back has no ok marker" "${n}/out" "✅"
  check_lacks "notify rolled back has no failed marker" "${n}/out" "❌"
}

notify_invalid_status() {
  # arrange
  n="$(new_dir notify-bad)"
  mv "$(mkcurl notify-bad-bin)" "${n}/bin"
  # act
  run_notify "${n}" "STATUS=weird"
  # assert
  check_status "notify invalid status exit" "$(cat "${n}/status")" 1
  n2="$(new_dir notify-nostatus)"
  mv "$(mkcurl notify-nostatus-bin)" "${n2}/bin"
  run_notify "${n2}"
  check_status "notify missing status exit" "$(cat "${n2}/status")" 1
}

notify_webhook() {
  # arrange
  n="$(new_dir notify-hook)"
  mv "$(mkcurl notify-hook-bin)" "${n}/bin"
  # act
  run_notify "${n}" STATUS=failed NOTIFY_WEBHOOK_URL=https://hooks.example.com/x
  # assert
  check_status "notify webhook exit" "$(cat "${n}/status")" 0
  check_has "notify webhook url" "${n}/logs/args" "https://hooks.example.com/x"
  check_has "notify webhook POST" "${n}/logs/args" "POST"
  check_has "notify webhook json key" "${n}/logs/args" '"text"'
  check_has "notify webhook message module" "${n}/logs/args" "api"
  check_has "notify webhook message tag" "${n}/logs/args" "api-v1.2.3"
  check_has "notify webhook message marker" "${n}/logs/args" "❌"
}

notify_webhook_failure() {
  # arrange
  n="$(new_dir notify-hookfail)"
  mv "$(mkcurl notify-hookfail-bin)" "${n}/bin"
  # act
  run_notify "${n}" STATUS=ok NOTIFY_WEBHOOK_URL=https://hooks.example.com/x CURL_EXIT=22
  # assert
  check_status "notify webhook failure still exits 0" "$(cat "${n}/status")" 0
  cat "${n}/out" "${n}/err" > "${n}/both"
  check_has "notify webhook failure warns" "${n}/both" "::warning::"
}

hook_runs_script
hook_runs_non_executable
hook_runs_executable
hook_propagates_exit
hook_exports_cache_dir
hook_missing_script
hook_step_unset
record_success
record_production
record_failure_state
record_invalid_state
record_missing_state
notify_status_case ok ok "✅"
notify_status_case failed failed "❌"
notify_status_case rolled-back "rolled back" "↩️"
notify_distinct_markers
notify_invalid_status
notify_webhook
notify_webhook_failure

echo "${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ]
