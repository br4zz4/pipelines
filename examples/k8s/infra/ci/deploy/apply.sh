#!/bin/sh
# apply.sh — make the environment's infrastructure match the release. Runs in
# the module's infra directory, after the release tag is validated and before
# the image is deployed. "Nothing to apply" is a valid result.
#
# Anything a project needs around the apply (seeding secrets, for instance)
# belongs in a helper outside ci/, such as lib/, which this script calls: ci/
# holds the hooks of the vocabulary and nothing else.
#
# Environment: ENVIRONMENT, OVERLAY.
set -eu

OVERLAY="${OVERLAY:-overlays/${ENVIRONMENT:-staging}}"

echo "== apply ${OVERLAY}"
kubectl apply -k "${OVERLAY}"
