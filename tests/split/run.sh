#!/bin/sh
# run.sh — fixture tests for actions/split/split.sh.
#
# Usage: sh tests/split/run.sh
#
# Runs the script in a throwaway clone whose origin and push URL are a local
# bare repository (no network) and asserts the build tags pushed, the `builds`
# output, the summary and the failure modes. Exits 1 when any assertion fails.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="${ROOT}/actions/split/split.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

ZONE="America/Sao_Paulo"
DAY="$(TZ="${ZONE}" date +%Y-%m-%d)"
PASSED=0
FAILED=0
STATUS=0
CASE=""

pass() {
  echo "PASS ${1}"
  PASSED=$(( PASSED + 1 ))
}

fail() {
  echo "FAIL ${1}"
  FAILED=$(( FAILED + 1 ))
}

setup() {
  CASE="${WORK}/${1}"
  rm -rf "${CASE}"
  mkdir -p "${CASE}"
  git init -q --bare "${CASE}/origin.git"
  git init -q "${CASE}/work"
  (
    cd "${CASE}/work"
    git config user.email "fixture@example.com"
    git config user.name "split fixture"
    git config commit.gpgsign false
    git config tag.gpgsign false
    git commit -q --allow-empty -m base
    git remote add origin "${CASE}/origin.git"
  )
}

remote_tags() {
  git -C "${CASE}/origin.git" tag -l | sort | tr '\n' ' ' | sed 's/ $//'
}

push_remote_tag() {
  (
    cd "${CASE}/work"
    git tag "${1}"
    git push -q origin "refs/tags/${1}"
    git tag -d "${1}" > /dev/null
  )
}

run_split() {
  changes="${1}"
  : > "${CASE}/gh"
  : > "${CASE}/summary"
  STATUS=0
  (
    cd "${CASE}/work"
    env CHANGES="${changes}" GH_PIPELINES_TOKEN="${TOKEN-token}" \
      REMOTE_URL="${CASE}/origin.git" ZONE="${ZONE}" \
      GITHUB_OUTPUT="${CASE}/gh" GITHUB_STEP_SUMMARY="${CASE}/summary" \
      sh "${SCRIPT}"
  ) > "${CASE}/log" 2>&1 || STATUS=$?
}

output_value() {
  sed -n "s/^${1}=//p" "${CASE}/gh" | tail -n 1
}

expect_tags() {
  scenario="${1}"
  expected="${2}"
  got="$(remote_tags)"
  if [ "${got}" = "${expected}" ]; then
    pass "${scenario}"
  else
    fail "${scenario}: expected '${expected}', got '${got}'"
  fi
}

expect_success() {
  if [ "${STATUS}" -eq 0 ]; then
    pass "${1}"
  else
    fail "${1}: exit ${STATUS}: $(cat "${CASE}/log")"
  fi
}

expect_failure() {
  if [ "${STATUS}" -ne 0 ]; then
    pass "${1}"
  else
    fail "${1}: expected failure, exit 0"
  fi
}

expect_log() {
  if grep -qF -- "${2}" "${CASE}/log"; then
    pass "${1}"
  else
    fail "${1}: '${2}' not in log: $(cat "${CASE}/log")"
  fi
}

expect_log_line() {
  if grep -F -- "${2}" "${CASE}/log" | grep -qF -- "${3}"; then
    pass "${1}"
  else
    fail "${1}: no '${2}' line citing '${3}': $(cat "${CASE}/log")"
  fi
}

expect_output() {
  got="$(output_value "${2}")"
  if [ "${got}" = "${3}" ]; then
    pass "${1}"
  else
    fail "${1}: expected ${2}='${3}', got '${got}'"
  fi
}

CORE_GATEWAY='{"core":{"any":true,"code":true,"infra":false},"events":{"any":false,"code":false,"infra":false},"gateway":{"any":true,"code":false,"infra":true}}'
NONE='{"core":{"any":false,"code":false,"infra":false},"events":{"any":false,"code":false,"infra":false},"gateway":{"any":false,"code":false,"infra":false}}'
ONLY_CORE='{"core":{"any":true,"code":true,"infra":false},"events":{"any":false,"code":false,"infra":false}}'

echo "# a: two changed modules get one build tag each, in order"
setup two-modules
run_split "${CORE_GATEWAY}"
expect_success "two modules exit 0"
expect_tags "two modules push build tags" "build/core.${DAY}.001 build/gateway.${DAY}.001"
expect_output "two modules builds output" builds "core.${DAY}.001,gateway.${DAY}.001"
core_line="$(grep -nF "core.${DAY}.001" "${CASE}/log" | head -n 1 | cut -d: -f1 || true)"
gateway_line="$(grep -nF "gateway.${DAY}.001" "${CASE}/log" | head -n 1 | cut -d: -f1 || true)"
if [ -n "${core_line}" ] && [ -n "${gateway_line}" ] && [ "${core_line}" -lt "${gateway_line}" ]; then
  pass "two modules processed alphabetically"
