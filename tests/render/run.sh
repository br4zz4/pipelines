#!/bin/sh
# run.sh — fixture tests for actions/conform/render.py.
#
# Usage: sh tests/render/run.sh
set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "${HERE}/../.." && pwd)"
RENDER="${ROOT}/actions/conform/render.py"
FIXTURES="${HERE}/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

. "${ROOT}/tests/lib/python.sh"
ensure_python "${ROOT}" "${WORK}"

PASSED=0
FAILED=0

pass() {
  echo "PASS ${1}"
  PASSED=$(( PASSED + 1 ))
}

fail() {
  echo "FAIL ${1}"
  FAILED=$(( FAILED + 1 ))
}

norm_date() {
  cat "$1"
}

props() {
  "${PY}" "${HERE}/props.py" "$@"
}

echo "# four modules: structure and properties"
if "${PY}" "${RENDER}" --root "${FIXTURES}/four-modules" --out "${WORK}/four"; then
  pass "four-modules renders with exit 0"
else
  fail "four-modules renders with exit 0"
fi
if props "${WORK}/four" has_warranty core:postgres engine: events:postgres,redis gateway: ; then
  pass "four-modules satisfies every generated-workflow property"
else
  fail "four-modules satisfies every generated-workflow property"
fi

echo "# main, build and deploy do not depend on the modules"
"${PY}" "${RENDER}" --root "${FIXTURES}/single-module" --out "${WORK}/single" >/dev/null 2>&1 || true
for f in main.yml build.yml deploy.yml; do
  if cmp -s "${WORK}/four/${f}" "${WORK}/single/${f}"; then
    pass "${f} is byte-identical across different module registries"
  else
    fail "${f} is byte-identical across different module registries"
  fi
done
if ! grep -q 'services/events' "${WORK}/four/deploy.yml" "${WORK}/four/build.yml" "${WORK}/four/main.yml"; then
  pass "custom code.dir never reaches the generated workflows"
else
  fail "custom code.dir never reaches the generated workflows"
fi
if grep -q 'code_dir: ${{ needs.release-start.outputs.code_dir }}' "${WORK}/four/deploy.yml"; then
  pass "deploy.yml gets code_dir from release-start"
else
  fail "deploy.yml gets code_dir from release-start"
fi

echo "# determinism"
"${PY}" "${RENDER}" --root "${FIXTURES}/four-modules" --out "${WORK}/four2" || true
same=1
for f in pr.yml main.yml build.yml deploy.yml; do
  cmp -s "${WORK}/four/${f}" "${WORK}/four2/${f}" || same=0
done
if [ "${same}" -eq 1 ] && [ -f "${WORK}/four/pr.yml" ]; then
  pass "two runs produce identical bytes"
else
  fail "two runs produce identical bytes"
fi

echo "# restricted key is passed only by the deploy caller"
if grep -qF 'WARD_KEY_RESTRICTED: ${{ secrets.WARD_KEY_HAS_WARRANTY_RESTRICTED }}' "${WORK}/four/deploy.yml" 2>/dev/null; then
  pass "deploy.yml passes WARD_KEY_RESTRICTED with a restricted vault"
else
  fail "deploy.yml passes WARD_KEY_RESTRICTED with a restricted vault"
fi
if [ "$(grep -c '_RESTRICTED' "${WORK}/four/deploy.yml")" -eq 1 ]; then
  pass "deploy.yml mentions _RESTRICTED only in the secret pass-through line"
else
  fail "deploy.yml mentions _RESTRICTED only in the secret pass-through line"
fi
if ! grep -q '_RESTRICTED' "${WORK}/four/pr.yml" 2>/dev/null \
  && ! grep -q '_RESTRICTED' "${WORK}/four/main.yml" 2>/dev/null \
  && ! grep -q '_RESTRICTED' "${WORK}/four/build.yml" 2>/dev/null \
  && [ -f "${WORK}/four/pr.yml" ]; then
  pass "_RESTRICTED never rendered outside deploy.yml"
else
  fail "_RESTRICTED never rendered outside deploy.yml"
fi
if ! grep -q 'production_key_secret' "${WORK}/four/deploy.yml"; then
  pass "deploy.yml has no production_key_secret"
else
  fail "deploy.yml has no production_key_secret"
fi

echo "# restricted vault is optional"
if "${PY}" "${RENDER}" --root "${FIXTURES}/no-restricted" --out "${WORK}/norestr"; then
  pass "no-restricted renders with exit 0"
else
  fail "no-restricted renders with exit 0"
fi
if [ -f "${WORK}/norestr/deploy.yml" ] \
  && ! grep -q '_RESTRICTED' "${WORK}/norestr/pr.yml" "${WORK}/norestr/main.yml" "${WORK}/norestr/build.yml" "${WORK}/norestr/deploy.yml" \
  && ! grep -q 'WARD_KEY_RESTRICTED' "${WORK}/norestr/deploy.yml"; then
  pass "no _RESTRICTED in any generated file without a restricted vault"
else
  fail "no _RESTRICTED in any generated file without a restricted vault"
fi
if grep -q 'has_warranty' "${WORK}/norestr/deploy.yml" && grep -q 'WARD_KEY_HAS_WARRANTY' "${WORK}/norestr/deploy.yml"; then
  pass "no-restricted deploy.yml still carries the default key"
else
  fail "no-restricted deploy.yml still carries the default key"
fi

echo "# ref"
refs() {
  cat "${1}"/pr.yml "${1}"/main.yml "${1}"/build.yml "${1}"/deploy.yml | grep -o 'br4zz4/pipelines/[A-Za-z0-9_./-]*@[A-Za-z0-9_.-]*' || true
}
"${PY}" "${RENDER}" --root "${FIXTURES}/four-modules" --out "${WORK}/beta" --ref v1-beta || true
refs "${WORK}/beta" > "${WORK}/beta-refs"
refs "${WORK}/four" > "${WORK}/v2-refs"
if [ -s "${WORK}/beta-refs" ] && ! grep -v '@v1-beta$' "${WORK}/beta-refs" | grep -q . ; then
  pass "--ref v1-beta rewrites every br4zz4/pipelines reference"
