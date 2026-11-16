#!/bin/sh
# Runs ci/<context>/<step>.sh, relative to the module side directory.
# Context is derived from the step name: checks for quality steps, deploy for
# deployment steps. Every hook is mandatory — a step with nothing to do keeps a
# script that says why and exits 0.
set -eu

STEP="${STEP:?STEP is not set}"

case "$STEP" in
  lint|audit|test|build|validate|plan) CONTEXT=checks ;;
  apply|rollout|verify|rollback)        CONTEXT=deploy ;;
  *) echo "::error::unknown step '$STEP' — not in any hook vocabulary"; exit 1 ;;
esac

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
