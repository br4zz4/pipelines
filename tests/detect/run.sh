#!/bin/sh
# run.sh — fixture tests for actions/detect/detect.py.
#
# Usage: sh tests/detect/run.sh
#
# Builds a throwaway repository with two modules and asserts the single `changes`
# object detect emits (any/code/infra per module) for push and dispatch events. Every assertion prints PASS or FAIL; the script exits 1 when
# at least one of them fails.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
DETECT="${ROOT}/actions/detect/detect.py"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0
OUT=""

value() {
  python3 - "${1}" "${2}" <<'PY'
import json
import sys

path, expr = sys.argv[1], sys.argv[2]
values = {}
with open(path, encoding="utf-8") as handle:
    for line in handle:
        key, _, value = line.rstrip("\n").partition("=")
        values[key] = value

changes = json.loads(values["changes"])


def flags(module):
    entry = changes[module]
    return "".join("1" if entry[k] is True else "0" if entry[k] is False else "?" for k in ("any", "code", "infra"))


print(eval(expr))
PY
}

expect() {
  scenario="${1}"
  expected="${2}"
  expr="${3}"
  got="$(value "${OUT}" "${expr}" 2>&1 || true)"
  if [ "${got}" = "${expected}" ]; then
    echo "PASS ${scenario}"
    PASSED=$(( PASSED + 1 ))
  else
    echo "FAIL ${scenario}: expected ${expected}, got ${got}"
    FAILED=$(( FAILED + 1 ))
  fi
}

ok() {
  echo "PASS ${1}"
  PASSED=$(( PASSED + 1 ))
}

bad() {
  echo "FAIL ${1}"
  FAILED=$(( FAILED + 1 ))
}

detect() {
  event="${1}"
  before="${2}"
  OUT="${WORK}/output"
  : > "${OUT}"
  GITHUB_OUTPUT="${OUT}" \
  GITHUB_EVENT_NAME="${event}" \
  GITHUB_BASE_REF=main \
  EVENT_BEFORE="${before}" \
  INPUT_REGISTRY="${REGISTRY:-.github/modules.json}" \
  python3 "${DETECT}"
}

SUMMARY='"|".join(m + "=" + flags(m) for m in sorted(changes))'

mkdir -p "${WORK}/.github" "${WORK}/docs"
mkdir -p "${WORK}/modules/core/code" "${WORK}/modules/core/infra"
mkdir -p "${WORK}/modules/gateway/code" "${WORK}/modules/gateway/infra"
cd "${WORK}" || exit 1

cat > .github/modules.json <<'JSON'
{
  "shared": [".github/", ".project/", "Makefile", "compose.yml"],
  "modules": {
    "core": {
      "code": { "dir": "modules/core/code" },
      "infra": { "dir": "modules/core/infra" }
    },
    "gateway": {
      "code": { "dir": "modules/gateway/code" },
      "infra": { "dir": "modules/gateway/infra" }
    }
  }
}
JSON

printf 'x\n' > modules/core/code/.keep
printf 'x\n' > modules/core/infra/.keep
printf 'x\n' > modules/gateway/code/.keep
printf 'x\n' > modules/gateway/infra/.keep
printf '# docs\n' > docs/README.md

git init -q
git config user.email "fixture@example.com"
git config user.name "detect fixture"
git add -A
git commit -qm base
BASE="$(git rev-parse HEAD)"

echo "# a: push touching only modules/core/code"
printf 'code\n' > modules/core/code/app.txt
git add -A
git commit -qm "core code"
CORE="$(git rev-parse HEAD)"
detect push "${BASE}"
expect "push touches only core code" "core=110|gateway=000" "${SUMMARY}"
expect "changes holds JSON booleans" "True|True|False" \
  '"|".join(str(x) for x in (changes["core"]["any"], changes["core"]["code"], changes["gateway"]["any"] or changes["core"]["infra"]))'

echo "# b: push touching only modules/gateway/infra"
printf 'infra\n' > modules/gateway/infra/main.txt
git add -A
git commit -qm "gateway infra"
GW="$(git rev-parse HEAD)"
detect push "${CORE}"
expect "push touches only gateway infra" "core=000|gateway=101" "${SUMMARY}"

echo "# c: push touching core infra and gateway code"
printf 'infra\n' > modules/core/infra/main.txt
printf 'code\n' > modules/gateway/code/app.txt
git add -A
git commit -qm "mixed"
MIX="$(git rev-parse HEAD)"
detect push "${GW}"
expect "push touches core infra and gateway code" "core=101|gateway=110" "${SUMMARY}"

