#!/bin/sh
# deploy.sh — promote the image and wait for the rollout. The infrastructure is
# apply.sh's job: deploy never applies manifests.
#
# Environment: NAMESPACE, DEPLOYMENT.
set -eu

NAMESPACE="${NAMESPACE:-default}"
DEPLOYMENT="${DEPLOYMENT:?DEPLOYMENT is not set}"

kubectl -n "${NAMESPACE}" deploy status "deployment/${DEPLOYMENT}" --timeout=300s
