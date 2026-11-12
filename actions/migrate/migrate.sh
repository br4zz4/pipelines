#!/bin/sh
# migrate.sh <job> <image> <tag> — update the job image, then execute it and wait.
set -eu

JOB="${JOB:?JOB is not set}"
IMAGE="${IMAGE:?IMAGE is not set}"
TAG="${TAG_INPUT:?TAG_INPUT is not set}"
REGION="${GCP_REGION:-us-west1}"

OVERRIDE="${MODULE_DIR:-.}/deploy/ci/migrate.sh"
if [ -f "${OVERRIDE}" ] && [ "${MODULE_DIR:-.}" != "." ]; then
  echo "== deploy/ci/migrate.sh (project override)"
  exec sh "${OVERRIDE}" "${JOB}" "${IMAGE}" "${TAG}"
fi

gcloud run jobs update "${JOB}" --image "${IMAGE}:${TAG}" --region "${REGION}" --quiet
gcloud run jobs execute "${JOB}" --region "${REGION}" --wait
