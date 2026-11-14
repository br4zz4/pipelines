#!/bin/sh
# tag.sh — <prefix>.YYYY-MM-DD.NNN for today, N read as a number and written
# zero-padded to three digits. Needs the existing tags (fetch-depth: 0); the
# remote is checked so a re-run cannot collide.
set -eu

PREFIX="${PREFIX:?PREFIX is not set}"
ZONE="${ZONE:-America/Sao_Paulo}"
DAY="$(TZ="${ZONE}" date +%Y-%m-%d)"
BASE="${PREFIX}.${DAY}"

# Leading zeros are stripped before the arithmetic: a shell reads `009` as an
# invalid octal, and the sequence is zero-padded on output only.
LAST="$(git tag -l "${BASE}.*" \
  | sed "s/^${PREFIX}\.${DAY}\.//" \
  | grep -E '^[0-9]+$' \
  | sed 's/^0*//' \
  | sort -n \
  | tail -n 1 || true)"

N=$(( ${LAST:-0} + 1 ))
TAG="${BASE}.$(printf '%03d' "${N}")"

while git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1; do
  N=$(( N + 1 ))
  TAG="${BASE}.$(printf '%03d' "${N}")"
done

echo "${TAG}"
echo "tag=${TAG}" >> "${GITHUB_OUTPUT}"
