#!/bin/sh
# ci-hook — run the lint or test hook from the copy of the base taken before the agent started, without the agent's credentials.
set -u

STEP="${1:-}"
[ "$#" -eq 0 ] || shift

case "${STEP}" in
  lint | test) ;;
  *)
    echo "ci-hook: step must be lint or test, got '${STEP}'" >&2
    exit 2
    ;;
esac

BASE="${AUTOFIX_BASE_HOOKS:?AUTOFIX_BASE_HOOKS is not set}"
ROOT="${AUTOFIX_ROOT:?AUTOFIX_ROOT is not set}"
CODE_DIR="${AUTOFIX_CODE_DIR:?AUTOFIX_CODE_DIR is not set}"
MODULE="${AUTOFIX_MODULE:?AUTOFIX_MODULE is not set}"

if [ -f "${BASE}/run/${STEP}" ]; then
  SCRIPT="${BASE}/run/${STEP}"
elif [ -f "${BASE}/ci/checks/${STEP}.sh" ]; then
  SCRIPT="${BASE}/ci/checks/${STEP}.sh"
else
  echo "ci-hook: no ${STEP} hook in the base copy" >&2
  exit 66
fi

cd "${ROOT}/${CODE_DIR}" || exit 66
CACHE="$(pwd)/.ci-cache"

if [ -x "${SCRIPT}" ]; then
  exec env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY \
    MODULE="${MODULE}" ENVIRONMENT=test BASE_SHA= CI_CACHE_DIR="${CACHE}" "${SCRIPT}" "$@"
fi
exec env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY \
  MODULE="${MODULE}" ENVIRONMENT=test BASE_SHA= CI_CACHE_DIR="${CACHE}" sh "${SCRIPT}" "$@"
