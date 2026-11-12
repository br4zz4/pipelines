#!/bin/sh
# requirements.sh — a release tag is `<module>.YYYY.MM.DD.N` (legacy `v...`
# accepted), exists in git and points at the commit of this run.
set -eu

TAG="${TAG_INPUT:?TAG_INPUT is not set}"
SHA="${GITHUB_SHA:?GITHUB_SHA is not set}"

MODULE_TAG='^[A-Za-z_][A-Za-z0-9_-]*\.[0-9][0-9][0-9][0-9]\.[0-9][0-9]\.[0-9][0-9]\.[0-9][0-9]*$'
LEGACY_TAG='^v[0-9][0-9][0-9][0-9]\.[0-9][0-9]\.[0-9][0-9][-.][0-9A-Za-z][0-9A-Za-z]*$'

if printf '%s' "${TAG}" | grep -Eq "${MODULE_TAG}"; then
  echo "module release: ${TAG}"
elif printf '%s' "${TAG}" | grep -Eq "${LEGACY_TAG}"; then
  echo "legacy release: ${TAG}"
else
  echo "::error::invalid release tag '${TAG}' (expected <module>.YYYY.MM.DD.N)"
  exit 1
fi

git fetch --tags --force origin >/dev/null

if ! git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  echo "::error::tag '${TAG}' is not in git — run the release pipeline first"
  exit 1
fi

TAG_COMMIT="$(git rev-parse "refs/tags/${TAG}^{commit}")"
if [ "${SHA}" != "${TAG_COMMIT}" ]; then
  echo "::error::this run is on ${SHA} but tag ${TAG} points at ${TAG_COMMIT}."
  echo "::error::dispatch the deploy from the tag ref."
  exit 1
fi

echo "verified: tag '${TAG}' -> ${TAG_COMMIT}"
