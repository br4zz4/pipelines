#!/bin/sh
# Runs <dir>/ci/<step>.sh (relative to the module facet directory). A project
# that has no such script simply has no such step.
set -eu

STEP="${STEP:?STEP is not set}"

run_script() {
  if [ -x "$1" ]; then "$1"; else sh "$1"; fi
}

if [ -f "ci/${STEP}.sh" ]; then
  echo "== ci/${STEP}.sh"
  run_script "ci/${STEP}.sh"
else
  echo "::notice::no ci/${STEP}.sh in $(pwd) — step '${STEP}' skipped"
fi
