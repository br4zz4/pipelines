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
  check_has "deploy services input is marked obsolete" "${inputs}" "Deprecated, ignored: verify and rollback run without services"
}

STEP_ACTION="${ROOT}/actions/step/action.yml"

yaml_eval() {
  PATH="/tmp/pyyaml-venv/bin:${PATH}" python3 -I -c "${1}" "${2}" 2>/dev/null
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
  for s in apply deployment verify rollback; do
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
  check_has "deploy ${job} uses the step action" "${block}" "uses: br4zz4/pipelines/actions/step@v1"
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
  deploy_needs_case rollback "deployment migrate preflight rollout verify"
  deploy_needs_case record "apply deployment migrate rollout verify"
  got="$(deploy_job_attr notify needs)"
  for j in migrate rollout; do
    case " ${got} " in *" ${j} "*) ok "deploy notify needs ${j}";; *) ko "deploy notify needs ${j}: got '${got}'";; esac
  done
}

deploy_rollback_condition() {
  # arrange
  cond="$(deploy_job_attr rollback if)"
  # assert
  case "${cond}" in *"always()"*) ok "deploy rollback keeps always()";; *) ko "deploy rollback keeps always(): '${cond}'";; esac
  for j in deployment migrate rollout verify; do
    case "${cond}" in *"needs.${j}.result == 'failure'"*) ok "deploy rollback fires on ${j} failure";; *) ko "deploy rollback fires on ${j} failure: '${cond}'";; esac
  done
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
  check_has "deploy preflight apply needed action" "${WORK}/gating" "step_uses=br4zz4/pipelines/actions/apply-needed@v1"
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
  check_has "apply-needed resolves the previous release" "${WORK}/previous-step" "uses=br4zz4/pipelines/actions/resolve@v1"
  if grep -qx "if=" "${WORK}/previous-step"; then ok "apply-needed resolves in every environment"; else ko "apply-needed resolves in every environment: $(cat "${WORK}/previous-step")"; fi
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
for name in ("apply", "deployment", "migrate", "rollout", "verify", "rollback"):
    j = d["jobs"][name]
    vals = [s.get("with", {}).get("previous-tag", "MISSING") for s in j["steps"] if str(s.get("uses", "")).startswith("br4zz4/pipelines/actions/step@")]
    print(name + "=" + ",".join(vals))
    print(name + "_needs=" + str("preflight" in j.get("needs", [])))'
  # act
  got="$(yaml_eval "${expr}" "${DEPLOY_WORKFLOW}")"
  printf '%s\n' "${got}" > "${WORK}/previous-jobs"
  # assert
  for j in apply deployment migrate rollout verify rollback; do
    check_has "deploy ${j} passes previous-tag" "${WORK}/previous-jobs" "${j}=\${{ needs.preflight.outputs.previous }}"
    check_has "deploy ${j} needs preflight" "${WORK}/previous-jobs" "${j}_needs=True"
  done
}

contract_documents_previous_tag() {
  # assert
  check_has "contract cites PREVIOUS_TAG" "${ROOT}/docs/contract.md" "PREVIOUS_TAG"
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

hook_runs_script
hook_runs_non_executable
hook_runs_executable
hook_propagates_exit
hook_exports_cache_dir
hook_missing_script
hook_step_unset
hook_run_executable_wins
hook_run_only
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
deploy_lean_job verify
deploy_lean_job rollback
deploy_services_input_only
deploy_optional_job migrate
deploy_optional_job rollout
deploy_graph
deploy_rollback_condition
deploy_apply_gating
contract_documents_optional_hooks
step_passes_step_input
example_setup_declares_step
apply_needed_declares_previous_output
apply_needed_resolves_in_every_environment
step_declares_previous_tag_input
step_exports_previous_tag_to_hook
deploy_preflight_outputs_previous
deploy_jobs_pass_previous_tag
contract_documents_previous_tag
hook_receives_previous_tag

echo "${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ]
