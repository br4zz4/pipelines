#!/bin/sh
# fly.sh — snapshot the rollback point, promote the image, migrate and roll the
# services. The infrastructure is apply.sh's job: fly never plans or applies.
#
# Environment: TAG, PREFIX, IMAGE, SOURCE_IMAGE, ENVIRONMENT, REGION.
# Output: rollback=<revision> on $GITHUB_OUTPUT.
set -eu

TAG="${TAG:?TAG is not set}"
PREFIX="${PREFIX:?PREFIX is not set}"
IMAGE="${IMAGE:?IMAGE is not set}"
SOURCE_IMAGE="${SOURCE_IMAGE:-${IMAGE}}"
REGION="${REGION:-us-west1}"

echo "== image ${IMAGE}:${TAG}"
docker manifest inspect "${IMAGE}:${TAG}" >/dev/null

echo "== rollback point"
current_revision() {
  gcloud run services describe "${PREFIX}-$1" --region "${REGION}" \
    --format='value(status.traffic[].revisionName,status.traffic[].percent)' 2>/dev/null \
    | paste - - | awk '$2 == 100 {print $1; exit}'
}
ROLLBACK="$(current_revision web)"
echo "rollback=${ROLLBACK}" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
echo "web: ${ROLLBACK:-<none>}"

echo "== promote ${SOURCE_IMAGE}:${TAG} -> ${IMAGE}:${TAG}"
if [ "${SOURCE_IMAGE}" != "${IMAGE}" ]; then
  docker buildx imagetools create -t "${IMAGE}:${TAG}" "${SOURCE_IMAGE}:${TAG}"
fi

echo "== migrate"
if gcloud run jobs describe "${PREFIX}-migrate" --region "${REGION}" >/dev/null 2>&1; then
  gcloud run jobs update "${PREFIX}-migrate" --image "${IMAGE}:${TAG}" --region "${REGION}" --quiet
  gcloud run jobs execute "${PREFIX}-migrate" --region "${REGION}" --wait
else
  echo "no ${PREFIX}-migrate job: skipping"
fi

echo "== services"
gcloud run deploy "${PREFIX}-web" --image "${IMAGE}:${TAG}" --region "${REGION}" --quiet
gcloud run deploy "${PREFIX}-worker" --image "${IMAGE}:${TAG}" --region "${REGION}" --quiet
