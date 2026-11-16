#!/bin/sh
# build.sh — build the image and push it to ECR with BuildKit GHA layer cache.
# Production never builds: it deploys the tag staging already pushed.
#
# Environment: IMAGE (ECR repository URI, without tag), TAG, MODULE.
set -eu

IMAGE="${IMAGE:?IMAGE is not set}"
TAG="${TAG:?TAG is not set}"

aws ecr get-login-password | docker login --username AWS --password-stdin "${IMAGE%%/*}"

docker buildx build \
  --tag "${IMAGE}:${TAG}" \
  --cache-from "type=gha,scope=${MODULE}" \
  --cache-to   "type=gha,scope=${MODULE},mode=max" \
  --push \
  .
