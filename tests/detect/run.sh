#!/bin/sh
# run.sh — fixture tests for actions/detect/detect.py.
#
# Usage: sh tests/detect/run.sh
#
# Builds a throwaway repository with two modules and asserts the matrices, the
# changed module list and the per-module booleans detect emits for push and
# dispatch events. Every assertion prints PASS or FAIL; the script exits 1 when
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


def legs(kind):
    return json.loads(values[kind])["include"]


def leg(kind, module):
    for entry in legs(kind):
        if entry["module"] == module:
            return entry
    raise SystemExit(f"no leg {module} in {kind}")


print(eval(expr))
PY
}

expect() {
  scenario="${1}"
  expected="${2}"
  expr="${3}"
  got="$(value "${OUT}" "${expr}")"
  if [ "${got}" = "${expected}" ]; then
    echo "PASS ${scenario}"
    PASSED=$(( PASSED + 1 ))
  else
    echo "FAIL ${scenario}: expected ${expected}, got ${got}"
    FAILED=$(( FAILED + 1 ))
  fi
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
  INPUT_REGISTRY=.github/modules.json \
  python3 "${DETECT}"
}

mkdir -p "${WORK}/.github" "${WORK}/docs"
mkdir -p "${WORK}/modules/ruby_app_example/code/ci"
mkdir -p "${WORK}/modules/ruby_app_example/infra/ci"
mkdir -p "${WORK}/modules/go_app_example/code/ci"
mkdir -p "${WORK}/modules/go_app_example/infra/ci"
cd "${WORK}" || exit 1

cat > .github/modules.json <<'JSON'
{
  "shared": [".github/", ".project/", "Makefile", "compose.yml"],
  "modules": {
    "ruby_app_example": {
      "code": { "dir": "modules/ruby_app_example/code" },
      "infra": { "dir": "modules/ruby_app_example/infra" }
    },
    "go_app_example": {}
  }
}
JSON

for step in lint test build; do
  printf '#!/bin/sh\nset -eu\n' > "modules/ruby_app_example/code/ci/${step}.sh"
done
for step in check prepare; do
  printf '#!/bin/sh\nset -eu\n' > "modules/ruby_app_example/infra/ci/${step}.sh"
done
printf '#!/bin/sh\nset -eu\n' > modules/go_app_example/code/ci/test.sh
for step in check fly glide rollback; do
  printf '#!/bin/sh\nset -eu\n' > "modules/go_app_example/infra/ci/${step}.sh"
done
printf '# docs\n' > docs/README.md

git init -q
git config user.email "fixture@example.com"
git config user.name "detect fixture"
git add -A
git commit -qm base
BASE="$(git rev-parse HEAD)"

echo "# a: push touching only modules/ruby_app_example/code"
printf 'puts :ok\n' > modules/ruby_app_example/code/app.rb
git add -A
git commit -qm "ruby code"
RUBY="$(git rev-parse HEAD)"
detect push "${BASE}"
expect "push touches only ruby_app_example code" \
  "tracks=ruby_app_example|code=ruby_app_example|infra=none|steps=lint,test|changed=true|modules=ruby_app_example|ruby_code=true|ruby_infra=false|go_code=false|go_infra=false|any=true" \
  'f"""tracks={values["tracks"]}|code={",".join(e["module"] for e in legs("code"))}|infra={",".join(e["module"] for e in legs("infra"))}|steps={leg("code", "ruby_app_example")["steps"]}|changed={leg("code", "ruby_app_example")["changed"]}|modules={",".join(e["module"] for e in legs("modules"))}|ruby_code={values["ruby_app_example_code"]}|ruby_infra={values["ruby_app_example_infra"]}|go_code={values["go_app_example_code"]}|go_infra={values["go_app_example_infra"]}|any={values["any"]}"""'

