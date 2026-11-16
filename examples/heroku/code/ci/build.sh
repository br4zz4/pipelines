#!/bin/sh
# build.sh — build the container and push it to the Heroku registry of the
# staging app. Production never builds: it promotes what staging runs.
#
# Environment: HEROKU_APP, HEROKU_API_KEY (from the ward scope of the module).
set -eu

HEROKU_APP="${HEROKU_APP:?HEROKU_APP is not set}"

heroku container:login
heroku container:push web --app "${HEROKU_APP}"
