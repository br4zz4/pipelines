#!/bin/sh
set -u

GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
PATCH_SH="${ROOT}/actions/patch/patch.sh"
WORK="$(cd -P "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0
COUNT=0
STATUS=0
CODE=modules/core/code
GIT="git -c user.name=t -c user.email=t@t"

pass() {
  echo "PASS ${1}"
  PASSED=$(( PASSED + 1 ))
}

fail() {
  echo "FAIL ${1}"
  FAILED=$(( FAILED + 1 ))
}

seed() {
  mkdir -p "${1}/${CODE}/src" "${1}/${CODE}/test" "${1}/${CODE}/run" "${1}/${CODE}/ci/checks" "${1}/modules/checkout/code/src" "${1}/.github/workflows" "${1}/.ward"
  printf 'broken\n' > "${1}/${CODE}/src/app.txt"
  printf 'old\n' > "${1}/${CODE}/test/existing_test.txt"
  printf 'hook\n' > "${1}/${CODE}/run/test"
  printf 'check\n' > "${1}/${CODE}/ci/checks/test.sh"
  printf 'tool\n' > "${1}/${CODE}/mise.toml"
  printf 'other\n' > "${1}/modules/checkout/code/src/other.txt"
  printf 'wf\n' > "${1}/.github/workflows/ci.yml"
  printf 'cfg\n' > "${1}/.ward/config.yaml"
  printf 'readme\n' > "${1}/README.md"
}

new_repo() {
  COUNT=$(( COUNT + 1 ))
  CASE="${WORK}/case${COUNT}"
  REPO="${CASE}/repo"
  GOUT="${CASE}/github_output"
  LOG="${CASE}/log"
  PATCH="${CASE}/fix.patch"
  RESULT="${CASE}/result.json"
  mkdir -p "${REPO}"
  : > "${GOUT}"
  git -C "${REPO}" init -q
  seed "${REPO}"
  git -C "${REPO}" add -A
  ${GIT} -C "${REPO}" commit -q -m base
}

build_patch() {
  rm -rf "${CASE}/gen"
  cp -R "${REPO}" "${CASE}/gen"
  for spec in "$@"; do
    f="${spec}"
    mkdir -p "${CASE}/gen/$(dirname "${f}")"
    printf 'changed %s\n' "${f}" > "${CASE}/gen/${f}"
  done
  git -C "${CASE}/gen" add -A
  git -C "${CASE}/gen" diff --no-color --cached --binary > "${PATCH}"
}

write_result() {
  printf '%s\n' "${1}" > "${RESULT}"
}

