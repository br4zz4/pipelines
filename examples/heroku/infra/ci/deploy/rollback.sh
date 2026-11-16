#!/bin/sh
# rollback.sh — go back to the release deploy.sh recorded. Fails when there is
# none: a failed first deploy has nothing to return to, and that is never a
# silent success.
#
# Environment: HEROKU_APP, ROLLBACK_POINT.
set -eu

HEROKU_APP="${HEROKU_APP:?HEROKU_APP is not set}"

if [ -z "${ROLLBACK_POINT:-}" ]; then
  echo "::error::no rollback point: there is no previous release to return to"
  exit 1
fi

heroku releases:rollback "v${ROLLBACK_POINT}" --app "${HEROKU_APP}"
