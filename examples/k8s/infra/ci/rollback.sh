#!/bin/sh
# rollback.sh — undo the last rollout of the deployment. Fails when there is no
# rollback point.
#
# Environment: NAMESPACE, DEPLOYMENT, ROLLBACK_POINT.
set -eu

NAMESPACE="${NAMESPACE:-default}"
DEPLOYMENT="${DEPLOYMENT:?DEPLOYMENT is not set}"
ROLLBACK_POINT="${ROLLBACK_POINT:?no rollback point: nothing to return to}"

kubectl -n "${NAMESPACE}" rollout undo "deployment/${DEPLOYMENT}" --to-revision="${ROLLBACK_POINT}"
kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOYMENT}" --timeout=300s
