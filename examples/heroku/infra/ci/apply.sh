#!/bin/sh
# apply.sh — make the app's config vars match the release. "Nothing to apply" is
# a valid result.
#
# Environment: HEROKU_APP, HEROKU_CONFIG (JSON object of config vars, optional), TAG.
set -eu

HEROKU_APP="${HEROKU_APP:?HEROKU_APP is not set}"
TAG="${TAG:?TAG is not set}"

if [ -z "${HEROKU_CONFIG:-}" ] || [ "${HEROKU_CONFIG}" = "{}" ]; then
  echo "nothing to apply"
  exit 0
fi

python3 - <<'PY'
import json
import os
import subprocess

config = json.loads(os.environ["HEROKU_CONFIG"])
arguments = [f"{key}={value}" for key, value in config.items()]
subprocess.run(["heroku", "config:set", "--app", os.environ["HEROKU_APP"], *arguments], check=True)
PY
