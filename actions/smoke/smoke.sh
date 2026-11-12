#!/bin/sh
# smoke.sh — the Cloud Run URL always blocks; the public URL only warns unless strict.
set -eu

PREFIX="${PREFIX:?PREFIX is not set}"
PUBLIC_URL="${PUBLIC_URL:-}"
REGION="${GCP_REGION:-us-west1}"
STRICT="${STRICT:-false}"

OVERRIDE="${MODULE_DIR:-.}/deploy/ci/smoke.sh"
if [ -f "${OVERRIDE}" ] && [ "${MODULE_DIR:-.}" != "." ]; then
  echo "== deploy/ci/smoke.sh (project override)"
  exec sh "${OVERRIDE}" "${PREFIX}" "${PUBLIC_URL}"
fi

check() {
  echo "smoke: $1/up"
  curl -fsS --retry 5 --retry-delay 5 --retry-all-errors "$1/up" >/dev/null
}

RUN_URL="$(gcloud run services describe "${PREFIX}-web" --region "${REGION}" --format='value(status.url)')"
check "${RUN_URL}"

if [ -z "${PUBLIC_URL}" ]; then
  echo "no public URL configured: Cloud Run only"
  exit 0
fi

HOST="$(printf '%s' "${PUBLIC_URL}" | sed -E 's#https?://([^/]+).*#\1#')"
if getent hosts "${HOST}" >/dev/null 2>&1; then
  check "${PUBLIC_URL}"
elif [ "${STRICT}" = "true" ]; then
  echo "::error::${PUBLIC_URL} does not resolve"
  exit 1
else
  echo "::warning::${PUBLIC_URL} does not resolve (DNS not mapped): Cloud Run only"
fi
