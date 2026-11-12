#!/bin/sh
# snapshot.sh <prefix> — writes web_revision= and worker_revision= to GITHUB_OUTPUT.
set -eu

PREFIX="${PREFIX:?PREFIX is not set}"
REGION="${GCP_REGION:-us-west1}"

OVERRIDE="${MODULE_DIR:-.}/deploy/ci/snapshot.sh"
if [ -f "${OVERRIDE}" ] && [ "${MODULE_DIR:-.}" != "." ]; then
  echo "== deploy/ci/snapshot.sh (project override)"
  exec sh "${OVERRIDE}" "${PREFIX}"
fi

traffic_revision() {
  service="${PREFIX}-$1"
  revision="$(gcloud run services describe "${service}" --region "${REGION}" \
    --format='value(status.traffic[].revisionName,status.traffic[].percent)' 2>/dev/null \
    | paste - - | awk '$2==100 {print $1; exit}')"
  if [ -z "${revision}" ]; then
    revision="$(gcloud run services describe "${service}" --region "${REGION}" \
      --format='value(status.latestReadyRevisionName)' 2>/dev/null || true)"
  fi
  printf '%s' "${revision}"
}

WEB="$(traffic_revision web)"
WORKER="$(traffic_revision worker)"

echo "web_revision=${WEB}" >> "${GITHUB_OUTPUT}"
echo "worker_revision=${WORKER}" >> "${GITHUB_OUTPUT}"
echo "rollback point: web=${WEB:-<none>} worker=${WORKER:-<none>}"
