#!/bin/sh
# rollback.sh — a failed deploy asks for a deploy of the last release recorded
# green in the environment. The dispatch runs the workflow of the failed release's
# ref, and `rollback_to` makes the deploy raise the earlier release instead.
#
#   none        no earlier release, or it is the failed one: nothing to go back to
#   skipped     a newer release of the module waits for its deploy; it is the fix forward
#   dispatched  `deploy.yml` was dispatched on TAG with rollback_to=PREVIOUS
#
# Environment: ENVIRONMENT, MODULE, TAG, PREVIOUS, GH_TOKEN, GH_REPO, GITHUB_OUTPUT.
set -eu

ENV_NAME="${ENVIRONMENT:?ENVIRONMENT is not set}"
MODULE="${MODULE:?MODULE is not set}"
TAG="${TAG_INPUT:?TAG_INPUT is not set}"
PREVIOUS="${PREVIOUS:-}"
OUT="${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"

finish() {
  echo "status=$1" >> "${OUT}"
  echo "target=$2" >> "${OUT}"
  echo "detail=$3" >> "${OUT}"
  echo "$3"
}

if [ -z "${PREVIOUS}" ] || [ "${PREVIOUS}" = "${TAG}" ]; then
  finish none "" "no earlier release to roll back to"
  exit 0
fi

RUNS="$(gh run list --workflow deploy.yml --limit 100 --json status,displayTitle,databaseId)"
QUEUED="$(printf '%s' "${RUNS}" | PREFIX="${ENV_NAME} · ${MODULE}." python3 -c 'import json, os, sys
prefix = os.environ["PREFIX"]
waiting = ("queued", "pending", "waiting", "requested")
for run in json.load(sys.stdin):
    title = run.get("displayTitle") or ""
    if run.get("status") in waiting and title.startswith(prefix):
        print(title.split(" · ", 1)[1].split()[0])
        break')"

if [ -n "${QUEUED}" ]; then
  finish skipped "" "rollback skipped: ${QUEUED} is queued"
  exit 0
fi

gh workflow run deploy.yml --ref "${TAG}" -f environment="${ENV_NAME}" -f rollback_to="${PREVIOUS}"
finish dispatched "${PREVIOUS}" "rolling back to ${PREVIOUS}"