else
  fail "--ref v1-beta rewrites every br4zz4/pipelines reference: $(sort -u "${WORK}/beta-refs" | tr '\n' ' ')"
fi
for part in actions/conform actions/detect actions/split actions/target actions/releases actions/gate .github/workflows/code.yml .github/workflows/infra.yml .github/workflows/build.yml .github/workflows/deploy.yml; do
  if grep -q "br4zz4/pipelines/${part}@v1-beta" "${WORK}/beta-refs"; then
    pass "--ref v1-beta reaches ${part}"
  else
    fail "--ref v1-beta reaches ${part}"
  fi
done
if [ -s "${WORK}/v2-refs" ] && ! grep -v '@v2$' "${WORK}/v2-refs" | grep -q . ; then
  pass "default ref is v2"
else
  fail "default ref is v2"
fi
if grep -rho 'br4zz4/setup-ward@[A-Za-z0-9_.-]*' "${WORK}/beta" "${WORK}/four" | grep -q . \
  && ! grep -rho 'br4zz4/setup-ward@[A-Za-z0-9_.-]*' "${WORK}/beta" "${WORK}/four" | grep -v '@v1$' | grep -q . ; then
  pass "br4zz4/setup-ward stays @v1 regardless of --ref"
else
  fail "br4zz4/setup-ward stays @v1 regardless of --ref"
fi

echo "# invalid inputs"
for case in bad-module-name bad-service ward-two-defaults ward-no-default ward-many-defaults ward-two-namespaces; do
  status=0
  "${PY}" "${RENDER}" --root "${FIXTURES}/invalid/${case}" --out "${WORK}/inv-${case}" \
    >/dev/null 2>"${WORK}/err-${case}" || status=$?
  if [ "${status}" -eq 2 ] && [ -s "${WORK}/err-${case}" ]; then
    pass "invalid ${case} exits 2 with stderr"
  else
    fail "invalid ${case} exits 2 with stderr (status=${status})"
  fi
done

"${PY}" "${RENDER}" --root "${FIXTURES}/invalid/ward-many-defaults" --out "${WORK}/many" >/dev/null 2>"${WORK}/err-many" || true
if grep -q 'has_warranty' "${WORK}/err-many" && grep -q 'other' "${WORK}/err-many"; then
  pass "many defaults without pair names them on stderr"
else
  fail "many defaults without pair names them on stderr"
fi

echo "# promote: key writes promote.yml and the deploy force input"
PROMOTE="${FIXTURES}/promote"
status=0
"${PY}" "${RENDER}" --root "${PROMOTE}" --out "${WORK}/promote" >/dev/null 2>"${WORK}/err-promote" || status=$?
if [ "${status}" -eq 0 ]; then
  pass "promote fixture renders with exit 0"
else
  fail "promote fixture renders with exit 0 (status=${status})"
fi
for f in pr.yml main.yml build.yml deploy.yml promote.yml; do
  if [ -f "${WORK}/promote/${f}" ] && cmp -s "${WORK}/promote/${f}" "${PROMOTE}/expected/${f}"; then
    pass "promote fixture ${f} matches the expected bytes"
  else
    fail "promote fixture ${f} matches the expected bytes"
    diff "${PROMOTE}/expected/${f}" "${WORK}/promote/${f}" 2>&1 | head -10 || true
  fi
done
"${PY}" "${RENDER}" --root "${PROMOTE}" --out "${WORK}/promote2" >/dev/null 2>&1 || true
if [ -f "${WORK}/promote/promote.yml" ] && cmp -s "${WORK}/promote/promote.yml" "${WORK}/promote2/promote.yml"; then
  pass "promote.yml is deterministic"
else
  fail "promote.yml is deterministic"
fi
"${PY}" "${RENDER}" --root "${PROMOTE}" --out "${WORK}/promote-beta" --ref v1-beta >/dev/null 2>&1 || true
if [ -f "${WORK}/promote-beta/promote.yml" ] \
  && grep -o 'br4zz4/pipelines/[A-Za-z0-9_./-]*@[A-Za-z0-9_.-]*' "${WORK}/promote-beta/promote.yml" | grep -q . \
  && ! grep -o 'br4zz4/pipelines/[A-Za-z0-9_./-]*@[A-Za-z0-9_.-]*' "${WORK}/promote-beta/promote.yml" | grep -v '@v1-beta$' | grep -q . \
  && grep -q 'br4zz4/pipelines/actions/promote@v1-beta' "${WORK}/promote-beta/promote.yml" \
  && grep -q 'br4zz4/pipelines/.github/workflows/promote.yml@v1-beta' "${WORK}/promote-beta/promote.yml"; then
  pass "--ref v1-beta rewrites every reference in promote.yml"
else
  fail "--ref v1-beta rewrites every reference in promote.yml"
fi
if [ -f "${WORK}/promote/promote.yml" ] \
  && grep -q 'group: promote-${{ needs.target.outputs.module }}' "${WORK}/promote/promote.yml" \
  && grep -q 'cancel-in-progress: true' "${WORK}/promote/promote.yml" \
  && grep -q '^  workflow_dispatch:$' "${WORK}/promote/promote.yml" \
  && grep -q '^run-name: promote · ${{ inputs.tag }}$' "${WORK}/promote/promote.yml" \
  && grep -q '^          tag: ${{ inputs.tag }}$' "${WORK}/promote/promote.yml" \
  && ! grep -q 'workflow_run' "${WORK}/promote/promote.yml" \
  && ! grep -q '^  incident:' "${WORK}/promote/promote.yml" \
  && ! grep -q '^    if:' "${WORK}/promote/promote.yml"; then
  pass "promote.yml is dispatch-only, has no incident job, and keeps the per-module concurrency"
else
  fail "promote.yml is dispatch-only, has no incident job, and keeps the per-module concurrency"