echo "# d: push touching only docs"
printf 'more docs\n' >> docs/README.md
git add -A
git commit -qm docs
DOCS="$(git rev-parse HEAD)"
detect push "${MIX}"
expect "push touches only docs" "core=000|gateway=000" "${SUMMARY}"

echo "# e: push touching a shared path"
printf 'shared\n' > .github/shared.txt
git add -A
git commit -qm shared
detect push "${DOCS}"
expect "push touches .github (shared)" "core=111|gateway=111" "${SUMMARY}"

echo "# f: workflow_dispatch counts as everything"
detect workflow_dispatch ""
expect "workflow_dispatch touches every module" "core=111|gateway=111" "${SUMMARY}"

echo "# g: other events count as everything"
detect schedule ""
expect "schedule touches every module" "core=111|gateway=111" "${SUMMARY}"

echo "# h: output contract"
detect push "${BASE}"
if [ "$(grep -c '^changes=' "${OUT}")" -eq 1 ] && [ "$(wc -l < "${OUT}" | tr -d ' ')" -eq 1 ]; then
  ok "single changes line is emitted"
else
  bad "single changes line is emitted: $(cat "${OUT}")"
fi
for key in code infra modules tracks any core_code core_infra gateway_code gateway_infra; do
  if grep -q "^${key}=" "${OUT}"; then
    bad "legacy output ${key} must not exist"
  else
    ok "legacy output ${key} is absent"
  fi
done

echo "# i: push without a valid before nor HEAD^ counts as everything"
SOLO="${WORK}/solo"
mkdir -p "${SOLO}/.github" "${SOLO}/modules/core/code"
cp .github/modules.json "${SOLO}/.github/modules.json"
printf 'x\n' > "${SOLO}/modules/core/code/.keep"
(
  cd "${SOLO}"
  git init -q
  git config user.email "fixture@example.com"
  git config user.name "detect fixture"
  git add -A
  git commit -qm only
)
cd "${SOLO}"
detect push "0000000000000000000000000000000000000000"
expect "push with no before and no HEAD^ touches every module" "core=111|gateway=111" "${SUMMARY}"
cd "${WORK}"

echo "# j: invalid module name is rejected"
mkdir -p "${WORK}/bad"
cat > "${WORK}/bad/modules.json" <<'JSON'
{ "modules": { "Bad-Name": {} } }
JSON
OUT="${WORK}/output"
: > "${OUT}"
if GITHUB_OUTPUT="${OUT}" GITHUB_EVENT_NAME=workflow_dispatch GITHUB_BASE_REF=main EVENT_BEFORE="" \
  INPUT_REGISTRY="${WORK}/bad/modules.json" python3 "${DETECT}" >/dev/null 2>&1; then
  bad "module name Bad-Name is rejected"
else
  ok "module name Bad-Name is rejected"
fi

cd "${WORK}" || exit 1

echo "# k: commit with only documentation"
PRE_DOCS="$(git rev-parse HEAD)"
mkdir -p .project/docs modules/core/infra/terraform/gcp
printf 'readme\n' > README.md
printf 'x\n' > docs/x.md
printf 'old\n' > .project/docs/old.txt
printf 'gcp\n' > modules/core/infra/terraform/gcp/README.md
git add -A
git commit -qm "only documentation"
detect push "${PRE_DOCS}"
expect "documentation-only commit touches nothing" "core=000|gateway=000" "${SUMMARY}"

echo "# l: documentation together with code"
PRE_MIXED_DOCS="$(git rev-parse HEAD)"
printf 'more\n' >> docs/x.md
mkdir -p modules/core/code/app/models
printf 'class A; end\n' > modules/core/code/app/models/a.rb
git add -A
git commit -qm "docs and code"
detect push "${PRE_MIXED_DOCS}"
expect "documentation with code keeps code true and infra false" "core=110|gateway=000" "${SUMMARY}"

echo "# m: .project outside docs stays shared"
PRE_PROJECT="$(git rev-parse HEAD)"
mkdir -p .project/ci/gcp
printf '#!/bin/sh\n' > .project/ci/gcp/apply.sh
git add -A
git commit -qm "project ci"
detect push "${PRE_PROJECT}"
expect ".project/ci change touches code and infra of every module" "core=111|gateway=111" "${SUMMARY}"

echo
echo "passed=${PASSED} failed=${FAILED}"
[ "${FAILED}" -eq 0 ] || exit 1
