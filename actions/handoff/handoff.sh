#!/bin/sh
# handoff.sh — pass a Critical issue to a Fix run: label it fix:requested and say so.
set -u

ISSUE="${ISSUE:?ISSUE is not set}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
: "${GH_TOKEN:?GH_TOKEN is not set}"

LABEL=fix:requested
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

gh label create "${LABEL}" --force -R "${REPO}" > /dev/null 2>&1 || echo "::warning::handoff: could not create the label ${LABEL}"

if ! gh issue edit "${ISSUE}" --add-label "${LABEL}" -R "${REPO}"; then
  echo "::error::handoff: could not label #${ISSUE}"
  exit 1
fi

printf '%s\n' "[autofix] handed off to fix" > "${WORK}/comment.md"
gh issue comment "${ISSUE}" -R "${REPO}" --body-file "${WORK}/comment.md" || echo "::warning::handoff: could not comment on #${ISSUE}"
echo "handoff: #${ISSUE} labelled ${LABEL}"