fi
if grep -q 'require_promoted: ${{ !inputs.force }}' "${WORK}/promote/deploy.yml" \
  && grep -q 'promote_enabled: true' "${WORK}/promote/deploy.yml" \
  && grep -q '      force:' "${WORK}/promote/deploy.yml"; then
  pass "promote deploy.yml has the force input and passes require_promoted"
else
  fail "promote deploy.yml has the force input and passes require_promoted"
fi

echo "# max_per_day is 0 when promote has no limit"
mkdir -p "${WORK}/nolimit/.github" "${WORK}/nolimit/.ward"
cp "${PROMOTE}/.ward/config.yaml" "${WORK}/nolimit/.ward/config.yaml"
printf '{"modules": {"solo": {}}, "promote": {}}\n' > "${WORK}/nolimit/.github/modules.json"
"${PY}" "${RENDER}" --root "${WORK}/nolimit" --out "${WORK}/nolimit-out" >/dev/null 2>&1 || true
if [ -f "${WORK}/nolimit-out/promote.yml" ] && grep -q '^      max_per_day: 0$' "${WORK}/nolimit-out/promote.yml"; then
  pass "promote: {} renders max_per_day 0"
else
  fail "promote: {} renders max_per_day 0"
fi

echo "# without the promote key nothing changes"
for fx in four-modules single-module no-restricted; do
  "${PY}" "${RENDER}" --root "${FIXTURES}/${fx}" --out "${WORK}/nopromote-${fx}" >/dev/null 2>&1 || true
  if [ -f "${WORK}/nopromote-${fx}/deploy.yml" ] \
    && [ ! -e "${WORK}/nopromote-${fx}/promote.yml" ] \
    && [ "$(ls "${WORK}/nopromote-${fx}" | tr '\n' ' ')" = "build.yml deploy.yml main.yml pr.yml " ] \
    && ! grep -q 'force\|require_promoted\|promote_enabled' "${WORK}/nopromote-${fx}/deploy.yml"; then
    pass "${fx} writes no promote.yml and no force input"
  else
    fail "${fx} writes no promote.yml and no force input"
  fi
done
for pair in four-modules:four single-module:single; do
  fx="${pair%%:*}"
  ref="${WORK}/${pair##*:}"
  same=1
  for f in pr.yml main.yml build.yml deploy.yml; do
    cmp -s "${WORK}/nopromote-${fx}/${f}" "${ref}/${f}" || same=0
  done
  if [ "${same}" -eq 1 ] && [ -f "${ref}/pr.yml" ]; then
    pass "${fx} renders the same bytes as before promote"
  else
    fail "${fx} renders the same bytes as before promote"
  fi
done
for fx in four-modules single-module no-restricted; do
  snapshot="${HERE}/golden/${fx}.cksum"
  if [ -f "${WORK}/nopromote-${fx}/pr.yml" ] \
    && (cd "${WORK}/nopromote-${fx}" && cksum pr.yml main.yml build.yml deploy.yml) | cmp -s - "${snapshot}"; then
    pass "${fx} bytes match the golden checksums"
  else
    fail "${fx} bytes match the golden checksums"
  fi
done

echo "# invalid promote config"
for pair in promote-zero:max_per_day promote-unknown-key:bogus_key; do
  case="${pair%%:*}"
  key="${pair##*:}"
  status=0
  "${PY}" "${RENDER}" --root "${FIXTURES}/invalid/${case}" --out "${WORK}/inv-${case}" \
    >/dev/null 2>"${WORK}/err-${case}" || status=$?
  if [ "${status}" -eq 2 ] && grep -q "${key}" "${WORK}/err-${case}" && [ ! -e "${WORK}/inv-${case}/promote.yml" ]; then
    pass "invalid ${case} exits 2 citing ${key}"
  else
    fail "invalid ${case} exits 2 citing ${key} (status=${status})"
  fi
done

echo "# sentry: key adds the sentry inputs to build and deploy"
SENTRY="${FIXTURES}/sentry"
status=0
python3 "${RENDER}" --root "${SENTRY}" --out "${WORK}/sentry" >/dev/null 2>"${WORK}/err-sentry" || status=$?
if [ "${status}" -eq 0 ]; then
  pass "sentry fixture renders with exit 0"
else
  fail "sentry fixture renders with exit 0 (status=${status})"
fi
for f in pr.yml main.yml build.yml deploy.yml; do
  if [ -f "${WORK}/sentry/${f}" ] && cmp -s "${WORK}/sentry/${f}" "${SENTRY}/expected/${f}"; then
    pass "sentry fixture ${f} matches the expected bytes"
  else
    fail "sentry fixture ${f} matches the expected bytes"
    diff "${SENTRY}/expected/${f}" "${WORK}/sentry/${f}" 2>&1 | head -10 || true
  fi
done
if [ "$(ls "${WORK}/sentry" 2>/dev/null | tr '\n' ' ')" = "build.yml deploy.yml main.yml pr.yml " ]; then
  pass "sentry writes no extra workflow"
else
  fail "sentry writes no extra workflow"
fi
if grep -q '^      sentry_url: https://sentry.io$' "${WORK}/sentry/build.yml" "${WORK}/sentry/deploy.yml"; then
  pass "sentry.url defaults to https://sentry.io"
else
  fail "sentry.url defaults to https://sentry.io"
fi
SENTRY_URL="${FIXTURES}/sentry-url"
status=0
python3 "${RENDER}" --root "${SENTRY_URL}" --out "${WORK}/sentry-url" >/dev/null 2>&1 || status=$?
for f in pr.yml main.yml build.yml deploy.yml; do
  if [ "${status}" -eq 0 ] && [ -f "${WORK}/sentry-url/${f}" ] && cmp -s "${WORK}/sentry-url/${f}" "${SENTRY_URL}/expected/${f}"; then
    pass "sentry-url fixture ${f} matches the expected bytes"
  else
    fail "sentry-url fixture ${f} matches the expected bytes"
  fi
done
python3 "${RENDER}" --root "${SENTRY}" --out "${WORK}/sentry2" >/dev/null 2>&1 || true
same=1
for f in pr.yml main.yml build.yml deploy.yml; do
  cmp -s "${WORK}/sentry/${f}" "${WORK}/sentry2/${f}" || same=0
