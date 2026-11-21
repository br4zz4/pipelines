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

CODE_CHECKS="lint audit test build"
INFRA_CHECKS="validate plan"
INFRA_DEPLOY="apply deployment verify"

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
    mkdir -p "${proj}/${code}/ci/checks" "${proj}/${infra}/ci/checks" "${proj}/${infra}/ci/deploy"
    for hook in ${CODE_CHECKS}; do
      printf '#!/bin/sh\nset -eu\n' > "${proj}/${code}/ci/checks/${hook}.sh"
    done
    for hook in ${INFRA_CHECKS}; do
      printf '#!/bin/sh\nset -eu\n' > "${proj}/${infra}/ci/checks/${hook}.sh"
    done
    for hook in ${INFRA_DEPLOY}; do
      printf '#!/bin/sh\nset -eu\n' > "${proj}/${infra}/ci/deploy/${hook}.sh"
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

new_case a3
rm "${CASE}/.github/workflows/build.yml"
expect_violation "missing build.yml is reported" "${CASE}" "build.yml differs from the render (missing)"
new_case a4
printf '# drift\n' >> "${CASE}/.github/workflows/build.yml"
expect_violation "divergent build.yml is reported" "${CASE}" "build.yml differs from the render"
conform check "${WORK}/good"
if [ "${STATUS}" -eq 0 ] && ! grep -q 'build.yml' "${OUT}"; then
  pass "build.yml is not an undeclared extra workflow"
else
  fail "build.yml is not an undeclared extra workflow: status=${STATUS}"
fi

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
printf '#!/bin/sh\n' > "${CASE}/modules/core/infra/ci/deploy/rollback.sh"
expect_violation "rollback.sh is retired in v2" "${CASE}" "rollback.sh is retired in v2: a failed deploy dispatches a deploy of the previous release"
new_case d2
rm "${CASE}/services/events/ci/checks/lint.sh"
expect_violation "missing code hook in custom dir is reported" "${CASE}" "lint.sh"
new_case d3
rm "${CASE}/modules/gateway/code/ci/checks/audit.sh"
expect_violation "missing audit.sh names the module" "${CASE}" "gateway"

echo "# e: hook outside the vocabulary"
new_case e1
printf '#!/bin/sh\n' > "${CASE}/modules/core/code/ci/checks/bogus.sh"
expect_violation "unknown code hook bogus.sh is reported" "${CASE}" "bogus.sh"
new_case e2
printf '#!/bin/sh\n' > "${CASE}/modules/engine/infra/ci/checks/lint.sh"
expect_violation "code hook inside infra dir is reported" "${CASE}" "lint.sh"

echo "# optional deploy hooks: migrate and rollout"
new_case opt1
printf '#!/bin/sh\n' > "${CASE}/modules/core/infra/ci/deploy/migrate.sh"
printf '#!/bin/sh\n' > "${CASE}/modules/core/infra/ci/deploy/rollout.sh"
conform check "${CASE}"
if [ "${STATUS}" -eq 0 ]; then
  pass "infra migrate.sh and rollout.sh are accepted"
else
  fail "infra migrate.sh and rollout.sh are accepted: status=${STATUS} out=$(tr '\n' ' ' < "${OUT}")"
fi
new_case opt2
printf '#!/bin/sh\n' > "${CASE}/modules/core/infra/ci/deploy/outro.sh"
expect_violation "unknown deploy hook outro.sh is still rejected" "${CASE}" "outro.sh"
new_case opt3
printf '#!/bin/sh\n' > "${CASE}/modules/core/code/ci/checks/migrate.sh"
expect_violation "migrate.sh in a code dir is rejected" "${CASE}" "migrate.sh"

echo "# run: run/<step> satisfies lint, audit and test"
new_case run1
CODE="${CASE}/modules/core/code"
mkdir -p "${CODE}/run"
for hook in lint audit test; do
  printf '#!/bin/sh\n' > "${CODE}/run/${hook}"
  rm "${CODE}/ci/checks/${hook}.sh"
