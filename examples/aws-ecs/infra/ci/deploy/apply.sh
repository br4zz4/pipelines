#!/bin/sh
# apply.sh — make the environment's infrastructure match the release. Runs in
# the module's infra directory, after the release tag is validated and before
# the image is deployed. "Nothing to apply" is a valid result.
#
# Anything a project needs around the apply (seeding secrets, for instance)
# belongs in a helper outside ci/, such as lib/, which this script calls: ci/
# holds the hooks of the vocabulary and nothing else.
#
# Environment: TAG, ENVIRONMENT, TF_DIR, TF_BUCKET, TF_STATE_KEY, TF_VARS.
set -eu

TAG="${TAG:?TAG is not set}"
TF_DIR="${TF_DIR:-terraform}"
TF_BUCKET="${TF_BUCKET:?TF_BUCKET is not set}"
TF_STATE_KEY="${TF_STATE_KEY:?TF_STATE_KEY is not set}"
TF_VARS="${TF_VARS:-}"
TF_ENV_DIR="${TF_DIR}/envs/${ENVIRONMENT:-staging}"

echo "== terraform apply ${TF_ENV_DIR}"
terraform -chdir="${TF_ENV_DIR}" init -input=false \
  -backend-config="bucket=${TF_BUCKET}" \
  -backend-config="key=${TF_STATE_KEY}" >/dev/null

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

set +e
terraform -chdir="${TF_ENV_DIR}" plan -input=false -lock=false -no-color \
  -detailed-exitcode -out=plan.tfplan
PLAN_STATUS=$?
set -e

case "${PLAN_STATUS}" in
  0)
    echo "nothing to apply"
    rm -f "${TF_ENV_DIR}/plan.tfplan"
    ;;
  2)
    terraform -chdir="${TF_ENV_DIR}" apply -input=false -auto-approve -no-color plan.tfplan
    rm -f "${TF_ENV_DIR}/plan.tfplan"
    ;;
  *)
    echo "::error::terraform plan failed" >&2
    exit 1
    ;;
esac