done
if [ "${same}" -eq 1 ] && [ -f "${WORK}/sentry/build.yml" ]; then
  pass "sentry render is deterministic"
else
  fail "sentry render is deterministic"
fi
python3 "${RENDER}" --root "${SENTRY}" --out "${WORK}/sentry-beta" --ref v1-beta >/dev/null 2>&1 || true
if [ -f "${WORK}/sentry-beta/build.yml" ] \
  && grep -q 'br4zz4/pipelines/.github/workflows/build.yml@v1-beta' "${WORK}/sentry-beta/build.yml" \
  && grep -q '^      sentry_org: brazza-tech$' "${WORK}/sentry-beta/build.yml"; then
  pass "sentry inputs survive --ref"
else
  fail "sentry inputs survive --ref"
fi
for f in pr.yml main.yml; do
  if [ -f "${WORK}/sentry/${f}" ] && ! grep -q 'sentry' "${WORK}/sentry/${f}"; then
    pass "sentry never reaches ${f}"
  else
    fail "sentry never reaches ${f}"
  fi
done

echo "# without the sentry key nothing changes"
for fx in four-modules single-module no-restricted promote; do
  python3 "${RENDER}" --root "${FIXTURES}/${fx}" --out "${WORK}/nosentry-${fx}" >/dev/null 2>&1 || true
  if [ -f "${WORK}/nosentry-${fx}/deploy.yml" ] && ! grep -rqi 'sentry' "${WORK}/nosentry-${fx}"; then
    pass "${fx} renders no sentry input"
  else
    fail "${fx} renders no sentry input"
  fi
done

echo "# invalid sentry config"
for pair in sentry-no-org:org sentry-empty-project:project sentry-http-url:url sentry-unknown-key:bogus_key; do
  case="${pair%%:*}"
  key="${pair##*:}"
  status=0
  python3 "${RENDER}" --root "${FIXTURES}/invalid/${case}" --out "${WORK}/inv-${case}" \
    >/dev/null 2>"${WORK}/err-${case}" || status=$?
  if [ "${status}" -eq 2 ] && grep -q "sentry" "${WORK}/err-${case}" && grep -q "${key}" "${WORK}/err-${case}" && [ ! -e "${WORK}/inv-${case}/build.yml" ]; then
    pass "invalid ${case} exits 2 citing ${key}"
  else
    fail "invalid ${case} exits 2 citing ${key} (status=${status})"
  fi
done

echo "# autofix: key writes the consumer autofix.yml"
AUTOFIX="${FIXTURES}/autofix"
status=0
python3 "${RENDER}" --root "${AUTOFIX}" --out "${WORK}/autofix" >/dev/null 2>"${WORK}/err-autofix" || status=$?
if [ "${status}" -eq 0 ]; then
  pass "autofix fixture renders with exit 0"
else
  fail "autofix fixture renders with exit 0 (status=${status})"
fi
for f in pr.yml main.yml build.yml deploy.yml autofix.yml; do
  if [ -f "${WORK}/autofix/${f}" ] && norm_date "${WORK}/autofix/${f}" | cmp -s - "${AUTOFIX}/expected/${f}"; then
    pass "autofix fixture ${f} matches the expected bytes"
  else
    fail "autofix fixture ${f} matches the expected bytes"
    diff "${AUTOFIX}/expected/${f}" "${WORK}/autofix/${f}" 2>&1 | head -10 || true
  fi
done
if [ "$(ls "${WORK}/autofix" 2>/dev/null | tr '\n' ' ')" = "autofix.yml build.yml deploy.yml main.yml pr.yml " ]; then
  pass "autofix without autofix.sentry writes no sentry-intake.yml"
else
  fail "autofix without autofix.sentry writes no sentry-intake.yml"
fi
python3 "${RENDER}" --root "${AUTOFIX}" --out "${WORK}/autofix2" >/dev/null 2>&1 || true
if [ -f "${WORK}/autofix/autofix.yml" ] && cmp -s "${WORK}/autofix/autofix.yml" "${WORK}/autofix2/autofix.yml"; then
  pass "autofix.yml is deterministic"
else
  fail "autofix.yml is deterministic"
fi
for f in pr.yml main.yml build.yml deploy.yml; do
  if [ -f "${WORK}/autofix/${f}" ] && cmp -s "${WORK}/autofix/${f}" "${WORK}/four/${f}"; then
    pass "autofix leaves ${f} byte-identical to the render without the key"
  else
    fail "autofix leaves ${f} byte-identical to the render without the key"
  fi
done
if [ -f "${WORK}/autofix/autofix.yml" ] \
  && grep -q '^    types: \[ labeled \]$' "${WORK}/autofix/autofix.yml" \
  && grep -q '^  workflow_dispatch:$' "${WORK}/autofix/autofix.yml" \
  && grep -q "if: \${{ github.event_name == 'workflow_dispatch' || github.event.label.name == 'urgency:critical' }}" "${WORK}/autofix/autofix.yml" \
  && grep -q '^    uses: br4zz4/pipelines/.github/workflows/autofix.yml@v2$' "${WORK}/autofix/autofix.yml" \
  && grep -q '^      max_per_day: 5$' "${WORK}/autofix/autofix.yml" \
  && grep -q '^      WARD_KEY: ${{ secrets.WARD_KEY_HAS_WARRANTY }}$' "${WORK}/autofix/autofix.yml" \
  && grep -q 'group: autofix-${{ github.event.issue.number || inputs.issue }}' "${WORK}/autofix/autofix.yml"; then
  pass "autofix.yml carries the label guard, the reusable call, the cap and the per-issue concurrency"
else
  fail "autofix.yml carries the label guard, the reusable call, the cap and the per-issue concurrency"
fi
if [ -f "${WORK}/autofix/autofix.yml" ] \
  && python3 - "${WORK}/autofix/autofix.yml" <<'PY'
