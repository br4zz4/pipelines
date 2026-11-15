#!/bin/sh
# deploy.sh — register a task definition with the release image and roll the
# service to it. The infrastructure is apply.sh's job: deploy never applies it.
#
# Environment: CLUSTER, SERVICE, CONTAINER (default app), IMAGE, TAG.
# Output: rollback=<task definition arn> on $GITHUB_OUTPUT.
set -eu

CLUSTER="${CLUSTER:?CLUSTER is not set}"
SERVICE="${SERVICE:?SERVICE is not set}"
CONTAINER="${CONTAINER:-app}"
IMAGE="${IMAGE:?IMAGE is not set}"
TAG="${TAG:?TAG is not set}"

CURRENT="$(aws ecs describe-services --cluster "${CLUSTER}" --services "${SERVICE}" \
  --query 'services[0].taskDefinition' --output text)"
[ "${CURRENT}" != "None" ] || CURRENT=""
echo "rollback=${CURRENT}" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
echo "rollback point: ${CURRENT:-<none>}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

aws ecs describe-task-definition --task-definition "${CURRENT:?no task definition to derive the release from}" \
  --query taskDefinition --output json > "${WORK}/current.json"

python3 - "${WORK}/current.json" "${WORK}/next.json" "${CONTAINER}" "${IMAGE}:${TAG}" <<'PY'
import json
import sys

source, target, container, image = sys.argv[1:5]
definition = json.load(open(source))
for key in ("taskDefinitionArn", "revision", "status", "requiresAttributes",
            "compatibilities", "registeredAt", "registeredBy"):
    definition.pop(key, None)
for entry in definition["containerDefinitions"]:
    if entry["name"] == container:
        entry["image"] = image
json.dump(definition, open(target, "w"))
PY

NEXT="$(aws ecs register-task-definition --cli-input-json "file://${WORK}/next.json" \
  --query taskDefinition.taskDefinitionArn --output text)"

aws ecs update-service --cluster "${CLUSTER}" --service "${SERVICE}" --task-definition "${NEXT}" >/dev/null
aws ecs wait services-stable --cluster "${CLUSTER}" --services "${SERVICE}"
echo "deployed ${NEXT}"
