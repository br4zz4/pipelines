#!/bin/sh
# Runs ci/<context>/<step>.sh, relative to the module side directory.
# Every hook of the vocabulary is mandatory: a module with nothing to do keeps a
# script that says why and exits 0, so a missing script is an error, never a skip.
set -eu

CONTEXT="${CONTEXT:?CONTEXT is not set}"
STEP="${STEP:?STEP is not set}"

if [ ! -f "ci/${CONTEXT}/${STEP}.sh" ]; then
  echo "::error::missing ci/${CONTEXT}/${STEP}.sh in $(pwd) — every hook is mandatory; a step with nothing to do prints why and exits 0"
  exit 1
fi

CI_CACHE_DIR="$(pwd)/.ci-cache"
export CI_CACHE_DIR

echo "== ci/${CONTEXT}/${STEP}.sh"
if [ -x "ci/${CONTEXT}/${STEP}.sh" ]; then
  "./ci/${CONTEXT}/${STEP}.sh"
else
  sh "ci/${CONTEXT}/${STEP}.sh"
fi
