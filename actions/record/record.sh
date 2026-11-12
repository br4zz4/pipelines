#!/bin/sh
# record.sh <environment> — one deployment per module, tagged in the payload so a
# promotion can find the last release that passed in an environment.
set -eu

ENV_NAME="${ENVIRONMENT:?ENVIRONMENT is not set}"
MODULE="${MODULE:?MODULE is not set}"
TAG="${TAG_INPUT:?TAG_INPUT is not set}"
APP_URL="${APP_URL:-}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"

OVERRIDE="${MODULE_DIR:-.}/deploy/ci/record.sh"
if [ -f "${OVERRIDE}" ] && [ "${MODULE_DIR:-.}" != "." ]; then
  echo "== deploy/ci/record.sh (project override)"
  exec sh "${OVERRIDE}" "${ENV_NAME}" "${MODULE}" "${TAG}"
fi

PRODUCTION=false
[ "${ENV_NAME}" = "production" ] && PRODUCTION=true

BODY="$(python3 -c 'import json,sys
env, module, tag, production = sys.argv[1:5]
print(json.dumps({"ref": tag, "environment": env, "auto_merge": False, "required_contexts": [],
                  "production_environment": production == "true", "transient_environment": False,
                  "description": f"{module} {tag}", "payload": {"tag": tag, "module": module}}))' \
  "${ENV_NAME}" "${MODULE}" "${TAG}" "${PRODUCTION}")"

ID="$(printf '%s' "${BODY}" | gh api -X POST "repos/${REPO}/deployments" --input - --jq '.id')"

gh api -X POST "repos/${REPO}/deployments/${ID}/statuses" \
  -f state=success -f environment="${ENV_NAME}" -f environment_url="${APP_URL}" >/dev/null

echo "recorded: ${MODULE} ${TAG} in ${ENV_NAME} (deployment ${ID})"
