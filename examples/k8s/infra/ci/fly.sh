#!/bin/sh
# fly.sh — record the current revision, apply the overlay (with the optional
# pre-apply/post-apply hooks) and wait for the rollout.
#
# Environment: NAMESPACE, DEPLOYMENT, OVERLAY.
# Output: rollback=<revision> on $GITHUB_OUTPUT.
set -eu

NAMESPACE="${NAMESPACE:-default}"
DEPLOYMENT="${DEPLOYMENT:?DEPLOYMENT is not set}"
OVERLAY="${OVERLAY:-overlays/${ENVIRONMENT:-staging}}"

# Optional hooks, relative to the infra directory: ci/pre-apply.sh and
# ci/post-apply.sh. A module with nothing to do around the apply omits them.
run_hook() {
  if [ -f "ci/$1.sh" ]; then
    echo "== ci/$1.sh"
    sh "ci/$1.sh"
  else
    echo "no ci/$1.sh: skipping"
  fi
}

REVISION="$(kubectl -n "${NAMESPACE}" get "deployment/${DEPLOYMENT}" \
  -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}' 2>/dev/null || true)"
echo "rollback=${REVISION}" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
echo "rollback point: ${REVISION:-<none>}"

run_hook pre-apply
kubectl apply -k "${OVERLAY}"
run_hook post-apply

kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOYMENT}" --timeout=300s
