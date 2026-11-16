#!/bin/sh
# gate.sh — sums up the jobs a workflow depends on. RESULTS is `toJSON(needs)`:
# success and skipped pass; failure and cancelled fail the gate.
set -eu

RESULTS="${RESULTS:-}"
[ -n "$RESULTS" ] || { echo "::error::RESULTS is not set" >&2; exit 1; }

SUMMARY="$(printf '%s' "${RESULTS}" | python3 -c 'import json, sys
needs = json.load(sys.stdin)
bad = 0
for job in sorted(needs):
    result = (needs[job] or {}).get("result", "unknown")
    print(f"{job}: {result}")
    if result in ("failure", "cancelled", "unknown"):
        bad += 1
sys.exit(1 if bad else 0)')" && STATUS=0 || STATUS=$?

[ -n "${SUMMARY}" ] && printf '%s\n' "${SUMMARY}"
if [ "${STATUS}" -ne 0 ]; then
  echo "::error::a job this gate depends on did not pass"
  exit 1
fi
