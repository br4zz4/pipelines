#!/bin/sh
# run.sh — fixture tests for actions/conform/conform.py.
#
# Usage: sh tests/conform/run.sh
set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "${HERE}/../.." && pwd)"
RENDER="${ROOT}/actions/conform/render.py"
CONFORM="${ROOT}/actions/conform/conform.py"
FIXTURE="${ROOT}/tests/render/fixtures/four-modules"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

GIT_AUTHOR_NAME=t
GIT_AUTHOR_EMAIL=t@t
GIT_COMMITTER_NAME=t
GIT_COMMITTER_EMAIL=t@t
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

PASSED=0
FAILED=0
STATUS=0
OUT="${WORK}/out"

pass() {
  echo "PASS ${1}"
  PASSED=$(( PASSED + 1 ))
}

fail() {
  echo "FAIL ${1}"
  FAILED=$(( FAILED + 1 ))
}

CODE_HOOKS="lint audit test build"
INFRA_HOOKS="validate plan apply deploy verify rollback"

module_dirs() {
  echo "core modules/core/code modules/core/infra"
  echo "engine modules/engine/code modules/engine/infra"
  echo "events services/events modules/events/infra"
  echo "gateway modules/gateway/code modules/gateway/infra"
}

build_project() {
  proj="${1}"
  rm -rf "${proj}"
  mkdir -p "${proj}"
  cp -R "${FIXTURE}/." "${proj}/"
  module_dirs | while read -r _ code infra; do
    mkdir -p "${proj}/${code}/ci" "${proj}/${infra}/ci"
    for hook in ${CODE_HOOKS}; do
      printf '#!/bin/sh\nset -eu\n' > "${proj}/${code}/ci/${hook}.sh"
    done
    for hook in ${INFRA_HOOKS}; do
      printf '#!/bin/sh\nset -eu\n' > "${proj}/${infra}/ci/${hook}.sh"
    done
    printf '[tools]\n' > "${proj}/${code}/mise.toml"
    printf '[tools]\n' > "${proj}/${infra}/mise.toml"
  done
  mkdir -p "${proj}/.github/actions/setup"
  printf 'name: setup\nruns:\n  using: composite\n  steps: []\n' > "${proj}/.github/actions/setup/action.yml"
  python3 "${RENDER}" --root "${proj}" >/dev/null 2>&1 || fail "render.py produces the fixture workflows"
}

conform() {
  mode="${1}"
  proj="${2}"
  STATUS=0
  python3 "${CONFORM}" --root "${proj}" --mode "${mode}" >"${OUT}" 2>"${WORK}/err" || STATUS=$?
}

expect_violation() {
  scenario="${1}"
  proj="${2}"
  needle="${3}"
  conform check "${proj}"
  if [ "${STATUS}" -eq 1 ] && grep '^::error::' "${OUT}" | grep -qi -- "${needle}"; then
    pass "${scenario}"
  else
    fail "${scenario}: status=${STATUS} needle=${needle} out=$(tr '\n' ' ' < "${OUT}")"
  fi
}

new_case() {
  CASE="${WORK}/case-${1}"
  cp -R "${WORK}/good" "${CASE}"
}

build_project "${WORK}/good"

echo "# green: fully conformant project"
conform check "${WORK}/good"
if [ "${STATUS}" -eq 0 ]; then
  pass "conformant project exits 0"
else
  fail "conformant project exits 0: status=${STATUS} out=$(tr '\n' ' ' < "${OUT}")"
fi

echo "# a: committed workflow differs from render"
new_case a1
printf '# drift\n' >> "${CASE}/.github/workflows/pr.yml"
expect_violation "pr.yml drift is reported" "${CASE}" "pr.yml"
new_case a2
rm "${CASE}/.github/workflows/deploy.yml"
expect_violation "missing deploy.yml is reported" "${CASE}" "deploy.yml"

echo "# b: undeclared workflow file"
new_case b1
printf 'name: extra\n' > "${CASE}/.github/workflows/extra.yml"
expect_violation "undeclared extra.yml is reported" "${CASE}" "extra.yml"
new_case b2
printf 'name: extra\n' > "${CASE}/.github/workflows/extra.yml"
python3 - "${CASE}/.github/modules.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data["extra_workflows"] = ["extra.yml"]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
python3 "${RENDER}" --root "${CASE}" >/dev/null 2>&1 || true
conform check "${CASE}"
if [ "${STATUS}" -eq 0 ]; then
  pass "declared extra_workflows file is accepted"