run_patch() {
  STATUS=0
  (
    cd "${REPO}" && env -i \
      PATH="${PATH}" \
      HOME="${CASE}" \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_CONFIG_NOSYSTEM=1 \
      GITHUB_OUTPUT="${GOUT}" \
      sh "${PATCH_SH}" "$@"
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

reject() {
  expect_status "${1}" 1
  out_has "${1}: reason" "reason=${2}"
}

file_is() {
  if [ -f "${2}" ] && [ "$(cat "${2}")" = "${3}" ]; then
    pass "${1}"
  else
    fail "${1}: ${2} is not '${3}'"
  fi
}

file_absent() {
  if [ -e "${2}" ]; then
    fail "${1}: ${2} exists"
  else
    pass "${1}"
  fi
}

APP="${CODE}/src/app.txt"
NEWTEST="${CODE}/test/regression_test.txt"

if [ -f "${PATCH_SH}" ]; then
  pass "patch.sh exists"
else
  fail "patch.sh missing"
fi

new_repo
: > "${PATCH}"
write_result "{\"tests\":[\"${NEWTEST}\"]}"
run_patch scope "${PATCH}" "${RESULT}" "${CODE}"
reject "empty patch" "empty patch"

for forbidden in \
  ".github/workflows/ci.yml" \
  ".ward/config.yaml" \
  "${CODE}/ci/checks/test.sh" \
  "${CODE}/ci/checks/lint.sh" \
  "${CODE}/run/test" \
  "${CODE}/run/lint" \
  "ci/setup.sh" \
  "run/boot" \
  "mise.toml" \
  "${CODE}/mise.toml" \
  "${CODE}/e2e/spec.txt"; do
  new_repo
  build_patch "${APP}" "${NEWTEST}" "${forbidden}"
  write_result "{\"tests\":[\"${NEWTEST}\"]}"
  run_patch scope "${PATCH}" "${RESULT}" "${CODE}"
  reject "forbidden ${forbidden}" "forbidden path ${forbidden}"
done

new_repo
build_patch "${APP}" "${NEWTEST}" "${CODE}/ci/checks/test.sh"
write_result "{\"tests\":[\"${NEWTEST}\"]}"
run_patch scope "${PATCH}" "${RESULT}" "${CODE}"
reject "forbidden existing ci hook edit" "forbidden path ${CODE}/ci/checks/test.sh"

new_repo
mkdir -p "${CASE}/gen"
rm -rf "${CASE}/gen"
cp -R "${REPO}" "${CASE}/gen"
mkdir -p "${CASE}/gen/${CODE}/run"
git -C "${CASE}/gen" mv "${APP}" "${CODE}/run/app.txt"
git -C "${CASE}/gen" add -A
git -C "${CASE}/gen" diff --no-color --cached --binary -M > "${PATCH}"
write_result "{\"tests\":[\"${NEWTEST}\"]}"
run_patch scope "${PATCH}" "${RESULT}" "${CODE}"
reject "forbidden rename into run/" "forbidden path ${CODE}/run/app.txt"

new_repo
rm -rf "${CASE}/gen"
cp -R "${REPO}" "${CASE}/gen"
git -C "${CASE}/gen" mv "${CODE}/run/test" "${CODE}/src/moved.txt"
git -C "${CASE}/gen" add -A
git -C "${CASE}/gen" diff --no-color --cached --binary -M > "${PATCH}"
write_result "{\"tests\":[\"${NEWTEST}\"]}"
run_patch scope "${PATCH}" "${RESULT}" "${CODE}"
reject "forbidden rename out of run/" "forbidden path ${CODE}/run/test"

new_repo
rm -rf "${CASE}/gen"
cp -R "${REPO}" "${CASE}/gen"
printf '\000\001\002binary\000' > "${CASE}/gen/.github/blob.bin"
printf 'x\n' > "${CASE}/gen/${APP}"
git -C "${CASE}/gen" add -A
git -C "${CASE}/gen" diff --no-color --cached --binary > "${PATCH}"
write_result "{\"tests\":[\"${NEWTEST}\"]}"
run_patch scope "${PATCH}" "${RESULT}" "${CODE}"
reject "forbidden binary file" "forbidden path .github/blob.bin"

new_repo
build_patch "${APP}" "${NEWTEST}" "modules/checkout/code/src/other.txt"
write_result "{\"tests\":[\"${NEWTEST}\"]}"
run_patch scope "${PATCH}" "${RESULT}" "${CODE}"
reject "outside module" "outside module modules/checkout/code/src/other.txt"

new_repo
build_patch "${APP}" "${NEWTEST}" "README.md"
write_result "{\"tests\":[\"${NEWTEST}\"]}"
run_patch scope "${PATCH}" "${RESULT}" "${CODE}"
reject "outside module root file" "outside module README.md"

new_repo
build_patch "${APP}" "${NEWTEST}" ".github/workflows/ci.yml" "modules/checkout/code/src/other.txt"
write_result "{\"tests\":[\"${NEWTEST}\"]}"
run_patch scope "${PATCH}" "${RESULT}" "${CODE}"
reject "forbidden before outside module" "forbidden path .github/workflows/ci.yml"

new_repo
build_patch "modules/checkout/code/src/other.txt" "${CODE}/run/test"
write_result "{\"tests\":[]}"
run_patch scope "${PATCH}" "${RESULT}" "${CODE}"
reject "forbidden before outside module and empty tests" "forbidden path ${CODE}/run/test"

new_repo
build_patch "${APP}" "modules/checkout/code/src/other.txt"
write_result '{"tests":[]}'
run_patch scope "${PATCH}" "${RESULT}" "${CODE}"
reject "outside module before empty tests" "outside module modules/checkout/code/src/other.txt"

new_repo
build_patch "${APP}" "${NEWTEST}"
write_result '{"tests":[]}'
run_patch scope "${PATCH}" "${RESULT}" "${CODE}"
reject "empty tests" "empty tests"

new_repo
build_patch "${APP}" "${NEWTEST}"
write_result '{"status":"fixed"}'
run_patch scope "${PATCH}" "${RESULT}" "${CODE}"
reject "missing tests key" "empty tests"

new_repo
build_patch "${APP}" "${NEWTEST}"
write_result "{\"tests\":[\"${CODE}/test/other_test.txt\"]}"
run_patch scope "${PATCH}" "${RESULT}" "${CODE}"
reject "test not in patch" "test ${CODE}/test/other_test.txt not in patch"

new_repo
build_patch "${APP}" "${NEWTEST}"
write_result "{\"tests\":[\"${NEWTEST}\",\"${CODE}/test/ghost_test.txt\"]}"
run_patch scope "${PATCH}" "${RESULT}" "${CODE}"
reject "second test not in patch" "test ${CODE}/test/ghost_test.txt not in patch"

new_repo
build_patch "${APP}" "${NEWTEST}"
write_result "{\"tests\":[\"${NEWTEST}\"]}"
run_patch scope "${PATCH}" "${RESULT}" "${CODE}"
if expect_status "scope green" 0; then
  out_has "scope green: empty reason" "reason="
fi

new_repo
build_patch "${APP}" "${NEWTEST}" "${CODE}/test/existing_test.txt"
write_result "{\"tests\":[\"${NEWTEST}\",\"${CODE}/test/existing_test.txt\"]}"
run_patch scope "${PATCH}" "${RESULT}" "${CODE}"
if expect_status "scope green with several tests" 0; then
  out_has "scope green with several tests: empty reason" "reason="
fi

new_repo
build_patch "${APP}" "${NEWTEST}" "${CODE}/src/runner.txt" "${CODE}/src/ci_helper.txt" "${CODE}/src/mise.toml.txt" "${CODE}/src/github.txt"
write_result "{\"tests\":[\"${NEWTEST}\"]}"
run_patch scope "${PATCH}" "${RESULT}" "${CODE}"
if expect_status "scope green with lookalike names" 0; then
  out_has "scope green with lookalike names: empty reason" "reason="
fi

new_repo
build_patch "${APP}" "${NEWTEST}"
write_result "{\"tests\":[\"${NEWTEST}\"]}"
run_patch tests "${PATCH}" "${RESULT}"
if expect_status "tests applies" 0; then
  file_is "tests: test file applied" "${REPO}/${NEWTEST}" "changed ${NEWTEST}"
  file_is "tests: production file untouched" "${REPO}/${APP}" "broken"
fi

new_repo
build_patch "${APP}" "${NEWTEST}" "${CODE}/test/existing_test.txt" "${CODE}/test/second_test.txt"
write_result "{\"tests\":[\"${NEWTEST}\",\"${CODE}/test/existing_test.txt\"]}"
run_patch tests "${PATCH}" "${RESULT}"
if expect_status "tests applies several" 0; then
  file_is "tests several: new test applied" "${REPO}/${NEWTEST}" "changed ${NEWTEST}"
  file_is "tests several: modified test applied" "${REPO}/${CODE}/test/existing_test.txt" "changed ${CODE}/test/existing_test.txt"
  file_absent "tests several: unlisted test not applied" "${REPO}/${CODE}/test/second_test.txt"
  file_is "tests several: production file untouched" "${REPO}/${APP}" "broken"
fi

new_repo
build_patch "${APP}" "${NEWTEST}" "${CODE}/src/extra.txt"
write_result "{\"tests\":[\"${NEWTEST}\"]}"
run_patch tests "${PATCH}" "${RESULT}"
expect_status "tests ignores other production files" 0
file_absent "tests: new production file not applied" "${REPO}/${CODE}/src/extra.txt"

new_repo
build_patch "${APP}" "${NEWTEST}" "${CODE}/src/extra.txt"
write_result "{\"tests\":[\"${NEWTEST}\"]}"
printf 'dirty\n' > "${REPO}/${APP}"
run_patch full "${PATCH}"
if expect_status "full applies" 0; then
  file_is "full: production file patched" "${REPO}/${APP}" "changed ${APP}"
  file_is "full: test file applied" "${REPO}/${NEWTEST}" "changed ${NEWTEST}"
  file_is "full: new production file applied" "${REPO}/${CODE}/src/extra.txt" "changed ${CODE}/src/extra.txt"
fi

new_repo
build_patch "${APP}" "${NEWTEST}"
write_result "{\"tests\":[\"${NEWTEST}\"]}"
run_patch tests "${PATCH}" "${RESULT}"
printf 'scratch\n' > "${REPO}/${CODE}/src/scratch.txt"
printf 'tampered\n' > "${REPO}/${CODE}/test/existing_test.txt"
run_patch full "${PATCH}"
if expect_status "full after tests" 0; then
  file_is "full after tests: production file patched" "${REPO}/${APP}" "changed ${APP}"
  file_is "full after tests: test file applied once" "${REPO}/${NEWTEST}" "changed ${NEWTEST}"
  file_absent "full after tests: untracked scratch removed" "${REPO}/${CODE}/src/scratch.txt"
  file_is "full after tests: tracked edit reverted" "${REPO}/${CODE}/test/existing_test.txt" "old"
fi

echo "${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ]
