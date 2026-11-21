#!/bin/sh
# run.sh — fixture tests for actions/target/target.py.
#
# Usage: sh tests/target/run.sh
#
# Builds throwaway repositories and asserts what target resolves from a build tag: the
# module, tag, directories, services and the code/infra flags computed since the last
# release that is an ancestor of HEAD. Every assertion prints PASS or FAIL; the script
# exits 1 when at least one of them fails.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
TARGET="${ROOT}/actions/target/target.py"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0
COUNT=0
OUT="${WORK}/output"
SUMMARY="${WORK}/summary"
LOG="${WORK}/log"
STATUS=0

pass() {
  echo "PASS ${1}"
  PASSED=$(( PASSED + 1 ))
}

fail() {
  echo "FAIL ${1}"
  FAILED=$(( FAILED + 1 ))
}

run_target() {
  : > "${OUT}"
  : > "${SUMMARY}"
  STATUS=0
  REF_NAME="${1}" GITHUB_OUTPUT="${OUT}" GITHUB_STEP_SUMMARY="${SUMMARY}" \
    python3 "${TARGET}" > "${LOG}" 2>&1 || STATUS=$?
}

field() {
  sed -n "s/^${1}=//p" "${OUT}" | tail -n 1
}

check() {
  scenario="${1}"
  key="${2}"
  expected="${3}"
  got="$(field "${key}")"
  if [ "${got}" = "${expected}" ]; then
    pass "${scenario}: ${key}=${expected}"
  else
    fail "${scenario}: ${key} expected '${expected}', got '${got}'"
  fi
}

check_flags() {
  check "${1}" code "${2}"
  check "${1}" infra "${3}"
}

check_summary() {
  if grep -qxF "${2}" "${SUMMARY}"; then
    pass "${1}: summary '${2}'"
  else
    fail "${1}: summary expected '${2}', got '$(cat "${SUMMARY}")'"
  fi
}

check_error() {
  scenario="${1}"
  message="${2}"
  if [ "${STATUS}" -ne 0 ] && grep -qxF "${message}" "${LOG}"; then
    pass "${scenario}"
  else
    fail "${scenario}: expected exit != 0 and '${message}', got status ${STATUS} and '$(cat "${LOG}")'"
  fi
}

registry() {
  mkdir -p .github
  cat > .github/modules.json <<'JSON'
{
  "shared": [".github/", ".ward/", "Makefile"],
  "modules": {
    "core": {
      "services": ["api", "worker"]
    },
    "gateway": {},
    "events": {
      "code": { "dir": "modules/events/app" }
    }
  }
}
JSON
}

commit() {
  git add -A
  git commit -qm "${1}"
}

new_repo() {
  COUNT=$(( COUNT + 1 ))
  mkdir -p "${WORK}/repo${COUNT}"
  cd "${WORK}/repo${COUNT}" || exit 1
  git init -q -b main
  git config user.email "fixture@example.com"
  git config user.name "target fixture"
  registry
  mkdir -p modules/core/code modules/core/infra modules/gateway/code modules/gateway/infra
  mkdir -p modules/events/app modules/events/infra docs .ward
  printf 'x\n' > modules/core/code/app.txt
  printf 'x\n' > modules/core/infra/main.txt
  printf 'x\n' > modules/gateway/code/app.txt
  printf 'x\n' > modules/gateway/infra/main.txt
  printf 'x\n' > modules/events/app/app.txt
  printf 'x\n' > modules/events/infra/main.txt
  printf 'x\n' > .ward/x
  printf '# a\n' > docs/a.md
  commit base
}

touch_code() {
  printf '%s\n' "${1}" >> modules/core/code/app.txt
  commit "code ${1}"
}

touch_infra() {
  printf '%s\n' "${1}" >> modules/core/infra/main.txt
  commit "infra ${1}"
}

