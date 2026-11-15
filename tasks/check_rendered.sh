#!/bin/sh
# check_rendered.sh — render every fixture project and validate the output
# against the reusable workflows (inputs and secrets) and the standard rules.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

for fixture in "${ROOT}"/tests/render/fixtures/four-modules "${ROOT}"/tests/render/fixtures/single-module; do
  out="${WORK}/$(basename "${fixture}")"
  mkdir -p "${out}/.github"
  python3 "${ROOT}/actions/conform/render.py" --root "${fixture}" --out "${out}/.github/workflows"
  python3 "${ROOT}/tasks/check.py" --consumers "${out}"
  python3 "${ROOT}/tasks/check.py" --standard "${out}/.github/workflows"
done