else
  fail "two modules processed alphabetically: core line '${core_line}', gateway line '${gateway_line}'"
fi
head_sha="$(git -C "${CASE}/work" rev-parse HEAD)"
tag_target="$(git -C "${CASE}/origin.git" rev-parse "build/core.${DAY}.001^{commit}" 2>/dev/null || true)"
if [ "${tag_target}" = "${head_sha}" ]; then pass "build tag points at HEAD"; else fail "build tag points at HEAD: ${tag_target} != ${head_sha}"; fi
tag_type="$(git -C "${CASE}/origin.git" cat-file -t "build/core.${DAY}.001" 2>/dev/null || true)"
if [ "${tag_type}" = "tag" ]; then pass "build tag is annotated"; else fail "build tag is annotated: got '${tag_type}'"; fi
subject="$(git -C "${CASE}/origin.git" tag -l --format='%(contents:subject)' "build/core.${DAY}.001" 2>/dev/null || true)"
if [ "${subject}" = "build core.${DAY}.001" ]; then pass "build tag message"; else fail "build tag message: got '${subject}'"; fi

echo "# b: nothing changed"
setup nothing
run_split "${NONE}"
expect_success "nothing to build exit 0"
expect_tags "nothing to build pushes nothing" ""
expect_log "nothing to build message" "nothing to build"
if grep -qF "nothing to build" "${CASE}/summary"; then pass "nothing to build summary"; else fail "nothing to build summary: $(cat "${CASE}/summary")"; fi

echo "# c: build tag already on the remote reserves the number"
setup remote-build-tag
push_remote_tag "build/core.${DAY}.001"
before="$(git -C "${CASE}/origin.git" rev-parse "build/core.${DAY}.001")"
run_split "${ONLY_CORE}"
expect_success "reserved build tag exit 0"
expect_tags "reserved build tag pushes .002" "build/core.${DAY}.001 build/core.${DAY}.002"
expect_output "reserved build tag builds output" builds "core.${DAY}.002"
after="$(git -C "${CASE}/origin.git" rev-parse "build/core.${DAY}.001")"
if [ "${before}" = "${after}" ]; then pass "existing build tag is not overwritten"; else fail "existing build tag is not overwritten: ${before} -> ${after}"; fi

echo "# d: release tag without build tag reserves the number"
setup release-only
(cd "${CASE}/work" && git tag "core.${DAY}.001")
run_split "${ONLY_CORE}"
expect_success "release tag exit 0"
expect_tags "release tag pushes .002" "build/core.${DAY}.002"
expect_output "release tag builds output" builds "core.${DAY}.002"

echo "# e: rejected push fails the module, other modules still go"
setup rejected
cat > "${CASE}/origin.git/hooks/pre-receive" <<'HOOK'
#!/bin/sh
while read old new ref; do
  case "${ref}" in
    refs/tags/build/core.*) echo "rejected ${ref}" >&2; exit 1 ;;
  esac
done
exit 0
HOOK
chmod +x "${CASE}/origin.git/hooks/pre-receive"
run_split "${CORE_GATEWAY}"
expect_failure "rejected core exits non-zero"
expect_tags "rejected core still pushes gateway" "build/gateway.${DAY}.001"
expect_log_line "rejected core error cites core" "::error::" "core"
expect_output "rejected core builds output lists only gateway" builds "gateway.${DAY}.001"
if grep -F "::error::" "${CASE}/log" | grep -qF "gateway"; then
  fail "rejected core error does not cite gateway: $(cat "${CASE}/log")"
else
  pass "rejected core error does not cite gateway"
fi

echo "# f: existing remote tag is never force-overwritten"
setup no-force
push_remote_tag "build/core.${DAY}.001"
(cd "${CASE}/work" && git commit -q --allow-empty -m second)
before="$(git -C "${CASE}/origin.git" rev-parse "build/core.${DAY}.001")"
run_split "${ONLY_CORE}"
after="$(git -C "${CASE}/origin.git" rev-parse "build/core.${DAY}.001")"
if [ "${before}" = "${after}" ]; then pass "tag stays on its original object"; else fail "tag stays on its original object: ${before} -> ${after}"; fi
expect_tags "no-force pushes next number" "build/core.${DAY}.001 build/core.${DAY}.002"

echo "# g: missing token"
setup no-token
TOKEN="" run_split "${ONLY_CORE}"
expect_failure "missing token exits non-zero"
expect_log "missing token message" "missing token"
expect_tags "missing token pushes nothing" ""

echo
echo "passed=${PASSED} failed=${FAILED}"
[ "${FAILED}" -eq 0 ] || exit 1
