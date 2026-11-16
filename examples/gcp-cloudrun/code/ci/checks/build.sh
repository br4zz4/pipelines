#!/bin/sh
# build.sh — build the image and push it with BuildKit GHA layer cache.
# Production never builds: it promotes the image staging built.
#
# Environment: IMAGE (full registry path, without tag), TAG, MODULE.
set -eu

IMAGE="${IMAGE:?IMAGE is not set}"
TAG="${TAG:?TAG is not set}"

docker buildx build \
  --tag "${IMAGE}:${TAG}" \
  --cache-from "type=gha,scope=${MODULE}" \
  --cache-to   "type=gha,scope=${MODULE},mode=max" \
  --push \
  .