echo "# invalid build tags"
new_repo
for ref in build/core-x core.2026-11-21.001 build/Core.2026-11-21.001 build/core.2026-11-21 build/core.2026-11-21.001.2 core; do
  run_target "${ref}"
  check_error "invalid '${ref}'" "::error::invalid build tag '${ref}' (expected build/<module>.YYYY-MM-DD.NNN)"
done

echo "# unknown module"
run_target build/ghost.2026-11-21.001
check_error "module outside the registry" "::error::build tag build/ghost.2026-11-21.001 names module ghost, which is not in .github/modules.json"

echo "# outputs from the registry"
new_repo
run_target build/core.2026-11-21.001
check "defaults" module core
check "defaults" tag core.2026-11-21.001
check "defaults" code_dir modules/core/code
check "defaults" infra_dir modules/core/infra
check "defaults" services api,worker
run_target build/gateway.2026-11-21.001
check "no services" services ""
check "no services" code_dir modules/gateway/code
run_target build/events.2026-11-21.001
check "custom dir" module events
check "custom dir" code_dir modules/events/app
check "custom dir" infra_dir modules/events/infra

echo "# no release"
new_repo
touch_code one
run_target build/core.2026-11-21.001
check_flags "no release" true true
check_summary "no release" "last release: none; code=true infra=true"

echo "# last release is an ancestor"
new_repo
git tag core.2026-11-01.001
touch_code one
run_target build/core.2026-11-21.001
check_flags "only code" true false
check_summary "only code" "last release: core.2026-11-01.001; code=true infra=false"

new_repo
git tag core.2026-11-01.001
touch_infra one
run_target build/core.2026-11-21.001
check_flags "only infra" false true
check_summary "only infra" "last release: core.2026-11-01.001; code=false infra=true"

new_repo
git tag core.2026-11-01.001
printf 'more\n' >> docs/a.md
commit docs
run_target build/core.2026-11-21.001
check_flags "only docs" false false
check_summary "only docs" "last release: core.2026-11-01.001; code=false infra=false"

new_repo
git tag core.2026-11-01.001
printf 'shared\n' >> .ward/x
commit shared
run_target build/core.2026-11-21.001
check_flags "shared" true true

new_repo
git tag core.2026-11-01.001
printf 'x\n' >> modules/gateway/code/app.txt
commit gateway
run_target build/core.2026-11-21.001
check_flags "other module changed" false false

new_repo
git tag events.2026-11-01.001
printf 'x\n' >> modules/events/app/app.txt
commit events
run_target build/events.2026-11-21.001
check_flags "custom code dir" true false

echo "# ordering"
new_repo
git tag core.2026-11-01.999
touch_infra one
git tag core.2026-11-01.1000
touch_code two
run_target build/core.2026-11-21.001
check_flags "four digit NNN is an integer" true false
check_summary "four digit NNN is an integer" "last release: core.2026-11-01.1000; code=true infra=false"

new_repo
git tag core.2026-11-02.001
touch_infra one
git tag core.2026-11-01.009
touch_code two
run_target build/core.2026-11-21.001
check_flags "date wins over NNN" true true
check_summary "date wins over NNN" "last release: core.2026-11-02.001; code=true infra=true"

new_repo
git tag core.2026-11-01.002
touch_infra one
git tag core.2026-11-01.010
touch_code two
run_target build/core.2026-11-21.001
check_flags "NNN as integer" true false
check_summary "NNN as integer" "last release: core.2026-11-01.010; code=true infra=false"

echo "# ignored tags"
new_repo
git tag core.2026-11-01.001
touch_infra one
git tag build/core.2026-11-20.001
git tag gateway.2026-11-20.001
touch_code two
run_target build/core.2026-11-21.001
check_flags "build and other module tags ignored" true true
check_summary "build and other module tags ignored" "last release: core.2026-11-01.001; code=true infra=true"

