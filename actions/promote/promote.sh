#!/bin/sh
# promote.sh — pull, retag and push, so the target runs the exact same digest.
set -eu

SOURCE="${SOURCE:?SOURCE is not set}"
IMAGE="${IMAGE:?IMAGE is not set}"
TAG="${TAG_INPUT:?TAG_INPUT is not set}"

OVERRIDE="${MODULE_DIR:-.}/deploy/ci/promote.sh"
if [ -f "${OVERRIDE}" ] && [ "${MODULE_DIR:-.}" != "." ]; then
  echo "== deploy/ci/promote.sh (project override)"
  exec sh "${OVERRIDE}" "${SOURCE}" "${IMAGE}" "${TAG}"
fi

docker pull "${SOURCE}:${TAG}"
docker tag "${SOURCE}:${TAG}" "${IMAGE}:${TAG}"
docker tag "${SOURCE}:${TAG}" "${IMAGE}:latest"
docker push "${IMAGE}:${TAG}"
docker push "${IMAGE}:latest"
