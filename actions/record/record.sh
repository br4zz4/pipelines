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
RELEASE_URL="${RELEASE_URL:-}"

case "${ENV_NAME}" in
  staging | production | promoted) ;;
  *)
    echo "::error::ENVIRONMENT must be staging, production or promoted, got '${ENV_NAME}'"
    exit 1
    ;;
esac

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
env, module, tag, production, release_url = sys.argv[1:6]
payload = {"module": module, "tag": tag}
if release_url:
    payload["release_url"] = release_url
print(json.dumps({"ref": tag, "environment": env, "auto_merge": False, "required_contexts": [],
                  "production_environment": production == "true", "transient_environment": False,
                  "description": f"{module} {tag}", "payload": payload}))' \
  "${ENV_NAME}" "${MODULE}" "${TAG}" "${PRODUCTION}" "${RELEASE_URL}")"

ID="$(printf '%s' "${BODY}" | gh api -X POST "repos/${REPO}/deployments" --input - --jq '.id')"

gh api -X POST "repos/${REPO}/deployments/${ID}/statuses" \
  -f state="${STATE}" -f environment="${ENV_NAME}" -f environment_url="${APP_URL}" >/dev/null

echo "recorded ${STATE}: ${MODULE} ${TAG} in ${ENV_NAME} (deployment ${ID})"
[ -z "${APP_URL}" ] || echo "url: ${APP_URL}"
