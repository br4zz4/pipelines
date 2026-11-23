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
  mkdir -p "${m}/ci/checks" "${m}/ci/deploy"
  echo "${m}"
}

hook_runs_script() {
  # arrange
  m="$(mkmodule hook-run)"
  printf '#!/bin/sh\necho ran-build\n' > "${m}/ci/checks/build.sh"
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
  printf 'echo plain\n' > "${m}/ci/checks/test.sh"
  chmod 644 "${m}/ci/checks/test.sh"
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
  printf '#!/bin/sh\necho direct\n' > "${m}/ci/checks/lint.sh"
  chmod 755 "${m}/ci/checks/lint.sh"
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
  printf '#!/bin/sh\nexit 7\n' > "${m}/ci/checks/build.sh"
  # act
  status=0
  (cd "${m}" && env STEP=build sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  # assert
  check_status "hook propagates script exit code" "${status}" 7
}

hook_exports_cache_dir() {
  # arrange
  m="$(mkmodule hook-cache)"
  printf '#!/bin/sh\necho "$CI_CACHE_DIR"\n' > "${m}/ci/checks/build.sh"
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
  (cd "${m}" && env STEP=deployment sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  # assert
  check_status "hook missing script fails" "${status}" 1
  cat "${WORK}/out" "${WORK}/err" > "${WORK}/both"
  check_has "hook missing script error" "${WORK}/both" "::error::missing ci/deploy/deployment.sh"
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

mkrun() {
  m="$(new_dir "${1}")"
  mkdir -p "${m}/run"
  echo "${m}"
}

hook_run_executable_wins() {
  # arrange
  m="$(mkrun hook-run-wins)"
  mkdir -p "${m}/ci/checks"
  printf '#!/bin/sh\necho from-run\n' > "${m}/run/lint"
  chmod 755 "${m}/run/lint"
  printf '#!/bin/sh\necho from-ci\n' > "${m}/ci/checks/lint.sh"
  chmod 755 "${m}/ci/checks/lint.sh"
  # act
  status=0
  (cd "${m}" && env STEP=lint sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  # assert
  check_status "hook run/lint exit" "${status}" 0
  check_has "hook run/lint announces" "${WORK}/out" "== run/lint"
  check_has "hook run/lint output" "${WORK}/out" "from-run"
  check_lacks "hook run/lint skips ci/checks" "${WORK}/out" "from-ci"
  check_lacks "hook run/lint does not announce ci/checks" "${WORK}/out" "== ci/checks/lint.sh"
}

hook_run_only() {
  # arrange
  m="$(mkrun hook-run-only)"
  printf '#!/bin/sh\necho only-run\n' > "${m}/run/audit"
  chmod 755 "${m}/run/audit"
  # act
  status=0
  (cd "${m}" && env STEP=audit sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  # assert
  check_status "hook run-only exit" "${status}" 0
  check_has "hook run-only output" "${WORK}/out" "only-run"
}

hook_run_non_executable() {
  # arrange
  m="$(mkrun hook-run-noexec)"
  printf 'echo via-sh\n' > "${m}/run/test"
  chmod 644 "${m}/run/test"
  # act
  status=0
  (cd "${m}" && env STEP=test sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  # assert
  check_status "hook run non-executable exit" "${status}" 0
  check_has "hook run non-executable announces" "${WORK}/out" "== run/test"
  check_has "hook run non-executable output" "${WORK}/out" "via-sh"
}

hook_legacy_checks_flow() {
  # arrange
  m="$(mkmodule hook-legacy)"
  printf '#!/bin/sh\necho legacy-lint\n' > "${m}/ci/checks/lint.sh"
  chmod 755 "${m}/ci/checks/lint.sh"
  # act
  status=0
  (cd "${m}" && env STEP=lint sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  # assert
  check_status "hook legacy exit" "${status}" 0
  check_has "hook legacy announces" "${WORK}/out" "== ci/checks/lint.sh"
  check_has "hook legacy output" "${WORK}/out" "legacy-lint"
}

hook_missing_run_and_checks() {
  for s in lint audit test; do
    # arrange
    m="$(mkmodule "hook-none-${s}")"
    # act
    status=0
    (cd "${m}" && env STEP="${s}" sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
    # assert
    check_status "hook ${s} without run or checks fails" "${status}" 1
    cat "${WORK}/out" "${WORK}/err" > "${WORK}/both"
    check_has "hook ${s} missing message" "${WORK}/both" "missing run/${s} or ci/checks/${s}.sh"
  done
}

hook_build_ignores_run() {
  # arrange
  m="$(mkrun hook-build-run)"
  mkdir -p "${m}/ci/checks"
  printf '#!/bin/sh\necho run-build\n' > "${m}/run/build"
  chmod 755 "${m}/run/build"
  # act
  status=0
  (cd "${m}" && env STEP=build sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  # assert
  check_status "hook build without ci/checks fails" "${status}" 1
  cat "${WORK}/out" "${WORK}/err" > "${WORK}/both"
  check_has "hook build requires ci/checks" "${WORK}/both" "missing ci/checks/build.sh"
  check_lacks "hook build does not run run/build" "${WORK}/both" "run-build"
  printf '#!/bin/sh\necho ci-build\n' > "${m}/ci/checks/build.sh"
  status=0
  (cd "${m}" && env STEP=build sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  check_status "hook build with ci/checks exit" "${status}" 0
  check_has "hook build runs ci/checks" "${WORK}/out" "ci-build"
  check_lacks "hook build ignores run/build" "${WORK}/out" "run-build"
}

hook_run_exports_cache_dir() {
  # arrange
  m="$(mkrun hook-run-cache)"
  printf '#!/bin/sh\necho "$CI_CACHE_DIR"\n' > "${m}/run/lint"
  chmod 755 "${m}/run/lint"
  # act
  status=0
  (cd "${m}" && env STEP=lint sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  expected="$(cd "${m}" && pwd)/.ci-cache"
  # assert
  check_status "hook run cache dir exit" "${status}" 0
  if grep -qxF -- "${expected}" "${WORK}/out"; then ok "hook run exports CI_CACHE_DIR"; else ko "hook run exports CI_CACHE_DIR: want '${expected}' got '$(cat "${WORK}/out")'"; fi
}

hook_run_propagates_exit() {
  for mode in 755 644; do
    # arrange
    m="$(mkrun "hook-run-fail-${mode}")"
    printf '#!/bin/sh\nexit 9\n' > "${m}/run/test"
    chmod "${mode}" "${m}/run/test"
    # act
    status=0
    (cd "${m}" && env STEP=test sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
    # assert
    check_status "hook run propagates exit (${mode})" "${status}" 9
  done
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
  env -u STATE -u APP_URL -u RELEASE_URL GH_LOG_DIR="${rdir}/logs" PATH="${rdir}/bin:${PATH}" \
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

record_promoted_with_release_url() {
  # arrange
  r="$(new_dir record-promoted)"
  mv "$(mkgh record-promoted-bin)" "${r}/bin"
  # act
  run_record "${r}" ENVIRONMENT=promoted STATE=success RELEASE_URL=https://r1.example.com
  # assert
  check_status "record promoted exit" "$(cat "${r}/status")" 0
  compact="$(tr -d ' \n\t' < "${r}/logs/stdin.1" 2>/dev/null)"
  case "${compact}" in *'"environment":"promoted"'*) ok "record environment promoted";; *) ko "record environment promoted: ${compact}";; esac
  case "${compact}" in *'"production_environment":false'*) ok "record promoted is not production";; *) ko "record promoted is not production: ${compact}";; esac
  case "${compact}" in *'"payload":{"module":"api","tag":"api-v1.2.3","release_url":"https://r1.example.com"}'*) ok "record payload carries release_url";; *) ko "record payload carries release_url: ${compact}";; esac
  check_has "record promoted status environment" "${r}/logs/args.2" "environment=promoted"
}

record_without_release_url() {
  # arrange
  r="$(new_dir record-no-release-url)"
  mv "$(mkgh record-no-release-url-bin)" "${r}/bin"
  # act
  run_record "${r}" ENVIRONMENT=staging STATE=success RELEASE_URL=
  # assert
  check_status "record without release_url exit" "$(cat "${r}/status")" 0
  compact="$(tr -d ' \n\t' < "${r}/logs/stdin.1" 2>/dev/null)"
  case "${compact}" in *'"payload":{"module":"api","tag":"api-v1.2.3"}'*) ok "record payload without release_url is unchanged";; *) ko "record payload without release_url is unchanged: ${compact}";; esac
  check_lacks "record payload has no release_url key" "${r}/logs/stdin.1" "release_url"
}

record_invalid_environment() {
  # arrange
  r="$(new_dir record-bad-env)"
  mv "$(mkgh record-bad-env-bin)" "${r}/bin"
  # act
  run_record "${r}" ENVIRONMENT=qa STATE=success
  # assert
  check_nonzero "record invalid environment fails" "$(cat "${r}/status")"
  if [ ! -e "${r}/logs/count" ]; then ok "record invalid environment does not call gh"; else ko "record invalid environment called gh"; fi
}

record_action_declares_release_url() {
  # arrange
  got="$(python3 -I -c 'import sys, yaml
a = yaml.safe_load(open(sys.argv[1]))
i = a["inputs"].get("release_url")
print("MISSING" if i is None else "required=" + str(i.get("required", False)) + " default=" + repr(i.get("default")))
print("env=" + str(a["runs"]["steps"][0]["env"].get("RELEASE_URL")))' "${ROOT}/actions/record/action.yml" 2>/dev/null)"
  # assert
  case "${got}" in *"required=False"*) ok "record action declares release_url as optional";; *) ko "record action declares release_url as optional: '${got}'";; esac
  case "${got}" in *"default=''"*) ok "record action release_url defaults to empty";; *) ko "record action release_url defaults to empty: '${got}'";; esac
  case "${got}" in *'env=${{ inputs.release_url }}'*) ok "record action passes release_url to RELEASE_URL";; *) ko "record action passes release_url to RELEASE_URL: '${got}'";; esac
}

deploy_declares_promote_inputs() {
  # arrange
  got="$(python3 -I -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
i = d.get("on", d.get(True))["workflow_call"]["inputs"]
for n in ("require_promoted", "promote_enabled"):
    v = i.get(n)
    print(n + "=" + ("MISSING" if v is None else str(v.get("type")) + " " + repr(v.get("default")) + " " + str(v.get("required", False))))' "${DEPLOY_WORKFLOW}" 2>/dev/null)"
  # assert
  case "${got}" in *"require_promoted=boolean False False"*) ok "deploy declares require_promoted boolean false";; *) ko "deploy declares require_promoted boolean false: '${got}'";; esac
  case "${got}" in *"promote_enabled=boolean False False"*) ok "deploy declares promote_enabled boolean false";; *) ko "deploy declares promote_enabled boolean false: '${got}'";; esac
}

deploy_verify_publishes_release_url() {
  # arrange
  got="$(python3 -I -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print("release_url=" + str(d["jobs"]["verify"].get("outputs", {}).get("release_url", "MISSING")))' "${DEPLOY_WORKFLOW}" 2>/dev/null)"
  # assert
  case "${got}" in *"release_url=\${{ steps."*"outputs.release_url }}"*) ok "deploy verify publishes release_url";; *) ko "deploy verify publishes release_url: '${got}'";; esac
}

deploy_staging_record_requires_promoted() {
  # arrange
  got="$(python3 -I -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
s = next((s for s in d["jobs"]["preflight"]["steps"] if s.get("name") == "staging record"), {})
print("uses=" + str(s.get("uses")))
print("environment=" + str((s.get("with") or {}).get("environment")))' "${DEPLOY_WORKFLOW}" 2>/dev/null)"
  # assert
  case "${got}" in *"uses=br4zz4/pipelines/actions/resolve@v2"*) ok "deploy staging record resolves";; *) ko "deploy staging record resolves: '${got}'";; esac
  case "${got}" in *"environment=\${{ inputs.require_promoted && 'promoted' || 'staging' }}"*) ok "deploy staging record uses promoted when require_promoted";; *) ko "deploy staging record uses promoted when require_promoted: '${got}'";; esac
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
  env -u STATUS -u KIND -u NOTIFY_WEBHOOK_URL -u APP_URL CURL_LOG_DIR="${ndir}/logs" PATH="${ndir}/bin:${PATH}" \
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

