#!/bin/sh
# prepare.sh — server-side diff of the rendered overlay. Runs in the module's
# infra directory, on pull requests and on main, as a gate: the tag only exists
# when this passes. `kubectl diff` exits 1 when it finds differences, which is a
# pass; "nothing to apply" is a pass too. The rollout never diffs.
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
