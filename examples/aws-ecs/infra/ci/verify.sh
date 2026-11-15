#!/bin/sh
# verify.sh — hit the environment health endpoint until it answers or the
# retries run out. The url it publishes is what record and notify point at.
#
# Environment: URL, HEALTH (default /up), RETRIES (default 12), DELAY (default 10).
# Output: url=<URL> on $GITHUB_OUTPUT.
set -eu

URL="${URL:?URL is not set}"
HEALTH="${HEALTH:-/up}"
RETRIES="${RETRIES:-12}"
DELAY="${DELAY:-10}"

if curl -fsS --retry "${RETRIES}" --retry-delay "${DELAY}" --retry-connrefused --retry-all-errors \
  "${URL}${HEALTH}" >/dev/null; then
  echo "healthy: ${URL}${HEALTH}"
  echo "url=${URL}" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
  exit 0
fi

echo "::error::${URL}${HEALTH} did not answer after ${RETRIES} retries"
exit 1
