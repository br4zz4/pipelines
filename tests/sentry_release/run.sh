#!/bin/sh
# run.sh — fixture tests for actions/sentry-release/sentry_release.sh (fake curl, no network).
set -u

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

SCRIPT="${ROOT}/actions/sentry-release/sentry_release.sh"
TOKEN="tok-s3cret-123"
VERSION="has_warranty@core.2026-11-21.001"
REL="https://sentry.io/api/0/organizations/brazza-tech/releases/"
RELV="${REL}${VERSION}/"
DEP="${RELV}deploys/"
LINK="https://sentry.io/organizations/brazza-tech/releases/${VERSION}/"

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

check_has() {
  if grep -qF -- "${3}" "${2}" 2>/dev/null; then ok "${1}"; else ko "${1}: '${3}' not found in ${2##*/}"; fi
}

check_lacks() {
  if grep -qF -- "${3}" "${2}" 2>/dev/null; then ko "${1}: '${3}' unexpectedly in ${2##*/}"; else ok "${1}"; fi
}

check_seq() {
  printf '%s\n' "${3}" > "${WORK}/expected"
  if [ ! -e "${2}/seq" ]; then : > "${2}/seq"; fi
  if [ "$(cat "${2}/seq")" = "$(cat "${WORK}/expected")" ]; then ok "${1}"; else ko "${1}: calls were: $(tr '\n' '|' < "${2}/seq")"; fi
}

new_dir() {
  d="${WORK}/${1}"
  rm -rf "${d}"
  mkdir -p "${d}"
  echo "${d}"
}

mkcurl() {
  cat > "${1}/curl" <<'CURL'
#!/bin/sh
L="${CURL_LOG_DIR}"
method=GET
data=''
out=''
wfmt=''
fail=0
url=''
printf '%s\n' "$@" > "${L}/args.tmp"
: > "${L}/hdr.tmp"
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -H) printf '%s\n' "$2" >> "${L}/hdr.tmp"; shift 2 ;;
    -d|--data|--data-binary) data="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    -w) wfmt="$2"; shift 2 ;;
    --max-time|--retry) shift 2 ;;
    -*) case "$1" in *f*) fail=1 ;; esac; shift ;;
    *) url="$1"; shift ;;
  esac
done
if [ "${data}" = "@-" ]; then data="$(cat)"; fi
printf '%s %s\n' "${method}" "${url}" >> "${L}/seq"
idx="$(wc -l < "${L}/seq" | tr -d ' ')"
n="$(grep -cFx "${method} ${url}" "${L}/seq")"
mv "${L}/args.tmp" "${L}/${idx}.args"
mv "${L}/hdr.tmp" "${L}/${idx}.headers"
printf '%s' "${data}" | tr -d ' \t\n' > "${L}/${idx}.body"
if grep -q '^::add-mask::' "${OUT_FILE}" 2>/dev/null; then echo yes > "${L}/${idx}.mask"; else echo no > "${L}/${idx}.mask"; fi
status="$(awk -v k="${method} ${url}" -v n="${n}" '$1" "$2==k { c++; last=$3; if (c==n) { print $3; found=1; exit } } END { if (!found) print (last ? last : "200") }' "${L}/routes")"
emit_w() {
  if [ -n "${wfmt}" ]; then printf '%s' "$(printf '%s' "${wfmt}" | sed "s/%{http_code}/${1}/g")"; fi
}
if [ "${status}" = "timeout" ]; then
  echo "curl: (28) Operation timed out after 15001 milliseconds" >&2
  emit_w 000
  exit 28
fi
if [ "${status}" -ge 400 ]; then
  if [ "${fail}" -eq 1 ]; then
    echo "curl: (22) The requested URL returned error: ${status}" >&2
    emit_w "${status}"
    exit 22
  fi
fi
if [ -n "${out}" ]; then echo '{}' > "${out}"; else echo '{}'; fi
emit_w "${status}"
exit 0
CURL
  chmod 755 "${1}/curl"
}

route() {
  printf '%s %s %s\n' "${2}" "${3}" "${4}" >> "${1}/logs/routes"
}

new_case() {
  c="$(new_dir "${1}")"
  mkdir -p "${c}/bin" "${c}/logs"
  mkcurl "${c}/bin"
  : > "${c}/logs/routes"
  : > "${c}/summary"
  echo "${c}"
}

