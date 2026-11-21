#!/bin/sh
# split.sh — one build tag per module the push changed. `build/<release tag>`
# starts the Build of that module; the Build deletes it once the release tag is
# published. A module that fails does not stop the others; the job fails at the end.
#
# Environment: CHANGES (detect output), GH_PIPELINES_TOKEN, GITHUB_REPOSITORY,
# REMOTE_URL (optional override of the push URL), GITHUB_OUTPUT, GITHUB_STEP_SUMMARY.
set -eu

CHANGES="${CHANGES:?CHANGES is not set}"
OUT="${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
ATTEMPTS=5
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
TAG_SH="${HERE}/../tag/tag.sh"

if [ -z "${GH_PIPELINES_TOKEN:-}" ]; then
  echo "::error::missing token: a build tag needs a PAT, because a tag pushed with GITHUB_TOKEN does not start workflows"
  exit 1
fi

REMOTE="${REMOTE_URL:-https://x-access-token:${GH_PIPELINES_TOKEN}@github.com/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}.git}"

git config --local --get-regexp '^http\..*\.extraheader$' 2>/dev/null | while read -r KEY _; do
  git config --local --unset-all "${KEY}" || true
done

MODULES="$(printf '%s' "${CHANGES}" | python3 -c 'import json, sys
changes = json.load(sys.stdin)
print("\n".join(name for name in sorted(changes) if changes[name].get("any")))')"

summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "$1" >> "${GITHUB_STEP_SUMMARY}"
  fi
}

if [ -z "${MODULES}" ]; then
  echo "nothing to build"
  summary "nothing to build"
  echo "builds=" >> "${OUT}"
  exit 0
fi

PUSHED=""
FAILED=""
TAG_OUT="$(mktemp)"
TAG_LOG="$(mktemp)"
trap 'rm -f "${TAG_OUT}" "${TAG_LOG}"' EXIT

for MODULE in ${MODULES}; do
  DONE=""
  N=0
  while [ "${N}" -lt "${ATTEMPTS}" ]; do
    N=$(( N + 1 ))
    : > "${TAG_OUT}"
    if ! PREFIX="${MODULE}" TAG_REMOTE="${REMOTE}" GITHUB_OUTPUT="${TAG_OUT}" sh "${TAG_SH}" > "${TAG_LOG}"; then
      cat "${TAG_LOG}"
      echo "could not name a release for ${MODULE} (attempt ${N}/${ATTEMPTS})"
      continue
    fi
    NAME="$(sed -n 's/^tag=//p' "${TAG_OUT}")"
    if ! git -c user.name="github-actions[bot]" \
        -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
        tag -a "build/${NAME}" -m "build ${NAME}"; then
      echo "could not create build/${NAME} (attempt ${N}/${ATTEMPTS})"
      continue
    fi
    if git push "${REMOTE}" "refs/tags/build/${NAME}" >/dev/null 2>&1; then
      echo "build/${NAME} -> $(git rev-parse HEAD)"
      PUSHED="${PUSHED:+${PUSHED},}${NAME}"
      DONE=1
      break
    fi
    git tag -d "build/${NAME}" >/dev/null
    echo "build/${NAME} was not accepted (attempt ${N}/${ATTEMPTS})"
  done
  if [ -z "${DONE}" ]; then
    FAILED="${FAILED:+${FAILED}, }${MODULE}"
  fi
done

echo "builds=${PUSHED}" >> "${OUT}"
summary "build tags: ${PUSHED:-none}"

if [ -n "${FAILED}" ]; then
  echo "::error::could not push a build tag for ${FAILED}"
  exit 1
fi
