#!/bin/sh
# verify.sh <tag> <image> — tag format, tag in git, commit match, image in registry.
set -eu

TAG="${TAG_INPUT:?TAG_INPUT is not set}"
IMAGE="${IMAGE:?IMAGE is not set}"
REGION="${GCP_REGION:-us-west1}"
REGISTRY_HOST="${REGION}-docker.pkg.dev"

OVERRIDE="${MODULE_DIR:-.}/deploy/ci/verify.sh"
if [ -f "${OVERRIDE}" ] && [ "${MODULE_DIR:-.}" != "." ]; then
  echo "== deploy/ci/verify.sh (project override)"
  exec sh "${OVERRIDE}" "${TAG}" "${IMAGE}"
fi

case "${TAG}" in
  v[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9].[0-9]*) ;;
  v[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]-[0-9a-f]*) ;;
  *) echo "::error::invalid release tag '${TAG}' (expected vYYYY.MM.DD.N)"; exit 1 ;;
esac

git fetch --tags --force origin >/dev/null

if ! git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  echo "::error::tag '${TAG}' is not in git — run the main pipeline first"
  exit 1
fi

TAG_COMMIT="$(git rev-parse "refs/tags/${TAG}^{commit}")"
if [ -n "${GITHUB_SHA:-}" ] && [ "${GITHUB_SHA}" != "${TAG_COMMIT}" ]; then
  echo "::error::this run is on ${GITHUB_SHA} but tag ${TAG} points at ${TAG_COMMIT}."
  echo "::error::dispatch the deploy from the tag ref."
  exit 1
fi

gcloud auth print-access-token | docker login -u oauth2accesstoken --password-stdin "https://${REGISTRY_HOST}" >/dev/null

if ! docker manifest inspect "${IMAGE}:${TAG}" >/dev/null 2>&1; then
  echo "::error::image '${IMAGE}:${TAG}' is not in the registry"
  exit 1
fi

echo "verified: tag '${TAG}' and image '${IMAGE}:${TAG}'"