run_sentry() {
  c="${1}"
  shift
  status=0
  env CURL_LOG_DIR="${c}/logs" OUT_FILE="${c}/out" PATH="${c}/bin:${PATH}" \
    COMMAND=release SENTRY_ORG=brazza-tech SENTRY_PROJECT=has_warranty SENTRY_URL=https://sentry.io \
    TAG_INPUT=core.2026-11-21.001 ENVIRONMENT=staging APP_URL=https://staging.example.com \
    SENTRY_AUTH_TOKEN="${TOKEN}" VAULT=acme GITHUB_REPOSITORY=acme/app GITHUB_SHA=abc123def \
    GITHUB_STEP_SUMMARY="${c}/summary" \
    "$@" sh "${SCRIPT}" >"${c}/out" 2>"${c}/err" || status=$?
  echo "${status}" > "${c}/status"
  cat "${c}/out" "${c}/err" > "${c}/all"
}

release_posts_then_finalizes() {
  # arrange
  c="$(new_case release-ok)"
  route "${c}" POST "${REL}" 201
  # act
  run_sentry "${c}" COMMAND=release
  # assert
  check_status "release exit" "$(cat "${c}/status")" 0
  check_seq "release calls POST then PUT" "${c}/logs" "POST ${REL}
PUT ${RELV}"
  check_has "release POST version" "${c}/logs/1.body" "\"version\":\"${VERSION}\""
  check_has "release POST projects" "${c}/logs/1.body" "\"projects\":[\"has_warranty\"]"
  check_has "release POST refs repository" "${c}/logs/1.body" "\"repository\":\"acme/app\""
  check_has "release POST refs commit" "${c}/logs/1.body" "\"commit\":\"abc123def\""
  check_has "release PUT dateReleased" "${c}/logs/2.body" "\"dateReleased\":\""
  check_has "release summary created" "${c}/summary" "Sentry release ${VERSION}: created"
  check_has "release summary link" "${c}/summary" "${LINK}"
}

release_without_github_integration() {
  # arrange
  c="$(new_case release-norefs)"
  route "${c}" POST "${REL}" 400
  route "${c}" POST "${REL}" 201
  # act
  run_sentry "${c}" COMMAND=release
  # assert
  check_status "release norefs exit" "$(cat "${c}/status")" 0
  check_seq "release norefs calls" "${c}/logs" "POST ${REL}
POST ${REL}
PUT ${RELV}"
  check_has "release norefs first has refs" "${c}/logs/1.body" "\"refs\""
  check_lacks "release norefs retry drops refs" "${c}/logs/2.body" "refs"
  check_has "release norefs retry keeps version" "${c}/logs/2.body" "\"version\":\"${VERSION}\""
  check_has "release norefs warning" "${c}/all" "::warning::sentry: release created without commits (no GitHub integration for acme/app)"
  check_has "release norefs summary created" "${c}/summary" "Sentry release ${VERSION}: created"
}

release_already_exists() {
  code="${1}"
  # arrange
  c="$(new_case "release-exists-${code}")"
  route "${c}" POST "${REL}" "${code}"
  # act
  run_sentry "${c}" COMMAND=release
  # assert
  check_status "release ${code} exit" "$(cat "${c}/status")" 0
  check_seq "release ${code} continues to PUT" "${c}/logs" "POST ${REL}
PUT ${RELV}"
  check_has "release ${code} summary exists" "${c}/summary" "Sentry release ${VERSION}: exists"
  check_lacks "release ${code} no failed" "${c}/summary" "failed"
}

deploy_posts_deploy() {
  # arrange
  c="$(new_case deploy-ok)"
  route "${c}" POST "${DEP}" 201
  # act
  run_sentry "${c}" COMMAND=deploy
  # assert
  check_status "deploy exit" "$(cat "${c}/status")" 0
  check_seq "deploy single call" "${c}/logs" "POST ${DEP}"
  check_has "deploy environment" "${c}/logs/1.body" "\"environment\":\"staging\""
  check_has "deploy name is tag" "${c}/logs/1.body" "\"name\":\"core.2026-11-21.001\""
  check_has "deploy url" "${c}/logs/1.body" "\"url\":\"https://staging.example.com\""
  check_has "deploy dateFinished" "${c}/logs/1.body" "\"dateFinished\":\""
  check_has "deploy summary marked" "${c}/summary" "deploy staging: marked"
  check_has "deploy summary link" "${c}/summary" "${LINK}"
}