new_repo
git tag core.2026-11-01.001
git checkout -q -b side
touch_infra side
git tag core.2026-11-05.001
git checkout -q main
touch_code main
run_target build/core.2026-11-21.001
check_flags "newer release not an ancestor" true false
check_summary "newer release not an ancestor" "last release: core.2026-11-01.001; code=true infra=false"

new_repo
touch_code one
git checkout -q -b side
touch_infra side
git tag core.2026-11-05.001
git checkout -q main
touch_code two
run_target build/core.2026-11-21.001
check_flags "only non ancestor releases" true true
check_summary "only non ancestor releases" "last release: none; code=true infra=true"

echo "# errors computing the range"
new_repo
git tag core.2026-11-01.001
touch_code one
printf 'x\n' > modules/Bad.txt
python3 - <<'PY'
import json

with open(".github/modules.json", encoding="utf-8") as handle:
    reg = json.load(handle)
reg["modules"]["Bad"] = {}
with open(".github/modules.json", "w", encoding="utf-8") as handle:
    json.dump(reg, handle)
PY
commit "bad registry"
run_target build/core.2026-11-21.001
check_flags "detect fails" true true
check "detect fails" module core

echo "# build tag behind a published release"
new_repo
git tag core.2026-11-21.003
touch_code one
run_target build/core.2026-11-21.002
check_error "older build tag is refused" "::error::build tag build/core.2026-11-21.002 is behind core.2026-11-21.003: a newer release of core is already published"
check "older build tag emits nothing" module ""

new_repo
touch_code one
git checkout -q -b side
touch_infra side
git tag core.2026-11-21.003
git checkout -q main
touch_code two
run_target build/core.2026-11-21.002
check_error "newer release outside the ancestry still refuses" "::error::build tag build/core.2026-11-21.002 is behind core.2026-11-21.003: a newer release of core is already published"

new_repo
git tag core.2026-11-21.001
touch_code one
run_target build/core.2026-11-21.002
check "older release does not block" module core
check "older release does not block" tag core.2026-11-21.002

new_repo
git tag gateway.2026-11-21.009
git tag build/core.2026-11-21.009
touch_code one
run_target build/core.2026-11-21.002
check "other module and build tags do not block" module core

new_repo
git tag core.2026-11-21.002
touch_code one
run_target build/core.2026-11-21.002
check "release equal to the build tag does not block" module core

echo "# reuse"
new_repo
git tag core.2026-11-01.001
touch_code one
run_target build/core.2026-11-21.001
check "one first-parent commit behind" reuse true

new_repo
git tag core.2026-11-01.001
touch_code one
touch_code two
run_target build/core.2026-11-21.001
check "two commits behind" reuse false

new_repo
touch_code one
run_target build/core.2026-11-21.001
check "no release" reuse false

new_repo
git tag core.2026-11-01.001
run_target build/core.2026-11-21.001
check "release at HEAD" reuse false

new_repo
git tag core.2026-11-01.001
git checkout -q -b side
printf 'x\n' >> modules/gateway/code/app.txt
commit gateway-side
git checkout -q main
touch_code main
git merge -q --no-ff side -m merge
run_target build/core.2026-11-21.001
check "merge commit counts first-parent steps" reuse false

new_repo
git tag core.2026-11-01.001
touch_code one
printf 'x\n' > modules/Bad.txt
python3 - <<'PY'
import json

with open(".github/modules.json", encoding="utf-8") as handle:
    reg = json.load(handle)
reg["modules"]["Bad"] = {}
with open(".github/modules.json", "w", encoding="utf-8") as handle:
    json.dump(reg, handle)
PY
git add -A
git commit -qm "bad registry"
run_target build/core.2026-11-21.001
check "detect fails after one commit" reuse false
check_flags "detect fails after one commit" true true

run_target build/ghost.2026-11-21.001
check "unknown module" reuse ""

echo
echo "passed=${PASSED} failed=${FAILED}"
[ "${FAILED}" -eq 0 ] || exit 1
