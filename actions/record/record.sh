#!/bin/sh
# record.sh — one deployment per release, tagged in the payload so a promotion
# can find the last release that passed in an environment. STATE is `success`
# when the release is live and verified, `failure` otherwise.
set -eu

ENV_NAME="${ENVIRONMENT:?ENVIRONMENT is not set}"
MODULE="${MODULE:?MODULE is not set}"
TAG="${TAG_INPUT:?TAG_INPUT is not set}"
STATE="${STATE:-}"
APP_URL="${APP_URL:-}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"

case "${STATE}" in
  success | failure) ;;
  *)
    echo "::error::STATE must be success or failure, got '${STATE}'"
    exit 1
    ;;
esac

PRODUCTION=false
[ "${ENV_NAME}" = "production" ] && PRODUCTION=true

BODY="$(python3 -c 'import json,sys
env, module, tag, production = sys.argv[1:5]
print(json.dumps({"ref": tag, "environment": env, "auto_merge": False, "required_contexts": [],
                  "production_environment": production == "true", "transient_environment": False,
                  "description": f"{module} {tag}", "payload": {"module": module, "tag": tag}}))' \
  "${ENV_NAME}" "${MODULE}" "${TAG}" "${PRODUCTION}")"

ID="$(printf '%s' "${BODY}" | gh api -X POST "repos/${REPO}/deployments" --input - --jq '.id')"

gh api -X POST "repos/${REPO}/deployments/${ID}/statuses" \
  -f state="${STATE}" -f environment="${ENV_NAME}" -f environment_url="${APP_URL}" >/dev/null

echo "recorded ${STATE}: ${MODULE} ${TAG} in ${ENV_NAME} (deployment ${ID})"
[ -z "${APP_URL}" ] || echo "url: ${APP_URL}"
