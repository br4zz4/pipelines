#!/bin/sh
# rollback.sh — a failed deploy asks for a deploy of the last release recorded
# green in the environment. The dispatch runs the workflow of the failed release's
# ref, and `rollback_to` makes the deploy raise the earlier release instead.
#
#   none        no earlier release, or it is the failed one: nothing to go back to
#   skipped     another release of the module is queued or running for the environment;
#               it is the fix forward, and the dispatch would cancel it in the deploy group
#   dispatched  `deploy.yml` was dispatched on TAG with rollback_to=PREVIOUS
#
# Environment: ENVIRONMENT, MODULE, TAG_INPUT, PREVIOUS, RUN_ID, GH_TOKEN, GH_REPO, GITHUB_OUTPUT.
set -eu

ENV_NAME="${ENVIRONMENT:?ENVIRONMENT is not set}"
MODULE="${MODULE:?MODULE is not set}"
TAG="${TAG_INPUT:?TAG_INPUT is not set}"
PREVIOUS="${PREVIOUS:-}"
RUN_ID="${RUN_ID:-}"
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
BUSY="$(printf '%s' "${RUNS}" | PREFIX="${ENV_NAME} · ${MODULE}." SELF_TAG="${TAG}" SELF_RUN="${RUN_ID}" python3 -c 'import json, os, sys
prefix, own_tag, own_run = os.environ["PREFIX"], os.environ["SELF_TAG"], os.environ["SELF_RUN"]
rollback_prefix = prefix.replace(" · ", " · rollback · ", 1)
active = ("queued", "pending", "waiting", "requested", "in_progress")
for run in json.load(sys.stdin):
    title = run.get("displayTitle") or ""
    rolling = title.startswith(rollback_prefix)
    if run.get("status") not in active or not (title.startswith(prefix) or rolling):
        continue
    if own_run and str(run.get("databaseId")) == own_run:
        continue
    name = title.split(" · ")[2 if rolling else 1].split()[0]
    if name != own_tag:
        print(name)
        break')"

if [ -n "${BUSY}" ]; then
  finish skipped "" "rollback skipped: ${BUSY} is queued"
  exit 0
fi

gh workflow run deploy.yml --ref "${TAG}" -f environment="${ENV_NAME}" -f rollback_to="${PREVIOUS}"
finish dispatched "${PREVIOUS}" "rolling back to ${PREVIOUS}"
