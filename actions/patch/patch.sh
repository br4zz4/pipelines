#!/bin/sh
# patch.sh — scope rules of an agent patch, and the two ways the verify job applies it (tests only, whole patch).
set -u

COMMAND="${1:-}"

emit_reason() {
  [ -z "${GITHUB_OUTPUT:-}" ] || echo "reason=$1" >> "${GITHUB_OUTPUT}"
}

refuse() {
  echo "::error::$1" >&2
  emit_reason "$1"
  exit 1
}

patch_files() {
  awk '
    /^diff --git a\// {
      line = substr($0, length("diff --git a/") + 1)
      split_at = index(line, " b/")
      print substr(line, 1, split_at - 1)
      print substr(line, split_at + 3)
    }
  ' "$1" | awk '!seen[$0]++'
}

result_tests() {
  python3 - "$1" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        tests = json.load(handle).get("tests") or []
except (OSError, ValueError, AttributeError):
    tests = []
for item in tests:
    print(item)
PY
}

forbidden() {
  case "$1" in
    .github/* | .ward/* | ci/* | */ci/* | run/* | */run/* | mise.toml | */mise.toml) return 0 ;;
  esac
  case "$1" in
    "$2"/e2e/*) return 0 ;;
  esac
  return 1
}

scope() {
  patch="${1:?patch is required}"
  result="${2:?result.json is required}"
  code_dir="${3:?code_dir is required}"

  if [ ! -s "${patch}" ] || ! grep -q '^diff --git ' "${patch}"; then
    refuse "empty patch"
  fi
  files="$(patch_files "${patch}")"

  for file in ${files}; do
    if forbidden "${file}" "${code_dir}"; then
      refuse "forbidden path ${file}"
    fi
  done
  for file in ${files}; do
    case "${file}" in
      "${code_dir}"/*) ;;
      *) refuse "outside module ${file}" ;;
    esac
  done

  tests="$(result_tests "${result}")"
  [ -n "${tests}" ] || refuse "empty tests"
  for test_file in ${tests}; do
    printf '%s\n' "${files}" | grep -qxF "${test_file}" || refuse "test ${test_file} not in patch"
  done

  emit_reason ""
  echo "scope: ok"
}

apply_tests() {
  patch="${1:?patch is required}"
  result="${2:?result.json is required}"
  tests="$(result_tests "${result}")"
  [ -n "${tests}" ] || refuse "empty tests"
  set --
  for test_file in ${tests}; do
    set -- "$@" "--include=${test_file}"
  done
  git apply "$@" "${patch}" || refuse "tests do not apply"
}

apply_full() {
  patch="${1:?patch is required}"
  git checkout -- . && git clean -fd -e .autofix > /dev/null
  git apply "${patch}" || refuse "patch does not apply"
}

case "${COMMAND}" in
  scope) shift; scope "$@" ;;
  tests) shift; apply_tests "$@" ;;
  full) shift; apply_full "$@" ;;
  *)
    echo "usage: patch.sh scope <patch> <result.json> <code_dir> | tests <patch> <result.json> | full <patch>" >&2
    exit 2
    ;;
esac
