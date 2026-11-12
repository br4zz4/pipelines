#!/bin/sh
# notify.sh — summary always; webhook only when configured. A failure here never
# reverts a deploy.
set -eu

ENV_NAME="${ENVIRONMENT:?ENVIRONMENT is not set}"
MODULE="${MODULE:?MODULE is not set}"
TAG="${TAG_INPUT:?TAG_INPUT is not set}"
STATUS="${STATUS:-ok}"

MESSAGE="deploy ${MODULE} ${TAG} -> ${ENV_NAME}: ${STATUS}. ${RUN_URL}"
echo "${MESSAGE}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## deploy ${MODULE} ${TAG} -> ${ENV_NAME}"
    echo ""
    echo "${STATUS} — [run](${RUN_URL})"
    [ -n "${APP_URL:-}" ] && echo "" && echo "<${APP_URL}>"
  } >> "${GITHUB_STEP_SUMMARY}"
fi

if [ -n "${NOTIFY_WEBHOOK_URL:-}" ]; then
  PAYLOAD="$(python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}))' "${MESSAGE}")"
  curl -fsS -X POST -H 'Content-Type: application/json' --data "${PAYLOAD}" "${NOTIFY_WEBHOOK_URL}" >/dev/null
  echo "notification sent"
else
  echo "no webhook configured: result only in the run"
fi
