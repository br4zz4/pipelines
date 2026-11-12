#!/bin/sh
# glide.sh — hit the environment health endpoint until it answers or the
# attempts run out. The url it publishes is what land and notify point at.
#
# Environment: URL, HEALTH (default /up), RETRIES (default 12), DELAY (default 10).
# Output: url=<URL> on $GITHUB_OUTPUT.
set -eu

URL="${URL:?URL is not set}"
HEALTH="${HEALTH:-/up}"
RETRIES="${RETRIES:-12}"
DELAY="${DELAY:-10}"

ATTEMPT=1
while [ "${ATTEMPT}" -le "${RETRIES}" ]; do
  if curl -fsS "${URL}${HEALTH}" >/dev/null; then
    echo "healthy: ${URL}${HEALTH}"
    echo "url=${URL}" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
    exit 0
  fi
  echo "attempt ${ATTEMPT}/${RETRIES}: ${URL}${HEALTH} not ready"
  ATTEMPT=$(( ATTEMPT + 1 ))
  sleep "${DELAY}"
done

echo "::error::${URL}${HEALTH} did not answer after ${RETRIES} attempts"
exit 1
