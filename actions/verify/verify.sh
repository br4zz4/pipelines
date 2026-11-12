#!/bin/sh
# verify.sh <tag> — tag format, tag in git, tag commit match.
set -eu

TAG="${TAG_INPUT:?TAG_INPUT is not set}"
SHA="${GITHUB_SHA:?GITHUB_SHA is not set}"

OVERRIDE="${MODULE_DIR:-.}/deploy/ci/verify.sh"
if [ -f "${OVERRIDE}" ] && [ "${MODULE_DIR:-.}" != "." ]; then
  echo "== deploy/ci/verify.sh (project override)"
  exec sh "${OVERRIDE}" "${TAG}"
fi

case "${TAG}" in
  v[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9].[0-9]*) ;;
  v[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]-[0-9a-f]*) ;;
  *) echo "::error::invalid release tag '${TAG}' (expected vYYYY.MM.DD.N)"; exit 1 ;;
esac

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
