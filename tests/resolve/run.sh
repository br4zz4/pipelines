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

RESOLVE="${ROOT}/actions/resolve/resolve.py"

mkgh() {
  mkdir -p "${1}/bin"
  cat > "${1}/bin/gh" <<'GH'
#!/bin/sh
echo "$2" >> "${GH_CALLS}"
case "$2" in
  *"/deployments/7/statuses"*) echo '[{"state":"success"}]' ;;
  *"/deployments/8/statuses"*) echo '[{"state":"success"}]' ;;
  *"/deployments/9/statuses"*) echo '[{"state":"success"}]' ;;
  *"environment=promoted"*"&page=1")
    echo '[{"id":9,"payload":{"module":"core","tag":"core.2026-11-21.003","release_url":"https://r3.example.com"}},{"id":8,"payload":{"module":"core","tag":"core.2026-11-21.002"}},{"id":7,"payload":{"module":"core","tag":"core.2026-11-21.001","release_url":"https://r1.example.com"}}]' ;;
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
    INPUT_ENVIRONMENT="${2}" INPUT_MODULE="${3}" INPUT_TAG="${4}" python3 -I "${RESOLVE}" >"${1}/log" 2>&1 || resolve_status=$?
}

resolve_promoted_green() {
  # arrange
  t="$(new_dir resolve-promoted)"
  mkgh "${t}"
  # act
  resolve_run "${t}" promoted core core.2026-11-21.001
  # assert
  check_status "resolve in promoted succeeds" "${resolve_status}" 0
  check_has "resolve in promoted outputs the tag" "${t}/out" "tag=core.2026-11-21.001"
  check_has "resolve in promoted queries the promoted environment" "${t}/calls" "environment=promoted"
  check_has "resolve in promoted logs the environment" "${t}/log" "in promoted"
}

resolve_promoted_release_url() {
  # arrange
  t="$(new_dir resolve-release-url)"
  mkgh "${t}"
  # act
  resolve_run "${t}" promoted core core.2026-11-21.001
  # assert
  check_status "resolve release_url exit" "${resolve_status}" 0
  check_has "resolve outputs release_url from the payload" "${t}/out" "release_url=https://r1.example.com"
}

resolve_release_url_empty_when_absent() {
  # arrange
  t="$(new_dir resolve-no-release-url)"
  mkgh "${t}"
  # act
  resolve_run "${t}" promoted core core.2026-11-21.002
  # assert
  check_status "resolve without release_url in payload exit" "${resolve_status}" 0
  check_has "resolve outputs the tag without release_url" "${t}/out" "tag=core.2026-11-21.002"
  if grep -qx 'release_url=' "${t}/out" || ! grep -q '^release_url=' "${t}/out"; then ok "resolve release_url is empty when the payload has none"; else ko "resolve release_url is empty when the payload has none: $(cat "${t}/out")"; fi
}

resolve_promoted_latest_without_tag() {
  # arrange
  t="$(new_dir resolve-latest)"
  mkgh "${t}"
  # act
  resolve_run "${t}" promoted core ""
  # assert
  check_status "resolve latest in promoted exit" "${resolve_status}" 0
  check_has "resolve latest in promoted picks the newest green" "${t}/out" "tag=core.2026-11-21.003"
  check_has "resolve latest in promoted outputs its release_url" "${t}/out" "release_url=https://r3.example.com"
}

resolve_promoted_missing_tag_fails() {
  # arrange
  t="$(new_dir resolve-missing)"
  mkgh "${t}"
  # act
  resolve_run "${t}" promoted core core.2026-11-21.099
  # assert
  check_nonzero "resolve fails when the tag has no promoted record" "${resolve_status}"
  check_has "resolve missing promoted message" "${t}/log" "core core.2026-11-21.099 is not recorded green in promoted: nothing to promote"
  check_lacks "resolve missing promoted writes no tag" "${t}/out" "tag="
  check_lacks "resolve missing promoted writes no release_url" "${t}/out" "release_url="
}

resolve_promoted_ignores_other_environments() {
  # arrange
  t="$(new_dir resolve-other-env)"
  mkgh "${t}"
  # act
  resolve_run "${t}" staging core core.2026-11-21.001
  # assert
  check_nonzero "resolve in staging finds nothing in promoted data" "${resolve_status}"
  check_has "resolve in staging names the environment" "${t}/log" "is not recorded green in staging"
}

resolve_promoted_green
resolve_promoted_release_url
resolve_release_url_empty_when_absent
resolve_promoted_latest_without_tag
resolve_promoted_missing_tag_fails
resolve_promoted_ignores_other_environments

echo "${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ]