import json
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
raw = re.search(r"^      modules: '(.*)'$", text, re.M).group(1)
data = json.loads(raw)
assert data == {
    "core": {"code": "modules/core/code", "services": "postgres"},
    "engine": {"code": "modules/engine/code", "services": ""},
    "events": {"code": "services/events", "services": "postgres,redis"},
    "gateway": {"code": "modules/gateway/code", "services": ""},
}, data
PY
then
  pass "autofix.yml modules JSON maps every module to its code dir and services"
else
  fail "autofix.yml modules JSON maps every module to its code dir and services"
fi
python3 "${RENDER}" --root "${AUTOFIX}" --out "${WORK}/autofix-beta" --ref v1-beta >/dev/null 2>&1 || true
if [ -f "${WORK}/autofix-beta/autofix.yml" ] \
  && grep -q 'br4zz4/pipelines/.github/workflows/autofix.yml@v1-beta' "${WORK}/autofix-beta/autofix.yml"; then
  pass "--ref v1-beta rewrites the autofix.yml reference"
else
  fail "--ref v1-beta rewrites the autofix.yml reference"
fi

python3 "${RENDER}" --root "${FIXTURES}/autofix-sentry" --out "${WORK}/autofix-sentry" >/dev/null 2>&1 || true
python3 "${RENDER}" --root "${FIXTURES}/autofix-sentry-defaults" --out "${WORK}/autofix-sentry-defaults" >/dev/null 2>&1 || true
for fx in autofix autofix-sentry autofix-sentry-defaults; do
  if grep -q "^run-name: \"autofix #\${{ github.event.issue.number || inputs.issue }}" "${WORK}/${fx}/autofix.yml" 2>/dev/null \
    && ! grep -q 'autofix · ' "${WORK}/${fx}/autofix.yml"; then
    pass "${fx} autofix.yml run-name starts with autofix #"
  else
    fail "${fx} autofix.yml run-name starts with autofix #"
  fi
done

echo "# autofix: max_per_day defaults to 0"
mkdir -p "${WORK}/afdefault/.github" "${WORK}/afdefault/.ward"
cp "${PROMOTE}/.ward/config.yaml" "${WORK}/afdefault/.ward/config.yaml"
printf '{"modules": {"solo": {}}, "autofix": {}}\n' > "${WORK}/afdefault/.github/modules.json"
python3 "${RENDER}" --root "${WORK}/afdefault" --out "${WORK}/afdefault-out" >/dev/null 2>&1 || true
if [ -f "${WORK}/afdefault-out/autofix.yml" ] && grep -q '^      max_per_day: 0$' "${WORK}/afdefault-out/autofix.yml"; then
  pass "autofix: {} renders max_per_day 0"
else
  fail "autofix: {} renders max_per_day 0"
fi
printf '{"modules": {"solo": {}}, "autofix": {"max_per_day": 0}}\n' > "${WORK}/afdefault/.github/modules.json"
python3 "${RENDER}" --root "${WORK}/afdefault" --out "${WORK}/afzero-out" >/dev/null 2>&1 || true
if [ -f "${WORK}/afzero-out/autofix.yml" ] && grep -q '^      max_per_day: 0$' "${WORK}/afzero-out/autofix.yml"; then
  pass "autofix.max_per_day 0 is accepted"
else
  fail "autofix.max_per_day 0 is accepted"
fi

echo "# autofix.sentry: key writes the scheduled sentry-intake.yml"
for fx in autofix-sentry autofix-sentry-defaults; do
  FX="${FIXTURES}/${fx}"
  status=0
  python3 "${RENDER}" --root "${FX}" --out "${WORK}/${fx}" >/dev/null 2>"${WORK}/err-${fx}" || status=$?
  if [ "${status}" -eq 0 ]; then
    pass "${fx} fixture renders with exit 0"
  else
    fail "${fx} fixture renders with exit 0 (status=${status})"
  fi
  for f in pr.yml main.yml build.yml deploy.yml autofix.yml sentry-intake.yml; do
    if [ -f "${WORK}/${fx}/${f}" ] && norm_date "${WORK}/${fx}/${f}" | cmp -s - "${FX}/expected/${f}"; then
      pass "${fx} fixture ${f} matches the expected bytes"
    else
      fail "${fx} fixture ${f} matches the expected bytes"
      diff "${FX}/expected/${f}" "${WORK}/${fx}/${f}" 2>&1 | head -10 || true
    fi
  done
  if [ "$(ls "${WORK}/${fx}" 2>/dev/null | tr '\n' ' ')" = "autofix.yml build.yml deploy.yml main.yml pr.yml sentry-intake.yml " ]; then
    pass "${fx} writes exactly the six workflows"
  else
    fail "${fx} writes exactly the six workflows"
  fi
  python3 "${RENDER}" --root "${FX}" --out "${WORK}/${fx}-2" >/dev/null 2>&1 || true
  if [ -f "${WORK}/${fx}/sentry-intake.yml" ] && cmp -s "${WORK}/${fx}/sentry-intake.yml" "${WORK}/${fx}-2/sentry-intake.yml"; then
    pass "${fx} sentry-intake.yml is deterministic"
  else
    fail "${fx} sentry-intake.yml is deterministic"
  fi
  if [ -f "${WORK}/${fx}/sentry-intake.yml" ] \
    && grep -q '^  workflow_dispatch:$' "${WORK}/${fx}/sentry-intake.yml" \
    && grep -q '^    - cron: ' "${WORK}/${fx}/sentry-intake.yml" \
    && grep -q '^          persist-credentials: false$' "${WORK}/${fx}/sentry-intake.yml" \
    && grep -q 'scopes: has_warranty:secrets.ci.common' "${WORK}/${fx}/sentry-intake.yml" \
    && grep -q 'uses: br4zz4/pipelines/actions/sentry@v2' "${WORK}/${fx}/sentry-intake.yml" \
    && grep -q 'sentry_token: ${{ env.SENTRY_AUTH_TOKEN }}' "${WORK}/${fx}/sentry-intake.yml" \
    && grep -q 'token: ${{ env.GH_PIPELINES_TOKEN }}' "${WORK}/${fx}/sentry-intake.yml"; then
    pass "${fx} sentry-intake.yml schedules, checks out without credentials and calls actions/sentry"
  else
    fail "${fx} sentry-intake.yml schedules, checks out without credentials and calls actions/sentry"
  fi
