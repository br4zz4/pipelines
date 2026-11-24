#!/bin/sh
# Install the system packages a hook needs, from the cache when it is warm.
# Inputs: PACKAGES (space list), CACHE_DIR, APT_LISTS_DIR (default /var/lib/apt/lists).
set -u

PACKAGES="${PACKAGES:-}"
CACHE_DIR="${CACHE_DIR:?CACHE_DIR is not set}"
LISTS="${APT_LISTS_DIR:-/var/lib/apt/lists}"

[ -n "${PACKAGES}" ] || exit 0

if ! command -v apt-get >/dev/null 2>&1; then
  echo "::error::packages: apt-get not found, cannot install ${PACKAGES}" >&2
  exit 1
fi

mkdir -p "${CACHE_DIR}/archives" "${CACHE_DIR}/lists"

install_packages() {
  # shellcheck disable=SC2086
  sudo apt-get install --no-install-recommends -y -o "Dir::Cache::Archives=${CACHE_DIR}/archives" ${PACKAGES}
}

cold_install() {
  sudo apt-get update -qq || return 1
  install_packages || return 1
  mkdir -p "${CACHE_DIR}/lists"
  cp -R "${LISTS}/." "${CACHE_DIR}/lists/" 2>/dev/null || true
  sudo chown -R "$(id -u):$(id -g)" "${CACHE_DIR}" 2>/dev/null || true
}

if ls "${CACHE_DIR}"/archives/*.deb >/dev/null 2>&1; then
  sudo mkdir -p "${LISTS}"
  sudo cp -R "${CACHE_DIR}/lists/." "${LISTS}/" 2>/dev/null || true
  if install_packages; then
    exit 0
  fi
  echo "packages: install from cache failed, falling back to apt-get update"
fi

cold_install
