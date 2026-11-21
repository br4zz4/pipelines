#!/bin/sh
# python.sh — sourced by test runners.
#
# ensure_python <root> <dir>: sets PY to a python3 that can import yaml.
# Uses the host python3 when PyYAML is present; otherwise creates a venv in
# <dir>/venv and installs <root>/requirements-dev.txt. The caller owns <dir>
# and removes it.
ensure_python() {
  _root="${1}"
  _dir="${2}"
  if python3 -c 'import yaml' >/dev/null 2>&1; then
    PY="python3"
    export PY
    return 0
  fi
  python3 -m venv "${_dir}/venv" || return 1
  "${_dir}/venv/bin/python" -m pip install -q --disable-pip-version-check -r "${_root}/requirements-dev.txt" || return 1
  PY="${_dir}/venv/bin/python"
  export PY
}