notify_annotation_case() {
  label="${1}"
  status_value="${2}"
  level="${3}"
  other="${4}"
  # arrange
  n="$(new_dir "notify-ann-${label}")"
  mv "$(mkcurl "notify-ann-${label}-bin")" "${n}/bin"
  # act
  run_notify "${n}" "STATUS=${status_value}" DETAIL=boom
  # assert
  check_status "notify annotation ${label} exit" "$(cat "${n}/status")" 0
  check_has "notify annotation ${label} level and title" "${n}/out" "::${level} title=deploy api staging::"
  check_lacks "notify annotation ${label} not ${other}" "${n}/out" "::${other} title="
  ann="$(grep "^::${level} title=" "${n}/out" || true)"
  msg="$(grep -v '^::' "${n}/out" | head -n 1)"
  if [ -n "${msg}" ] && [ "${ann}" = "::${level} title=deploy api staging::${msg}" ]; then ok "notify annotation ${label} carries the message"; else ko "notify annotation ${label} message: '${ann}' vs '${msg}'"; fi
  check_has "notify annotation ${label} message has status" "${n}/out" "${status_value}"
  check_has "notify annotation ${label} message has detail" "${n}/out" "(boom)"
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

DEPLOY_WORKFLOW="${ROOT}/.github/workflows/deploy.yml"

job_block() {
  awk -v job="${2}" '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { current = $1; sub(/:$/, "", current) }
    /^[^ ]/ { current = "" }
    current == job { print }
  ' "${1}"
}

deploy_lean_job() {
  job="${1}"
  # arrange
  block="${WORK}/deploy-${job}"
  job_block "${DEPLOY_WORKFLOW}" "${job}" > "${block}"
  # assert
  if [ -s "${block}" ]; then ok "deploy.yml declares ${job}"; else ko "deploy.yml declares ${job}"; fi
  check_lacks "deploy ${job} has no services" "${block}" "services:"
  check_has "deploy ${job} runs on 2 vCPU" "${block}" "runs-on: blacksmith-2vcpu-ubuntu-2404"
  check_lacks "deploy ${job} does not run on 4 vCPU" "${block}" "blacksmith-4vcpu-ubuntu-2404"
}

deploy_services_input_only() {
  # arrange
  matches="${WORK}/services-matches"
  grep -n 'services:' "${DEPLOY_WORKFLOW}" > "${matches}" || true
  # assert
  if [ "$(wc -l < "${matches}" | tr -d ' ')" -eq 1 ]; then ok "deploy.yml declares services only as an input"; else ko "deploy.yml declares services only as an input: $(cat "${matches}")"; fi
  inputs="${WORK}/deploy-inputs"
  awk '/^  workflow_call:/{f=1} f{print} /^jobs:/{exit}' "${DEPLOY_WORKFLOW}" > "${inputs}"
  check_has "deploy services input stays declared" "${inputs}" "services:"
  check_lacks "deploy services input does not mention rollback" "${inputs}" "ignored: verify and rollback"
  check_has "deploy services input is marked obsolete" "${inputs}" "Deprecated, ignored: verify runs without services"
}

STEP_ACTION="${ROOT}/actions/step/action.yml"

yaml_eval() {
  PATH="/tmp/pyyaml-venv/bin:${PATH}" python3 -I -c "${1}" "${2}" 2>/dev/null
}

HOOK_ACTION="${ROOT}/actions/hook/action.yml"

hook_declares_url_outputs() {
  for n in url release_url; do
    # arrange
    expr="import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print(((d.get('outputs') or {}).get('${n}') or {}).get('value', 'missing'))"
    # act
    got="$(yaml_eval "${expr}" "${HOOK_ACTION}")"
    # assert
    if [ "${got}" = "\${{ steps.run.outputs.${n} }}" ]; then ok "hook action declares output ${n}"; else ko "hook action declares output ${n}: got '${got}'"; fi
  done
}

hook_declares_every_output_step_forwards() {
  # arrange
  expr='import sys, yaml, re
s = yaml.safe_load(open(sys.argv[1]))
h = yaml.safe_load(open(sys.argv[2]))
declared = set((h.get("outputs") or {}).keys())
for k, o in (s.get("outputs") or {}).items():
    for x in re.findall(r"steps\.hook\.outputs\.([A-Za-z0-9_-]+)", str(o.get("value", ""))):
        if x not in declared:
            print("missing " + x)'
  # act
  got="$(PATH="/tmp/pyyaml-venv/bin:${PATH}" python3 -I -c "${expr}" "${STEP_ACTION}" "${HOOK_ACTION}" 2>&1)"
  # assert
  if [ -z "${got}" ]; then ok "hook declares every output step reads from steps.hook"; else ko "hook declares every output step reads from steps.hook: ${got}"; fi
}

step_passes_step_input() {
  # arrange
  expr='import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for s in d["runs"]["steps"]:
    if s.get("uses") == "./.github/actions/setup":
        print(s.get("with", {}).get("step", ""))'
  # act
  got="$(yaml_eval "${expr}" "${STEP_ACTION}")"
  # assert
  if [ "${got}" = '${{ inputs.step }}' ]; then ok "step action passes step to setup"; else ko "step action passes step to setup: got '${got}'"; fi
}

example_setup_declares_step() {
  for f in "${ROOT}"/examples/*/setup-action.yml; do
    name="$(basename "$(dirname "${f}")")"
    # arrange
    expr='import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
i = (d.get("inputs") or {}).get("step")
if i is None:
    print("missing")
else:
    print("optional" if not i.get("required", False) else "required")'
    # act
    got="$(yaml_eval "${expr}" "${f}")"
    # assert
    if [ "${got}" = "optional" ]; then ok "example ${name} setup declares optional step input"; else ko "example ${name} setup declares optional step input: got '${got}'"; fi
  done
}

hook_optional_missing_skips() {
  for s in migrate rollout; do
    # arrange
    m="$(mkmodule "hook-optional-none-${s}")"
    # act
    status=0
    (cd "${m}" && env STEP="${s}" sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
    # assert
    check_status "hook ${s} without script exits 0" "${status}" 0
    cat "${WORK}/out" "${WORK}/err" > "${WORK}/both"
    check_has "hook ${s} without script says skipping" "${WORK}/both" "skipping"
    check_lacks "hook ${s} without script is not an error" "${WORK}/both" "::error::"
  done
}

hook_optional_present_runs() {
  for s in migrate rollout; do
    for mode in 755 644; do
      # arrange
      m="$(mkmodule "hook-optional-run-${s}-${mode}")"
      printf '#!/bin/sh\necho ran-%s\n' "${s}" > "${m}/ci/deploy/${s}.sh"
      chmod "${mode}" "${m}/ci/deploy/${s}.sh"
      # act
      status=0
      (cd "${m}" && env STEP="${s}" sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
      # assert
      check_status "hook ${s} runs script (${mode})" "${status}" 0
      check_has "hook ${s} announces (${mode})" "${WORK}/out" "== ci/deploy/${s}.sh"
      check_has "hook ${s} output (${mode})" "${WORK}/out" "ran-${s}"
      check_lacks "hook ${s} present does not skip (${mode})" "${WORK}/out" "skipping"
    done
  done
}

hook_optional_propagates_exit() {
  for s in migrate rollout; do
    # arrange
    m="$(mkmodule "hook-optional-fail-${s}")"
    printf '#!/bin/sh\nexit 7\n' > "${m}/ci/deploy/${s}.sh"
    chmod 755 "${m}/ci/deploy/${s}.sh"
    # act
    status=0
    (cd "${m}" && env STEP="${s}" sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
    # assert
    check_status "hook ${s} propagates exit" "${status}" 7
  done
}

hook_deploy_mandatory_still_fail() {
  for s in apply deployment verify; do
    # arrange
    m="$(mkmodule "hook-mandatory-${s}")"
    # act
    status=0
    (cd "${m}" && env STEP="${s}" sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
    # assert
    check_status "hook ${s} without script fails" "${status}" 1
    cat "${WORK}/out" "${WORK}/err" > "${WORK}/both"
    check_has "hook ${s} missing message" "${WORK}/both" "missing ci/deploy/${s}.sh"
  done
}

hook_rollback_is_unknown() {
  # arrange
  m="$(mkmodule hook-rollback-retired)"
  printf '#!/bin/sh\necho ran-retired\n' > "${m}/ci/deploy/rollback.sh"
  # act
  status=0
  (cd "${m}" && env STEP=rollback sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  # assert
  check_status "hook rollback is no longer a step" "${status}" 1
  cat "${WORK}/out" "${WORK}/err" > "${WORK}/both"
  check_has "hook rollback is an unknown step" "${WORK}/both" "unknown step 'rollback'"
  check_lacks "hook rollback never runs the script" "${WORK}/both" "ran-retired"
}

deploy_optional_job() {
  job="${1}"
  # arrange
  block="${WORK}/deploy-${job}"
  job_block "${DEPLOY_WORKFLOW}" "${job}" > "${block}"
  # assert
  if [ -s "${block}" ]; then ok "deploy.yml declares ${job}"; else ko "deploy.yml declares ${job}"; fi
  check_has "deploy ${job} name" "${block}" "name: ${job}"
  check_has "deploy ${job} environment" "${block}" "environment: \${{ inputs.environment == 'production' && 'production' || 'staging' }}"
  check_has "deploy ${job} runs on 2 vCPU" "${block}" "runs-on: blacksmith-2vcpu-ubuntu-2404"
  check_has "deploy ${job} checks out submodules" "${block}" "submodules: recursive"
  check_has "deploy ${job} checks out the tag" "${block}" "ref: \${{ inputs.tag }}"
  check_has "deploy ${job} uses the step action" "${block}" "uses: br4zz4/pipelines/actions/step@v2"
  check_has "deploy ${job} step input" "${block}" "step: ${job}"
  check_has "deploy ${job} side infra" "${block}" "side: infra"
  check_has "deploy ${job} dir" "${block}" "dir: \${{ inputs.infra_dir }}"
  check_has "deploy ${job} vault" "${block}" "vault: \${{ inputs.vault }}"
  check_has "deploy ${job} key" "${block}" "key: \${{ secrets.WARD_KEY }}"
  check_has "deploy ${job} restricted key" "${block}" "restricted-key:"
  check_has "deploy ${job} tag" "${block}" "tag: \${{ inputs.tag }}"
}

deploy_job_attr() {
  PATH="/tmp/pyyaml-venv/bin:${PATH}" python3 -I -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
j = d["jobs"].get(sys.argv[2])
if j is None:
    print("MISSING")
else:
    v = j.get(sys.argv[3])
    print(" ".join(sorted(v)) if isinstance(v, list) else v)' "${DEPLOY_WORKFLOW}" "${1}" "${2}" 2>/dev/null
}

deploy_needs_case() {
  job="${1}"
  want="${2}"
  # act
  got="$(deploy_job_attr "${job}" needs)"
  # assert
  if [ "${got}" = "${want}" ]; then ok "deploy ${job} needs"; else ko "deploy ${job} needs: want '${want}' got '${got}'"; fi
}

deploy_graph() {
  deploy_needs_case migrate "apply preflight"
  deploy_needs_case deployment "apply preflight"
  deploy_needs_case rollout "apply deployment migrate preflight"
  deploy_needs_case verify "apply deployment migrate preflight rollout"
  deploy_needs_case record "apply deployment migrate preflight rollout verify"
  deploy_needs_case notify "apply deployment migrate preflight record rollout verify"
  # assert
  if [ "$(deploy_job_attr rollback needs)" = "MISSING" ]; then ok "deploy has no rollback job"; else ko "deploy has no rollback job"; fi
}

deploy_record_step() {
  PATH="/tmp/pyyaml-venv/bin:${PATH}" python3 -I -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = d["jobs"]["record"]["steps"]
step = next((s for s in steps if s.get("id") == sys.argv[2]), {})
print(step.get(sys.argv[3]))' "${DEPLOY_WORKFLOW}" "${1}" "${2}" 2>/dev/null
}

deploy_rollback_condition() {
  # arrange
  cond="$(deploy_record_step rollback if)"
  # assert
  case "${cond}" in *"!cancelled()"*) ok "deploy rollback step keeps !cancelled()";; *) ko "deploy rollback step keeps !cancelled(): '${cond}'";; esac
  case "${cond}" in *"always()"*) ko "deploy rollback step has no always(): '${cond}'";; *) ok "deploy rollback step has no always()";; esac
  case "${cond}" in *"inputs.rollback_of == ''"*) ok "deploy rollback never chains";; *) ko "deploy rollback never chains: '${cond}'";; esac
  for j in deployment migrate rollout verify; do
    case "${cond}" in *"needs.${j}.result == 'failure'"*) ok "deploy rollback fires on ${j} failure";; *) ko "deploy rollback fires on ${j} failure: '${cond}'";; esac
  done
  case "${cond}" in *"needs.apply"*) ko "deploy rollback ignores apply: '${cond}'";; *) ok "deploy rollback ignores apply";; esac
}

deploy_rollback_job() {
  # arrange
  PATH="/tmp/pyyaml-venv/bin:${PATH}" python3 -I -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
j = d["jobs"]["record"]
print("workflow_permissions=" + ",".join(k + ":" + v for k, v in sorted(d.get("permissions", {}).items())))
print("record_permissions=" + ",".join(k + ":" + v for k, v in sorted(j.get("permissions", {}).items())))
for k, v in sorted(j.get("outputs", {}).items()):
    print("record_output_" + k + "=" + str(v))
print("rollback_of_default=" + repr(d.get("on", d.get(True))["workflow_call"]["inputs"]["rollback_of"].get("default")))
for s in j["steps"]:
    if s.get("id") == "rollback":
        print("uses=" + str(s.get("uses")))
        for k, v in sorted(s.get("with", {}).items()):
            print("with_" + k + "=" + str(v))
for n in ("record", "notify"):
    print(n + "_environment=" + str("environment" in d["jobs"][n]))
for n, job in d["jobs"].items():
    print("job_" + n + "_actions_write=" + str(job.get("permissions", {}).get("actions") == "write"))
    for s in job.get("steps", []):
        if "rollback" in s.get("with", {}):
            print("step_input_rollback=" + n)
        if "actions/step@" in str(s.get("uses")) and s.get("with", {}).get("step") == "rollback":
            print("hook_rollback=" + n)
    if "rollback" in job.get("outputs", {}):
        print("job_output_rollback=" + n)' "${DEPLOY_WORKFLOW}" > "${WORK}/rollback-job" 2>/dev/null || true
  # assert
  check_has "deploy record has no environment" "${WORK}/rollback-job" "record_environment=False"
  check_has "deploy notify has no environment" "${WORK}/rollback-job" "notify_environment=False"
  check_has "deploy record permissions" "${WORK}/rollback-job" "record_permissions=actions:write,contents:read,deployments:write"
  check_has "deploy record has actions write" "${WORK}/rollback-job" "job_record_actions_write=True"
  check_lacks "deploy notify has no actions write" "${WORK}/rollback-job" "job_notify_actions_write=True"
  check_lacks "deploy verify has no actions write" "${WORK}/rollback-job" "job_verify_actions_write=True"
  check_lacks "deploy rollout has no actions write" "${WORK}/rollback-job" "job_rollout_actions_write=True"
  check_has "deploy workflow permissions are read-only plus id-token" "${WORK}/rollback-job" "workflow_permissions=contents:read,id-token:write"
  check_has "deploy record exposes status output" "${WORK}/rollback-job" "record_output_status=\${{ steps.rollback.outputs.status }}"
  check_has "deploy record exposes target output" "${WORK}/rollback-job" "record_output_target=\${{ steps.rollback.outputs.target }}"
  check_has "deploy record exposes detail output" "${WORK}/rollback-job" "record_output_detail=\${{ steps.rollback.outputs.detail }}"
  check_has "deploy declares rollback_of" "${WORK}/rollback-job" "rollback_of_default=''"
  check_has "deploy rollback step uses the rollback action" "${WORK}/rollback-job" "uses=br4zz4/pipelines/actions/rollback@v2"
  check_has "deploy rollback environment" "${WORK}/rollback-job" "with_environment=\${{ inputs.environment }}"
  check_has "deploy rollback module" "${WORK}/rollback-job" "with_module=\${{ inputs.module }}"
  check_has "deploy rollback tag" "${WORK}/rollback-job" "with_tag=\${{ inputs.tag }}"
  check_has "deploy rollback previous" "${WORK}/rollback-job" "with_previous=\${{ needs.preflight.outputs.previous }}"
  check_has "deploy rollback token" "${WORK}/rollback-job" "with_token=\${{ github.token }}"
  check_lacks "deploy rollback has no step hook" "${WORK}/rollback-job" "hook_rollback"
  check_lacks "deploy has no rollback step input" "${WORK}/rollback-job" "step_input_rollback"
  check_lacks "deploy has no rollback job output named rollback" "${WORK}/rollback-job" "job_output_rollback"
  check_lacks "deploy has no rollback-point" "${DEPLOY_WORKFLOW}" "rollback-point"
  check_lacks "deploy has no ROLLBACK_POINT" "${DEPLOY_WORKFLOW}" "ROLLBACK_POINT"
}

deploy_rollback_preflight() {
  # arrange
  PATH="/tmp/pyyaml-venv/bin:${PATH}" python3 -I -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for s in d["jobs"]["preflight"]["steps"]:
    n = s.get("name")
    if n == "requirements":
        print("strict=" + str(s["with"].get("strict")))
    if n == "rollback target":
        print("target_uses=" + str(s.get("uses")))
        print("target_if=" + str(s.get("if")))
        for k, v in sorted(s["with"].items()):
            print("target_" + k + "=" + str(v))
    if n == "apply needed":
        print("force=" + str(s["with"].get("force")))' "${DEPLOY_WORKFLOW}" > "${WORK}/rollback-pre" 2>/dev/null || true
  # assert
  check_has "deploy preflight requirements strict" "${WORK}/rollback-pre" "strict=\${{ inputs.rollback_of == '' }}"
  check_has "deploy rollback target resolves" "${WORK}/rollback-pre" "target_uses=br4zz4/pipelines/actions/resolve@v2"
  check_has "deploy rollback target runs on rollback_of" "${WORK}/rollback-pre" "target_if=inputs.rollback_of != ''"
  check_has "deploy rollback target environment" "${WORK}/rollback-pre" "target_environment=\${{ inputs.environment }}"
  check_has "deploy rollback target module" "${WORK}/rollback-pre" "target_module=\${{ inputs.module }}"
  check_has "deploy rollback target tag" "${WORK}/rollback-pre" "target_tag=\${{ inputs.tag }}"
  check_has "deploy apply needed forced on rollback" "${WORK}/rollback-pre" "force=\${{ inputs.rollback_of != '' }}"
}

deploy_outcome_run() {
  # arrange
  PATH="/tmp/pyyaml-venv/bin:${PATH}" python3 -I -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for s in d["jobs"]["notify"]["steps"]:
    if s.get("id") == "outcome":
        sys.stdout.write(s["run"])' "${DEPLOY_WORKFLOW}" > "${WORK}/outcome.sh" 2>/dev/null || true
  # assert
  if [ -s "${WORK}/outcome.sh" ]; then ok "deploy notify has an outcome step"; else ko "deploy notify has an outcome step"; fi
}

deploy_outcome_case() {
  label="${1}"; verify="${2}"; of="${3}"; tag="${4}"; rdetail="${5}"; want_status="${6}"; want_detail="${7}"; rstatus="${8:-}"; rexpected="${9:-false}"
  # arrange
  : > "${WORK}/outcome.out"
  # act
  env VERIFY="${verify}" ROLLBACK_OF="${of}" TAG="${tag}" ROLLBACK_DETAIL="${rdetail}" ROLLBACK_STATUS="${rstatus}" ROLLBACK_EXPECTED="${rexpected}" GITHUB_OUTPUT="${WORK}/outcome.out" sh "${WORK}/outcome.sh" >/dev/null 2>&1 || true
  # assert
  if [ "$(grep '^status=' "${WORK}/outcome.out")" = "status=${want_status}" ]; then ok "deploy outcome ${label} status"; else ko "deploy outcome ${label} status: $(cat "${WORK}/outcome.out")"; fi
  if [ "$(grep '^detail=' "${WORK}/outcome.out")" = "detail=${want_detail}" ]; then ok "deploy outcome ${label} detail"; else ko "deploy outcome ${label} detail: $(cat "${WORK}/outcome.out")"; fi
}

deploy_outcome() {
  deploy_outcome_run
  deploy_outcome_case "plain success" success "" core.1 "" ok ""
  deploy_outcome_case "rollback success" success core.2 core.1 "" "rolled back" "core.1 after core.2 failed"
  deploy_outcome_case "dispatched uses detail" failure "" core.2 "rolling back to core.1" failed "rolling back to core.1" dispatched true
  deploy_outcome_case "skipped uses detail" failure "" core.2 "rollback skipped: core.3 is queued" failed "rollback skipped: core.3 is queued" skipped true
  deploy_outcome_case "none uses detail" failure "" core.2 "no previous release" failed "no previous release" none true
  deploy_outcome_case "dispatch failed" failure "" core.2 "" failed "rollback dispatch failed" "" true
  deploy_outcome_case "dispatch failed ignores stale detail" failure "" core.2 "rolling back to core.1" failed "rollback dispatch failed" "" true
  deploy_outcome_case "apply failure has no detail" failure "" core.2 "" failed "" "" false
  deploy_outcome_case "skipped verify" skipped "" core.2 "" failed "" "" false
  deploy_outcome_case "rollback failure" failure core.2 core.1 "" failed "rollback of core.2 failed" "" false
  deploy_outcome_case "rollback failure ignores expected" failure core.2 core.1 "" failed "rollback of core.2 failed" "" true
  # arrange
  PATH="/tmp/pyyaml-venv/bin:${PATH}" python3 -I -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for s in d["jobs"]["notify"]["steps"]:
    if s.get("uses", "").startswith("br4zz4/pipelines/actions/notify@"):
        print("status=" + str(s["with"].get("status")))
        print("detail=" + str(s["with"].get("detail")))' "${DEPLOY_WORKFLOW}" > "${WORK}/notify-with" 2>/dev/null || true
  # assert
  check_has "deploy notify uses outcome status" "${WORK}/notify-with" "status=\${{ steps.outcome.outputs.status }}"
  check_has "deploy notify uses outcome detail" "${WORK}/notify-with" "detail=\${{ steps.outcome.outputs.detail }}"
}

deploy_apply_gating() {
  # arrange
  PATH="/tmp/pyyaml-venv/bin:${PATH}" python3 -I -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
pre = d["jobs"]["preflight"]
step = next((s for s in pre["steps"] if s.get("name") == "apply needed"), {})
print("step_id=" + str(step.get("id")))
print("step_uses=" + str(step.get("uses")))
print("pre_out=" + str(pre.get("outputs", {}).get("apply")))
print("apply_if=" + str(d["jobs"]["apply"].get("if")))
for j in ("deployment", "migrate", "rollout", "verify"):
    print(j + "_if=" + str(d["jobs"][j].get("if")))
print("record_if=" + str(d["jobs"]["record"].get("if")))' "${DEPLOY_WORKFLOW}" > "${WORK}/gating" 2>/dev/null || true
  # assert
  check_has "deploy preflight apply needed step id" "${WORK}/gating" "step_id=apply"
  check_has "deploy preflight apply needed action" "${WORK}/gating" "step_uses=br4zz4/pipelines/actions/apply-needed@v2"
  check_has "deploy preflight apply output" "${WORK}/gating" "pre_out=\${{ steps.apply.outputs.needed }}"
  check_has "deploy apply is conditional" "${WORK}/gating" "apply_if=\${{ needs.preflight.outputs.apply == 'true' }}"
  for j in deployment migrate rollout verify; do
    check_has "deploy ${j} survives skipped apply" "${WORK}/gating" "${j}_if=\${{ !failure() && !cancelled() }}"
  done
  check_has "deploy record runs only after a deployment" "${WORK}/gating" "record_if=\${{ always() && needs.deployment.result != 'skipped' }}"
}

contract_documents_optional_hooks() {
  # arrange
  table="${WORK}/contract-table"
  grep -F '| infra |' "${ROOT}/docs/contract.md" > "${table}"
  # assert
  check_has "contract hooks table cites migrate" "${table}" "migrate"
  check_has "contract hooks table cites rollout" "${table}" "rollout"
  check_has "contract hooks table marks them optional" "${table}" "optional"
}

APPLY_NEEDED_ACTION="${ROOT}/actions/apply-needed/action.yml"

apply_needed_declares_previous_output() {
  # arrange
  expr='import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print(d.get("outputs", {}).get("previous", {}).get("value", "MISSING"))
print(d.get("outputs", {}).get("needed", {}).get("value", "MISSING"))'
  # act
  got="$(yaml_eval "${expr}" "${APPLY_NEEDED_ACTION}")"
  # assert
  if [ "$(echo "${got}" | sed -n 1p)" = '${{ steps.previous.outputs.tag }}' ]; then ok "apply-needed exposes previous output"; else ko "apply-needed exposes previous output: got '$(echo "${got}" | sed -n 1p)'"; fi
  if [ "$(echo "${got}" | sed -n 2p)" = '${{ steps.needed.outputs.needed }}' ]; then ok "apply-needed keeps needed output"; else ko "apply-needed keeps needed output: got '$(echo "${got}" | sed -n 2p)'"; fi
}

apply_needed_resolves_in_every_environment() {
  # arrange
  expr='import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for s in d["runs"]["steps"]:
    if s.get("id") == "previous":
        print("uses=" + str(s.get("uses")))
        print("if=" + str(s.get("if", "")))'
  # act
  got="$(yaml_eval "${expr}" "${APPLY_NEEDED_ACTION}")"
  printf '%s\n' "${got}" > "${WORK}/previous-step"
  # assert
  check_has "apply-needed resolves the previous release" "${WORK}/previous-step" "uses=br4zz4/pipelines/actions/resolve@v2"
  if grep -qx "if=" "${WORK}/previous-step"; then ok "apply-needed resolves in every environment"; else ko "apply-needed resolves in every environment: $(cat "${WORK}/previous-step")"; fi
}

deploy_record_dispatches_promote_on_staging_success() {
  # arrange
  step="${WORK}/record-promote-step"
  awk '/^  record:/{r=1;next} r&&/^  [a-z]/{r=0} r&&/^      - name: promote$/{p=1;print;next} p&&/^      - /{p=0} p{print}' "${ROOT}/.github/workflows/deploy.yml" > "${step}"
  # assert
  check_has "record has a promote step" "${step}" "- name: promote"
  check_has "promote step runs only on staging" "${step}" "inputs.environment == 'staging'"
  check_has "promote step requires promote_enabled" "${step}" "inputs.promote_enabled"
  check_has "promote step skips rollbacks" "${step}" "inputs.rollback_of == ''"
  check_has "promote step requires verify success" "${step}" "needs.verify.result == 'success'"
  check_has "promote step dispatches promote.yml" "${step}" "gh workflow run promote.yml"
  check_has "promote step passes the tag input" "${step}" '-f tag="${TAG}"'
}

deploy_has_incident_job_on_production_failure() {
  # arrange
  job="${WORK}/deploy-incident-job"
  awk '/^  incident:/{r=1} r&&/^  [a-z]/&&!/^  incident:/{r=0} r{print}' "${ROOT}/.github/workflows/deploy.yml" > "${job}"
  # assert
  check_has "deploy has an incident job" "${job}" "  incident:"
  check_has "incident needs every deploy job through record" "${job}" "needs: [ preflight, apply, deployment, migrate, rollout, verify, record ]"
  check_has "incident runs always" "${job}" "always()"
  check_has "incident runs only in production" "${job}" "inputs.environment == 'production'"
  check_has "incident requires promote_enabled" "${job}" "inputs.promote_enabled"
  check_has "incident requires a failed need" "${job}" "contains(needs.*.result, 'failure')"
  check_has "incident sets up ward" "${job}" "br4zz4/setup-ward@"
  check_has "incident calls the critical action" "${job}" "br4zz4/pipelines/actions/critical@"
  check_has "incident runs the incident command" "${job}" "command: incident"
  check_has "incident passes the module" "${job}" 'module: ${{ inputs.module }}'
  check_has "incident passes the tag" "${job}" 'tag: ${{ inputs.tag }}'
  check_has "incident passes the run url" "${job}" "run_url:"
  check_has "incident passes the pipelines token" "${job}" "GH_PIPELINES_TOKEN"
}

step_declares_previous_tag_input() {
  # arrange
  expr='import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
i = d.get("inputs", {}).get("previous-tag")
print("MISSING" if i is None else repr(i.get("default")) + " " + str(i.get("required", False)))'
  # act
  got="$(yaml_eval "${expr}" "${STEP_ACTION}")"
  # assert
  if [ "${got}" = "'' False" ]; then ok "step declares optional previous-tag input"; else ko "step declares optional previous-tag input: got '${got}'"; fi
}

step_exports_previous_tag_to_hook() {
  # arrange
  expr='import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for s in d["runs"]["steps"]:
    if s.get("id") == "hook":
        print(s.get("env", {}).get("PREVIOUS_TAG", "MISSING"))'
  # act
  got="$(yaml_eval "${expr}" "${STEP_ACTION}")"
  # assert
  if [ "${got}" = '${{ inputs.previous-tag }}' ]; then ok "step exports PREVIOUS_TAG to the hook"; else ko "step exports PREVIOUS_TAG to the hook: got '${got}'"; fi
}

deploy_preflight_outputs_previous() {
  # arrange
  expr='import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print(d["jobs"]["preflight"].get("outputs", {}).get("previous", "MISSING"))'
  # act
  got="$(yaml_eval "${expr}" "${DEPLOY_WORKFLOW}")"
  # assert
  if [ "${got}" = '${{ steps.apply.outputs.previous }}' ]; then ok "deploy preflight outputs previous"; else ko "deploy preflight outputs previous: got '${got}'"; fi
}

deploy_jobs_pass_previous_tag() {
  # arrange
  expr='import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for name in ("apply", "deployment", "migrate", "rollout", "verify"):
    j = d["jobs"][name]
    vals = [s.get("with", {}).get("previous-tag", "MISSING") for s in j["steps"] if str(s.get("uses", "")).startswith("br4zz4/pipelines/actions/step@")]
    print(name + "=" + ",".join(vals))
    print(name + "_needs=" + str("preflight" in j.get("needs", [])))'
  # act
  got="$(yaml_eval "${expr}" "${DEPLOY_WORKFLOW}")"
  printf '%s\n' "${got}" > "${WORK}/previous-jobs"
  # assert
  for j in apply deployment migrate rollout verify; do
    check_has "deploy ${j} passes previous-tag" "${WORK}/previous-jobs" "${j}=\${{ needs.preflight.outputs.previous }}"
    check_has "deploy ${j} needs preflight" "${WORK}/previous-jobs" "${j}_needs=True"
  done
}

contract_documents_previous_tag() {
  # assert
  check_has "contract cites PREVIOUS_TAG" "${ROOT}/docs/contract.md" "PREVIOUS_TAG"
}

hook_promote_hooks_via_run() {
  for s in regression e2e; do
    # arrange
    m="$(mkrun "hook-promote-run-${s}")"
    printf '#!/bin/sh\necho "run-%s cwd=$(basename "$(pwd)")"\n' "${s}" > "${m}/run/${s}"
    chmod 755 "${m}/run/${s}"
    # act
    status=0
    (cd "${m}" && env STEP="${s}" sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
    # assert
    check_status "hook ${s} via run exit" "${status}" 0
    check_has "hook ${s} via run announces" "${WORK}/out" "== run/${s}"
    check_has "hook ${s} via run output in side dir" "${WORK}/out" "run-${s} cwd=$(basename "${m}")"
  done
}

hook_promote_hooks_via_checks() {
  for s in regression e2e; do
    # arrange
    m="$(mkmodule "hook-promote-checks-${s}")"
    printf '#!/bin/sh\necho "checks-%s"\n' "${s}" > "${m}/ci/checks/${s}.sh"
    chmod 755 "${m}/ci/checks/${s}.sh"
    # act
    status=0
    (cd "${m}" && env STEP="${s}" sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
    # assert
    check_status "hook ${s} via ci/checks exit" "${status}" 0
    check_has "hook ${s} via ci/checks announces" "${WORK}/out" "== ci/checks/${s}.sh"
    check_has "hook ${s} via ci/checks output" "${WORK}/out" "checks-${s}"
  done
}

hook_promote_hooks_missing() {
  for s in regression e2e; do
    # arrange
    m="$(mkmodule "hook-promote-none-${s}")"
    # act
    status=0
    (cd "${m}" && env STEP="${s}" sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
    # assert
    check_status "hook ${s} without run or checks fails" "${status}" 1
    cat "${WORK}/out" "${WORK}/err" > "${WORK}/both"
    check_has "hook ${s} missing message" "${WORK}/both" "::error::missing run/${s} or ci/checks/${s}.sh"
  done
}

hook_receives_base_sha_and_target_url() {
  # arrange
  m="$(mkrun hook-base-target)"
  printf '#!/bin/sh\necho "base=${BASE_SHA} target=${TARGET_URL}"\n' > "${m}/run/regression"
  chmod 755 "${m}/run/regression"
  # act
  status=0
  (cd "${m}" && env STEP=regression BASE_SHA=abc123 TARGET_URL=https://staging.example.com sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  # assert
  check_status "hook base sha and target url run" "${status}" 0
  check_has "hook receives BASE_SHA and TARGET_URL" "${WORK}/out" "base=abc123 target=https://staging.example.com"
}

hook_verify_writes_release_url() {
  # arrange
  m="$(mkmodule hook-release-url)"
  printf '#!/bin/sh\necho "release_url=https://r1.example.com" >> "${GITHUB_OUTPUT}"\n' > "${m}/ci/deploy/verify.sh"
  : > "${WORK}/gho-release"
  # act
  status=0
  (cd "${m}" && env STEP=verify GITHUB_OUTPUT="${WORK}/gho-release" sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  # assert
  check_status "hook verify release_url run" "${status}" 0
  check_has "hook verify output carries release_url" "${WORK}/gho-release" "release_url=https://r1.example.com"
}

step_declares_promote_inputs_and_output() {
  # arrange
  expr='import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
i = d["inputs"]
print("base-sha=" + str("base-sha" in i))
print("target-url=" + str("target-url" in i))
for s in d["runs"]["steps"]:
    if s.get("id") == "hook":
        e = s.get("env", {})
        print("BASE_SHA=" + str(e.get("BASE_SHA", "MISSING")))
        print("TARGET_URL=" + str(e.get("TARGET_URL", "MISSING")))
print("release_url=" + str(d.get("outputs", {}).get("release_url", {}).get("value", "MISSING")))'
  # act
  got="$(yaml_eval "${expr}" "${STEP_ACTION}")"
  printf '%s\n' "${got}" > "${WORK}/step-promote"
  # assert
  check_has "step declares base-sha input" "${WORK}/step-promote" "base-sha=True"
  check_has "step declares target-url input" "${WORK}/step-promote" "target-url=True"
  check_has "step exports BASE_SHA to the hook" "${WORK}/step-promote" 'BASE_SHA=${{ inputs.base-sha }}'
  check_has "step exports TARGET_URL to the hook" "${WORK}/step-promote" 'TARGET_URL=${{ inputs.target-url }}'
  check_has "step exposes release_url output" "${WORK}/step-promote" 'release_url=${{ steps.hook.outputs.release_url }}'
}

hook_receives_previous_tag() {
  # arrange
  m="$(mkmodule hook-previous)"
  printf '#!/bin/sh\necho "prev=${PREVIOUS_TAG}"\n' > "${m}/ci/deploy/deployment.sh"
  # act
  status=0
  (cd "${m}" && env STEP=deployment PREVIOUS_TAG=core.20260101.1 sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  # assert
  check_status "hook previous tag run" "${status}" 0
  check_has "hook script receives PREVIOUS_TAG" "${WORK}/out" "prev=core.20260101.1"
}

step_declares_sentry_release_input() {
  # arrange
  expr='import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
i = d.get("inputs", {}).get("sentry-release")
print("MISSING" if i is None else repr(i.get("default")) + " " + str(i.get("required", False)))'
  # act
  got="$(yaml_eval "${expr}" "${STEP_ACTION}")"
  # assert
  if [ "${got}" = "'' False" ]; then ok "step declares optional sentry-release input"; else ko "step declares optional sentry-release input: got '${got}'"; fi
}

step_exports_sentry_release_to_hook() {
  # arrange
  expr='import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for s in d["runs"]["steps"]:
    if s.get("id") == "hook":
        print(s.get("env", {}).get("SENTRY_RELEASE", "MISSING"))'
  # act
  got="$(yaml_eval "${expr}" "${STEP_ACTION}")"
  # assert
  if [ "${got}" = '${{ inputs.sentry-release }}' ]; then ok "step exports SENTRY_RELEASE to the hook"; else ko "step exports SENTRY_RELEASE to the hook: got '${got}'"; fi
}

hook_receives_sentry_release() {
  # arrange
  m="$(mkmodule hook-sentry-release)"
  printf '#!/bin/sh\necho "sr=${SENTRY_RELEASE} tag=${TAG}"\n' > "${m}/ci/checks/build.sh"
  # act
  status=0
  (cd "${m}" && env STEP=build TAG=core.2026-11-21.001 SENTRY_RELEASE=has_warranty@core.2026-11-21.001 sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  # assert
  check_status "hook sentry release run" "${status}" 0
  check_has "hook script receives SENTRY_RELEASE and TAG" "${WORK}/out" "sr=has_warranty@core.2026-11-21.001 tag=core.2026-11-21.001"
}

hook_sentry_release_empty_without_input() {
  # arrange
  m="$(mkmodule hook-sentry-release-empty)"
  printf '#!/bin/sh\necho "sr=[${SENTRY_RELEASE-}]"\n' > "${m}/ci/checks/build.sh"
  # act
  status=0
  (cd "${m}" && env -u SENTRY_RELEASE STEP=build TAG=core.2026-11-21.001 sh "${HOOK}") >"${WORK}/out" 2>"${WORK}/err" || status=$?
  # assert
  check_status "hook without sentry release run" "${status}" 0
  check_has "hook script sees SENTRY_RELEASE empty" "${WORK}/out" "sr=[]"
}

build_sentry_dump() {
  python3 -I -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
i = d.get("on", d.get(True))["workflow_call"]["inputs"]
for n in ("sentry_org", "sentry_project", "sentry_url"):
    v = i.get(n)
    print(n + "=" + ("MISSING" if v is None else repr(v.get("default")) + " " + str(v.get("type")) + " " + str(v.get("required", False))))
j = d["jobs"]
im = next((s for s in j["image"]["steps"] if str(s.get("uses", "")).startswith("br4zz4/pipelines/actions/step@")), {})
print("image_sentry_release=" + str((im.get("with") or {}).get("sentry-release")))
names = [s.get("name") for s in j["release"]["steps"]]
print("release_steps=" + " ".join(str(n) for n in names))
sr = next((s for s in j["release"]["steps"] if s.get("name") == "sentry-release"), {})
w = sr.get("with") or {}
print("sr_uses=" + str(sr.get("uses")))
print("sr_if=" + str(sr.get("if")))
for k in ("command", "org", "project", "url", "tag", "vault", "token"):
    print("sr_" + k + "=" + str(w.get(k)))' "${BUILD_WORKFLOW}" > "${WORK}/build-sentry" 2>/dev/null || true
}

build_sentry_release() {
  # arrange
  build_sentry_dump
  d="${WORK}/build-sentry"
  # assert
  check_has "build declares sentry_org" "${d}" "sentry_org='' string False"
  check_has "build declares sentry_project" "${d}" "sentry_project='' string False"
  check_has "build declares sentry_url" "${d}" "sentry_url='' string False"
  check_has "build image passes sentry-release" "${d}" "image_sentry_release=\${{ inputs.sentry_org != '' && format('{0}@{1}', inputs.sentry_project, inputs.tag) || '' }}"
  check_has "build release has the sentry-release step after stamp" "${d}" "release_steps=checkout secrets stamp sentry-release"
  check_has "build sentry-release uses the action" "${d}" "sr_uses=br4zz4/pipelines/actions/sentry-release@v2"
  check_has "build sentry-release only with sentry_org" "${d}" "sr_if=inputs.sentry_org != ''"
  check_has "build sentry-release command" "${d}" "sr_command=release"
  check_has "build sentry-release org" "${d}" "sr_org=\${{ inputs.sentry_org }}"
  check_has "build sentry-release project" "${d}" "sr_project=\${{ inputs.sentry_project }}"
  check_has "build sentry-release url" "${d}" "sr_url=\${{ inputs.sentry_url }}"
  check_has "build sentry-release tag" "${d}" "sr_tag=\${{ inputs.tag }}"
  check_has "build sentry-release vault" "${d}" "sr_vault=\${{ inputs.vault }}"
  check_has "build sentry-release token from env" "${d}" "sr_token=\${{ env.SENTRY_AUTH_TOKEN }}"
}

build_sentry_release_expression_without_key() {
  # arrange
  build_sentry_dump
  expr="$(grep '^image_sentry_release=' "${WORK}/build-sentry" | cut -d= -f2-)"
  # act
  got="$(python3 -I -c 'import sys
e = sys.argv[1].strip()
print("RESOLVES_EMPTY" if e.startswith("${{ inputs.sentry_org != \x27\x27 &&") and e.endswith("|| \x27\x27 }}") else "NO")' "${expr}")"
  # assert
  if [ "${got}" = "RESOLVES_EMPTY" ]; then ok "build image sentry-release is empty without sentry_org"; else ko "build image sentry-release is empty without sentry_org: '${expr}'"; fi
}

deploy_sentry_dump() {
  python3 -I -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
i = d.get("on", d.get(True))["workflow_call"]["inputs"]
for n in ("sentry_org", "sentry_project", "sentry_url"):
    v = i.get(n)
    print(n + "=" + ("MISSING" if v is None else repr(v.get("default")) + " " + str(v.get("type")) + " " + str(v.get("required", False))))
steps = d["jobs"]["record"]["steps"]
print("record_steps=" + " ".join(str(s.get("name")) for s in steps))
by = {s.get("name"): s for s in steps}
print("record_uses=" + str(by.get("record", {}).get("uses")))
print("rollback_if=" + str(by.get("rollback", {}).get("if")))
print("record_if=" + str(by.get("record", {}).get("if")))
co = by.get("checkout", {})
cw = co.get("with") or {}
print("checkout_uses=" + str(co.get("uses")))
print("checkout_if=" + str(co.get("if")))
for k in ("ref", "submodules", "persist-credentials"):
    print("checkout_" + k + "=" + str(cw.get(k)))
se = by.get("secrets", {})
sw = se.get("with") or {}
print("secrets_uses=" + str(se.get("uses")))
print("secrets_if=" + str(se.get("if")))
for k in ("vault", "key", "scopes"):
    print("secrets_" + k + "=" + str(sw.get(k)).strip())
sr = by.get("sentry-release", {})
w = sr.get("with") or {}
print("sr_uses=" + str(sr.get("uses")))
print("sr_if=" + str(sr.get("if")))
for k in ("command", "org", "project", "url", "tag", "environment", "app_url", "vault", "token"):
    print("sr_" + k + "=" + str(w.get(k)))' "${DEPLOY_WORKFLOW}" > "${WORK}/deploy-sentry" 2>/dev/null || true
}

deploy_sentry_mark() {
  # arrange
  deploy_sentry_dump
  d="${WORK}/deploy-sentry"
  cond="inputs.sentry_org != '' && needs.verify.result == 'success'"
  # assert
  check_has "deploy declares sentry_org" "${d}" "sentry_org='' string False"
  check_has "deploy declares sentry_project" "${d}" "sentry_project='' string False"
  check_has "deploy declares sentry_url" "${d}" "sentry_url='' string False"
  check_has "record keeps its steps and adds the sentry ones after" "${d}" "record_steps=record rollback promote checkout secrets sentry-release"
  check_has "record step is unchanged" "${d}" "record_uses=br4zz4/pipelines/actions/record@v2"
  check_has "record step has no condition" "${d}" "record_if=None"
  check_has "rollback condition is unchanged" "${d}" "rollback_if=\${{ !cancelled() && inputs.rollback_of == '' && (needs.deployment.result == 'failure' || needs.migrate.result == 'failure' || needs.rollout.result == 'failure' || needs.verify.result == 'failure') }}"
  check_has "deploy checkout uses checkout" "${d}" "checkout_uses=actions/checkout@v7"
  check_has "deploy checkout only with key and green verify" "${d}" "checkout_if=${cond}"
  check_has "deploy checkout ref" "${d}" "checkout_ref=\${{ inputs.tag }}"
  check_has "deploy checkout submodules" "${d}" "checkout_submodules=recursive"
  check_has "deploy checkout does not persist credentials" "${d}" "checkout_persist-credentials=False"
  check_has "deploy secrets uses setup-ward" "${d}" "secrets_uses=br4zz4/setup-ward@v1"
  check_has "deploy secrets only with key and green verify" "${d}" "secrets_if=${cond}"
  check_has "deploy secrets vault" "${d}" "secrets_vault=\${{ inputs.vault }}"
  check_has "deploy secrets key" "${d}" "secrets_key=\${{ secrets.WARD_KEY }}"
  check_has "deploy secrets scope is ci.common" "${d}" "secrets_scopes=\${{ inputs.vault }}:secrets.ci.common"
  check_has "deploy sentry-release uses the action" "${d}" "sr_uses=br4zz4/pipelines/actions/sentry-release@v2"
  check_has "deploy sentry-release only with key and green verify" "${d}" "sr_if=${cond}"
  check_has "deploy sentry-release command" "${d}" "sr_command=deploy"
  check_has "deploy sentry-release org" "${d}" "sr_org=\${{ inputs.sentry_org }}"
  check_has "deploy sentry-release project" "${d}" "sr_project=\${{ inputs.sentry_project }}"
  check_has "deploy sentry-release url" "${d}" "sr_url=\${{ inputs.sentry_url }}"
  check_has "deploy sentry-release tag" "${d}" "sr_tag=\${{ inputs.tag }}"
  check_has "deploy sentry-release environment" "${d}" "sr_environment=\${{ inputs.environment }}"
  check_has "deploy sentry-release app_url from verify" "${d}" "sr_app_url=\${{ needs.verify.outputs.url }}"
  check_has "deploy sentry-release vault" "${d}" "sr_vault=\${{ inputs.vault }}"
  check_has "deploy sentry-release token from env" "${d}" "sr_token=\${{ env.SENTRY_AUTH_TOKEN }}"
}

deploy_sentry_skipped_without_key() {
  # arrange
  deploy_sentry_dump
  d="${WORK}/deploy-sentry"
  # act
  got="$(python3 -I -c 'import sys
bad = []
for l in open(sys.argv[1]):
    k, _, v = l.rstrip("\n").partition("=")
    if k in ("checkout_if", "secrets_if", "sr_if") and not v.startswith("inputs.sentry_org != \x27\x27 &&"):
        bad.append(k)
print("ALL_SKIPPED" if not bad and open(sys.argv[1]).read().count("_if=inputs.sentry_org") == 3 else "NO " + " ".join(bad))' "${d}")"
  # assert
  if [ "${got}" = "ALL_SKIPPED" ]; then ok "deploy sentry steps are skipped without sentry_org"; else ko "deploy sentry steps are skipped without sentry_org: ${got}"; fi
}

hook_runs_script
hook_runs_non_executable
hook_runs_executable
hook_propagates_exit
hook_exports_cache_dir
hook_missing_script
TAG="${ROOT}/actions/tag/tag.sh"
TAG_ZONE="America/Sao_Paulo"
TAG_DAY="$(TZ="${TAG_ZONE}" date +%Y-%m-%d)"

tag_repo() {
  t="$(new_dir "tag-${1}")"
  git init -q --bare "${t}/origin.git"
  git init -q "${t}/work"
  (
    cd "${t}/work" || exit 1
    git config user.email fixture@example.com
    git config user.name fixture
    git config commit.gpgsign false
    git config tag.gpgsign false
    git commit -q --allow-empty -m base
    git remote add origin "${t}/origin.git"
  )
  echo "${t}"
}

tag_run() {
  : > "${1}/out"
  : > "${1}/gh"
  tag_status=0
  (cd "${1}/work" && env PREFIX=core ZONE="${TAG_ZONE}" GITHUB_OUTPUT="${1}/gh" sh "${TAG}") >"${1}/out" 2>"${1}/err" || tag_status=$?
}

tag_expect() {
  got="$(cat "${1}/out")"
  if [ "${tag_status}" -eq 0 ] && [ "${got}" = "${2}" ]; then ok "${3}"; else ko "${3}: status ${tag_status}, expected '${2}', got '${got}'"; fi
}

tag_build_local_reserves() {
  # arrange
  t="$(tag_repo build-local)"
  (cd "${t}/work" && git tag "build/core.${TAG_DAY}.001")
  # act
  tag_run "${t}"
  # assert
  tag_expect "${t}" "core.${TAG_DAY}.002" "tag skips a number reserved by a local build tag"
  check_has "tag output omits build prefix" "${t}/gh" "tag=core.${TAG_DAY}.002"
  check_lacks "tag output has no build/ in stdout" "${t}/out" "build/"
  check_lacks "tag output has no build/ in GITHUB_OUTPUT" "${t}/gh" "build/"
}

tag_build_remote_reserves() {
  # arrange
  t="$(tag_repo build-remote)"
  (cd "${t}/work" && git tag "build/core.${TAG_DAY}.001" && git push -q origin "refs/tags/build/core.${TAG_DAY}.001" && git tag -d "build/core.${TAG_DAY}.001" >/dev/null)
  # act
  tag_run "${t}"
  # assert
  tag_expect "${t}" "core.${TAG_DAY}.002" "tag skips a number reserved by a remote-only build tag"
}

tag_build_remote_loop_skips() {
  # arrange
  t="$(tag_repo build-loop)"
  (cd "${t}/work" && for n in 001 002 003; do git tag "build/core.${TAG_DAY}.${n}" && git push -q origin "refs/tags/build/core.${TAG_DAY}.${n}" && git tag -d "build/core.${TAG_DAY}.${n}" >/dev/null; done)
  # act
  tag_run "${t}"
  # assert
  tag_expect "${t}" "core.${TAG_DAY}.004" "tag skips consecutive remote-only build tags"
}

tag_release_and_build_max() {
  # arrange
  t="$(tag_repo mixed)"
  (cd "${t}/work" && git tag "core.${TAG_DAY}.002" && git tag "build/core.${TAG_DAY}.005")
  # act
  tag_run "${t}"
  # assert
  tag_expect "${t}" "core.${TAG_DAY}.006" "tag takes the highest of releases and build tags"
}

tag_release_only() {
  # arrange
  t="$(tag_repo release-only)"
  (cd "${t}/work" && git tag "core.${TAG_DAY}.001")
  # act
  tag_run "${t}"
  # assert
  tag_expect "${t}" "core.${TAG_DAY}.002" "tag still counts plain release tags"
}

tag_fresh_day() {
  # arrange
  t="$(tag_repo fresh)"
  # act
  tag_run "${t}"
  # assert
  tag_expect "${t}" "core.${TAG_DAY}.001" "tag starts at 001"
}

tag_other_prefix_ignored() {
  # arrange
  t="$(tag_repo other-prefix)"
  (cd "${t}/work" && git tag "build/gateway.${TAG_DAY}.007")
  # act
  tag_run "${t}"
  # assert
  tag_expect "${t}" "core.${TAG_DAY}.001" "tag ignores build tags of other modules"
}

tag_four_digits() {
  # arrange
  t="$(tag_repo four-digits)"
  (cd "${t}/work" && git tag "build/core.${TAG_DAY}.0999")
  # act
  tag_run "${t}"
  # assert
  tag_expect "${t}" "core.${TAG_DAY}.1000" "tag rolls 0999 to 1000 on build tags"
}

tag_remote_run() {
  : > "${1}/out"
  : > "${1}/gh"
  : > "${1}/err"
  tag_status=0
  (cd "${1}/work" && env PREFIX=core ZONE="${TAG_ZONE}" TAG_REMOTE="${2}" GITHUB_OUTPUT="${1}/gh" sh "${TAG}") >"${1}/out" 2>"${1}/err" || tag_status=$?
}

tag_remote_override() {
  # arrange
  t="$(tag_repo remote-override)"
  git init -q --bare "${t}/other.git"
  (cd "${t}/work" && git tag "build/core.${TAG_DAY}.001" && git push -q "${t}/other.git" "refs/tags/build/core.${TAG_DAY}.001" && git tag -d "build/core.${TAG_DAY}.001" >/dev/null)
  # act
  tag_remote_run "${t}" "${t}/other.git"
  # assert
  tag_expect "${t}" "core.${TAG_DAY}.002" "tag skips a name taken on TAG_REMOTE but free on origin"
}

tag_remote_override_ignores_origin() {
  # arrange
  t="$(tag_repo remote-ignores-origin)"
  git init -q --bare "${t}/other.git"
  (cd "${t}/work" && git tag "build/core.${TAG_DAY}.001" && git push -q origin "refs/tags/build/core.${TAG_DAY}.001" && git tag -d "build/core.${TAG_DAY}.001" >/dev/null)
  # act
  tag_remote_run "${t}" "${t}/other.git"
  # assert
  tag_expect "${t}" "core.${TAG_DAY}.001" "tag with TAG_REMOTE does not consult origin"
}

tag_remote_invalid_fails() {
  # arrange
  t="$(tag_repo remote-invalid)"
  # act
  tag_remote_run "${t}" "${t}/does-not-exist.git"
  # assert
  check_nonzero "tag fails when the remote cannot be listed" "${tag_status}"
  check_has "tag reports the listing failure" "${t}/out" "could not list the tags of the remote"
  check_lacks "tag does not fall back to .001 on a broken remote" "${t}/out" "core.${TAG_DAY}.001"
  check_lacks "tag writes no output on a broken remote" "${t}/gh" "tag="
}

target_declares_reuse_output() {
  # arrange
  got="$(python3 -I -c 'import sys, yaml
a = yaml.safe_load(open(sys.argv[1]))
print("reuse=" + str(a["outputs"].get("reuse", {}).get("value")))' "${ROOT}/actions/target/action.yml" 2>/dev/null)"
  # assert
  case "${got}" in *'reuse=${{ steps.target.outputs.reuse }}'*) ok "target action declares the reuse output";; *) ko "target action declares the reuse output: '${got}'";; esac
}

RESOLVE="${ROOT}/actions/resolve/resolve.py"

resolve_gh() {
  mkdir -p "${1}/bin"
  cat > "${1}/bin/gh" <<'GH'
#!/bin/sh
echo "$2" >> "${GH_CALLS}"
case "$2" in
  *"/statuses"*) echo '[{"state":"success"}]' ;;
  *"&page=1") python3 -I -c 'import json
print(json.dumps([{"id": 1000 + i, "payload": {"module": "other", "tag": "other.%d" % i}} for i in range(100)]))' ;;
  *"&page=2") echo '[{"id":7,"payload":{"module":"core","tag":"core.2026-11-21.001"}}]' ;;
  *) echo '[]' ;;
esac
GH
  chmod 755 "${1}/bin/gh"
}

resolve_run() {
  : > "${1}/out"
  : > "${1}/calls"
  resolve_status=0
  PATH="${1}/bin:${PATH}" GH_CALLS="${1}/calls" GITHUB_OUTPUT="${1}/out" GITHUB_REPOSITORY=o/r GH_TOKEN=t \
    INPUT_ENVIRONMENT=staging INPUT_MODULE="${2}" INPUT_TAG="${3}" python3 -I "${RESOLVE}" >"${1}/log" 2>&1 || resolve_status=$?
}

resolve_paginates() {
  # arrange
  t="$(new_dir resolve-pages)"
  resolve_gh "${t}"
  # act
  resolve_run "${t}" core core.2026-11-21.001
  # assert
  check_status "resolve finds a tag beyond the first page" "${resolve_status}" 0
  check_has "resolve outputs the tag from page 2" "${t}/out" "tag=core.2026-11-21.001"
  check_has "resolve asked for page 2" "${t}/calls" "&page=2"
}

resolve_first_page_wins() {
  # arrange
  t="$(new_dir resolve-first)"
  mkdir -p "${t}/bin"
  cat > "${t}/bin/gh" <<'GH'
#!/bin/sh
echo "$2" >> "${GH_CALLS}"
case "$2" in
  *"/statuses"*) echo '[{"state":"success"}]' ;;
  *"&page=1") python3 -I -c 'import json
rows = [{"id": 1000 + i, "payload": {"module": "other", "tag": "other.%d" % i}} for i in range(99)]
rows.insert(3, {"id": 9, "payload": {"module": "core", "tag": "core.2026-11-21.005"}})
print(json.dumps(rows))' ;;
  *) echo '[{"id":7,"payload":{"module":"core","tag":"core.2026-11-21.001"}}]' ;;
esac
GH
  chmod 755 "${t}/bin/gh"
  # act
  resolve_run "${t}" core ""
  # assert
  check_status "resolve without tag succeeds" "${resolve_status}" 0
  check_has "resolve returns the newest green on page 1" "${t}/out" "tag=core.2026-11-21.005"
  check_lacks "resolve does not ask for page 2 once found" "${t}/calls" "&page=2"
}

NOTIFY_ACTION="${ROOT}/actions/notify/action.yml"

notify_detail_in_message_and_summary() {
  # arrange
  n="$(new_dir notify-detail)"
  mv "$(mkcurl notify-detail-bin)" "${n}/bin"
  # act
  run_notify "${n}" "STATUS=failed" "DETAIL=rolling back to api-v1.2.2"
  # assert
  check_status "notify detail exit" "$(cat "${n}/status")" 0
  check_has "notify detail in message" "${n}/out" "failed (rolling back to api-v1.2.2)"
  check_has "notify detail in summary" "${n}/summary" "failed (rolling back to api-v1.2.2)"
}

notify_without_detail_is_unchanged() {
  # arrange
  n="$(new_dir notify-nodetail)"
  mv "$(mkcurl notify-nodetail-bin)" "${n}/bin"
  # act
  run_notify "${n}" "STATUS=failed"
  # assert
  check_status "notify without detail exit" "$(cat "${n}/status")" 0
  check_has "notify without detail message" "${n}/out" "-> staging: failed. https://github.com/acme/app/actions/runs/1"
  check_lacks "notify without detail message has no parens" "${n}/out" "("
  check_has "notify without detail summary" "${n}/summary" "failed — [run]"
  check_lacks "notify without detail summary has no detail" "${n}/summary" "failed ("
}

notify_action_declares_detail() {
  # arrange
  got="$(python3 -I -c 'import sys, yaml
a = yaml.safe_load(open(sys.argv[1]))
i = a["inputs"].get("detail")
print("MISSING" if i is None else "required=" + str(i.get("required", False)))
print("env=" + str(a["runs"]["steps"][0]["env"].get("DETAIL")))' "${NOTIFY_ACTION}" 2>/dev/null)"
  # assert
  case "${got}" in *"required=False"*) ok "notify action declares detail as optional";; *) ko "notify action declares detail as optional: '${got}'";; esac
  case "${got}" in *'env=${{ inputs.detail }}'*) ok "notify action passes detail to DETAIL";; *) ko "notify action passes detail to DETAIL: '${got}'";; esac
}

notify_kind_case() {
  label="${1}"
  status_value="${2}"
  marker="${3}"
  kind_value="${4}"
  expected="${5}"
  # arrange
  n="$(new_dir "notify-kind-${label}")"
  mv "$(mkcurl "notify-kind-${label}-bin")" "${n}/bin"
  # act
  run_notify "${n}" "STATUS=${status_value}" ${kind_value:+KIND="${kind_value}"}
  # assert
  check_status "notify kind ${label} exit" "$(cat "${n}/status")" 0
  check_has "notify kind ${label} message" "${n}/out" "${expected}"
  check_has "notify kind ${label} summary heading" "${n}/summary" "${expected%: *}"
  for f in out summary; do
    check_has "notify kind ${label} ${f} marker" "${n}/${f}" "${marker}"
  done
}

notify_promote_markers_distinct() {
  # arrange
  n="$(new_dir notify-promote-markers)"
  mv "$(mkcurl notify-promote-markers-bin)" "${n}/bin"
  # act
  run_notify "${n}" "STATUS=promoted" KIND=promote
  # assert
  check_lacks "notify promoted has no superseded marker" "${n}/out" "⏭️"
  check_lacks "notify promoted has no capped marker" "${n}/out" "⛔"
  check_lacks "notify promoted has no failed marker" "${n}/out" "❌"
  run_notify "${n}" "STATUS=superseded" KIND=promote
  check_lacks "notify superseded has no promoted marker" "${n}/out" "🚀"
  check_lacks "notify superseded has no capped marker" "${n}/out" "⛔"
  run_notify "${n}" "STATUS=capped" KIND=promote
  check_lacks "notify capped has no promoted marker" "${n}/out" "🚀"
  check_lacks "notify capped has no superseded marker" "${n}/out" "⏭️"
}

notify_kind_defaults_to_deploy() {
  # arrange
  n="$(new_dir notify-kind-default)"
  mv "$(mkcurl notify-kind-default-bin)" "${n}/bin"
  # act
  run_notify "${n}" "STATUS=ok"
  # assert
  check_has "notify without kind says deploy" "${n}/out" "deploy api api-v1.2.3 -> staging: ok"
  check_lacks "notify without kind does not say promote" "${n}/out" "promote api"
}

notify_invalid_status_with_promote_kind() {
  # arrange
  n="$(new_dir notify-kind-bad)"
  mv "$(mkcurl notify-kind-bad-bin)" "${n}/bin"
  # act
  run_notify "${n}" "STATUS=weird" KIND=promote
  # assert
  check_status "notify invalid status still fails with kind promote" "$(cat "${n}/status")" 1
}

notify_promote_annotation_levels() {
  # arrange
  n="$(new_dir notify-kind-annot)"
  mv "$(mkcurl notify-kind-annot-bin)" "${n}/bin"
  # act
  run_notify "${n}" "STATUS=failed" KIND=promote
  # assert
  check_has "notify promote failed is an error" "${n}/out" "::error title=promote api staging::"
  run_notify "${n}" "STATUS=promoted" KIND=promote
  check_has "notify promoted is a notice" "${n}/out" "::notice title=promote api staging::"
  check_lacks "notify promoted is not an error" "${n}/out" "::error"
}

notify_autofix_case() {
  label="${1}"
  status_value="${2}"
  marker="${3}"
  level="${4}"
  # arrange
  n="$(new_dir "notify-autofix-${label}")"
  mv "$(mkcurl "notify-autofix-${label}-bin")" "${n}/bin"
  # act
  run_notify "${n}" "STATUS=${status_value}" KIND=autofix ENVIRONMENT=issue TAG_INPUT="#12"
  # assert
  check_status "notify autofix ${label} exit" "$(cat "${n}/status")" 0
  check_has "notify autofix ${label} message" "${n}/out" "${marker} autofix api #12 -> issue: ${status_value}"
  check_has "notify autofix ${label} summary" "${n}/summary" "${marker} autofix api #12 -> issue"
  check_has "notify autofix ${label} level" "${n}/out" "::${level} title=autofix api issue::"
}

notify_autofix_markers_distinct() {
  # arrange
  n="$(new_dir notify-autofix-markers)"
  mv "$(mkcurl notify-autofix-markers-bin)" "${n}/bin"
  # act
  run_notify "${n}" "STATUS=opened" KIND=autofix ENVIRONMENT=issue TAG_INPUT="#12"
  # assert
  check_lacks "notify opened has no gave up marker" "${n}/out" "🏳️"
  check_lacks "notify opened has no rejected marker" "${n}/out" "🚫"
  check_lacks "notify opened has no failed marker" "${n}/out" "❌"
  run_notify "${n}" "STATUS=gave up" KIND=autofix ENVIRONMENT=issue TAG_INPUT="#12"
  check_lacks "notify gave up has no opened marker" "${n}/out" "🔧"
  check_lacks "notify gave up has no rejected marker" "${n}/out" "🚫"
  run_notify "${n}" "STATUS=rejected" KIND=autofix ENVIRONMENT=issue TAG_INPUT="#12"
  check_lacks "notify rejected has no opened marker" "${n}/out" "🔧"
  check_lacks "notify rejected has no gave up marker" "${n}/out" "🏳️"
}

notify_autofix_invalid_status() {
  # arrange
  n="$(new_dir notify-autofix-bad)"
  mv "$(mkcurl notify-autofix-bad-bin)" "${n}/bin"
  # act
  run_notify "${n}" "STATUS=weird" KIND=autofix ENVIRONMENT=issue TAG_INPUT="#12"
  # assert
  check_status "notify invalid status still fails with kind autofix" "$(cat "${n}/status")" 1
}

notify_autofix_failed_is_error() {
  # arrange
  n="$(new_dir notify-autofix-failed)"
  mv "$(mkcurl notify-autofix-failed-bin)" "${n}/bin"
  # act
  run_notify "${n}" "STATUS=failed" KIND=autofix ENVIRONMENT=issue TAG_INPUT="#12"
  # assert
  check_status "notify autofix failed exit" "$(cat "${n}/status")" 0
  check_has "notify autofix failed is an error" "${n}/out" "::error title=autofix api issue::"
}

AUTOFIX_WORKFLOW="${ROOT}/.github/workflows/autofix.yml"

autofix_dump() {
  python3 -I -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
j = d["jobs"]
on = d.get("on", d.get(True))
wc = on["workflow_call"]
print("jobs=" + " ".join(j))
for k in ("vault", "issue", "event", "sender", "max_per_day", "modules"):
    i = wc["inputs"].get(k)
    print("input_" + k + "=" + ("MISSING" if i is None else str(i.get("type")) + " " + str(i.get("default"))))
print("secrets=" + " ".join(sorted(wc.get("secrets") or {})))
def steps(n):
    return j.get(n, {}).get("steps", [])
for n, v in j.items():
    needs = v.get("needs")
    needs = [needs] if isinstance(needs, str) else sorted(needs or [])
    print(n + "_needs=" + " ".join(needs))
    print(n + "_if=" + str(v.get("if")))
    print(n + "_name=" + str(v.get("name")))
    print(n + "_timeout=" + str(v.get("timeout-minutes")))
    print(n + "_permissions=" + str(sorted((v.get("permissions") or {}).items())))
    print(n + "_environment=" + str("environment" in v))
    print(n + "_matrix=" + str("matrix" in (v.get("strategy") or {})))
    print(n + "_outputs=" + " ".join(sorted(v.get("outputs") or {})))
    print(n + "_unnamed=" + str(sum(1 for s in v.get("steps", []) if not s.get("name"))))
    print(n + "_uses=" + " ".join(s.get("uses", "-") for s in v.get("steps", [])))
    print(n + "_stepnames=" + "|".join(str(s.get("name")) for s in v.get("steps", [])))
    print(n + "_services=" + " ".join(sorted(v.get("services") or {})))
for n in ("select", "fix", "verify", "publish"):
    for s in steps(n):
        u = s.get("uses", "")
        w = s.get("with") or {}
        if u.startswith("actions/upload-artifact"):
            print(n + "_upload_" + str(w.get("name")) + "_if=" + str(s.get("if")))
            print(n + "_upload_" + str(w.get("name")) + "_path=" + " ".join(str(w.get("path")).split()))
        if u.startswith("actions/download-artifact"):
            print(n + "_download_" + str(w.get("name")))
        if u.startswith("actions/checkout"):
            print(n + "_checkout_persist=" + str(w.get("persist-credentials")))
for s in steps("select"):
    if s.get("uses", "").startswith("br4zz4/pipelines/actions/issue"):
        print("select_issue_id=" + str(s.get("id")))
        print("select_issue_token=" + str((s.get("with") or {}).get("token")))
for s in steps("fix"):
    if s.get("uses", "").startswith("br4zz4/pipelines/actions/agent"):
        print("fix_agent_key=" + str((s.get("with") or {}).get("key")))
for s in steps("verify"):
    u = s.get("uses", "")
    w = s.get("with") or {}
    tag = str(s.get("name")) + ":" + u.split("@")[0].replace("br4zz4/pipelines/", "") + ":" + str(w.get("command")) + str(w.get("scope", "")) 
    print("verify_step=" + tag + " id=" + str(s.get("id")) + " coe=" + str(s.get("continue-on-error")) + " export=" + str(w.get("export-key")) + " step=" + str(w.get("step")) + " env=" + str(w.get("environment")))
    if w.get("scopes"):
        print("verify_scopes=" + " ".join(str(w["scopes"]).split()))
    if "red" in str(s.get("name")) and s.get("run"):
        print("verify_red_check_if=" + str(s.get("if")))
        print("verify_red_check_run=" + str(s.get("run")))
    if s.get("id") == "reason":
        e = s.get("env") or {}
        print("verify_reason_env=" + " ".join(k + "=" + str(v) for k, v in sorted(e.items())))
        print("verify_reason_run=" + " ".join(str(s.get("run")).split()))
for s in steps("publish"):
    u = s.get("uses", "")
    w = s.get("with") or {}
    if u.startswith("br4zz4/pipelines/actions/publish"):
        for k, v in sorted(w.items()):
            print("publish_with_" + k + "=" + str(v))
    if u.startswith("br4zz4/pipelines/actions/notify"):
        print("notify_if=" + str(s.get("if")))
        for k, v in sorted(w.items()):
            print("notify_with_" + k + "=" + str(v))
    if u.startswith("br4zz4/setup-ward"):
        print("publish_ward_scopes=" + " ".join(str((w.get("scopes"))).split()))
print("publish_last=" + (steps("publish")[-1].get("name") if steps("publish") else "none"))' "${AUTOFIX_WORKFLOW}" > "${WORK}/autofix-dump" 2>"${WORK}/autofix-err" || true
}

autofix_workflow_shape() {
  # arrange
  autofix_dump
  d="${WORK}/autofix-dump"
  # assert
  check_has "autofix declares the literal jobs" "${d}" "jobs=select fix verify publish"
  check_has "autofix input vault" "${d}" "input_vault=string"
  check_has "autofix input issue" "${d}" "input_issue=string"
  check_has "autofix input event" "${d}" "input_event=string"
  check_has "autofix input sender" "${d}" "input_sender=string"
  check_has "autofix input max_per_day number default 0" "${d}" "input_max_per_day=number 0"
  check_has "autofix input modules" "${d}" "input_modules=string"
  check_has "autofix secret WARD_KEY" "${d}" "secrets=WARD_KEY"
  for j in select fix verify publish; do
    check_has "autofix ${j} name is literal" "${d}" "${j}_name=${j}"
    check_has "autofix ${j} has no unnamed step" "${d}" "${j}_unnamed=0"
    check_has "autofix ${j} has no environment" "${d}" "${j}_environment=False"
    check_has "autofix ${j} has no matrix" "${d}" "${j}_matrix=False"
  done
}

autofix_select_job() {
  # arrange
  autofix_dump
  d="${WORK}/autofix-dump"
  # assert
  check_has "autofix select permissions" "${d}" "select_permissions=[('actions', 'read'), ('contents', 'read'), ('issues', 'write'), ('pull-requests', 'read')]"
  check_has "autofix select uses the issue action" "${d}" "select_uses=br4zz4/pipelines/actions/issue"
  check_has "autofix select outputs" "${d}" "select_outputs=code_dir issue module outcome reason services title url"
  check_has "autofix select issue token is github.token" "${d}" 'select_issue_token=${{ github.token }}'
  check_has "autofix select uploads the issue artifact" "${d}" "select_upload_issue_if="
  check_has "autofix select issue artifact path" "${d}" "select_upload_issue_path=.autofix/issue.json"
  check_has "autofix select uploads only when selected" "${d}" "outcome == 'selected'"
}

autofix_fix_job() {
  # arrange
  autofix_dump
  d="${WORK}/autofix-dump"
  # assert
  check_has "autofix fix needs select" "${d}" "fix_needs=select"
  check_has "autofix fix runs only when selected" "${d}" "fix_if=\${{ needs.select.outputs.outcome == 'selected' }}"
  check_has "autofix fix timeout is 30 minutes" "${d}" "fix_timeout=30"
  check_has "autofix fix permissions are contents read" "${d}" "fix_permissions=[('contents', 'read')]"
  check_has "autofix fix declares postgres and redis services" "${d}" "fix_services=postgres redis"
  check_has "autofix fix downloads the issue artifact" "${d}" "fix_download_issue"
  check_has "autofix fix calls the agent action" "${d}" "br4zz4/pipelines/actions/agent"
  check_has "autofix fix agent key is WARD_KEY" "${d}" 'fix_agent_key=${{ secrets.WARD_KEY }}'
  check_has "autofix fix uploads the autofix artifact always" "${d}" "fix_upload_autofix_if=\${{ always() }}"
  check_has "autofix fix artifact carries result and patch" "${d}" "fix_upload_autofix_path=.autofix/result.json .autofix/fix.patch"
  check_has "autofix fix outputs" "${d}" "fix_outputs=status summary"
}

autofix_verify_job() {
  # arrange
  autofix_dump
  d="${WORK}/autofix-dump"
  # assert
  check_has "autofix verify needs select and fix" "${d}" "verify_needs=fix select"
  check_has "autofix verify runs only when fixed" "${d}" "verify_if=\${{ needs.fix.outputs.status == 'fixed' }}"
  check_has "autofix verify permissions are contents read" "${d}" "verify_permissions=[('contents', 'read')]"
  check_has "autofix verify downloads the autofix artifact" "${d}" "verify_download_autofix"
  check_has "autofix verify outputs" "${d}" "verify_outputs=reason result"
  check_has "autofix verify scope patch step" "${d}" "id=scope coe=True"
  check_has "autofix verify red step runs with continue-on-error" "${d}" "id=red coe=True"
  check_has "autofix verify test step does not export the key" "${d}" "export=false step=test env=test"
  check_has "autofix verify lint step" "${d}" "step=lint"
  check_has "autofix verify red scopes ci.test" "${d}" ":secrets.ci.test"
  check_has "autofix verify red scopes module code.test" "${d}" "secrets.\${{ needs.select.outputs.module }}.code.test"
  check_has "autofix verify fails when the regression test passes before the fix" "${d}" "regression test passed before the fix"
  check_has "autofix verify red tests step has id red_tests" "${d}" "red tests:actions/patch:tests id=red_tests"
  check_has "autofix verify green patch step has id green_patch" "${d}" "green patch:actions/patch:full id=green_patch"
  check_has "autofix verify reason reads red_tests outcome" "${d}" 'RED_TESTS=${{ steps.red_tests.outcome }}'
  check_has "autofix verify reason reads green_patch outcome" "${d}" 'GREEN_PATCH=${{ steps.green_patch.outcome }}'
  check_has "autofix verify reason covers patch not applying" "${d}" 'GREEN_PATCH}" = failure'
  check_has "autofix verify reason has patch does not apply" "${d}" 'reason="patch does not apply"'
  check_has "autofix verify reason covers tests not applying" "${d}" 'RED_TESTS}" = failure'
  check_has "autofix verify reason has tests do not apply" "${d}" 'reason="tests do not apply"'
  check_has "autofix verify red check depends on red outcome" "${d}" "steps.red.outcome == 'success'"
}

autofix_verify_order() {
  # arrange
  autofix_dump
  names="$(grep '^verify_stepnames=' "${WORK}/autofix-dump" | cut -d= -f2-)"
  # assert
  got="$(printf '%s' "${names}" | python3 -I -c 'import sys
n = sys.stdin.read().split("|")
def i(x):
    m = [k for k, v in enumerate(n) if x in v]
    return m[0] if m else -1
scope, red, green = i("scope"), i("red"), i("green")
print("ordered" if -1 not in (scope, red, green) and scope < red < green else "unordered")' 2>&1)"
  case "${got}" in ordered) ok "autofix verify runs scope, red, green in order";; *) ko "autofix verify order: '${names}'";; esac
}

autofix_publish_job() {
  # arrange
  autofix_dump
  d="${WORK}/autofix-dump"
  # assert
  check_has "autofix publish needs select fix verify" "${d}" "publish_needs=fix select verify"
  check_has "autofix publish if always and not skipped" "${d}" "publish_if=\${{ always() && needs.select.outputs.outcome != 'skipped' && needs.select.outputs.issue != '' }}"
  check_has "autofix publish checkout does not persist credentials" "${d}" "publish_checkout_persist=False"
  check_has "autofix publish loads ci.common" "${d}" "publish_ward_scopes=\${{ inputs.vault }}:secrets.ci.common"
  check_has "autofix publish downloads the autofix artifact" "${d}" "publish_download_autofix"
  check_has "autofix publish select_outcome" "${d}" 'publish_with_select_outcome=${{ needs.select.outputs.outcome }}'
  check_has "autofix publish select_reason" "${d}" 'publish_with_select_reason=${{ needs.select.outputs.reason }}'
  check_has "autofix publish fix_status" "${d}" 'publish_with_fix_status=${{ needs.fix.outputs.status }}'
  check_has "autofix publish fix_summary" "${d}" 'publish_with_fix_summary=${{ needs.fix.outputs.summary }}'
  check_has "autofix publish verify_result" "${d}" 'publish_with_verify_result=${{ needs.verify.result }}'
  check_has "autofix publish verify_reason" "${d}" 'publish_with_verify_reason=${{ needs.verify.outputs.reason }}'
  check_has "autofix publish base_ref" "${d}" 'publish_with_base_ref=${{ github.ref_name }}'
  check_has "autofix publish token from env" "${d}" 'publish_with_token=${{ env.GH_PIPELINES_TOKEN }}'
  check_has "autofix publish run_url" "${d}" "publish_with_run_url="
  check_has "autofix publish uses publish then notify" "${d}" "br4zz4/pipelines/actions/publish"
}

autofix_notify_step() {
  # arrange
  autofix_dump
  d="${WORK}/autofix-dump"
  # assert
  check_has "autofix notify is the last publish step" "${d}" "publish_last=notify"
  check_has "autofix notify runs always" "${d}" "notify_if=\${{ always() }}"
  check_has "autofix notify kind" "${d}" "notify_with_kind=autofix"
  check_has "autofix notify environment is issue" "${d}" "notify_with_environment=issue"
  check_has "autofix notify module falls back to unknown when select resolved no module" "${d}" "notify_with_module=\${{ needs.select.outputs.module != '' && needs.select.outputs.module || 'unknown' }}"
  check_has "autofix notify tag carries the issue number" "${d}" 'notify_with_tag=#${{ needs.select.outputs.issue }}'
  check_has "autofix notify status reads the publish outcome" "${d}" "notify_with_status="
  check_has "autofix notify status falls back to failed" "${d}" "'failed'"
}

notify_action_declares_kind() {
  # arrange
  got="$(python3 -I -c 'import sys, yaml
a = yaml.safe_load(open(sys.argv[1]))
i = a["inputs"].get("kind")
print("MISSING" if i is None else "required=" + str(i.get("required", False)) + " default=" + str(i.get("default")))
print("env=" + str(a["runs"]["steps"][0]["env"].get("KIND")))' "${NOTIFY_ACTION}" 2>/dev/null)"
  # assert
  case "${got}" in *"required=False default=deploy"*) ok "notify action declares kind defaulting to deploy";; *) ko "notify action declares kind defaulting to deploy: '${got}'";; esac
  case "${got}" in *'env=${{ inputs.kind }}'*) ok "notify action passes kind to KIND";; *) ko "notify action passes kind to KIND: '${got}'";; esac
}

STAMP="${ROOT}/actions/stamp/stamp.sh"
STAMP_ACTION="${ROOT}/actions/stamp/action.yml"
STAMP_REPO="owner/repo"
STAMP_URL="https://x-access-token:tok@github.com/${STAMP_REPO}.git"

stamp_repo() {
  t="$(new_dir "stamp-${1}")"
  git init -q --bare "${t}/origin.git"
  git init -q "${t}/work"
  (
    cd "${t}/work" || exit 1
    git config user.email fixture@example.com
    git config user.name fixture
    git config commit.gpgsign false
    git config tag.gpgsign false
    git commit -q --allow-empty -m base
    git remote add origin "${t}/origin.git"
    git config "url.${t}/origin.git.insteadOf" "${STAMP_URL}"
    git tag "build/core.2026-01-01.001"
    git push -q origin "refs/tags/build/core.2026-01-01.001"
  )
  echo "${t}"
}

stamp_refuse_deletes() {
  mkdir -p "${1}/origin.git/hooks"
  cat > "${1}/origin.git/hooks/pre-receive" <<'HOOK'
#!/bin/sh
while read -r old new ref; do
  if [ "${new}" = "0000000000000000000000000000000000000000" ]; then exit 1; fi
done
HOOK
  chmod +x "${1}/origin.git/hooks/pre-receive"
}

stamp_run() {
  stamp_status=0
  (cd "${1}/work" && env TAG_INPUT="core.2026-01-01.001" GH_PIPELINES_TOKEN=tok GITHUB_REPOSITORY="${STAMP_REPO}" ${2:+BUILD_TAG="${2}"} sh "${STAMP}") >"${1}/out" 2>"${1}/err" || stamp_status=$?
}

stamp_remote_has() {
  git -C "${1}/origin.git" show-ref --verify --quiet "refs/tags/${2}"
}

stamp_deletes_build_tag() {
  # arrange
  t="$(stamp_repo delete)"
  # act
  stamp_run "${t}" "build/core.2026-01-01.001"
  # assert
  check_status "stamp with BUILD_TAG exits 0" "${stamp_status}" 0
  if stamp_remote_has "${t}" "core.2026-01-01.001"; then ok "stamp pushes the release tag"; else ko "stamp pushes the release tag"; fi
  if stamp_remote_has "${t}" "build/core.2026-01-01.001"; then ko "stamp deletes the build tag on the remote"; else ok "stamp deletes the build tag on the remote"; fi
  check_has "stamp reports the deleted build tag" "${t}/out" "deleted build/core.2026-01-01.001"
}

stamp_without_build_tag_keeps_it() {
  # arrange
  t="$(stamp_repo keep)"
  # act
  stamp_run "${t}"
  # assert
  check_status "stamp without BUILD_TAG exits 0" "${stamp_status}" 0
  if stamp_remote_has "${t}" "core.2026-01-01.001"; then ok "stamp without BUILD_TAG pushes the release tag"; else ko "stamp without BUILD_TAG pushes the release tag"; fi
  if stamp_remote_has "${t}" "build/core.2026-01-01.001"; then ok "stamp without BUILD_TAG leaves the build tag"; else ko "stamp without BUILD_TAG leaves the build tag"; fi
}

stamp_empty_build_tag_keeps_it() {
  # arrange
  t="$(stamp_repo empty)"
  # act
  stamp_status=0
  (cd "${t}/work" && env TAG_INPUT="core.2026-01-01.001" GH_PIPELINES_TOKEN=tok BUILD_TAG="" GITHUB_REPOSITORY="${STAMP_REPO}" sh "${STAMP}") >"${t}/out" 2>"${t}/err" || stamp_status=$?
  # assert
  check_status "stamp with empty BUILD_TAG exits 0" "${stamp_status}" 0
  if stamp_remote_has "${t}" "build/core.2026-01-01.001"; then ok "stamp with empty BUILD_TAG leaves the build tag"; else ko "stamp with empty BUILD_TAG leaves the build tag"; fi
}

stamp_delete_failure_warns() {
  # arrange
  t="$(stamp_repo warn)"
  stamp_refuse_deletes "${t}"
  # act
  stamp_run "${t}" "build/core.2026-01-01.001"
  # assert
  check_status "stamp exits 0 when the build tag cannot be deleted" "${stamp_status}" 0
  check_has "stamp warns when the build tag cannot be deleted" "${t}/out" "::warning::could not delete build/core.2026-01-01.001"
  if stamp_remote_has "${t}" "core.2026-01-01.001"; then ok "stamp keeps the release tag when the delete fails"; else ko "stamp keeps the release tag when the delete fails"; fi
  check_lacks "stamp delete failure is not an error" "${t}/out" "::error::"
}

stamp_action_declares_build_tag() {
  # arrange
  got="$(python3 -I -c 'import sys, yaml
a = yaml.safe_load(open(sys.argv[1]))
i = a["inputs"].get("build_tag")
print("MISSING" if i is None else "required=" + str(i.get("required", False)))
s = a["runs"]["steps"][0]["env"]
print("env=" + str(s.get("BUILD_TAG")))' "${STAMP_ACTION}" 2>/dev/null)"
  # assert
  case "${got}" in *"required=False"*) ok "stamp action declares build_tag as optional";; *) ko "stamp action declares build_tag as optional: '${got}'";; esac
  case "${got}" in *'env=${{ inputs.build_tag }}'*) ok "stamp action passes build_tag to BUILD_TAG";; *) ko "stamp action passes build_tag to BUILD_TAG: '${got}'";; esac
}

BUILD_WORKFLOW="${ROOT}/.github/workflows/build.yml"

build_dump() {
  python3 -I -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
j = d["jobs"]
print("jobs=" + " ".join(j))
for n in ("code", "infra", "image", "release"):
    v = j.get(n, {})
    needs = v.get("needs")
    needs = [needs] if isinstance(needs, str) else sorted(needs or [])
    print(n + "_needs=" + " ".join(needs))
    print(n + "_if=" + str(v.get("if")))
for n, v in j.items():
    print(n + "_environment=" + str("environment" in v))
    print(n + "_matrix=" + str("matrix" in (v.get("strategy") or {})))
for k, v in sorted((j["code"].get("with") or {}).items()):
    print("code_with_" + k + "=" + str(v))
print("input_reuse_default=" + repr(d.get("on", d.get(True))["workflow_call"]["inputs"].get("reuse", {}).get("default")))
print("image_persist=" + str(next((s.get("with") or {} for s in j["image"]["steps"] if s.get("uses", "").startswith("actions/checkout")), {}).get("persist-credentials")))
for k, v in sorted((j["infra"].get("with") or {}).items()):
    print("infra_with_" + k + "=" + str(v))
for n in ("reuse-code", "reuse-infra"):
    print(n + "_name=" + str(j.get(n, {}).get("name")))
    print(n + "_steps=" + " ".join(str(s.get("id")) for s in j.get(n, {}).get("steps", [])))
    print(n + "_outputs=" + " ".join(sorted(j.get(n, {}).get("outputs") or {})))
    for s in j.get(n, {}).get("steps", []):
        print(n + "_" + str(s.get("id")) + "_prefix=" + str((s.get("with") or {}).get("check_prefix")))
st = next((s for s in j["release"]["steps"] if s.get("name") == "stamp"), {})
print("stamp_build_tag=" + str((st.get("with") or {}).get("build_tag")))
print("stamp_tag=" + str((st.get("with") or {}).get("tag")))' "${BUILD_WORKFLOW}" > "${WORK}/build-dump" 2>/dev/null || true
}

build_workflow_shape() {
  # arrange
  build_dump
  d="${WORK}/build-dump"
  # assert
  check_has "build declares the literal jobs" "${d}" "jobs=reuse-code reuse-infra code infra image release"
  check_has "build code needs reuse-code" "${d}" "code_needs=reuse-code"
  check_has "build infra needs reuse-infra" "${d}" "infra_needs=reuse-infra"
  if [ "$(grep '^code_needs=' "${d}" | cut -d= -f2)" != "$(grep '^infra_needs=' "${d}" | cut -d= -f2)" ]; then ok "build code and infra have different needs"; else ko "build code and infra have different needs: $(grep '_needs=' "${d}")"; fi
  check_has "build reuse-code name" "${d}" "reuse-code_name=reuse / code"
  check_has "build reuse-infra name" "${d}" "reuse-infra_name=reuse / infra"
  check_has "build reuse-code steps" "${d}" "reuse-code_steps=reuse"
  check_has "build reuse-infra steps" "${d}" "reuse-infra_steps=reuse"
  check_has "build reuse-code outputs" "${d}" "reuse-code_outputs=audit lint test"
  check_has "build reuse-infra outputs" "${d}" "reuse-infra_outputs=plan validate"
  check_has "build code runs on inputs.code" "${d}" "code_if=\${{ inputs.code == 'true' }}"
  check_has "build infra runs on inputs.infra" "${d}" "infra_if=\${{ inputs.infra == 'true' }}"
  check_has "build code skips lint" "${d}" "code_with_skip_lint=\${{ inputs.reuse == 'true' && needs.reuse-code.outputs.lint || 'false' }}"
  check_has "build code skips audit" "${d}" "code_with_skip_audit=\${{ inputs.reuse == 'true' && needs.reuse-code.outputs.audit || 'false' }}"
  check_has "build code skips test" "${d}" "code_with_skip_test=\${{ inputs.reuse == 'true' && needs.reuse-code.outputs.test || 'false' }}"
  check_has "build infra skips validate" "${d}" "infra_with_skip_validate=\${{ inputs.reuse == 'true' && needs.reuse-infra.outputs.validate || 'false' }}"
  check_has "build infra skips plan" "${d}" "infra_with_skip_plan=\${{ inputs.reuse == 'true' && needs.reuse-infra.outputs.plan || 'false' }}"
  check_has "build declares reuse input defaulting to false" "${d}" "input_reuse_default='false'"
  check_has "build image checkout does not persist credentials" "${d}" "image_persist=False"
  check_has "build image needs reuse-code, reuse-infra, code and infra" "${d}" "image_needs=code infra reuse-code reuse-infra"
  check_has "build image survives skipped sides" "${d}" "!failure()"
  check_has "build image survives cancelled sides" "${d}" "!cancelled()"
  check_has "build image requires reuse-code success" "${d}" "needs.reuse-code.result == 'success'"
  check_has "build image requires reuse-infra success" "${d}" "needs.reuse-infra.result == 'success'"
  check_has "build release needs image" "${d}" "release_needs=image"
  check_has "build release requires image success" "${d}" "needs.image.result == 'success'"
  check_has "build release stamps with the build tag" "${d}" "stamp_build_tag=build/\${{ inputs.tag }}"
  check_has "build release stamps the release tag" "${d}" "stamp_tag=\${{ inputs.tag }}"
  check_has "build reuse-code prefix" "${d}" "reuse-code_reuse_prefix=\${{ inputs.module }} / code"
  check_has "build reuse-infra prefix" "${d}" "reuse-infra_reuse_prefix=\${{ inputs.module }} / infra"
  for j in reuse-code reuse-infra code infra image release; do
    check_has "build ${j} has no environment" "${d}" "${j}_environment=False"
    check_has "build ${j} has no matrix" "${d}" "${j}_matrix=False"
  done
}

build_image_if_has_all() {
  # arrange
  build_dump
  cond="$(grep '^image_if=' "${WORK}/build-dump")"
  # assert
  for part in '!failure()' '!cancelled()' "needs.reuse-code.result == 'success'" "needs.reuse-infra.result == 'success'"; do
    case "${cond}" in *"${part}"*) ok "build image if has ${part}";; *) ko "build image if has ${part}: '${cond}'";; esac
  done
}

hook_step_unset
hook_run_executable_wins
hook_run_only
hook_promote_hooks_via_run
hook_promote_hooks_via_checks
hook_promote_hooks_missing
hook_receives_base_sha_and_target_url
hook_verify_writes_release_url
step_declares_promote_inputs_and_output
hook_run_non_executable
hook_legacy_checks_flow
hook_missing_run_and_checks
hook_build_ignores_run
hook_run_exports_cache_dir
hook_run_propagates_exit
hook_optional_missing_skips
hook_optional_present_runs
hook_optional_propagates_exit
hook_deploy_mandatory_still_fail
hook_rollback_is_unknown
record_success
record_production
record_failure_state
record_invalid_state
record_missing_state
record_promoted_with_release_url
record_without_release_url
record_invalid_environment
record_action_declares_release_url
deploy_declares_promote_inputs
deploy_verify_publishes_release_url
deploy_staging_record_requires_promoted
notify_status_case ok ok "✅"
notify_status_case failed failed "❌"
notify_status_case rolled-back "rolled back" "↩️"
notify_distinct_markers
notify_annotation_case failed failed error notice
notify_annotation_case ok ok notice error
notify_annotation_case rolled-back "rolled back" notice error
notify_invalid_status
notify_webhook
notify_webhook_failure
notify_detail_in_message_and_summary
notify_without_detail_is_unchanged
notify_action_declares_detail
notify_kind_case promoted promoted "🚀" promote "promote api api-v1.2.3 -> staging: promoted"
notify_kind_case superseded superseded "⏭️" promote "promote api api-v1.2.3 -> staging: superseded"
notify_kind_case capped capped "⛔" promote "promote api api-v1.2.3 -> staging: capped"
notify_kind_case failed-promote failed "❌" promote "promote api api-v1.2.3 -> staging: failed"
notify_kind_case explicit-deploy ok "✅" deploy "deploy api api-v1.2.3 -> staging: ok"
notify_promote_markers_distinct
notify_kind_defaults_to_deploy
notify_invalid_status_with_promote_kind
notify_promote_annotation_levels
notify_action_declares_kind
notify_autofix_case opened opened "🔧" notice
notify_autofix_case gave-up "gave up" "🏳️" notice
notify_autofix_case rejected rejected "🚫" notice
notify_autofix_markers_distinct
notify_autofix_invalid_status
notify_autofix_failed_is_error
autofix_workflow_shape
autofix_select_job
autofix_fix_job
autofix_verify_job
autofix_verify_order
autofix_publish_job
autofix_notify_step
deploy_lean_job verify
deploy_lean_job record
deploy_services_input_only
deploy_optional_job migrate
deploy_optional_job rollout
deploy_graph
deploy_rollback_condition
deploy_rollback_job
deploy_rollback_preflight
deploy_outcome
deploy_apply_gating
contract_documents_optional_hooks
step_passes_step_input
example_setup_declares_step
apply_needed_declares_previous_output
apply_needed_resolves_in_every_environment
step_declares_previous_tag_input
deploy_record_dispatches_promote_on_staging_success
deploy_has_incident_job_on_production_failure
step_exports_previous_tag_to_hook
deploy_preflight_outputs_previous
deploy_jobs_pass_previous_tag
contract_documents_previous_tag
hook_receives_previous_tag
tag_build_local_reserves
tag_build_remote_reserves
tag_build_remote_loop_skips
tag_release_and_build_max
tag_release_only
tag_fresh_day
tag_other_prefix_ignored
tag_four_digits
tag_remote_override
tag_remote_override_ignores_origin
tag_remote_invalid_fails
target_declares_reuse_output
resolve_paginates
resolve_first_page_wins
stamp_deletes_build_tag
stamp_without_build_tag_keeps_it
stamp_empty_build_tag_keeps_it
stamp_delete_failure_warns
stamp_action_declares_build_tag
build_workflow_shape
build_image_if_has_all
step_declares_sentry_release_input
step_exports_sentry_release_to_hook
hook_receives_sentry_release
hook_sentry_release_empty_without_input
build_sentry_release
build_sentry_release_expression_without_key
deploy_sentry_mark
deploy_sentry_skipped_without_key
hook_declares_url_outputs
hook_declares_every_output_step_forwards

echo "${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ]