done
if grep -q '^    - cron: .0 \* \* \* \*.$' "${WORK}/autofix-sentry-defaults/sentry-intake.yml" 2>/dev/null \
  && grep -q '^          environments: production,staging$' "${WORK}/autofix-sentry-defaults/sentry-intake.yml" \
  && grep -q "^          min_events: '5'$" "${WORK}/autofix-sentry-defaults/sentry-intake.yml" \
  && grep -q '^          url: https://sentry.io$' "${WORK}/autofix-sentry-defaults/sentry-intake.yml" \
  && grep -q '^      max_per_day: 0$' "${WORK}/autofix-sentry-defaults/autofix.yml"; then
  pass "autofix.sentry defaults: hourly, production and staging, 5 events, sentry.io"
else
  fail "autofix.sentry defaults: hourly, production and staging, 5 events, sentry.io"
fi
if [ -f "${WORK}/autofix-sentry/sentry-intake.yml" ] \
  && grep -q "^    - cron: '30 2 \* \* \*'$" "${WORK}/autofix-sentry/sentry-intake.yml" \
  && grep -q '^          environments: production$' "${WORK}/autofix-sentry/sentry-intake.yml" \
  && grep -q "^          min_events: '10'$" "${WORK}/autofix-sentry/sentry-intake.yml" \
  && grep -q '^          url: https://sentry.example.com$' "${WORK}/autofix-sentry/sentry-intake.yml"; then
  pass "autofix.sentry options and the top-level sentry url reach sentry-intake.yml"
else
  fail "autofix.sentry options and the top-level sentry url reach sentry-intake.yml"
fi
python3 "${RENDER}" --root "${FIXTURES}/autofix-sentry" --out "${WORK}/afs-beta" --ref v1-beta >/dev/null 2>&1 || true
if [ -f "${WORK}/afs-beta/sentry-intake.yml" ] \
  && grep -q 'br4zz4/pipelines/actions/sentry@v1-beta' "${WORK}/afs-beta/sentry-intake.yml" \
  && grep -q 'br4zz4/setup-ward@v1$' "${WORK}/afs-beta/sentry-intake.yml"; then
  pass "--ref v1-beta rewrites actions/sentry and keeps setup-ward @v1"
else
  fail "--ref v1-beta rewrites actions/sentry and keeps setup-ward @v1"
fi

echo "# without the autofix key nothing changes"
for fx in four-modules single-module no-restricted promote sentry sentry-url; do
  python3 "${RENDER}" --root "${FIXTURES}/${fx}" --out "${WORK}/noaf-${fx}" >/dev/null 2>&1 || true
  if [ -f "${WORK}/noaf-${fx}/deploy.yml" ] \
    && [ ! -e "${WORK}/noaf-${fx}/autofix.yml" ] \
    && [ ! -e "${WORK}/noaf-${fx}/sentry-intake.yml" ] \
    && ! grep -rqi 'autofix' "${WORK}/noaf-${fx}"; then
    pass "${fx} writes no autofix.yml and no sentry-intake.yml"
  else
    fail "${fx} writes no autofix.yml and no sentry-intake.yml"
  fi
done

echo "# invalid autofix config"
for pair in autofix-not-object:autofix autofix-max-negative:autofix.max_per_day autofix-max-string:autofix.max_per_day autofix-unknown-key:bogus_key autofix-sentry-no-top:autofix.sentry autofix-sentry-org:org autofix-sentry-unknown-key:bogus_key autofix-schedule-fields:schedule autofix-environments-empty:environments autofix-environments-string:environments autofix-min-events-zero:min_events; do
  case="${pair%%:*}"
  key="${pair##*:}"
  status=0
  python3 "${RENDER}" --root "${FIXTURES}/invalid/${case}" --out "${WORK}/inv-${case}" \
    >/dev/null 2>"${WORK}/err-${case}" || status=$?
  if [ "${status}" -eq 2 ] && grep -q "autofix" "${WORK}/err-${case}" && grep -q "${key}" "${WORK}/err-${case}" \
    && [ ! -e "${WORK}/inv-${case}/autofix.yml" ] && [ ! -e "${WORK}/inv-${case}/build.yml" ]; then
    pass "invalid ${case} exits 2 citing ${key}"
  else
    fail "invalid ${case} exits 2 citing ${key} (status=${status})"
  fi
done

echo "# fix: key writes the consumer fix.yml"
FIXFX="${FIXTURES}/fix"
status=0
"${PY}" "${RENDER}" --root "${FIXFX}" --out "${WORK}/fix" >/dev/null 2>"${WORK}/err-fix" || status=$?
if [ "${status}" -eq 0 ] && [ -f "${WORK}/fix/fix.yml" ]; then
  pass "fix fixture renders fix.yml with exit 0"
else
  fail "fix fixture renders fix.yml with exit 0 (status=${status})"
fi
if [ "$(ls "${WORK}/fix" 2>/dev/null | tr '\n' ' ')" = "build.yml deploy.yml fix.yml main.yml pr.yml " ]; then
  pass "fix without autofix writes the four workflows plus fix.yml"
else
  fail "fix without autofix writes the four workflows plus fix.yml"
fi
if "${PY}" "${HERE}/fix_props.py" "${WORK}/fix/fix.yml" v2 postgres >"${WORK}/fixprops" 2>&1; then
  pass "fix.yml satisfies every generated-workflow property"
else
  fail "fix.yml satisfies every generated-workflow property: $(tr '\n' ' ' < "${WORK}/fixprops")"
fi
"${PY}" "${RENDER}" --root "${FIXFX}" --out "${WORK}/fix2" >/dev/null 2>&1 || true
if [ -f "${WORK}/fix/fix.yml" ] && cmp -s "${WORK}/fix/fix.yml" "${WORK}/fix2/fix.yml"; then
  pass "fix.yml is deterministic"