deploy_production_environment() {
  # arrange
  c="$(new_case deploy-prod)"
  route "${c}" POST "${DEP}" 201
  # act
  run_sentry "${c}" COMMAND=deploy ENVIRONMENT=production
  # assert
  check_has "deploy production environment" "${c}/logs/1.body" "\"environment\":\"production\""
  check_has "deploy production summary" "${c}/summary" "deploy production: marked"
}

deploy_omits_empty_url() {
  # arrange
  c="$(new_case deploy-nourl)"
  route "${c}" POST "${DEP}" 201
  # act
  run_sentry "${c}" COMMAND=deploy APP_URL=
  # assert
  check_status "deploy nourl exit" "$(cat "${c}/status")" 0
  check_has "deploy nourl keeps environment" "${c}/logs/1.body" "\"environment\":\"staging\""
  check_lacks "deploy nourl omits url" "${c}/logs/1.body" "\"url\""
}

deploy_404_creates_release_and_retries() {
  # arrange
  c="$(new_case deploy-404)"
  route "${c}" POST "${DEP}" 404
  route "${c}" POST "${DEP}" 201
  route "${c}" POST "${REL}" 201
  # act
  run_sentry "${c}" COMMAND=deploy
  # assert
  check_status "deploy 404 exit" "$(cat "${c}/status")" 0
  check_seq "deploy 404 creates release and retries once" "${c}/logs" "POST ${DEP}
POST ${REL}
PUT ${RELV}
POST ${DEP}"
  check_has "deploy 404 release body version" "${c}/logs/2.body" "\"version\":\"${VERSION}\""
  check_has "deploy 404 release body refs" "${c}/logs/2.body" "\"commit\":\"abc123def\""
  check_has "deploy 404 retry environment" "${c}/logs/4.body" "\"environment\":\"staging\""
  check_has "deploy 404 summary marked" "${c}/summary" "deploy staging: marked"
}

deploy_404_twice_stops() {
  # arrange
  c="$(new_case deploy-404-twice)"
  route "${c}" POST "${DEP}" 404
  route "${c}" POST "${REL}" 201
  # act
  run_sentry "${c}" COMMAND=deploy
  # assert
  check_status "deploy 404 twice exit" "$(cat "${c}/status")" 0
  check_seq "deploy 404 twice retries only once" "${c}/logs" "POST ${DEP}
POST ${REL}
PUT ${RELV}
POST ${DEP}"
  check_has "deploy 404 twice warning" "${c}/all" "::warning::sentry: deploy"
  check_has "deploy 404 twice status" "${c}/all" "404"
  check_has "deploy 404 twice summary failed" "${c}/summary" "deploy staging: failed"
}

release_5xx_warns() {
  # arrange
  c="$(new_case release-5xx)"
  route "${c}" POST "${REL}" 503
  # act
  run_sentry "${c}" COMMAND=release
  # assert
  check_status "release 5xx exit" "$(cat "${c}/status")" 0
  check_has "release 5xx warning step" "${c}/all" "::warning::sentry: release"
  check_has "release 5xx warning status" "${c}/all" "503"
  check_has "release 5xx summary failed" "${c}/summary" "Sentry release ${VERSION}: failed"
}

release_timeout_warns() {
  # arrange
  c="$(new_case release-timeout)"
  route "${c}" POST "${REL}" timeout
  # act
  run_sentry "${c}" COMMAND=release
  # assert
  check_status "release timeout exit" "$(cat "${c}/status")" 0
  check_has "release timeout warning" "${c}/all" "::warning::sentry: release"
  check_has "release timeout summary failed" "${c}/summary" "Sentry release ${VERSION}: failed"
}

finalize_failure_warns() {
  # arrange
  c="$(new_case release-put-5xx)"
  route "${c}" POST "${REL}" 201
  route "${c}" PUT "${RELV}" 502
  # act
  run_sentry "${c}" COMMAND=release
  # assert
  check_status "finalize 5xx exit" "$(cat "${c}/status")" 0
  check_has "finalize 5xx warning" "${c}/all" "::warning::sentry:"
  check_has "finalize 5xx status" "${c}/all" "502"
}

