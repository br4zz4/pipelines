#!/bin/sh
set -u

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
AGENT="${ROOT}/actions/agent/agent.sh"
PROMPT_TEMPLATE="${ROOT}/actions/agent/prompt.md"
STEP_ACTION="${ROOT}/actions/step/action.yml"
WORK="$(cd -P "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0
COUNT=0
STATUS=0
CODE=modules/core/code

mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/claude" <<'CLAUDE'
#!/bin/sh
: > "${CLAUDE_ARGS}"
skip=0
for a in "$@"; do
  if [ "${skip}" = 1 ]; then
    printf '%s' "${a}" > "${CLAUDE_PROMPT}"
    skip=0
    continue
  fi
  printf '%s\n' "${a}" >> "${CLAUDE_ARGS}"
  if [ "${a}" = "-p" ]; then skip=1; fi
done
pwd -P > "${CLAUDE_NOTES}/cwd"
command -v ci-hook > "${CLAUDE_NOTES}/cihook" 2>/dev/null
printf '%s' "${CLAUDE_CODE_OAUTH_TOKEN:-}" > "${CLAUDE_NOTES}/claude_token"
mkdir -p .autofix
write_result() {
  printf '%s' "${1}" > .autofix/result.json
}
edit_code() {
  printf 'fixed\n' > modules/core/code/src/app.txt
  mkdir -p modules/core/code/test
  printf 'regression\n' > modules/core/code/test/regression_test.txt
  printf 'scratch\n' > .autofix/scratch.txt
}
case "${CLAUDE_MODE}" in
  fixed)
    edit_code
    write_result '{"status":"fixed","tests":["modules/core/code/test/regression_test.txt"],"summary":"root cause fixed"}'
    echo '{"result":"ok"}' ;;
  gave_up)
    edit_code
    write_result '{"status":"gave_up","tests":[],"summary":"cannot reproduce"}'
    echo '{"result":"ok"}' ;;
  fixed_no_tests)
    edit_code
    write_result '{"status":"fixed","tests":[],"summary":"no test"}' ;;
  unknown_status)
    edit_code
    write_result '{"status":"maybe","tests":["a"],"summary":"unsure"}' ;;
  bad_json)
    edit_code
    write_result '{not json' ;;
  absent)
    edit_code ;;
  exit_nonzero)
    edit_code
    write_result '{"status":"fixed","tests":["a"],"summary":"done"}'
    exit 3 ;;
  hooks)
    printf '#!/bin/sh\necho TAMPERED\n' > modules/core/code/run/test
    ci-hook test alpha beta > "${CLAUDE_NOTES}/test.out" 2>&1
    echo $? > "${CLAUDE_NOTES}/test.rc"
    ci-hook lint > "${CLAUDE_NOTES}/lint.out" 2>&1
    echo $? > "${CLAUDE_NOTES}/lint.rc"
    ci-hook e2e > "${CLAUDE_NOTES}/e2e.out" 2>&1
    echo $? > "${CLAUDE_NOTES}/e2e.rc"
    write_result '{"status":"gave_up","tests":[],"summary":"hooks probed"}' ;;
esac
exit 0
CLAUDE
chmod 755 "${WORK}/bin/claude"

pass() {
  echo "PASS ${1}"
  PASSED=$(( PASSED + 1 ))
}

fail() {
  echo "FAIL ${1}"
  FAILED=$(( FAILED + 1 ))
}

setup() {
  COUNT=$(( COUNT + 1 ))
  CASE="${WORK}/case${COUNT}"
  REPO="${CASE}/repo"
  RTEMP="${CASE}/tmp"
  GOUT="${CASE}/github_output"
  LOG="${CASE}/log"
  ARGS="${CASE}/args"
  PROMPT_OUT="${CASE}/prompt"
  NOTES="${CASE}/notes"
  PATCH="${REPO}/.autofix/fix.patch"
  mkdir -p "${REPO}/${CODE}/run" "${REPO}/${CODE}/src" "${REPO}/${CODE}/ci/checks" "${RTEMP}" "${NOTES}"
  : > "${GOUT}"
  cat > "${REPO}/${CODE}/run/test" <<'HOOK'
#!/bin/sh
echo "BASE-TEST token=[${CLAUDE_CODE_OAUTH_TOKEN:-}] api=[${ANTHROPIC_API_KEY:-}] module=[${MODULE:-}] env=[${ENVIRONMENT:-}] base=[${BASE_SHA:-}] cache=[${CI_CACHE_DIR:-}] cwd=[$(pwd -P)] args=[$*]"
HOOK
  cat > "${REPO}/${CODE}/ci/checks/test.sh" <<'HOOK'
#!/bin/sh
echo "CHECKS-TEST module=[${MODULE:-}]"
HOOK
  cat > "${REPO}/${CODE}/ci/checks/lint.sh" <<'HOOK'
#!/bin/sh
echo "CHECKS-LINT token=[${CLAUDE_CODE_OAUTH_TOKEN:-}] module=[${MODULE:-}] env=[${ENVIRONMENT:-}] base=[${BASE_SHA:-}] cwd=[$(pwd -P)] args=[$*]"
HOOK
  chmod 755 "${REPO}/${CODE}/run/test" "${REPO}/${CODE}/ci/checks/test.sh" "${REPO}/${CODE}/ci/checks/lint.sh"
  printf 'broken\n' > "${REPO}/${CODE}/src/app.txt"
  if [ "${1:-}" = "norun" ]; then
    rm -f "${REPO}/${CODE}/run/test"
  fi
  git -C "${REPO}" init -q
  git -C "${REPO}" remote add origin https://github.com/o/r.git
  git -C "${REPO}" add -A
  git -C "${REPO}" -c user.name=t -c user.email=t@t commit -q -m base
  mkdir -p "${REPO}/.autofix"
  printf '{"number":7,"title":"bug","body":"b","labels":[],"comments":[]}\n' > "${REPO}/.autofix/issue.json"
  cp -R "${REPO}" "${CASE}/pristine"
}

