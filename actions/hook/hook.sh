#!/bin/sh
# Runs ci/<step>.sh, relative to the module side directory (code or infra).
# Every hook of the vocabulary is mandatory: a module with nothing to do keeps a
# script that says why and exits 0, so a missing script is an error, never a skip.
set -eu

STEP="${STEP:?STEP is not set}"

if [ ! -f "ci/${STEP}.sh" ]; then
  echo "::error::missing ci/${STEP}.sh in $(pwd) — every hook is mandatory; a step with nothing to do prints why and exits 0"
  exit 1
fi

CI_CACHE_DIR="$(pwd)/.ci-cache"
export CI_CACHE_DIR

echo "== ci/${STEP}.sh"
if [ -x "ci/${STEP}.sh" ]; then
  "./ci/${STEP}.sh"
else
  sh "ci/${STEP}.sh"
fi
