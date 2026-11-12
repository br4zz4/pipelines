#!/bin/sh
# prepare.sh — read-only terraform plan. Runs in the module's infra directory,
# on pull requests and on main, as a gate: the tag only exists when this passes.
# "Nothing to apply" is a valid result — the rollout still runs apply.
#
# Environment: TF_DIR (default terraform), ENVIRONMENT, TF_BUCKET,
#              TF_STATE_PREFIX.
set -eu

TF_DIR="${TF_DIR:-terraform}"
TF_BUCKET="${TF_BUCKET:?TF_BUCKET is not set}"
TF_STATE_PREFIX="${TF_STATE_PREFIX:?TF_STATE_PREFIX is not set}"
TF_ENV_DIR="${TF_DIR}/envs/${ENVIRONMENT:-staging}"

terraform -chdir="${TF_ENV_DIR}" init -input=false \
  -backend-config="bucket=${TF_BUCKET}" \
  -backend-config="prefix=${TF_STATE_PREFIX}" >/dev/null

terraform -chdir="${TF_ENV_DIR}" plan -input=false -lock=false -no-color