done
conform check "${CASE}"
if [ "${STATUS}" -eq 0 ]; then
  pass "run/lint, run/audit, run/test with only build.sh conform"
else
  fail "run/lint, run/audit, run/test with only build.sh conform: status=${STATUS} out=$(tr '\n' ' ' < "${OUT}")"
fi

new_case run3
CODE="${CASE}/modules/core/code"
mkdir -p "${CODE}/run"
printf '#!/bin/sh\n' > "${CODE}/run/lint"
rm "${CODE}/ci/checks/lint.sh" "${CODE}/ci/checks/audit.sh" "${CODE}/ci/checks/test.sh"
conform check "${CASE}"
if [ "${STATUS}" -eq 1 ] \
  && grep '^::error::' "${OUT}" | grep -q 'ci/checks/audit.sh is missing' \
  && grep '^::error::' "${OUT}" | grep -q 'ci/checks/test.sh is missing' \
  && ! grep '^::error::' "${OUT}" | grep -q 'ci/checks/lint.sh is missing'; then
  pass "run/lint alone leaves audit and test reported missing"
else
  fail "run/lint alone leaves audit and test reported missing: status=${STATUS} out=$(tr '\n' ' ' < "${OUT}")"
fi

new_case run4
CODE="${CASE}/modules/core/code"
mkdir -p "${CODE}/run"
printf '#!/bin/sh\n' > "${CODE}/run/build"
rm "${CODE}/ci/checks/build.sh"
expect_violation "run/build does not satisfy build.sh" "${CASE}" "ci/checks/build.sh is missing"

new_case run5
CODE="${CASE}/modules/core/code"
mkdir -p "${CODE}/run"
printf '#!/bin/sh\n' > "${CODE}/run/lint"
rm "${CODE}/ci/checks/lint.sh" "${CODE}/ci/checks/audit.sh"
conform check "${CASE}"
if [ "${STATUS}" -eq 1 ] \
  && grep '^::error::' "${OUT}" | grep -q 'ci/checks/audit.sh is missing' \
  && ! grep '^::error::' "${OUT}" | grep -q 'ci/checks/lint.sh is missing'; then
  pass "run/lint satisfies only lint, not audit"
else
  fail "run/lint satisfies only lint, not audit: status=${STATUS} out=$(tr '\n' ' ' < "${OUT}")"
fi

new_case run6
CODE="${CASE}/modules/core/code"
mkdir -p "${CODE}/run"
printf '#!/bin/sh\n' > "${CODE}/run/lint"
printf '#!/bin/sh\n' > "${CODE}/ci/checks/bogus.sh"
expect_violation "unknown ci/checks file still fails next to run/lint" "${CASE}" "bogus.sh"

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

echo "# promote: key makes promote.yml, regression and e2e part of the standard"
build_promote_project() {
  proj="${1}"
  cp -R "${WORK}/good" "${proj}"
  python3 - "${proj}/.github/modules.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data["promote"] = {"max_per_day": 10}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
  module_dirs | while read -r _ code _; do
    mkdir -p "${proj}/${code}/run"
    printf '#!/bin/sh\n' > "${proj}/${code}/run/regression"
    printf '#!/bin/sh\n' > "${proj}/${code}/run/e2e"
  done
  python3 "${RENDER}" --root "${proj}" >/dev/null 2>&1 || fail "render.py produces the promote fixture workflows"
}

build_promote_project "${WORK}/promote-good"
conform check "${WORK}/promote-good"
if [ "${STATUS}" -eq 0 ] && [ -f "${WORK}/promote-good/.github/workflows/promote.yml" ]; then
  pass "conformant promote project exits 0 and has promote.yml"
else
  fail "conformant promote project exits 0 and has promote.yml: status=${STATUS} out=$(tr '\n' ' ' < "${OUT}")"
fi