else
  fail "fix.yml is deterministic"
fi
"${PY}" "${RENDER}" --root "${FIXFX}" --out "${WORK}/fix-beta" --ref v2-beta >/dev/null 2>&1 || true
if [ -f "${WORK}/fix-beta/fix.yml" ] && "${PY}" "${HERE}/fix_props.py" "${WORK}/fix-beta/fix.yml" v2-beta postgres >/dev/null 2>&1; then
  pass "--ref v2-beta rewrites the fix-run reference"
else
  fail "--ref v2-beta rewrites the fix-run reference"
fi
for fx in fix-defaults fix-autofix; do
  "${PY}" "${RENDER}" --root "${FIXTURES}/${fx}" --out "${WORK}/${fx}" >/dev/null 2>&1 || true
  if [ -f "${WORK}/${fx}/fix.yml" ] && "${PY}" "${HERE}/fix_props.py" "${WORK}/${fx}/fix.yml" v2 postgres >/dev/null 2>&1; then
    pass "${fx} renders a valid fix.yml"
  else
    fail "${fx} renders a valid fix.yml"
  fi
done
if [ -f "${WORK}/fix-autofix/autofix.yml" ] && [ -f "${WORK}/fix-autofix/fix.yml" ]; then
  pass "fix and autofix together write both workflows"
else
  fail "fix and autofix together write both workflows"
fi
"${PY}" "${RENDER}" --root "${FIXTURES}/fix-nopg" --out "${WORK}/fix-nopg" >/dev/null 2>&1 || true
if [ -f "${WORK}/fix-nopg/fix.yml" ] && "${PY}" "${HERE}/fix_props.py" "${WORK}/fix-nopg/fix.yml" v2 none >/dev/null 2>&1; then
  pass "fix.yml has no postgres service when no module declares postgres"
else
  fail "fix.yml has no postgres service when no module declares postgres"
fi
mkdir -p "${WORK}/fix-nokey/.github" "${WORK}/fix-nokey/.ward"
cp "${FIXFX}/.ward/config.yaml" "${WORK}/fix-nokey/.ward/config.yaml"
"${PY}" - "${FIXFX}/.github/modules.json" "${WORK}/fix-nokey/.github/modules.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
del data["fix"]
json.dump(data, open(sys.argv[2], "w", encoding="utf-8"))
PY
"${PY}" "${RENDER}" --root "${WORK}/fix-nokey" --out "${WORK}/fix-nokey-out" >/dev/null 2>&1 || true
if [ -f "${WORK}/fix-nokey-out/deploy.yml" ] && [ ! -e "${WORK}/fix-nokey-out/fix.yml" ] \
  && ! grep -rq 'fix-run' "${WORK}/fix-nokey-out"; then
  pass "without the fix key no fix.yml is written"
else
  fail "without the fix key no fix.yml is written"
fi
same=1
for f in pr.yml main.yml build.yml deploy.yml; do
  cmp -s "${WORK}/fix/${f}" "${WORK}/fix-nokey-out/${f}" || same=0
done
if [ "${same}" -eq 1 ] && [ -f "${WORK}/fix/pr.yml" ]; then
  pass "fix leaves the other workflows byte-identical to the render without the key"
else
  fail "fix leaves the other workflows byte-identical to the render without the key"
fi
for fx in four-modules single-module autofix sentry; do
  "${PY}" "${RENDER}" --root "${FIXTURES}/${fx}" --out "${WORK}/nofix-${fx}" >/dev/null 2>&1 || true
  if [ -f "${WORK}/nofix-${fx}/deploy.yml" ] && [ ! -e "${WORK}/nofix-${fx}/fix.yml" ]; then
    pass "${fx} writes no fix.yml"
  else
    fail "${fx} writes no fix.yml"
  fi
done
if [ -f "${WORK}/fix/fix.yml" ]; then
  mkdir -p "${WORK}/fix-consumers/.github"
  cp -R "${WORK}/fix" "${WORK}/fix-consumers/.github/workflows"
  if "${PY}" "${ROOT}/tasks/check.py" --consumers "${WORK}/fix-consumers" >"${WORK}/fix-cons.log" 2>&1 \
    && "${PY}" "${ROOT}/tasks/check.py" --standard "${WORK}/fix-consumers/.github/workflows" >>"${WORK}/fix-cons.log" 2>&1; then
    pass "rendered fix.yml passes check.py --consumers and --standard"
  else
    fail "rendered fix.yml passes check.py --consumers and --standard: $(tr '\n' ' ' < "${WORK}/fix-cons.log")"
  fi
else
  fail "rendered fix.yml passes check.py --consumers and --standard"
fi

if [ -f "${WORK}/fix-autofix/autofix.yml" ] \
  && sed -n '/^    uses: br4zz4\/pipelines\/.github\/workflows\/autofix.yml@v2$/,/^    secrets:$/p' "${WORK}/fix-autofix/autofix.yml" | grep -Fxq '      handoff: true'; then
  pass "fix with autofix passes handoff: true to the autofix workflow"
else
  fail "fix with autofix passes handoff: true to the autofix workflow"
fi
if [ -f "${WORK}/autofix/autofix.yml" ] && ! grep -q 'handoff' "${WORK}/autofix/autofix.yml" \
  && cmp -s "${WORK}/autofix/autofix.yml" "${AUTOFIX}/expected/autofix.yml"; then
  pass "autofix without fix has no handoff and stays byte-identical"
else
  fail "autofix without fix has no handoff and stays byte-identical"
fi

