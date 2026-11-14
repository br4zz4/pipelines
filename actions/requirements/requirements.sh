#!/bin/sh
# requirements.sh — a release tag is `<module>.YYYY-MM-DD.NNN` and exists in git.
# With STRICT=true (the default) it must also point at the commit of this run:
# the deploy was opened by that tag. A resolved release relaxes only the commit
# pin, never the format or the existence.
set -eu

TAG="${TAG_INPUT:?TAG_INPUT is not set}"
SHA="${GITHUB_SHA:?GITHUB_SHA is not set}"
STRICT="${STRICT:-true}"

MODULE_TAG='^[A-Za-z_][A-Za-z0-9_-]*\.[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]{3,}$'

if printf '%s' "${TAG}" | grep -Eq "${MODULE_TAG}"; then
  echo "module release: ${TAG}"
else
  echo "::error::invalid release tag '${TAG}' (expected <module>.YYYY-MM-DD.NNN)"
  exit 1
fi

git fetch --tags --force origin >/dev/null

if ! git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  echo "::error::tag '${TAG}' is not in git — run the release pipeline first"
  exit 1
fi

TAG_COMMIT="$(git rev-parse "refs/tags/${TAG}^{commit}")"

if [ "${STRICT}" = "true" ] && [ "${SHA}" != "${TAG_COMMIT}" ]; then
  echo "::error::this run is on ${SHA} but tag ${TAG} points at ${TAG_COMMIT}."
  echo "::error::dispatch the deploy from the tag ref."
  exit 1
fi

echo "verified: tag '${TAG}' -> ${TAG_COMMIT} (strict=${STRICT})"
