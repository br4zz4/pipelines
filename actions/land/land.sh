#!/bin/sh
# land.sh — one deployment per module, tagged in the payload so a promotion can
# find the last release that passed in an environment. `url` is optional: it
# normally comes from the glide hook.
set -eu

ENV_NAME="${ENVIRONMENT:?ENVIRONMENT is not set}"
MODULE="${MODULE:?MODULE is not set}"
TAG="${TAG_INPUT:?TAG_INPUT is not set}"
APP_URL="${APP_URL:-}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"

OVERRIDE="${DIR:+${DIR}/}ci/land.sh"
if [ -n "${DIR:-}" ] && [ -f "${OVERRIDE}" ]; then
  echo "== ${DIR}/ci/land.sh (project override)"
  exec sh "${OVERRIDE}" "${ENV_NAME}" "${MODULE}" "${TAG}"
fi

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
  -f state=success -f environment="${ENV_NAME}" -f environment_url="${APP_URL}" >/dev/null

echo "recorded: ${MODULE} ${TAG} in ${ENV_NAME} (deployment ${ID})"
[ -n "${APP_URL}" ] && echo "url: ${APP_URL}"