deploy_5xx_warns() {
  # arrange
  c="$(new_case deploy-5xx)"
  route "${c}" POST "${DEP}" 500
  # act
  run_sentry "${c}" COMMAND=deploy
  # assert
  check_status "deploy 5xx exit" "$(cat "${c}/status")" 0
  check_has "deploy 5xx warning step" "${c}/all" "::warning::sentry: deploy"
  check_has "deploy 5xx warning status" "${c}/all" "500"
  check_has "deploy 5xx summary failed" "${c}/summary" "deploy staging: failed"
  check_seq "deploy 5xx does not create release" "${c}/logs" "POST ${DEP}"
}

deploy_timeout_warns() {
  # arrange
  c="$(new_case deploy-timeout)"
  route "${c}" POST "${DEP}" timeout
  # act
  run_sentry "${c}" COMMAND=deploy
  # assert
  check_status "deploy timeout exit" "$(cat "${c}/status")" 0
  check_has "deploy timeout warning" "${c}/all" "::warning::sentry: deploy"
  check_has "deploy timeout summary failed" "${c}/summary" "deploy staging: failed"
}

missing_token_skips() {
  cmd="${1}"
  # arrange
  c="$(new_case "token-missing-${cmd}")"
  # act
  run_sentry "${c}" COMMAND="${cmd}" SENTRY_AUTH_TOKEN=
  # assert
  check_status "token missing ${cmd} exit" "$(cat "${c}/status")" 0
  check_has "token missing ${cmd} warning" "${c}/all" "::warning::sentry: SENTRY_AUTH_TOKEN missing in acme:secrets.ci.common"
  check_seq "token missing ${cmd} no curl" "${c}/logs" ""
}

token_is_masked_and_never_leaked() {
  # arrange
  c="$(new_case token-mask)"
  route "${c}" POST "${REL}" 201
  # act
  run_sentry "${c}" COMMAND=release
  # assert
  check_has "mask line printed" "${c}/out" "::add-mask::${TOKEN}"
  check_has "mask before 1st curl" "${c}/logs/1.mask" "yes"
  check_has "mask before 2nd curl" "${c}/logs/2.mask" "yes"
  grep -v '^::add-mask::' "${c}/all" > "${c}/filtered" || true
  check_lacks "token not in output" "${c}/filtered" "${TOKEN}"
  check_lacks "token not in summary" "${c}/summary" "${TOKEN}"
  check_lacks "token not in body" "${c}/logs/1.body" "${TOKEN}"
  check_lacks "token not in url" "${c}/logs/seq" "${TOKEN}"
  check_has "token sent as bearer header" "${c}/logs/1.headers" "Authorization: Bearer ${TOKEN}"
  grep -vF "Authorization: Bearer ${TOKEN}" "${c}/logs/1.args" > "${c}/args_rest" || true
  check_lacks "token only in Authorization header" "${c}/args_rest" "${TOKEN}"
}

token_masked_on_deploy() {
  # arrange
  c="$(new_case token-mask-deploy)"
  route "${c}" POST "${DEP}" 503
  # act
  run_sentry "${c}" COMMAND=deploy
  # assert
  check_has "deploy mask before curl" "${c}/logs/1.mask" "yes"
  grep -v '^::add-mask::' "${c}/all" > "${c}/filtered" || true
  check_lacks "deploy failure token not in output" "${c}/filtered" "${TOKEN}"
  check_lacks "deploy failure token not in summary" "${c}/summary" "${TOKEN}"
}

every_call_uses_curl_flags() {
  # arrange
  c="$(new_case flags)"
  route "${c}" POST "${DEP}" 404
  route "${c}" POST "${DEP}" 201
  route "${c}" POST "${REL}" 201
  # act
  run_sentry "${c}" COMMAND=deploy
  # assert
  for i in 1 2 3 4; do
    tr '\n' ' ' < "${c}/logs/${i}.args" > "${c}/flat"
    check_has "call ${i} uses -fsS --max-time 15 --retry 2" "${c}/flat" "-fsS --max-time 15 --retry 2"
  done
}

release_posts_then_finalizes
release_without_github_integration
release_already_exists 409
release_already_exists 208
deploy_posts_deploy
deploy_production_environment
deploy_omits_empty_url
deploy_404_creates_release_and_retries
deploy_404_twice_stops
release_5xx_warns
release_timeout_warns
finalize_failure_warns
deploy_5xx_warns
deploy_timeout_warns
missing_token_skips release
missing_token_skips deploy
token_is_masked_and_never_leaked
token_masked_on_deploy
every_call_uses_curl_flags

echo "${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ]
