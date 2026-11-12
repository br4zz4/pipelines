#!/bin/sh
# fly.sh — record the current revision, promote the image and wait for the
# rollout. The infrastructure is apply.sh's job: fly never applies manifests.
#
# Environment: NAMESPACE, DEPLOYMENT.
# Output: rollback=<revision> on $GITHUB_OUTPUT.
set -eu

NAMESPACE="${NAMESPACE:-default}"
DEPLOYMENT="${DEPLOYMENT:?DEPLOYMENT is not set}"

REVISION="$(kubectl -n "${NAMESPACE}" get "deployment/${DEPLOYMENT}" \
  -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}' 2>/dev/null || true)"
echo "rollback=${REVISION}" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
echo "rollback point: ${REVISION:-<none>}"

kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOYMENT}" --timeout=300s
