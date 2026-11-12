#!/bin/sh
# run.sh — fixture tests for actions/plan/plan.py.
#
# Usage: sh tests/plan/run.sh
#
# Builds a throwaway repository with two modules and asserts the matrices the
# plan emits for push, dispatch and release events. Every assertion prints
# PASS or FAIL; the script exits 1 when at least one of them fails.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
PLAN="${ROOT}/actions/plan/plan.py"
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

plan() {
  event="${1}"
  before="${2}"
  mode="${3}"
  ref="${4}"
  modules="${5}"
  environment="${6}"
  OUT="${WORK}/output"
  : > "${OUT}"
  GITHUB_OUTPUT="${OUT}" \
  GITHUB_EVENT_NAME="${event}" \
  GITHUB_BASE_REF=main \
  EVENT_BEFORE="${before}" \
  INPUT_MODE="${mode}" \
  INPUT_REF="${ref}" \
  INPUT_MODULES="${modules}" \
  INPUT_ENVIRONMENT="${environment}" \
  INPUT_REGISTRY=.github/modules.json \
  python3 "${PLAN}"
}

mkdir -p "${WORK}/.github" "${WORK}/docs"
mkdir -p "${WORK}/modules/ruby_app_example/code/ci"
mkdir -p "${WORK}/modules/ruby_app_example/deploy/ci"
mkdir -p "${WORK}/modules/go_app_example/code/ci"
mkdir -p "${WORK}/modules/go_app_example/deploy/ci"
cd "${WORK}" || exit 1

cat > .github/modules.json <<'JSON'
{
  "shared": [".github/", ".project/", "Makefile", "compose.yml"],
  "modules": {
    "ruby_app_example": {
      "code": { "dir": "modules/ruby_app_example/code" },
      "deploy": { "dir": "modules/ruby_app_example/deploy" },
      "environments": {
        "staging": { "url": "https://ruby.staging.example.com" },
        "production": { "url": "https://ruby.example.com" }
      }
    },
    "go_app_example": {
      "code": { "dir": "modules/go_app_example/code" },
      "deploy": { "dir": "modules/go_app_example/deploy" },
      "environments": {
        "staging": { "url": "https://go.staging.example.com" },
        "production": { "url": "https://go.example.com" }
      }
    }
  }
}
JSON

for step in lint test package; do
  printf '#!/bin/sh\nset -eu\n' > "modules/ruby_app_example/code/ci/${step}.sh"
done
for step in check plan; do
  printf '#!/bin/sh\nset -eu\n' > "modules/ruby_app_example/deploy/ci/${step}.sh"
done
printf '#!/bin/sh\nset -eu\n' > modules/go_app_example/code/ci/test.sh
for step in fly glide rollback; do
  printf '#!/bin/sh\nset -eu\n' > "modules/go_app_example/deploy/ci/${step}.sh"
done
printf '# docs\n' > docs/README.md

git init -q
git config user.email "fixture@example.com"
git config user.name "plan fixture"
git add -A
git commit -qm base
BASE="$(git rev-parse HEAD)"

echo "# a: push touching only modules/ruby_app_example/code"
printf 'puts :ok\n' > modules/ruby_app_example/code/app.rb
git add -A
git commit -qm "ruby code"
RUBY="$(git rev-parse HEAD)"
plan push "${BASE}" check "" "" staging
expect "push touches only ruby_app_example code" \
  "tracks=ruby_app_example|code=ruby_app_example|infra=none|release=ruby_app_example|steps=lint,test|package=true|code_changed=true" \
  'f"""tracks={values["tracks"]}|code={",".join(e["module"] for e in legs("code"))}|infra={",".join(e["module"] for e in legs("infra"))}|release={",".join(e["module"] for e in legs("release"))}|steps={leg("code", "ruby_app_example")["steps"]}|package={leg("code", "ruby_app_example")["package"]}|code_changed={leg("release", "ruby_app_example")["code_changed"]}"""'

echo "# b: push touching only modules/go_app_example/deploy/ci/fly.sh"
printf 'echo fly\n' >> modules/go_app_example/deploy/ci/fly.sh
git add -A
git commit -qm "go deploy"
GO="$(git rev-parse HEAD)"
plan push "${RUBY}" check "" "" staging
expect "push touches only go_app_example deploy" \
  "tracks=go_app_example|code=none|infra=go_app_example|release=go_app_example|infra_steps=|code_changed=false|package=false" \
  'f"""tracks={values["tracks"]}|code={",".join(e["module"] for e in legs("code"))}|infra={",".join(e["module"] for e in legs("infra"))}|release={",".join(e["module"] for e in legs("release"))}|infra_steps={leg("infra", "go_app_example")["steps"]}|code_changed={leg("release", "go_app_example")["code_changed"]}|package={leg("release", "go_app_example")["package"]}"""'