run_agent() {
  mode="${1}"
  shift
  STATUS=0
  (
    cd "${REPO}" && env -i \
      PATH="${WORK}/bin:${PATH}" \
      HOME="${CASE}" \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_CONFIG_NOSYSTEM=1 \
      GIT_TERMINAL_PROMPT=0 \
      MODULE=core \
      CODE_DIR="${CODE}" \
      RUNNER_TEMP="${RTEMP}" \
      GITHUB_WORKSPACE="${REPO}" \
      GITHUB_OUTPUT="${GOUT}" \
      CLAUDE_CODE_OAUTH_TOKEN=oauth-secret \
      ANTHROPIC_API_KEY=anthropic-secret \
      ENVIRONMENT=production \
      BASE_SHA=abc123 \
      CLAUDE_MODE="${mode}" \
      CLAUDE_ARGS="${ARGS}" \
      CLAUDE_PROMPT="${PROMPT_OUT}" \
      CLAUDE_NOTES="${NOTES}" \
      "$@" \
      sh "${AGENT}"
  ) > "${LOG}" 2>&1 || STATUS=$?
}

expect_status() {
  if [ "${STATUS}" -eq "${2}" ]; then
    pass "${1}: exit ${2}"
    return 0
  fi
  fail "${1}: expected exit ${2}, got ${STATUS}"
  sed 's/^/    /' "${LOG}"
  return 1
}

out_has() {
  if grep -qxF "${2}" "${GOUT}"; then
    pass "${1}"
  else
    fail "${1}: output lacks '${2}'"
    sed 's/^/    /' "${GOUT}"
  fi
}

out_lacks_key() {
  if grep -q "^${2}=" "${GOUT}"; then
    fail "${1}: output has '${2}'"
  else
    pass "${1}"
  fi
}

log_has() {
  if grep -qF -- "${2}" "${LOG}"; then
    pass "${1}"
  else
    fail "${1}: log lacks '${2}'"
    sed 's/^/    /' "${LOG}"
  fi
}

log_lacks() {
  if grep -qF -- "${2}" "${LOG}"; then
    fail "${1}: log has '${2}'"
  else
    pass "${1}"
  fi
}

file_has() {
  if [ -f "${2}" ] && grep -qF -- "${3}" "${2}"; then
    pass "${1}"
  else
    fail "${1}: ${2} lacks '${3}'"
  fi
}

file_lacks() {
  if [ -f "${2}" ] && ! grep -qF -- "${3}" "${2}"; then
    pass "${1}"
  else
    fail "${1}: ${2} missing or has '${3}'"
  fi
}

claude_not_called() {
  if [ -e "${ARGS}" ]; then
    fail "${1}: claude was called"
  else
    pass "${1}"
  fi
}

expect_leak() {
  expect_status "${1}" 1
  log_has "${1}: error names the leak" "::error::agent environment leaks ${2}"
  log_lacks "${1}: secret value not printed" "leak-value-123"
  claude_not_called "${1}: claude not called"
}

for name in GH_PIPELINES_TOKEN SENTRY_AUTH_TOKEN GITHUB_TOKEN WARD_KEY_DEFAULT WARD_KEY_RESTRICTED WARD_KEY_OTHER; do
  setup
  run_agent fixed "${name}=leak-value-123"
  expect_leak "guard ${name}" "${name}"
done