echo "# b: push touching only modules/go_app_example/infra/ci/check.sh"
printf 'echo check\n' >> modules/go_app_example/infra/ci/check.sh
git add -A
git commit -qm "go infra"
GO="$(git rev-parse HEAD)"
detect push "${RUBY}"
expect "push touches only go_app_example infra" \
  "tracks=go_app_example|code=none|infra=go_app_example|steps=check|changed=true|modules=go_app_example|ruby_code=false|go_code=false|go_infra=true|any=true" \
  'f"""tracks={values["tracks"]}|code={",".join(e["module"] for e in legs("code"))}|infra={",".join(e["module"] for e in legs("infra"))}|steps={leg("infra", "go_app_example")["steps"]}|changed={leg("infra", "go_app_example")["changed"]}|modules={",".join(e["module"] for e in legs("modules"))}|ruby_code={values["ruby_app_example_code"]}|go_code={values["go_app_example_code"]}|go_infra={values["go_app_example_infra"]}|any={values["any"]}"""'

echo "# c: push touching only modules/ruby_app_example/infra/ci/prepare.sh"
printf 'echo plan\n' >> modules/ruby_app_example/infra/ci/prepare.sh
git add -A
git commit -qm "ruby infra"
RDEP="$(git rev-parse HEAD)"
detect push "${GO}"
expect "push touches only ruby_app_example infra" \
  "tracks=ruby_app_example|code=none|infra=ruby_app_example|steps=check,prepare|modules=ruby_app_example|ruby_infra=true|any=true" \
  'f"""tracks={values["tracks"]}|code={",".join(e["module"] for e in legs("code"))}|infra={",".join(e["module"] for e in legs("infra"))}|steps={leg("infra", "ruby_app_example")["steps"]}|modules={",".join(e["module"] for e in legs("modules"))}|ruby_infra={values["ruby_app_example_infra"]}|any={values["any"]}"""'

echo "# d: push touching only docs/README.md"
printf 'more docs\n' >> docs/README.md
git add -A
git commit -qm docs
DOCS="$(git rev-parse HEAD)"
detect push "${RDEP}"
expect "push touches only docs" \
  "tracks=|any=false|code=1:none:false|infra=1:none:false|modules=1:none|ruby_code=false|ruby_infra=false|go_code=false|go_infra=false" \
  'f"""tracks={values["tracks"]}|any={values["any"]}|code={len(legs("code"))}:{legs("code")[0]["module"]}:{legs("code")[0]["changed"]}|infra={len(legs("infra"))}:{legs("infra")[0]["module"]}:{legs("infra")[0]["changed"]}|modules={len(legs("modules"))}:{legs("modules")[0]["module"]}|ruby_code={values["ruby_app_example_code"]}|ruby_infra={values["ruby_app_example_infra"]}|go_code={values["go_app_example_code"]}|go_infra={values["go_app_example_infra"]}"""'

echo "# e: push touching a shared path"
printf 'shared\n' > .github/shared.txt
git add -A
git commit -qm shared
detect push "${DOCS}"
expect "push touches .github (shared)" \
  "tracks=ruby_app_example,go_app_example|code=ruby_app_example,go_app_example|infra=ruby_app_example,go_app_example|modules=ruby_app_example,go_app_example|ruby_code=true|ruby_infra=true|go_code=true|go_infra=true|any=true" \
  'f"""tracks={values["tracks"]}|code={",".join(e["module"] for e in legs("code"))}|infra={",".join(e["module"] for e in legs("infra"))}|modules={",".join(e["module"] for e in legs("modules"))}|ruby_code={values["ruby_app_example_code"]}|ruby_infra={values["ruby_app_example_infra"]}|go_code={values["go_app_example_code"]}|go_infra={values["go_app_example_infra"]}|any={values["any"]}"""'

echo "# f: workflow_dispatch counts as everything"
detect workflow_dispatch ""
expect "workflow_dispatch touches every module" \
  "tracks=ruby_app_example,go_app_example|code=ruby_app_example,go_app_example|infra=ruby_app_example,go_app_example|modules=ruby_app_example,go_app_example|any=true" \
  'f"""tracks={values["tracks"]}|code={",".join(e["module"] for e in legs("code"))}|infra={",".join(e["module"] for e in legs("infra"))}|modules={",".join(e["module"] for e in legs("modules"))}|any={values["any"]}"""'

echo
echo "passed=${PASSED} failed=${FAILED}"
[ "${FAILED}" -eq 0 ] || exit 1
