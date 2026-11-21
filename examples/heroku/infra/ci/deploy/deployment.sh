#!/bin/sh
# deploy.sh — release the new one. Staging
# releases the container pushed by build; production promotes what staging runs.
#
# Environment: HEROKU_APP, TAG, SOURCE_APP (set only in production).
set -eu

HEROKU_APP="${HEROKU_APP:?HEROKU_APP is not set}"
TAG="${TAG:?TAG is not set}"

if [ -n "${SOURCE_APP:-}" ]; then
  heroku pipelines:promote --app "${SOURCE_APP}" --to "${HEROKU_APP}"
else
  heroku container:release web --app "${HEROKU_APP}"
fi

heroku config:set --app "${HEROKU_APP}" "RELEASE_TAG=${TAG}" >/dev/null
