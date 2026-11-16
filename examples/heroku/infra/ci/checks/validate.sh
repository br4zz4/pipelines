#!/bin/sh
# validate.sh — app.json must be valid JSON. Runs in the module's infra
# directory, without credentials.
set -eu

python3 -m json.tool app.json >/dev/null
echo "app.json is valid"
