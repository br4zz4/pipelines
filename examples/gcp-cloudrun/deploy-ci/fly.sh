#!/bin/sh
# fly.sh — verify the release, snapshot the rollback point, promote the image,
# apply the infrastructure, migrate and roll the Cloud Run services.
#
# Environment: TAG, PREFIX, IMAGE, SOURCE_IMAGE, ENVIRONMENT, REGION, TF_DIR,
#              TF_BUCKET, TF_STATE_PREFIX, TF_VARS.
# Output: rollback=<revision> on $GITHUB_OUTPUT.
set -eu

TAG="${TAG:?TAG is not set}"
PREFIX="${PREFIX:?PREFIX is not set}"
IMAGE="${IMAGE:?IMAGE is not set}"
SOURCE_IMAGE="${SOURCE_IMAGE:-${IMAGE}}"
REGION="${REGION:-us-west1}"
TF_DIR="${TF_DIR:-terraform}"
TF_BUCKET="${TF_BUCKET:?TF_BUCKET is not set}"
TF_STATE_PREFIX="${TF_STATE_PREFIX:?TF_STATE_PREFIX is not set}"
TF_VARS="${TF_VARS:-}"
TF_ENV_DIR="${TF_DIR}/envs/${ENVIRONMENT:-staging}"

echo "== verify ${TAG}"
git rev-parse -q --verify "refs/tags/${TAG}^{commit}" >/dev/null
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

echo "== terraform apply ${TF_ENV_DIR}"
terraform -chdir="${TF_ENV_DIR}" init -input=false \
  -backend-config="bucket=${TF_BUCKET}" \
  -backend-config="prefix=${TF_STATE_PREFIX}" >/dev/null
if [ -n "${TF_VARS}" ] && [ "${TF_VARS}" != "{}" ]; then
  VARS_FILE="$(mktemp)"
  python3 - "${TF_VARS}" "${TAG}" >"${VARS_FILE}" <<'PY'
import json
import sys

variables, tag = json.loads(sys.argv[1]), sys.argv[2]
for key, value in variables.items():
    print(f"{key}={str(value).replace('{tag}', tag)}")
PY
  while IFS="=" read -r key value; do
    export "TF_VAR_${key}=${value}"
  done <"${VARS_FILE}"
  rm -f "${VARS_FILE}"
fi
terraform -chdir="${TF_ENV_DIR}" apply -input=false -auto-approve -no-color

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
