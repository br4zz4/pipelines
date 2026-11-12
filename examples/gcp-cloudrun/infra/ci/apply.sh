#!/bin/sh
# apply.sh — make the environment's infrastructure match the release. Runs in
# the module's infra directory, after the release tag is validated and before
# the image rolls. "Nothing to apply" is a valid result.
#
# Optional hooks, relative to the infra directory: ci/pre-apply.sh and
# ci/post-apply.sh. A module with nothing to do around the apply omits them.
#
# Environment: TAG, ENVIRONMENT, TF_DIR, TF_BUCKET, TF_STATE_PREFIX, TF_VARS.
set -eu

TAG="${TAG:?TAG is not set}"
TF_DIR="${TF_DIR:-terraform}"
TF_BUCKET="${TF_BUCKET:?TF_BUCKET is not set}"
TF_STATE_PREFIX="${TF_STATE_PREFIX:?TF_STATE_PREFIX is not set}"
TF_VARS="${TF_VARS:-}"
TF_ENV_DIR="${TF_DIR}/envs/${ENVIRONMENT:-staging}"

run_hook() {
  if [ -f "ci/$1.sh" ]; then
    echo "== ci/$1.sh"
    sh "ci/$1.sh"
  else
    echo "no ci/$1.sh: skipping"
  fi
}

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
    run_hook pre-apply
    terraform -chdir="${TF_ENV_DIR}" apply -input=false -auto-approve -no-color plan.tfplan
    rm -f "${TF_ENV_DIR}/plan.tfplan"
    run_hook post-apply
    ;;
  *)
    echo "::error::terraform plan failed" >&2
    exit 1
    ;;
esac
