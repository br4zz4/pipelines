#!/bin/sh
# check.sh — terraform fmt and validate. Runs in the module's infra directory.
#
# Environment: TF_DIR (default terraform).
set -eu

TF_DIR="${TF_DIR:-terraform}"

terraform fmt -check -recursive "${TF_DIR}"

for env_dir in "${TF_DIR}"/envs/*/; do
  [ -f "${env_dir}/main.tf" ] || continue
  echo "== validate: ${env_dir}"
  (
    cd "${env_dir}"
    terraform init -backend=false -input=false >/dev/null
    terraform validate -no-color
  )
done
