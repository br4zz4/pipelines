#!/bin/sh
# expose.sh — expose ci-hook to the agent: a copy of the base hooks taken before it starts, and the command on PATH.
set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
MODULE="${MODULE:?MODULE is not set}"
CODE_DIR="${CODE_DIR:?CODE_DIR is not set}"
WORK="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
BASE_HOOKS="${WORK}/base-hooks"
BIN_DIR="${HOME:?HOME is not set}/.fix/bin"

rm -rf "${BASE_HOOKS}" "${BIN_DIR}"
mkdir -p "${BASE_HOOKS}" "${BIN_DIR}"
for dir in run lib ci; do
  [ ! -d "${CODE_DIR}/${dir}" ] || cp -R "${CODE_DIR}/${dir}" "${BASE_HOOKS}/${dir}"
done
cp "${HERE}/../agent/ci-hook.sh" "${BIN_DIR}/ci-hook"
chmod +x "${BIN_DIR}/ci-hook"

{
  echo "AUTOFIX_ROOT=$(pwd)"
  echo "AUTOFIX_CODE_DIR=${CODE_DIR}"
  echo "AUTOFIX_MODULE=${MODULE}"
  echo "AUTOFIX_BASE_HOOKS=${BASE_HOOKS}"
} >> "${GITHUB_ENV:?GITHUB_ENV is not set}"
echo "${BIN_DIR}" >> "${GITHUB_PATH:?GITHUB_PATH is not set}"
