#!/bin/sh
# plan.sh — read-only terraform plan. Runs in the module's infra directory,
# on pull requests and on main, as a gate: the tag only exists when this passes.
# "Nothing to apply" is a valid result — the deploy still runs apply.
#
# Environment: TF_DIR (default terraform), ENVIRONMENT, TF_BUCKET,
#              TF_STATE_KEY.
set -eu

TF_DIR="${TF_DIR:-terraform}"
TF_BUCKET="${TF_BUCKET:?TF_BUCKET is not set}"
TF_STATE_KEY="${TF_STATE_KEY:?TF_STATE_KEY is not set}"
TF_ENV_DIR="${TF_DIR}/envs/${ENVIRONMENT:-staging}"

terraform -chdir="${TF_ENV_DIR}" init -input=false \
  -backend-config="bucket=${TF_BUCKET}" \
  -backend-config="key=${TF_STATE_KEY}" >/dev/null

terraform -chdir="${TF_ENV_DIR}" plan -input=false -lock=false -no-color
