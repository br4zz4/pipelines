#!/bin/sh
# services.sh <prefix> <image> <tag> — deploy web and worker concurrently.
set -eu

PREFIX="${PREFIX:?PREFIX is not set}"
IMAGE="${IMAGE:?IMAGE is not set}"
TAG="${TAG_INPUT:?TAG_INPUT is not set}"
REGION="${GCP_REGION:-us-west1}"

OVERRIDE="${MODULE_DIR:-.}/deploy/ci/services.sh"
if [ -f "${OVERRIDE}" ] && [ "${MODULE_DIR:-.}" != "." ]; then
  echo "== deploy/ci/services.sh (project override)"
  exec sh "${OVERRIDE}" "${PREFIX}" "${IMAGE}" "${TAG}"
fi

gcloud run deploy "${PREFIX}-web" --image "${IMAGE}:${TAG}" --region "${REGION}" --quiet &
WEB_PID=$!
gcloud run deploy "${PREFIX}-worker" --image "${IMAGE}:${TAG}" --region "${REGION}" --quiet &
WORKER_PID=$!

STATUS=0
wait "${WEB_PID}" || { echo "::error::${PREFIX}-web deploy failed"; STATUS=1; }
wait "${WORKER_PID}" || { echo "::error::${PREFIX}-worker deploy failed"; STATUS=1; }
exit "${STATUS}"
