#!/bin/sh
# For lint|audit|test|regression|e2e runs run/<step> when present, else ci/checks/<step>.sh.
# Otherwise runs ci/<context>/<step>.sh, relative to the module side directory.
# Context is derived from the step name: checks for quality steps, deploy for
# deployment steps. Every hook is mandatory — a step with nothing to do keeps a
# script that says why and exits 0 — except migrate and rollout, which are optional
# and skipped when the script is missing.
set -eu

STEP="${STEP:?STEP is not set}"
OPTIONAL=""

case "$STEP" in
  lint|audit|test|regression|e2e|build|validate|plan) CONTEXT=checks ;;
  apply|deployment|verify)                 CONTEXT=deploy ;;
  migrate|rollout)                      CONTEXT=deploy; OPTIONAL=1 ;;
  *) echo "::error::unknown step '$STEP' — not in any hook vocabulary"; exit 1 ;;
esac

if [ "$STEP" = "test" ] && [ "${DIFF_ONLY:-false}" = "true" ]; then
  if [ ! -f "run/test.diff" ]; then
    echo "::error::missing run/test.diff in $(pwd) — diff_only is true, so the test step needs run/test.diff (set diff_only: false to run run/test)"
    exit 1
  fi
  echo "== run/test.diff"
  if [ -x "run/test.diff" ]; then
    CI_CACHE_DIR="$(pwd)/.ci-cache" ./run/test.diff
  else
    CI_CACHE_DIR="$(pwd)/.ci-cache" sh run/test.diff
  fi
  exit 0
fi

RUN_SCRIPT=""
case "$STEP" in
  lint|audit|test|regression|e2e) [ -f "run/${STEP}" ] && RUN_SCRIPT="run/${STEP}" ;;
esac

if [ -z "$RUN_SCRIPT" ] && [ ! -f "ci/${CONTEXT}/${STEP}.sh" ]; then
  if [ -n "$OPTIONAL" ]; then
    echo "no ci/${CONTEXT}/${STEP}.sh in $(pwd): skipping (optional hook)"
    exit 0
  fi
  case "$STEP" in
    lint|audit|test|regression|e2e) echo "::error::missing run/${STEP} or ci/checks/${STEP}.sh in $(pwd) — every hook is mandatory; a step with nothing to do prints why and exits 0" ;;
    *) echo "::error::missing ci/${CONTEXT}/${STEP}.sh in $(pwd) — every hook is mandatory; a step with nothing to do prints why and exits 0" ;;
  esac
  exit 1
fi

CI_CACHE_DIR="$(pwd)/.ci-cache"
export CI_CACHE_DIR

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
OUTPUT_LOG="tmp/artifacts/output.log"

launch() {
  if [ -x "$1" ]; then
    "./$1"
  else
    sh "$1"
  fi
}

run_hook() {
  case "$STEP" in
    regression|e2e)
      scratch="$(mktemp -d)"
      mkdir -p tmp/artifacts
      { if launch "$1"; then rc=0; else rc=$?; fi; echo "$rc" > "${scratch}/rc"; } 2>&1 | tee "${scratch}/raw"
      code="$(cat "${scratch}/rc" 2>/dev/null || echo 1)"
      python3 "${HERE}/redact.py" "${scratch}/raw" "${OUTPUT_LOG}" || echo "::warning::could not record ${OUTPUT_LOG}"
      rm -rf "${scratch}"
      return "$code"
      ;;
    *) launch "$1" ;;
  esac
}

if [ -n "$RUN_SCRIPT" ]; then
  echo "== ${RUN_SCRIPT}"
  run_hook "$RUN_SCRIPT"
  exit 0
fi

echo "== ci/${CONTEXT}/${STEP}.sh"
run_hook "ci/${CONTEXT}/${STEP}.sh"
