#!/bin/sh
# apply.sh — make the environment's infrastructure match the release. Runs in
# the module's infra directory, after the release tag is validated and before
# the image rolls. "Nothing to apply" is a valid result.
#
# Optional hooks, relative to the infra directory: ci/pre-apply.sh and
# ci/post-apply.sh. A module with nothing to do around the apply omits them.
#
# Environment: ENVIRONMENT, OVERLAY.
set -eu

OVERLAY="${OVERLAY:-overlays/${ENVIRONMENT:-staging}}"

run_hook() {
  if [ -f "ci/$1.sh" ]; then
    echo "== ci/$1.sh"
    sh "ci/$1.sh"
  else
    echo "no ci/$1.sh: skipping"
  fi
}

echo "== apply ${OVERLAY}"
run_hook pre-apply
kubectl apply -k "${OVERLAY}"
run_hook post-apply
