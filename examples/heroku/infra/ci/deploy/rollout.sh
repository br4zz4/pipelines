#!/bin/sh
# deploy.sh — record the current release, then release the new one. Staging
# releases the container pushed by build; production promotes what staging runs.
#
# Environment: HEROKU_APP, TAG, SOURCE_APP (set only in production).
# Output: rollback=<release number> on $GITHUB_OUTPUT.
set -eu

HEROKU_APP="${HEROKU_APP:?HEROKU_APP is not set}"
TAG="${TAG:?TAG is not set}"

CURRENT="$(heroku releases --app "${HEROKU_APP}" --num 1 --json \
  | python3 -c 'import json,sys; releases = json.load(sys.stdin); print(releases[0]["version"] if releases else "")')"
echo "rollback=${CURRENT}" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
echo "rollback point: ${CURRENT:-<none>}"

if [ -n "${SOURCE_APP:-}" ]; then
  heroku pipelines:promote --app "${SOURCE_APP}" --to "${HEROKU_APP}"
else
  heroku container:release web --app "${HEROKU_APP}"
fi

heroku config:set --app "${HEROKU_APP}" "RELEASE_TAG=${TAG}" >/dev/null
