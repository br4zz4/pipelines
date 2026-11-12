#!/bin/sh
# terraform.sh — one environment, one intent. fmt/validate needs no backend.
set -eu

MODE="${MODE:-check}"
TF_DIR="${TF_DIR:?TF_DIR is not set}"
TF_CHECK_DIR="${TF_CHECK_DIR:?TF_CHECK_DIR is not set}"
TF_BUCKET="${TF_BUCKET:?TF_BUCKET is not set}"
TF_STATE_PREFIX="${TF_STATE_PREFIX:?TF_STATE_PREFIX is not set}"
TF_VARS="${TF_VARS:-}"
TAG="${TAG_INPUT:-}"
REGION="${GCP_REGION:-us-west1}"

OVERRIDE="${MODULE_DIR:-.}/deploy/ci/terraform.sh"
if [ -f "${OVERRIDE}" ] && [ "${MODULE_DIR:-.}" != "." ]; then
  echo "== deploy/ci/terraform.sh (project override)"
  exec sh "${OVERRIDE}" "${MODE}" "${TF_DIR}"
fi

init_backend() {
  terraform -chdir="${TF_DIR}" init -input=false \
    -backend-config="bucket=${TF_BUCKET}" \
    -backend-config="prefix=${TF_STATE_PREFIX}" >/dev/null
}

case "${MODE}" in
  check)
    terraform fmt -check -recursive "${TF_CHECK_DIR}"
    for env_dir in "${TF_CHECK_DIR}"/*/envs/*/; do
      [ -f "${env_dir}/main.tf" ] || continue
      echo "== validate: ${env_dir}"
      ( cd "${env_dir}" && terraform init -backend=false -input=false >/dev/null && terraform validate -no-color )
    done
    ;;
  plan)
    init_backend
    LOG="$(mktemp)"
    STATUS=0
    terraform -chdir="${TF_DIR}" plan -input=false -lock=false -no-color >"${LOG}" 2>&1 || STATUS=$?
    cat "${LOG}"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      { echo "### terraform plan"; echo '```'; tail -n 200 "${LOG}"; echo '```'; } >> "${GITHUB_STEP_SUMMARY}"
    fi
    exit "${STATUS}"
    ;;
  apply)
    init_backend
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
    fi
    terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -no-color
    ;;
  *)
    echo "::error::unknown mode '${MODE}' (use check|plan|apply)"
    exit 64
    ;;
esac

echo "terraform ${MODE} ok in ${TF_DIR} (${REGION})"