promote_case() {
  CASE="${WORK}/case-${1}"
  cp -R "${WORK}/promote-good" "${CASE}"
}

promote_case p1
printf '# drift\n' >> "${CASE}/.github/workflows/promote.yml"
expect_violation "divergent promote.yml is reported" "${CASE}" "promote.yml differs from the render"

promote_case p2
rm -f "${CASE}/.github/workflows/promote.yml"
expect_violation "missing promote.yml with the key is reported" "${CASE}" "promote.yml differs from the render (missing)"

promote_case p3
rm "${CASE}/modules/core/code/run/e2e"
expect_violation "missing e2e hook with the key is reported" "${CASE}" "e2e"
if grep '^::error::' "${OUT}" | grep -qi 'core'; then
  pass "missing e2e hook names the module"
else
  fail "missing e2e hook names the module: out=$(tr '\n' ' ' < "${OUT}")"
fi

promote_case p4
rm "${CASE}/services/events/run/regression"
expect_violation "missing regression hook with the key is reported" "${CASE}" "regression"

promote_case p5
rm "${CASE}/modules/gateway/code/run/e2e"
printf '#!/bin/sh\n' > "${CASE}/modules/gateway/code/ci/checks/e2e.sh"
conform check "${CASE}"
if [ "${STATUS}" -eq 0 ]; then
  pass "ci/checks/e2e.sh satisfies the e2e hook"
else
  fail "ci/checks/e2e.sh satisfies the e2e hook: status=${STATUS} out=$(tr '\n' ' ' < "${OUT}")"
fi

promote_case p6
rm "${CASE}/modules/engine/code/run/regression"
printf '#!/bin/sh\n' > "${CASE}/modules/engine/code/ci/checks/regression.sh"
conform check "${CASE}"
if [ "${STATUS}" -eq 0 ]; then
  pass "ci/checks/regression.sh satisfies the regression hook"
else
  fail "ci/checks/regression.sh satisfies the regression hook: status=${STATUS} out=$(tr '\n' ' ' < "${OUT}")"
fi

promote_case p7
python3 "${RENDER}" --root "${CASE}" --ref v1-beta >/dev/null 2>&1 || true
expect_violation "promote.yml rendered with another ref is reported" "${CASE}" "promote.yml"

new_case n1
rm -f "${CASE}/modules/core/code/run/e2e" "${CASE}/modules/core/code/run/regression"
conform check "${CASE}"
if [ "${STATUS}" -eq 0 ] && ! grep -qi 'e2e\|regression' "${OUT}"; then
  pass "without the promote key absent e2e and regression do not fail"
else
  fail "without the promote key absent e2e and regression do not fail: status=${STATUS} out=$(tr '\n' ' ' < "${OUT}")"
fi

new_case n2
printf '#!/bin/sh\n' > "${CASE}/modules/core/code/ci/checks/e2e.sh"
printf '#!/bin/sh\n' > "${CASE}/modules/core/code/ci/checks/regression.sh"
conform check "${CASE}"
if [ "${STATUS}" -eq 0 ]; then
  pass "without the promote key e2e.sh and regression.sh are still in the vocabulary"
else
  fail "without the promote key e2e.sh and regression.sh are still in the vocabulary: status=${STATUS} out=$(tr '\n' ' ' < "${OUT}")"
fi

new_case n3
printf 'name: promote\n' > "${CASE}/.github/workflows/promote.yml"
expect_violation "promote.yml without the key is an undeclared workflow" "${CASE}" "promote.yml"

promote_case p8
conform check "${CASE}"
if [ "${STATUS}" -eq 0 ] && ! grep -q 'promote.yml is not part of the standard' "${OUT}"; then
  pass "promote.yml with the key is not an undeclared extra workflow"
else
  fail "promote.yml with the key is not an undeclared extra workflow: status=${STATUS} out=$(tr '\n' ' ' < "${OUT}")"
fi

