#!/bin/sh
# rollback.sh — send web traffic back to the revision fly.sh captured. Fails
# when there is no such revision.
#
# Environment: PREFIX, ROLLBACK_POINT, REGION.
set -eu

PREFIX="${PREFIX:?PREFIX is not set}"
REGION="${REGION:-us-west1}"
ROLLBACK_POINT="${ROLLBACK_POINT:?no rollback point: nothing to return to}"

gcloud run services update-traffic "${PREFIX}-web" --region "${REGION}" \
  --to-revisions="${ROLLBACK_POINT}=100" --quiet

echo "traffic reverted to ${ROLLBACK_POINT}"
