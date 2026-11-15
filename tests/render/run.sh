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

props() {
  python3 "${HERE}/props.py" "$@"
}

echo "# four modules: structure and properties"
if python3 "${RENDER}" --root "${FIXTURES}/four-modules" --out "${WORK}/four"; then
  pass "four-modules renders with exit 0"
else
  fail "four-modules renders with exit 0"
fi
if props "${WORK}/four" has_warranty core:postgres engine: events:postgres,redis gateway: ; then
  pass "four-modules satisfies every generated-workflow property"
else
  fail "four-modules satisfies every generated-workflow property"
fi

echo "# determinism"
python3 "${RENDER}" --root "${FIXTURES}/four-modules" --out "${WORK}/four2" || true
same=1
for f in pr.yml main.yml deploy.yml; do
  cmp -s "${WORK}/four/${f}" "${WORK}/four2/${f}" || same=0
done
if [ "${same}" -eq 1 ] && [ -f "${WORK}/four/pr.yml" ]; then
  pass "two runs produce identical bytes"
else
  fail "two runs produce identical bytes"
fi

echo "# restricted key only in deploy.yml"
if grep -q 'WARD_KEY_HAS_WARRANTY_RESTRICTED' "${WORK}/four/deploy.yml" 2>/dev/null \
  && ! grep -q '_RESTRICTED' "${WORK}/four/pr.yml" 2>/dev/null \
  && ! grep -q '_RESTRICTED' "${WORK}/four/main.yml" 2>/dev/null \
  && [ -f "${WORK}/four/pr.yml" ]; then
  pass "_RESTRICTED confined to deploy.yml"
else
  fail "_RESTRICTED confined to deploy.yml"
fi

echo "# single module with legacy ward vault form"
if python3 "${RENDER}" --root "${FIXTURES}/single-module" --out "${WORK}/single"; then
  pass "single-module renders with exit 0"
else
  fail "single-module renders with exit 0"
fi
if props "${WORK}/single" has_warranty solo: ; then
  pass "single-module satisfies every generated-workflow property"
else
  fail "single-module satisfies every generated-workflow property"
fi

echo "# default output directory"
cp -R "${FIXTURES}/four-modules" "${WORK}/proj"
if python3 "${RENDER}" --root "${WORK}/proj" \
  && [ -f "${WORK}/proj/.github/workflows/pr.yml" ] \
  && [ -f "${WORK}/proj/.github/workflows/main.yml" ] \
  && [ -f "${WORK}/proj/.github/workflows/deploy.yml" ] \
  && cmp -s "${WORK}/proj/.github/workflows/pr.yml" "${WORK}/four/pr.yml"; then
  pass "default --out is <root>/.github/workflows"
else
  fail "default --out is <root>/.github/workflows"
fi

echo "# restricted vault is optional"
if python3 "${RENDER}" --root "${FIXTURES}/no-restricted" --out "${WORK}/norestr"; then
  pass "no-restricted renders with exit 0"
else
  fail "no-restricted renders with exit 0"
fi
if [ -f "${WORK}/norestr/deploy.yml" ] \
  && ! grep -q '_RESTRICTED' "${WORK}/norestr/pr.yml" "${WORK}/norestr/main.yml" "${WORK}/norestr/deploy.yml" \
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
  cat "${1}"/pr.yml "${1}"/main.yml "${1}"/deploy.yml | grep -o 'br4zz4/pipelines/[A-Za-z0-9_./-]*@[A-Za-z0-9_.-]*' || true
}
python3 "${RENDER}" --root "${FIXTURES}/four-modules" --out "${WORK}/beta" --ref v1-beta || true
refs "${WORK}/beta" > "${WORK}/beta-refs"
refs "${WORK}/four" > "${WORK}/v1-refs"
if [ -s "${WORK}/beta-refs" ] && ! grep -v '@v1-beta$' "${WORK}/beta-refs" | grep -q . ; then
  pass "--ref v1-beta rewrites every br4zz4/pipelines reference"
else
  fail "--ref v1-beta rewrites every br4zz4/pipelines reference: $(sort -u "${WORK}/beta-refs" | tr '\n' ' ')"
fi
for part in actions/conform actions/detect actions/releases actions/gate actions/reuse actions/tag actions/step actions/stamp .github/workflows/code.yml .github/workflows/infra.yml .github/workflows/deploy.yml; do
  if grep -q "br4zz4/pipelines/${part}@v1-beta" "${WORK}/beta-refs"; then
    pass "--ref v1-beta reaches ${part}"
  else
    fail "--ref v1-beta reaches ${part}"
  fi
done
if [ -s "${WORK}/v1-refs" ] && ! grep -v '@v1$' "${WORK}/v1-refs" | grep -q . ; then
  pass "default ref is v1"
else
  fail "default ref is v1"
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
  python3 "${RENDER}" --root "${FIXTURES}/invalid/${case}" --out "${WORK}/inv-${case}" \
    >/dev/null 2>"${WORK}/err-${case}" || status=$?
  if [ "${status}" -eq 2 ] && [ -s "${WORK}/err-${case}" ]; then
    pass "invalid ${case} exits 2 with stderr"
  else
    fail "invalid ${case} exits 2 with stderr (status=${status})"
  fi
done

python3 "${RENDER}" --root "${FIXTURES}/invalid/ward-many-defaults" --out "${WORK}/many" >/dev/null 2>"${WORK}/err-many" || true
if grep -q 'has_warranty' "${WORK}/err-many" && grep -q 'other' "${WORK}/err-many"; then
  pass "many defaults without pair names them on stderr"
else
  fail "many defaults without pair names them on stderr"
fi

echo
echo "passed=${PASSED} failed=${FAILED}"
[ "${FAILED}" -eq 0 ] || exit 1