setup
git -C "${REPO}" remote set-url origin https://x-access-token:leak-value-123@github.com/o/r.git
run_agent fixed
expect_status "guard remote with user and token" 1
log_has "guard remote with user and token: error" "::error::agent environment leaks"
log_lacks "guard remote with user and token: value not printed" "leak-value-123"
claude_not_called "guard remote with user and token: claude not called"

setup
git -C "${REPO}" remote set-url origin https://leak-value-123@github.com/o/r.git
run_agent fixed
expect_status "guard remote with token only" 1
log_has "guard remote with token only: error" "::error::agent environment leaks"
log_lacks "guard remote with token only: value not printed" "leak-value-123"
claude_not_called "guard remote with token only: claude not called"

setup
git -C "${REPO}" config http.https://github.com/.extraheader "AUTHORIZATION: basic leak-value-123"
run_agent fixed
expect_status "guard extraheader" 1
log_has "guard extraheader: error" "::error::agent environment leaks"
log_lacks "guard extraheader: value not printed" "leak-value-123"
claude_not_called "guard extraheader: claude not called"

setup
git -C "${REPO}" remote set-url origin git@github.com:o/r.git
run_agent fixed
expect_status "guard passes with ssh remote without credential" 0

setup
run_agent fixed
if expect_status "clean environment" 0; then
  log_lacks "clean environment: no leak error" "environment leaks"
  out_has "clean environment: status" "status=fixed"
  out_has "clean environment: summary" "summary=root cause fixed"
  if [ -e "${ARGS}" ]; then pass "clean environment: claude called"; else fail "clean environment: claude not called"; fi
fi

setup
run_agent fixed
printf '%s\n' -p --model opus --max-turns 40 --output-format json --allowedTools 'Read,Edit,Write,Glob,Grep,Bash(ci-hook:*)' --disallowedTools 'WebFetch,WebSearch,Task' > "${CASE}/expected_args"
if cmp -s "${CASE}/expected_args" "${ARGS}"; then
  pass "claude arguments are exactly the contract"
else
  fail "claude arguments differ from the contract"
  sed 's/^/    /' "${ARGS}"
fi
file_has "prompt has code_dir substituted" "${PROMPT_OUT}" "${CODE}"
file_has "prompt has module substituted" "${PROMPT_OUT}" "core"
file_lacks "prompt has no placeholder left" "${PROMPT_OUT}" "{{"
file_has "prompt mentions issue.json" "${PROMPT_OUT}" ".autofix/issue.json"
file_has "prompt mentions result.json" "${PROMPT_OUT}" ".autofix/result.json"
if [ "$(cat "${NOTES}/cwd" 2>/dev/null)" = "${REPO}" ]; then
  pass "claude runs in the checkout"
else
  fail "claude cwd is '$(cat "${NOTES}/cwd" 2>/dev/null)', expected ${REPO}"