else
  fail "declared extra_workflows file is accepted: status=${STATUS} out=$(tr '\n' ' ' < "${OUT}")"
fi

echo "# c: _RESTRICTED outside deploy.yml"
new_case c
printf '# WARD_KEY_HAS_WARRANTY_RESTRICTED\n' >> "${CASE}/.github/workflows/main.yml"
expect_violation "_RESTRICTED in main.yml is reported" "${CASE}" "restricted"

echo "# d: missing hooks"
new_case d1
rm "${CASE}/modules/core/infra/ci/rollback.sh"
expect_violation "missing infra hook rollback.sh is reported" "${CASE}" "rollback.sh"
new_case d2
rm "${CASE}/services/events/ci/lint.sh"
expect_violation "missing code hook in custom dir is reported" "${CASE}" "lint.sh"
new_case d3
rm "${CASE}/modules/gateway/code/ci/audit.sh"
expect_violation "missing audit.sh names the module" "${CASE}" "gateway"

echo "# e: hook outside the vocabulary"
new_case e1
printf '#!/bin/sh\n' > "${CASE}/modules/core/code/ci/bogus.sh"
expect_violation "unknown code hook bogus.sh is reported" "${CASE}" "bogus.sh"
new_case e2
printf '#!/bin/sh\n' > "${CASE}/modules/engine/infra/ci/lint.sh"
expect_violation "code hook inside infra dir is reported" "${CASE}" "lint.sh"

echo "# f: missing mise.toml"
new_case f1
rm "${CASE}/modules/gateway/infra/mise.toml"
expect_violation "missing infra mise.toml is reported" "${CASE}" "mise.toml"
new_case f2
rm "${CASE}/services/events/mise.toml"
expect_violation "missing custom code dir mise.toml is reported" "${CASE}" "mise.toml"

echo "# g: missing setup action"
new_case g
rm "${CASE}/.github/actions/setup/action.yml"
expect_violation "missing setup action is reported" "${CASE}" "setup"

echo "# h: ward vaults"
new_case h1
printf 'vaults:\n  - name: has_warranty::default\n    path: .ward/vaults/default\n' > "${CASE}/.ward/config.yaml"
python3 "${RENDER}" --root "${CASE}" >/dev/null 2>&1 || true
conform check "${CASE}"
if [ "${STATUS}" -eq 0 ] \
  && ! grep -rq '_RESTRICTED' "${CASE}/.github/workflows"; then
  pass "ward without restricted is conformant"
else
  fail "ward without restricted is conformant: status=${STATUS} out=$(tr '\n' ' ' < "${OUT}")"
fi
new_case h2
printf 'vaults:\n  - name: has_warranty\n    path: a\n  - name: has_warranty::default\n    path: b\n  - name: has_warranty::restricted\n    path: c\n' > "${CASE}/.ward/config.yaml"
expect_violation "ward with two defaults is reported" "${CASE}" "ward"
new_case h3
printf 'vaults:\n  - name: has_warranty::restricted\n    path: c\n' > "${CASE}/.ward/config.yaml"
expect_violation "ward without a default is reported" "${CASE}" "ward"
new_case h4
printf 'vaults:\n  - name: has_warranty\n    path: a\n  - name: other::default\n    path: b\n' > "${CASE}/.ward/config.yaml"
expect_violation "ward with several defaults and no pair is reported" "${CASE}" "ward"

echo "# ref"
new_case r
python3 "${RENDER}" --root "${CASE}" --ref v1-beta >/dev/null 2>&1 || fail "render.py --ref v1-beta"
STATUS=0
python3 "${CONFORM}" --root "${CASE}" --mode check --ref v1-beta >"${OUT}" 2>&1 || STATUS=$?
if [ "${STATUS}" -eq 0 ]; then
  pass "project rendered with --ref v1-beta conforms with --ref v1-beta"
else
  fail "project rendered with --ref v1-beta conforms with --ref v1-beta: status=${STATUS} out=$(tr '\n' ' ' < "${OUT}")"
