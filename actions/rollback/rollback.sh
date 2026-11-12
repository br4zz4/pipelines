#!/bin/sh
# rollback.sh <prefix> <web-revision> <worker-revision>
set -eu

PREFIX="${PREFIX:?PREFIX is not set}"
WEB="${WEB_REVISION:-}"
WORKER="${WORKER_REVISION:-}"
REGION="${GCP_REGION:-us-west1}"

OVERRIDE="${MODULE_DIR:-.}/deploy/ci/rollback.sh"
if [ -f "${OVERRIDE}" ] && [ "${MODULE_DIR:-.}" != "." ]; then
  echo "== deploy/ci/rollback.sh (project override)"
  exec sh "${OVERRIDE}" "${PREFIX}" "${WEB}" "${WORKER}"
fi

if [ -z "${WEB}" ] && [ -z "${WORKER}" ]; then
  echo "::error::no previous revision to roll back to — manual action needed"
  exit 1
fi

if [ -n "${WEB}" ]; then
  gcloud run services update-traffic "${PREFIX}-web" --region "${REGION}" --to-revisions="${WEB}=100" --quiet
fi
if [ -n "${WORKER}" ]; then
  gcloud run services update-traffic "${PREFIX}-worker" --region "${REGION}" --to-revisions="${WORKER}=100" --quiet
fi

echo "traffic reverted: web=${WEB:-<none>} worker=${WORKER:-<none>}"
