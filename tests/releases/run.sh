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
  unset ROLLBACK_TO ENVIRONMENT_INPUT
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
{"modules":{"core":{},"events":{"code":{"dir":"modules/events/app"},"infra":{"dir":"modules/events/iac"}},"gateway":{}}}
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

echo "# b: dispatch on a tag defaults to staging"
run workflow_dispatch tag events.2026-11-15.012
expect "dispatch tag events" staging "core=|events=events.2026-11-15.012|gateway="

echo "# c: dispatch on a tag honors ENVIRONMENT_INPUT"
ENVIRONMENT_INPUT=production run workflow_dispatch tag events.2026-11-15.012
expect "dispatch tag events production" production "core=|events=events.2026-11-15.012|gateway="
ENVIRONMENT_INPUT=staging run workflow_dispatch tag core.2026-11-15.003
expect "dispatch tag core staging" staging "core=core.2026-11-15.003|events=|gateway="

echo "# d: dispatch on a branch always fails"
git tag core.2026-11-14.001
run workflow_dispatch branch main
expect_failure "branch dispatch with release tag" "dispatch requires a release tag"

git commit -q --allow-empty -m untagged
run workflow_dispatch branch main
expect_failure "branch dispatch without release tag" "dispatch requires a release tag"

field() {
  grep "^${1}=" "${OUT}" | head -n 1 | cut -d= -f2-
}

expect_field() {
  scenario="${1}"
  name="${2}"
  expected="${3}"
  if [ "${STATUS}" -ne 0 ]; then
    fail "${scenario}: exit ${STATUS}: $(cat "${LOG}")"
    return
  fi
  got="$(field "${name}")"
  if [ "${got}" = "${expected}" ]; then
    pass "${scenario}"
  else
    fail "${scenario}: expected ${name}='${expected}', got '${got}'"
  fi
}

echo "# i: rollback_to on dispatch"
ROLLBACK_TO=core.2026-11-10.002 run workflow_dispatch tag core.2026-11-15.003
expect "rollback maps module to ROLLBACK_TO" staging "core=core.2026-11-10.002|events=|gateway="
expect_field "rollback_of is the ref" rollback_of core.2026-11-15.003
expect_field "rollback tag output is ROLLBACK_TO" tag core.2026-11-10.002
ENVIRONMENT_INPUT=production ROLLBACK_TO=core.2026-11-10.002 run workflow_dispatch tag core.2026-11-15.003
expect "rollback keeps the environment input" production "core=core.2026-11-10.002|events=|gateway="

ROLLBACK_TO=events.2026-11-10.002 run workflow_dispatch tag core.2026-11-15.003
expect_failure "rollback_to of another module" "rollback_to events.2026-11-10.002 is not a release of core"
ROLLBACK_TO=xyz run workflow_dispatch tag core.2026-11-15.003
expect_failure "invalid rollback_to" "invalid release tag"

ROLLBACK_TO=core.2026-11-10.002 run push tag core.2026-11-15.003
expect "push ignores ROLLBACK_TO" staging "core=core.2026-11-15.003|events=|gateway="
expect_field "push has empty rollback_of" rollback_of ""
ROLLBACK_TO=xyz run push tag core.2026-11-15.003
expect_field "push ignores an invalid ROLLBACK_TO" rollback_of ""

run workflow_dispatch tag core.2026-11-15.003
expect_field "dispatch without ROLLBACK_TO has empty rollback_of" rollback_of ""
ROLLBACK_TO='' run workflow_dispatch tag core.2026-11-15.003
expect_field "dispatch with empty ROLLBACK_TO has empty rollback_of" rollback_of ""

echo "# j: code_dir and infra_dir"
run push tag core.2026-11-15.001
expect_field "default code_dir" code_dir modules/core/code
expect_field "default infra_dir" infra_dir modules/core/infra
run push tag events.2026-11-15.001
expect_field "custom code_dir" code_dir modules/events/app
expect_field "custom infra_dir" infra_dir modules/events/iac
ROLLBACK_TO=events.2026-11-10.002 run workflow_dispatch tag events.2026-11-15.001
expect_field "rollback keeps the module dirs" code_dir modules/events/app

echo "# k: action declares rollback_to, code_dir, infra_dir, rollback_of"
ACTION="${ROOT}/actions/releases/action.yml"
DECLARED="$(python3 -I -c 'import sys, yaml
a = yaml.safe_load(open(sys.argv[1]))
i = a["inputs"].get("rollback_to")
print("input=" + ("MISSING" if i is None else "ok"))
print("input_default=" + repr(None if i is None else i.get("default")))
for k in ("code_dir", "infra_dir", "rollback_of"):
    o = a["outputs"].get(k)
    print(k + "=" + ("MISSING" if o is None else o["value"]))
print("env=" + str(a["runs"]["steps"][0]["env"].get("ROLLBACK_TO")))' "${ACTION}" 2>&1 || true)"
for line in "input=ok" "input_default=''" 'code_dir=${{ steps.releases.outputs.code_dir }}' 'infra_dir=${{ steps.releases.outputs.infra_dir }}' 'rollback_of=${{ steps.releases.outputs.rollback_of }}' 'env=${{ inputs.rollback_to }}'; do
  if printf '%s\n' "${DECLARED}" | grep -qxF -- "${line}"; then pass "action declares ${line}"; else fail "action declares ${line}: ${DECLARED}"; fi
done


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
