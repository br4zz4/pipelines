#!/bin/sh
# rollback.sh — put the service back on the task definition deploy.sh recorded.
# Fails when there is none: a failed first deploy has nothing to return to, and
# that is never a silent success.
#
# Environment: CLUSTER, SERVICE, ROLLBACK_POINT.
set -eu

CLUSTER="${CLUSTER:?CLUSTER is not set}"
SERVICE="${SERVICE:?SERVICE is not set}"

if [ -z "${ROLLBACK_POINT:-}" ]; then
  echo "::error::no rollback point: there is no previous task definition to return to"
  exit 1
fi

aws ecs update-service --cluster "${CLUSTER}" --service "${SERVICE}" --task-definition "${ROLLBACK_POINT}" >/dev/null
aws ecs wait services-stable --cluster "${CLUSTER}" --services "${SERVICE}"
