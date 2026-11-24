#!/bin/sh
# publish.sh — turn the outcome of one autofix run into a pull request with automerge, or a comment and a label on the Critical issue.
set -u

ISSUE="${ISSUE:?ISSUE is not set}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
TOKEN="${GH_TOKEN:?GH_TOKEN is not set}"
TITLE="${TITLE:-}"
SELECT_OUTCOME="${SELECT_OUTCOME:-}"
SELECT_REASON="${SELECT_REASON:-}"
FIX_STATUS="${FIX_STATUS:-}"
FIX_SUMMARY="${FIX_SUMMARY:-}"
VERIFY_RESULT="${VERIFY_RESULT:-}"
VERIFY_REASON="${VERIFY_REASON:-}"
RUN_URL="${RUN_URL:-}"
BASE_REF="${BASE_REF:-main}"

BRANCH="fix/issue-${ISSUE}"
LABEL=autofix
FAILED_LABEL=autofix:failed
SUBJECT_LIMIT=60
AUTHOR_NAME='github-actions[bot]'
AUTHOR_EMAIL='github-actions[bot]@users.noreply.github.com'
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
ISSUE_URL="https://github.com/${REPO}/issues/${ISSUE}"

emit() {
  [ -z "${GITHUB_OUTPUT:-}" ] || echo "$1=$2" >> "${GITHUB_OUTPUT}"
}

try_gh() {
  action="$1"
  shift
  if gh "$@" > "${WORK}/gh.out" 2> "${WORK}/gh.err"; then
    return 0
  fi
  reason="$(python3 - "${WORK}/gh.err" "$(dirname "$0")/../critical" <<'PY'
import sys

sys.path.insert(0, sys.argv[2])
from critical import mask

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        line = next((item.strip() for item in handle if item.strip()), "")
except OSError:
    line = ""
print(mask(line))
PY
)"
  echo "::warning::publish: ${action} failed: ${reason}"
  return 1
}

comment() {
  printf '%s\n' "$1" > "${WORK}/comment.md"
  try_gh comment issue comment "${ISSUE}" --body-file "${WORK}/comment.md" -R "${REPO}" || true
}

mark_failed() {
  try_gh label label create "${FAILED_LABEL}" --force -R "${REPO}" || true
  try_gh label issue edit "${ISSUE}" --add-label "${FAILED_LABEL}" -R "${REPO}" || true
}

finish_without_pr() {
  comment "$2"
  mark_failed
  emit outcome "$1"
  emit url "${ISSUE_URL}"
  echo "autofix: $1"
}

regression_tests() {
  python3 - <<'PY'
import json

try:
    with open(".autofix/result.json", encoding="utf-8") as handle:
        for item in json.load(handle).get("tests") or []:
            print(f"- `{item}`")
except (OSError, ValueError, AttributeError):
    pass
PY
}

pull_request_body() {
  {
    echo "Fixes #${ISSUE}"
    echo
    echo "${FIX_SUMMARY}"
    echo
    echo "## Regression tests"
    echo
    regression_tests
    echo
    echo "Verification: ${RUN_URL}"
    echo
    echo "Gerado pelo autofix; entra por automerge quando o check/pr passar."
  } > "${WORK}/pr.md"
}

push_branch() {
  if git push "https://x-access-token:${TOKEN}@github.com/${REPO}.git" "${BRANCH}:refs/heads/${BRANCH}" > "${WORK}/push.log" 2>&1; then
    return 0
  fi
  sed "s/${TOKEN}/***/g" "${WORK}/push.log" >&2
  return 1
}

open_pull_request() {
  git apply .autofix/fix.patch || return 1
  git switch -c "${BRANCH}" > /dev/null 2>&1 || return 1
  git add -A -- . ':(exclude).autofix' || return 1
  subject="$(printf 'fix: #%s %s' "${ISSUE}" "${TITLE}" | cut -c1-"${SUBJECT_LIMIT}")"
  git -c user.name="${AUTHOR_NAME}" -c user.email="${AUTHOR_EMAIL}" commit -q -m "${subject}" || return 1
  push_branch || return 1

  try_gh label label create "${LABEL}" --force -R "${REPO}" || true
  pull_request_body
  try_gh "pr create" pr create --base "${BASE_REF}" --head "${BRANCH}" --label "${LABEL}" --title "${subject}" --body-file "${WORK}/pr.md" -R "${REPO}" || return 1
  pr_url="$(cat "${WORK}/gh.out")"

  if gh pr merge "${pr_url}" --auto --merge -R "${REPO}" > /dev/null 2>&1; then
    comment "[autofix] opened ${pr_url}"
  else
    comment "[autofix] opened ${pr_url} (auto-merge unavailable: enable \"Allow auto-merge\")"
  fi
  emit outcome opened
  emit url "${pr_url}"
  echo "autofix: opened ${pr_url}"
}

[ "${SELECT_OUTCOME}" != skipped ] || exit 0

if [ "${SELECT_OUTCOME}" = rejected ]; then
  finish_without_pr rejected "[autofix] rejected: ${SELECT_REASON} (${RUN_URL})"
elif [ "${VERIFY_RESULT}" = success ]; then
  open_pull_request || finish_without_pr failed "[autofix] failed (${RUN_URL})"
elif [ "${VERIFY_RESULT}" = failure ]; then
  finish_without_pr rejected "[autofix] rejected: ${VERIFY_REASON:-verify failed before a verdict} (${RUN_URL})"
elif [ "${FIX_STATUS}" = gave_up ]; then
  finish_without_pr "gave up" "[autofix] gave up: ${FIX_SUMMARY}"
else
  finish_without_pr failed "[autofix] failed (${RUN_URL})"
fi
exit 0