echo "# invalid fix config"
for pair in fix-not-object:fix fix-unknown-key:foo fix-max-negative:fix.max_per_day fix-max-bool:fix.max_per_day fix-max-float:fix.max_per_day fix-max-string:fix.max_per_day; do
  case="${pair%%:*}"
  key="${pair##*:}"
  status=0
  "${PY}" "${RENDER}" --root "${FIXTURES}/invalid/${case}" --out "${WORK}/inv-${case}" \
    >/dev/null 2>"${WORK}/err-${case}" || status=$?
  if [ "${status}" -eq 2 ] && grep -q "${key}" "${WORK}/err-${case}" \
    && [ ! -e "${WORK}/inv-${case}/fix.yml" ] && [ ! -e "${WORK}/inv-${case}/build.yml" ]; then
    pass "invalid ${case} exits 2 citing ${key}"
  else
    fail "invalid ${case} exits 2 citing ${key} (status=${status})"
  fi
done

echo "# code.test_workers validation"
mk_workers() {
  d="${WORK}/workers-${1}"
  mkdir -p "${d}/.github"
  cp -R "${FIXTURES}/single-module/.ward" "${d}/.ward"
  printf '{"shared": [".github/"], "modules": {"solo": {"code": {"test_workers": %s}}}}\n' "${2}" > "${d}/.github/modules.json"
}
for pair in zero:0 negative:-1 string:'"4"' float:1.5 bool:true; do
  name="${pair%%:*}"
  value="${pair#*:}"
  mk_workers "${name}" "${value}"
  status=0
  "${PY}" "${RENDER}" --root "${WORK}/workers-${name}" --out "${WORK}/workers-${name}-out" \
    >/dev/null 2>"${WORK}/workers-${name}-err" || status=$?
  if [ "${status}" -eq 2 ] && grep -qF 'modules.solo.code.test_workers: must be an integer >= 1' "${WORK}/workers-${name}-err"; then
    pass "test_workers ${value} is rejected with the exact message"
  else
    fail "test_workers ${value} is rejected with the exact message (status=${status})"
  fi
done
for value in 1 8; do
  mk_workers "ok${value}" "${value}"
  status=0
  "${PY}" "${RENDER}" --root "${WORK}/workers-ok${value}" --out "${WORK}/workers-ok${value}-out" \
    >/dev/null 2>"${WORK}/workers-ok${value}-err" || status=$?
  if [ "${status}" -eq 0 ] && [ -f "${WORK}/workers-ok${value}-out/pr.yml" ]; then
    pass "test_workers ${value} renders"
  else
    fail "test_workers ${value} renders (status=${status})"
  fi
done

echo "# test_workers does not change the rendered workflows"
mk_workers same 8
"${PY}" "${RENDER}" --root "${FIXTURES}/single-module" --out "${WORK}/workers-base-out" >/dev/null 2>&1 || true
"${PY}" "${RENDER}" --root "${WORK}/workers-same" --out "${WORK}/workers-same-out" >/dev/null 2>&1 || true
if [ -f "${WORK}/workers-same-out/pr.yml" ] && diff -r "${WORK}/workers-base-out" "${WORK}/workers-same-out" >/dev/null; then
  pass "registry with test_workers renders the same workflows as without"
else
  fail "registry with test_workers renders the same workflows as without"
fi

echo "# code.packages validation"
mk_packages() {
  d="${WORK}/packages-${1}"
  mkdir -p "${d}/.github"
  cp -R "${FIXTURES}/single-module/.ward" "${d}/.ward"
  printf '{"shared": [".github/"], "modules": {"solo": {"code": {"packages": %s}}}}\n' "${2}" > "${d}/.github/modules.json"
}
for pair in 'not-object:"curl"' 'list:["curl"]' 'unknown-hook:{"deploy":["curl"]}' 'empty-list:{"lint":[]}' 'not-a-list:{"lint":"curl"}' 'uppercase:{"lint":["Curl"]}' 'bad-char:{"lint":["libpq_dev"]}' 'leading-dash:{"lint":["-y"]}' 'space:{"lint":["a b"]}' 'non-string:{"lint":[1]}'; do
  name="${pair%%:*}"
  value="${pair#*:}"
  mk_packages "${name}" "${value}"
  status=0
  "${PY}" "${RENDER}" --root "${WORK}/packages-${name}" --out "${WORK}/packages-${name}-out" \
    >/dev/null 2>"${WORK}/packages-${name}-err" || status=$?
  if [ "${status}" -eq 2 ] && grep -qF 'modules.solo.code.packages' "${WORK}/packages-${name}-err" && [ ! -e "${WORK}/packages-${name}-out/pr.yml" ]; then
    pass "packages ${name} is rejected citing modules.solo.code.packages"
  else
    fail "packages ${name} is rejected citing modules.solo.code.packages (status=${status})"
  fi
done
for hook in lint audit test regression e2e build; do
  mk_packages "ok-${hook}" "{\"${hook}\": [\"libpq-dev\", \"g++\", \"libstdc++6\"]}"
  status=0
  "${PY}" "${RENDER}" --root "${WORK}/packages-ok-${hook}" --out "${WORK}/packages-ok-${hook}-out" \
    >/dev/null 2>"${WORK}/packages-ok-${hook}-err" || status=$?
  if [ "${status}" -eq 0 ] && [ -f "${WORK}/packages-ok-${hook}-out/pr.yml" ]; then
    pass "packages for ${hook} renders"
  else
    fail "packages for ${hook} renders (status=${status})"
  fi
done

echo "# packages do not change the rendered workflows"
mk_packages same '{"lint":["libpq-dev"],"test":["libpq-dev","zlib1g-dev"],"e2e":["xvfb"]}'
"${PY}" "${RENDER}" --root "${FIXTURES}/single-module" --out "${WORK}/packages-base-out" >/dev/null 2>&1 || true
"${PY}" "${RENDER}" --root "${WORK}/packages-same" --out "${WORK}/packages-same-out" >/dev/null 2>&1 || true
if [ -f "${WORK}/packages-same-out/pr.yml" ] && diff -r "${WORK}/packages-base-out" "${WORK}/packages-same-out" >/dev/null; then
  pass "registry with packages renders the same workflows as without"
else
  fail "registry with packages renders the same workflows as without"
fi

echo
echo "passed=${PASSED} failed=${FAILED}"
[ "${FAILED}" -eq 0 ] || exit 1