fi
case "$(cat "${NOTES}/cihook" 2>/dev/null)" in
  "${RTEMP}"/*|"${REPO}"/*) fail "ci-hook installed inside a writable tree: $(cat "${NOTES}/cihook")" ;;
  "") fail "ci-hook is not on the PATH of claude" ;;
  *) pass "ci-hook is on the PATH of claude" ;;
esac
if [ -d "${RTEMP}/base-hooks" ] && [ "$(find "${RTEMP}/base-hooks" -type f | wc -l | tr -d ' ')" -ge 3 ]; then
  pass "base hooks copied to RUNNER_TEMP"
else
  fail "base hooks not copied to ${RTEMP}/base-hooks"
fi

setup
run_agent fixed
if expect_status "fixed run" 0; then
  out_has "fixed: status" "status=fixed"
  out_has "fixed: summary" "summary=root cause fixed"
  if [ -s "${PATCH}" ]; then pass "fixed: fix.patch published"; else fail "fixed: fix.patch missing or empty"; fi
  file_has "fixed: patch changes tracked file" "${PATCH}" "${CODE}/src/app.txt"
  file_has "fixed: patch has the new test" "${PATCH}" "${CODE}/test/regression_test.txt"
  file_lacks "fixed: patch has no .autofix file" "${PATCH}" ".autofix/"
  if git -C "${CASE}/pristine" apply --check "${PATCH}" 2>/dev/null; then
    pass "fixed: patch applies on a pristine checkout"
  else
    fail "fixed: patch does not apply on a pristine checkout"
  fi
fi

setup
run_agent gave_up
if expect_status "gave_up run" 0; then
  out_has "gave_up: status" "status=gave_up"
  out_has "gave_up: summary" "summary=cannot reproduce"
  if [ -e "${PATCH}" ]; then fail "gave_up: fix.patch must not exist"; else pass "gave_up: no fix.patch"; fi
fi

for mode in fixed_no_tests unknown_status bad_json absent exit_nonzero; do
  setup
  run_agent "${mode}"
  out_has "${mode}: status failed" "status=failed"
  if [ -e "${PATCH}" ]; then fail "${mode}: fix.patch must not exist"; else pass "${mode}: no fix.patch"; fi
done

setup
run_agent hooks
expect_status "hooks run" 0
file_has "claude itself sees the oauth token" "${NOTES}/claude_token" "oauth-secret"
file_has "ci-hook test runs the base copy" "${NOTES}/test.out" "BASE-TEST"
file_lacks "ci-hook test ignores the workspace edit" "${NOTES}/test.out" "TAMPERED"
file_has "ci-hook test hides the oauth token" "${NOTES}/test.out" "token=[]"
file_has "ci-hook test hides the api key" "${NOTES}/test.out" "api=[]"
file_has "ci-hook test exports MODULE" "${NOTES}/test.out" "module=[core]"
file_has "ci-hook test forces ENVIRONMENT=test" "${NOTES}/test.out" "env=[test]"
file_has "ci-hook test empties BASE_SHA" "${NOTES}/test.out" "base=[]"
file_lacks "ci-hook test sets CI_CACHE_DIR" "${NOTES}/test.out" "cache=[]"
file_has "ci-hook test runs in the code dir" "${NOTES}/test.out" "cwd=[${REPO}/${CODE}]"
file_has "ci-hook test forwards arguments" "${NOTES}/test.out" "args=[alpha beta]"
file_lacks "ci-hook prefers run/test over ci/checks" "${NOTES}/test.out" "CHECKS-TEST"
file_has "ci-hook test exit 0" "${NOTES}/test.rc" "0"
file_has "ci-hook lint falls back to ci/checks/lint.sh" "${NOTES}/lint.out" "CHECKS-LINT"
file_has "ci-hook lint hides the oauth token" "${NOTES}/lint.out" "token=[]"
file_has "ci-hook lint forces ENVIRONMENT=test" "${NOTES}/lint.out" "env=[test]"
file_has "ci-hook lint empties BASE_SHA" "${NOTES}/lint.out" "base=[]"
file_has "ci-hook lint runs in the code dir" "${NOTES}/lint.out" "cwd=[${REPO}/${CODE}]"
file_has "ci-hook invalid step exits 2" "${NOTES}/e2e.rc" "2"

setup norun
run_agent hooks
file_has "ci-hook test falls back to ci/checks/test.sh" "${NOTES}/test.out" "CHECKS-TEST"
file_lacks "ci-hook test fallback ignores the workspace edit" "${NOTES}/test.out" "TAMPERED"

if [ -f "${PROMPT_TEMPLATE}" ]; then
  pass "prompt template exists"
else
  fail "prompt template missing"
fi
file_has "template has code_dir placeholder" "${PROMPT_TEMPLATE}" "{{code_dir}}"
file_has "template has module placeholder" "${PROMPT_TEMPLATE}" "{{module}}"
file_has "template reads issue.json" "${PROMPT_TEMPLATE}" ".autofix/issue.json"
file_has "template writes result.json" "${PROMPT_TEMPLATE}" ".autofix/result.json"
file_has "template confirms with ci-hook test" "${PROMPT_TEMPLATE}" "ci-hook test"
file_has "template confirms with ci-hook lint" "${PROMPT_TEMPLATE}" "ci-hook lint"
for forbidden in ci/ run/ e2e/ mise.toml; do
  file_has "template forbids ${forbidden}" "${PROMPT_TEMPLATE}" "${forbidden}"
done
if [ -f "${PROMPT_TEMPLATE}" ] && grep -qiE 'untrusted|não confiável|nao confiavel' "${PROMPT_TEMPLATE}"; then
  pass "template marks the issue as untrusted"
else
  fail "template does not mark the issue as untrusted"
fi
if [ -f "${PROMPT_TEMPLATE}" ] && ! grep -qiwE 'ruby|python|rails|node|gcp|aws' "${PROMPT_TEMPLATE}"; then
  pass "template is language and provider neutral"
else
  fail "template is missing or names a language or provider"
fi

step_dump() {
  python3 -I -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print("default=" + repr(d["inputs"].get("export-key", {}).get("default")))
for s in d["runs"]["steps"]:
    if s.get("name") == "secrets":
        print("passed=" + repr((s.get("with") or {}).get("export-key")))' "${1}" 2>/dev/null
}

DUMP="$(step_dump "${STEP_ACTION}")"
case "${DUMP}" in
  *"default='true'"*) pass "step input export-key defaults to 'true'" ;;
  *) fail "step input export-key default: ${DUMP}" ;;
esac
case "${DUMP}" in
  *"passed='\${{ inputs.export-key }}'"*) pass "step passes export-key to setup-ward" ;;
  *) fail "step does not pass export-key to setup-ward: ${DUMP}" ;;
esac

echo "${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ]