echo "# c: push touching only modules/ruby_app_example/deploy (a module with a package step)"
printf 'echo plan\n' >> modules/ruby_app_example/deploy/ci/plan.sh
git add -A
git commit -qm "ruby deploy"
RDEP="$(git rev-parse HEAD)"
plan push "${GO}" check "" "" staging
expect "infra-only change still builds the image of the module" \
  "tracks=ruby_app_example|code=none|release=ruby_app_example|code_changed=false|package=true" \
  'f"""tracks={values["tracks"]}|code={",".join(e["module"] for e in legs("code"))}|release={",".join(e["module"] for e in legs("release"))}|code_changed={leg("release", "ruby_app_example")["code_changed"]}|package={leg("release", "ruby_app_example")["package"]}"""'

echo "# d: push touching only docs/README.md"
printf 'more docs\n' >> docs/README.md
git add -A
git commit -qm docs
DOCS="$(git rev-parse HEAD)"
plan push "${RDEP}" check "" "" staging
expect "push touches only docs" \
  "tracks=|any=false|code=1:none:false|infra=1:none:false|release=1:none:false" \
  'f"""tracks={values["tracks"]}|any={values["any"]}|code={len(legs("code"))}:{legs("code")[0]["module"]}:{legs("code")[0]["changed"]}|infra={len(legs("infra"))}:{legs("infra")[0]["module"]}:{legs("infra")[0]["changed"]}|release={len(legs("release"))}:{legs("release")[0]["module"]}:{legs("release")[0]["changed"]}"""'

echo "# e: push touching a shared path"
printf 'shared\n' > .github/shared.txt
git add -A
git commit -qm shared
plan push "${DOCS}" check "" "" staging
expect "push touches .github (shared)" \
  "tracks=ruby_app_example,go_app_example|code=ruby_app_example,go_app_example|release=ruby_app_example,go_app_example|ruby_code_changed=true|go_code_changed=true" \
  'f"""tracks={values["tracks"]}|code={",".join(e["module"] for e in legs("code"))}|release={",".join(e["module"] for e in legs("release"))}|ruby_code_changed={leg("release", "ruby_app_example")["code_changed"]}|go_code_changed={leg("release", "go_app_example")["code_changed"]}"""'

echo "# f: workflow_dispatch counts as everything"
plan workflow_dispatch "" check "" "" staging
expect "workflow_dispatch touches every module" \
  "tracks=ruby_app_example,go_app_example|code=ruby_app_example,go_app_example|release=ruby_app_example,go_app_example" \
  'f"""tracks={values["tracks"]}|code={",".join(e["module"] for e in legs("code"))}|release={",".join(e["module"] for e in legs("release"))}"""'

echo "# g: release, annotated tag carrying only go_app_example"
git tag -a v2026.11.12.1 -m "release v2026.11.12.1
tracks: go_app_example"
plan release "" release v2026.11.12.1 "" production
expect "release tag carries only go_app_example" \
  "tag=v2026.11.12.1|legs=1|module=go_app_example|url=https://go.example.com|environment=production|code_dir=modules/go_app_example/code|deploy_dir=modules/go_app_example/deploy" \
  'f"""tag={values["tag"]}|legs={len(legs("modules"))}|module={leg("modules", "go_app_example")["module"]}|url={leg("modules", "go_app_example")["url"]}|environment={leg("modules", "go_app_example")["environment"]}|code_dir={leg("modules", "go_app_example")["code_dir"]}|deploy_dir={leg("modules", "go_app_example")["deploy_dir"]}"""'

echo "# h: release, lightweight tag carries every module"
git tag v2026.11.12.2
plan release "" release v2026.11.12.2 "" staging
expect "lightweight tag carries every module" \
  "legs=2|modules=go_app_example,ruby_app_example|staging_urls=https://go.staging.example.com,https://ruby.staging.example.com" \
  'f"""legs={len(legs("modules"))}|modules={values["tracks"]}|staging_urls={leg("modules", "go_app_example")["url"]},{leg("modules", "ruby_app_example")["url"]}"""'

echo "# i: release narrowed by INPUT_MODULES"
git tag -a v2026.11.12.3 -m "tracks: ruby_app_example,go_app_example"
plan release "" release v2026.11.12.3 ruby_app_example production
expect "modules input narrows the release" \
  "legs=1|module=ruby_app_example|url=https://ruby.example.com|tag=v2026.11.12.3" \
  'f"""legs={len(legs("modules"))}|module={leg("modules", "ruby_app_example")["module"]}|url={leg("modules", "ruby_app_example")["url"]}|tag={values["tag"]}"""'

echo
echo "passed=${PASSED} failed=${FAILED}"
[ "${FAILED}" -eq 0 ] || exit 1