echo "# sentry: key makes the sentry inputs part of the standard"
set_sentry() {
  python3 - "${1}/.github/modules.json" "${2}" <<'PY2'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data["sentry"] = json.loads(sys.argv[2])
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY2
}

new_case sg
set_sentry "${CASE}" '{"org": "brazza-tech", "project": "has_warranty"}'
python3 "${RENDER}" --root "${CASE}" >/dev/null 2>&1 || fail "render.py produces the sentry fixture workflows"
SENTRY_GOOD="${CASE}"
conform check "${SENTRY_GOOD}"
if [ "${STATUS}" -eq 0 ] \
  && grep -q 'sentry_org: brazza-tech' "${SENTRY_GOOD}/.github/workflows/build.yml" \
  && grep -q 'sentry_org: brazza-tech' "${SENTRY_GOOD}/.github/workflows/deploy.yml"; then
  pass "conformant sentry project exits 0 with the sentry inputs rendered"
else
  fail "conformant sentry project exits 0 with the sentry inputs rendered: status=${STATUS} out=$(tr '\n' ' ' < "${OUT}")"
fi

new_case s1
set_sentry "${CASE}" '{"org": "brazza-tech", "project": "has_warranty"}'
expect_violation "sentry key with workflows rendered before it is reported" "${CASE}" "build.yml differs from the render"

new_case s2
cp -R "${SENTRY_GOOD}" "${WORK}/case-s2x"
CASE="${WORK}/case-s2x"
printf '# drift\n' >> "${CASE}/.github/workflows/deploy.yml"
expect_violation "divergent deploy.yml with the sentry key is reported" "${CASE}" "deploy.yml differs from the render"

CASE="${WORK}/case-s3"
cp -R "${SENTRY_GOOD}" "${CASE}"
sed -i.bak '/sentry_url:/d' "${CASE}/.github/workflows/build.yml"
rm -f "${CASE}/.github/workflows/build.yml.bak"
expect_violation "build.yml without sentry_url with the key is reported" "${CASE}" "build.yml differs from the render"

CASE="${WORK}/case-s4"
cp -R "${SENTRY_GOOD}" "${CASE}"
set_sentry "${CASE}" '{"org": "brazza-tech", "project": "has_warranty", "url": "https://sentry.example.com"}'
expect_violation "changing sentry.url without re-rendering is reported" "${CASE}" "build.yml differs from the render"

for pair in '{"project": "has_warranty"}:org' '{"org": "brazza-tech", "project": ""}:project' '{"org": "brazza-tech", "project": "has_warranty", "url": "http://sentry.example.com"}:url' '{"org": "brazza-tech", "project": "has_warranty", "bogus_key": true}:bogus_key'; do
  value="${pair%:*}"
  key="${pair##*:}"
  CASE="${WORK}/case-sinv-${key}"
  cp -R "${WORK}/good" "${CASE}"
  set_sentry "${CASE}" "${value}"
  conform check "${CASE}"
  if [ "${STATUS}" -eq 1 ] && grep '^::error::' "${OUT}" | grep -qi 'sentry' && grep '^::error::' "${OUT}" | grep -qi -- "${key}"; then
    pass "invalid sentry config reproves citing ${key}"
  else
    fail "invalid sentry config reproves citing ${key}: status=${STATUS} out=$(tr '\n' ' ' < "${OUT}")"
  fi
done

new_case sn
conform check "${CASE}"
if [ "${STATUS}" -eq 0 ] && ! grep -rqi 'sentry' "${CASE}/.github/workflows" "${OUT}"; then
  pass "without the sentry key nothing changes"
else
  fail "without the sentry key nothing changes: status=${STATUS} out=$(tr '\n' ' ' < "${OUT}")"
fi

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
env -u GITHUB_HEAD_REF GH_PIPELINES_TOKEN=token CONFORM_PUSH_URL="${BARE}" \
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
env -u GITHUB_HEAD_REF GH_PIPELINES_TOKEN=token CONFORM_PUSH_URL="${BARE}" \
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
