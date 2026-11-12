#!/bin/sh
# plan.sh — server-side diff of the rendered overlay. Runs in the module's deploy
# directory. `kubectl diff` exits 1 when it finds differences, which is a pass.
#
# Environment: OVERLAY (default overlays/<ENVIRONMENT>).
set -eu

OVERLAY="${OVERLAY:-overlays/${ENVIRONMENT:-staging}}"

set +e
kubectl diff -k "${OVERLAY}"
STATUS=$?
set -e

if [ "${STATUS}" -gt 1 ]; then
  echo "::error::kubectl diff failed with status ${STATUS}"
  exit "${STATUS}"
fi
