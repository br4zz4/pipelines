#!/bin/sh
# build.sh — build the image and push it to ECR under the release tag.
# Production never builds: it deploys the tag staging already pushed.
#
# Environment: IMAGE (repository uri, without the tag), TAG.
set -eu

IMAGE="${IMAGE:?IMAGE is not set}"
TAG="${TAG:?TAG is not set}"

docker build --tag "${IMAGE}:${TAG}" .
docker push "${IMAGE}:${TAG}"
