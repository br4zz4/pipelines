#!/bin/sh
# run.sh — fixture tests for actions/apply-needed/needed.py.
#
# Usage: sh tests/apply_needed/run.sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
NEEDED="${ROOT}/actions/apply-needed/needed.py"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0

needed() {
  environment="${1}"
  module="${2}"
  tag="${3}"
  previous="${4}"
  out="${WORK}/output"
  : > "${out}"
  GITHUB_OUTPUT="${out}" ENVIRONMENT="${environment}" MODULE="${module}" TAG="${tag}" PREVIOUS="${previous}" FORCE="${FORCE:-}" \
    python3 "${NEEDED}" >/dev/null 2>&1 || true
  cat "${out}"
}

expect() {
  scenario="${1}"
  expected="${2}"
  got="$(needed "${3}" "${4}" "${5}" "${6}" | tr -d '\n')"
  if [ "${got}" = "needed=${expected}" ]; then
    echo "PASS ${scenario}"
    PASSED=$(( PASSED + 1 ))
  else
    echo "FAIL ${scenario}: expected needed=${expected}, got '${got}'"
    FAILED=$(( FAILED + 1 ))
  fi
}

commit_tag() {
  git add -A
  git commit -qm "${1}"
  git tag "${2}"
}

mkdir -p "${WORK}/repo/.github" "${WORK}/repo/docs" "${WORK}/repo/.ward"
mkdir -p "${WORK}/repo/modules/core/code" "${WORK}/repo/modules/core/infra"
mkdir -p "${WORK}/repo/modules/gateway/code" "${WORK}/repo/modules/gateway/infra"
cd "${WORK}/repo" || exit 1

cat > .github/modules.json <<'JSON'
{
  "shared": [".github/", ".ward/", "Makefile"],
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
printf 'x\n' > modules/core/code/app.txt
printf 'x\n' > modules/core/infra/main.txt
printf 'x\n' > modules/gateway/code/app.txt
printf 'x\n' > modules/gateway/infra/main.txt
printf 'x\n' > .ward/x
printf '# a\n' > docs/a.md
printf '# readme\n' > README.md

git init -q
git config user.email "fixture@example.com"
git config user.name "apply-needed fixture"
commit_tag base v1

echo "# environment and previous"
printf 'code\n' > modules/core/code/app.txt
commit_tag code v2
expect "production is always needed" true production core v2 v1
expect "empty previous is needed" true staging core v2 ""
expect "previous equal to tag is needed" true staging core v2 v2
expect "only code changed is not needed" false staging core v2 v1

echo "# infra"
printf 'infra\n' > modules/core/infra/main.txt
commit_tag infra v3
expect "infra changed is needed" true staging core v3 v2

echo "# shared"
printf 'shared\n' > .ward/x
commit_tag shared v4
expect "shared changed is needed" true staging core v4 v3
expect "shared changed is needed for another module" true staging gateway v4 v3

echo "# docs"
printf 'more\n' >> docs/a.md
printf 'more\n' >> README.md
commit_tag docs v5
expect "only docs changed is not needed" false staging core v5 v4

echo "# errors"
expect "missing tag is needed" true staging core v9 v1
expect "missing previous is needed" true staging core v5 v9

echo "# other module"
printf 'infra\n' > modules/gateway/infra/main.txt
commit_tag gateway v6
expect "another module infra changed is not needed" false staging core v6 v5
expect "own module infra changed is needed" true staging gateway v6 v5

echo "# intermediate steps"
printf 'tmp\n' > modules/core/infra/main.txt
git add -A
git commit -qm "infra change"
printf 'infra\n' > modules/core/infra/main.txt
commit_tag "infra revert" v7
expect "infra changed then reverted is needed" true staging core v7 v6
if git diff --quiet v6 v7 -- modules/core/infra; then
  echo "PASS net diff of the reverted infra is empty"
  PASSED=$(( PASSED + 1 ))
else
  echo "FAIL net diff of the reverted infra is empty"
  FAILED=$(( FAILED + 1 ))
fi

printf 'one\n' >> docs/a.md
git add -A
git commit -qm "docs one"
printf 'two\n' >> docs/a.md
commit_tag "docs two" v8
expect "several docs-only commits are not needed" false staging core v8 v7

printf 'one\n' > modules/core/code/app.txt
git add -A
git commit -qm "code one"
printf 'two\n' > modules/core/code/app.txt
commit_tag "code two" v9a
expect "several commits without infra change are not needed" false staging core v9a v8

count=0
while [ "${count}" -lt 41 ]; do
  count=$(( count + 1 ))
  printf '%s\n' "${count}" >> docs/a.md
  git add -A
  git commit -qm "docs ${count}"
done
git tag v10
expect "more than 40 commits is needed" true staging core v10 v9a

echo "# force"
FORCE=true expect "force is needed in staging without infra change" true staging core v2 v1
FORCE=true expect "force is needed with a previous" true staging core v6 v5
FORCE=false expect "force false keeps the comparison" false staging core v2 v1
FORCE="" expect "empty force keeps the comparison" false staging core v2 v1
FORCE=true expect "force is needed in production" true production core v2 v1

echo "# force input"
if python3 -I -c 'import sys, yaml
i = yaml.safe_load(open(sys.argv[1]))["inputs"].get("force")
sys.exit(0 if i is not None and i.get("default") == "false" and not i.get("required", False) else 1)' "${ROOT}/actions/apply-needed/action.yml"; then
  echo "PASS action declares force defaulting to 'false'"
  PASSED=$(( PASSED + 1 ))
else
  echo "FAIL action declares force defaulting to 'false'"
  FAILED=$(( FAILED + 1 ))
fi

echo
echo "passed=${PASSED} failed=${FAILED}"
[ "${FAILED}" -eq 0 ] || exit 1
