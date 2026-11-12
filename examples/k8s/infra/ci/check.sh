#!/bin/sh
# check.sh — render the kustomize overlay and validate the manifests. Runs in the
# module's deploy directory.
#
# Environment: OVERLAY (default overlays/<ENVIRONMENT>).
set -eu

OVERLAY="${OVERLAY:-overlays/${ENVIRONMENT:-staging}}"

kubectl kustomize "${OVERLAY}" | kubeconform -strict -summary -
