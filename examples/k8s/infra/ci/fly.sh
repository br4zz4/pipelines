#!/bin/sh
# fly.sh — record the current revision, apply the overlay and wait for the
# rollout.
#
# Environment: NAMESPACE, DEPLOYMENT, OVERLAY.
# Output: rollback=<revision> on $GITHUB_OUTPUT.
set -eu

NAMESPACE="${NAMESPACE:-default}"
DEPLOYMENT="${DEPLOYMENT:?DEPLOYMENT is not set}"
OVERLAY="${OVERLAY:-overlays/${ENVIRONMENT:-staging}}"

REVISION="$(kubectl -n "${NAMESPACE}" get "deployment/${DEPLOYMENT}" \
  -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}' 2>/dev/null || true)"
echo "rollback=${REVISION}" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
echo "rollback point: ${REVISION:-<none>}"

kubectl apply -k "${OVERLAY}"
kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOYMENT}" --timeout=300s
