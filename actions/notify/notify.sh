#!/bin/sh
# notify.sh — summary always; webhook only when configured. A failure here never
# reverts a deploy. STATUS is `ok`, `failed` or `rolled back`.
set -eu

ENV_NAME="${ENVIRONMENT:?ENVIRONMENT is not set}"
MODULE="${MODULE:?MODULE is not set}"
TAG="${TAG_INPUT:?TAG_INPUT is not set}"
STATUS="${STATUS:-}"
DETAIL="${DETAIL:-}"

case "${STATUS}" in
  "ok") MARK="✅" ;;
  "failed") MARK="❌" ;;
  "rolled back") MARK="↩️" ;;
  *)
    echo "::error::STATUS must be ok, failed or rolled back, got '${STATUS}'"
    exit 1
    ;;
esac

MESSAGE="${MARK} deploy ${MODULE} ${TAG} -> ${ENV_NAME}: ${STATUS}${DETAIL:+ (${DETAIL})}. ${RUN_URL:-}"
echo "${MESSAGE}"
case "${STATUS}" in
  "failed") echo "::error title=deploy ${MODULE} ${ENV_NAME}::${MESSAGE}" ;;
  *) echo "::notice title=deploy ${MODULE} ${ENV_NAME}::${MESSAGE}" ;;
esac

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## ${MARK} deploy ${MODULE} ${TAG} -> ${ENV_NAME}"
    echo ""
    echo "${STATUS}${DETAIL:+ (${DETAIL})} — [run](${RUN_URL:-})"
    if [ -n "${APP_URL:-}" ]; then
      echo ""
      echo "<${APP_URL}>"
    fi
  } >> "${GITHUB_STEP_SUMMARY}"
fi

if [ -n "${NOTIFY_WEBHOOK_URL:-}" ]; then
  PAYLOAD="$(python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}, ensure_ascii=False))' "${MESSAGE}")"
  if curl -fsS -X POST -H 'Content-Type: application/json' --data "${PAYLOAD}" "${NOTIFY_WEBHOOK_URL}" >/dev/null; then
    echo "notification sent"
  else
    echo "::warning::webhook notification failed; the deploy outcome is unchanged"
  fi
else
  echo "no webhook configured: result only in the run"
fi