fi
expect_violation "project rendered with --ref v1-beta fails without --ref" "${CASE}" "pr.yml"

echo "# i: service outside the catalog"
new_case i
python3 - "${CASE}/.github/modules.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data["modules"]["core"]["services"] = ["mysql"]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
expect_violation "unknown service mysql is reported" "${CASE}" "mysql"

echo "# step summary on divergence"
new_case s
printf '# drift\n' >> "${CASE}/.github/workflows/pr.yml"
SUMMARY="${WORK}/summary.md"
: > "${SUMMARY}"
STATUS=0
GITHUB_STEP_SUMMARY="${SUMMARY}" python3 "${CONFORM}" --root "${CASE}" --mode check >/dev/null 2>&1 || STATUS=$?
if [ "${STATUS}" -eq 1 ] && [ -s "${SUMMARY}" ]; then
  pass "divergence writes the expected diff to GITHUB_STEP_SUMMARY"
else
  fail "divergence writes the expected diff to GITHUB_STEP_SUMMARY: status=${STATUS}"
fi

echo "# fix without token"
new_case fx1
printf '# drift\n' >> "${CASE}/.github/workflows/pr.yml"
before="$(cksum < "${CASE}/.github/workflows/pr.yml")"
STATUS=0
env -u GH_PIPELINES_TOKEN python3 "${CONFORM}" --root "${CASE}" --mode fix >"${OUT}" 2>&1 || STATUS=$?
after="$(cksum < "${CASE}/.github/workflows/pr.yml")"
if [ "${STATUS}" -eq 1 ] && [ "${before}" = "${after}" ] && grep -q '^::error::' "${OUT}"; then
  pass "fix without token behaves as check and writes nothing"
else
  fail "fix without token behaves as check and writes nothing: status=${STATUS}"
fi

echo "# fix with token pushes a commit"
BARE="${WORK}/origin.git"
git init -q --bare "${BARE}"
new_case fx2
printf '# drift\n' >> "${CASE}/.github/workflows/pr.yml"
(
  cd "${CASE}"
  git init -q
  git checkout -q -b main
  git add -A
  git commit -qm base
  git remote add origin "${BARE}"
  git push -q origin main
)
base_head="$(git -C "${CASE}" rev-parse HEAD)"
STATUS=0
GH_PIPELINES_TOKEN=token CONFORM_PUSH_URL="${BARE}" \
  python3 "${CONFORM}" --root "${CASE}" --mode fix >"${OUT}" 2>"${WORK}/err" || STATUS=$?
subject="$(git -C "${BARE}" log -1 --format=%s main 2>/dev/null || true)"
if [ "${STATUS}" -eq 1 ] \
  && grep -qx '::error::workflows re-rendered; a new run was triggered' "${OUT}" \
  && [ "${subject}" = "ci: render workflows" ] \
  && [ "$(git -C "${BARE}" rev-parse main)" != "${base_head}" ] \
  && cmp -s "${CASE}/.github/workflows/pr.yml" "${WORK}/good/.github/workflows/pr.yml"; then
  pass "fix with token commits, pushes and fails with the re-render message"
else
  fail "fix with token commits, pushes and fails with the re-render message: status=${STATUS} subject=${subject} out=$(tr '\n' ' ' < "${OUT}")"
fi

echo "# fix when already conformant"
new_case fx3
(
  cd "${CASE}"
  git init -q
  git checkout -q -b main
  git add -A
  git commit -qm base
  git remote add origin "${BARE}"
)
count_before="$(git -C "${CASE}" rev-list --count HEAD)"
STATUS=0
GH_PIPELINES_TOKEN=token CONFORM_PUSH_URL="${BARE}" \
  python3 "${CONFORM}" --root "${CASE}" --mode fix >"${OUT}" 2>&1 || STATUS=$?
count_after="$(git -C "${CASE}" rev-list --count HEAD)"
if [ "${STATUS}" -eq 0 ] && [ "${count_before}" = "${count_after}" ]; then
  pass "fix on conformant project exits 0 without commit"
else
  fail "fix on conformant project exits 0 without commit: status=${STATUS}"
fi

echo
echo "passed=${PASSED} failed=${FAILED}"
[ "${FAILED}" -eq 0 ] || exit 1
