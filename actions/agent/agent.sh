#!/bin/sh
# agent.sh — run the agent on .autofix/issue.json inside a clean environment and publish .autofix/result.json and fix.patch.
set -u

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
MODULE="${MODULE:?MODULE is not set}"
CODE_DIR="${CODE_DIR:?CODE_DIR is not set}"
WORK="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
ROOT="$(pwd)"
OUT_DIR=.autofix
RESULT="${OUT_DIR}/result.json"
PATCH="${OUT_DIR}/fix.patch"
FORBIDDEN_VARS="GH_PIPELINES_TOKEN SENTRY_AUTH_TOKEN GITHUB_TOKEN"

leak() {
  echo "::error::agent environment leaks $1"
  exit 1
}

for name in ${FORBIDDEN_VARS}; do
  eval "value=\${${name}:-}"
  [ -z "${value}" ] || leak "${name}"
done

ward_name="$(env | sed -n 's/^\(WARD_KEY_[A-Za-z0-9_]*\)=.*/\1/p' | head -n 1)"
[ -z "${ward_name}" ] || leak "${ward_name}"

origin="$(git remote get-url origin 2>/dev/null || true)"
case "${origin}" in
  http://*@* | https://*@*) leak "git remote credentials" ;;
esac
[ -z "$(git config --get-regexp 'http\..*\.extraheader' 2>/dev/null || true)" ] || leak "git extraheader credentials"

BASE_HOOKS="${WORK}/base-hooks"
BIN_DIR="${HOME:?HOME is not set}/.autofix/bin"
rm -rf "${BASE_HOOKS}" "${BIN_DIR}"
mkdir -p "${BASE_HOOKS}" "${BIN_DIR}" "${OUT_DIR}"
for dir in run lib ci; do
  [ ! -d "${CODE_DIR}/${dir}" ] || cp -R "${CODE_DIR}/${dir}" "${BASE_HOOKS}/${dir}"
done
cp "${HERE}/ci-hook.sh" "${BIN_DIR}/ci-hook"
chmod +x "${BIN_DIR}/ci-hook"

AUTOFIX_ROOT="${ROOT}"
AUTOFIX_CODE_DIR="${CODE_DIR}"
AUTOFIX_MODULE="${MODULE}"
AUTOFIX_BASE_HOOKS="${BASE_HOOKS}"
PATH="${BIN_DIR}:${PATH}"
export AUTOFIX_ROOT AUTOFIX_CODE_DIR AUTOFIX_MODULE AUTOFIX_BASE_HOOKS PATH

PROMPT="$(sed -e "s|{{code_dir}}|${CODE_DIR}|g" -e "s|{{module}}|${MODULE}|g" "${HERE}/prompt.md")"

rm -f "${RESULT}" "${PATCH}"
claude -p "${PROMPT}" --model opus --max-turns 40 --output-format json \
  --allowedTools "Read,Edit,Write,Glob,Grep,Bash(ci-hook:*)" \
  --disallowedTools "WebFetch,WebSearch,Task" > "${OUT_DIR}/claude.json"
claude_status=$?

verdict="$(python3 - "${RESULT}" "${claude_status}" <<'PY'
import json
import sys

path, exit_code = sys.argv[1], int(sys.argv[2])
LIMIT = 1000
status, summary = "failed", "the agent produced no valid result"
if exit_code == 0:
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        value = data.get("status")
        text = str(data.get("summary", ""))[:LIMIT].replace("\n", " ").replace("\r", " ")
        if value == "gave_up":
            status, summary = "gave_up", text
        elif value == "fixed" and isinstance(data.get("tests"), list) and data["tests"]:
            status, summary = "fixed", text
    except (OSError, ValueError, AttributeError):
        pass
else:
    summary = f"the agent exited with status {exit_code}"
print(status)
print(summary)
PY
)"
status="$(printf '%s\n' "${verdict}" | sed -n '1p')"
summary="$(printf '%s\n' "${verdict}" | sed -n '2p')"

if [ "${status}" = fixed ]; then
  git add -N . > /dev/null 2>&1
  git diff --no-color --binary -- . ':!.autofix' > "${PATCH}"
else
  rm -f "${PATCH}"
fi

echo "agent: ${status}"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "status=${status}"
    echo "summary=${summary}"
  } >> "${GITHUB_OUTPUT}"
fi
exit 0
