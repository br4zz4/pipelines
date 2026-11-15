#!/bin/sh
# run.sh — fixture tests for actions/releases/releases.sh.
#
# Usage: sh tests/releases/run.sh
#
# Runs the script inside a throwaway git repository with a three-module
# registry and asserts the `releases` and `environment` outputs for tag pushes
# and dispatches, plus the failure modes. Exits 1 when any assertion fails.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="${ROOT}/actions/releases/releases.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0
OUT="${WORK}/output"
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

run() {
  : > "${OUT}"
  : > "${LOG}"
  STATUS=0
  EVENT_NAME="${1}" REF_TYPE="${2}" REF_NAME="${3}" GITHUB_OUTPUT="${OUT}" \
    sh "${SCRIPT}" > "${LOG}" 2>&1 || STATUS=$?
}

output() {
  python3 - "${OUT}" "${1}" <<'PY'
import json
import sys

values = {}
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        key, _, value = line.rstrip("\n").partition("=")
        values[key] = value

if sys.argv[2] == "environment":
    print(values["environment"])
else:
    releases = json.loads(values["releases"])
    print("|".join(f"{m}={releases[m]}" for m in sorted(releases)))
PY
}

expect() {
  scenario="${1}"
  expected_env="${2}"
  expected_rel="${3}"
  if [ "${STATUS}" -ne 0 ]; then
    fail "${scenario}: exit ${STATUS}: $(cat "${LOG}")"
    return
  fi
  got_env="$(output environment 2>&1 || true)"
  got_rel="$(output releases 2>&1 || true)"
  if [ "${got_env}" = "${expected_env}" ] && [ "${got_rel}" = "${expected_rel}" ]; then
    pass "${scenario}"
  else
    fail "${scenario}: expected ${expected_env} ${expected_rel}, got ${got_env} ${got_rel}"
  fi
}

expect_failure() {
  scenario="${1}"
  needle="${2:-}"
  if [ "${STATUS}" -eq 0 ]; then
    fail "${scenario}: expected failure, exit 0"
    return
  fi
  if [ -n "${needle}" ] && ! grep -q -- "${needle}" "${LOG}"; then
    fail "${scenario}: output lacks '${needle}': $(cat "${LOG}")"
    return
  fi
  pass "${scenario}"
}

mkdir -p "${WORK}/repo/.github"
cd "${WORK}/repo"
cat > .github/modules.json <<'JSON'
{"modules":{"core":{},"events":{},"gateway":{}}}
JSON
git init -q
git config user.email "fixture@example.com"
git config user.name "releases fixture"
git config tag.gpgsign false
git config commit.gpgsign false
git add -A
git commit -qm base

echo "# a: push of a release tag is staging"
run push tag core.2026-11-15.001
expect "push tag core" staging "core=core.2026-11-15.001|events=|gateway="

echo "# b: dispatch on a tag is production"
run workflow_dispatch tag events.2026-11-15.012
expect "dispatch tag events" production "core=|events=events.2026-11-15.012|gateway="

echo "# c: dispatch on a branch uses the tags at HEAD"
git tag core.2026-11-14.001
git tag foo.bar
git tag v1
run workflow_dispatch branch main
expect "branch with one release tag" production "core=core.2026-11-14.001|events=|gateway="

git tag events.2026-11-15.002
run workflow_dispatch branch main
expect "branch with core and events tags" production "core=core.2026-11-14.001|events=events.2026-11-15.002|gateway="

git tag core.2026-11-15.009
git tag core.2026-11-15.010
run workflow_dispatch branch main
expect "highest version wins (.010 over .009)" production "core=core.2026-11-15.010|events=events.2026-11-15.002|gateway="

echo "# d: tags on other commits are ignored"
git commit -q --allow-empty -m next
git tag gateway.2026-11-16.001
run workflow_dispatch branch main
expect "only tags pointing at HEAD count" production "core=|events=|gateway=gateway.2026-11-16.001"

echo "# e: branch without release tag fails"
git commit -q --allow-empty -m untagged
run workflow_dispatch branch main
expect_failure "dispatch on branch with no release tag" "this commit has no release tag"

git tag v2
git tag foo.bar2
run workflow_dispatch branch main
expect_failure "other tag formats do not count" "this commit has no release tag"

echo "# f: invalid tag format fails"
run push tag core.2026-11-15
expect_failure "date-only tag"
run push tag v1
expect_failure "v1 tag"
run push tag core.2026-11-15.01
expect_failure "two digit sequence"
run workflow_dispatch tag v1
expect_failure "dispatch on v1 tag"

echo "# g: unknown module fails"
run push tag billing.2026-11-15.001
expect_failure "tag of unregistered module" "billing"

echo "# h: unsupported events fail"
run push branch main
expect_failure "push of a branch"
run pull_request branch main
expect_failure "pull_request"
run schedule branch main
expect_failure "schedule"

echo
echo "passed=${PASSED} failed=${FAILED}"
[ "${FAILED}" -eq 0 ] || exit 1
