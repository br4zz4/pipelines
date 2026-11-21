#!/bin/sh
# release.sh — publish a tag of this repository.
#
#   release.sh v2           tag the current commit as it is
#   release.sh v2-beta      tag a commit whose internal references say @v2-beta
#
# The workflows and actions call each other by absolute reference
# (br4zz4/pipelines/...@v2), so a consumer on @v2-beta would still reach the code
# of @v2 inside the reusable workflows. A pre-release tag is therefore a commit
# that is not on any branch: the current one with every internal reference rewritten
# to the tag. Pre-release tags move: re-running replaces them.
#
# Usage: release.sh <tag> [--push]
set -eu

TAG="${1:?usage: release.sh <tag> [--push]}"
PUSH="${2:-}"

case "${TAG}" in
  v[0-9]*) ;;
  *) echo "release: tag must look like v2 or v2-beta, got '${TAG}'" >&2; exit 2 ;;
esac

if [ -n "$(git status --porcelain)" ]; then
  echo "release: the working tree is not clean" >&2
  exit 1
fi

START="$(git rev-parse --abbrev-ref HEAD)"
[ "${START}" != "HEAD" ] || START="$(git rev-parse HEAD)"

if [ "${TAG#*-}" != "${TAG}" ]; then
  git checkout -q --detach
  TAG="${TAG}" perl -pi -e 's{(br4zz4/pipelines/[A-Za-z0-9_./-]+)\@v[0-9]+\b}{$1\@$ENV{TAG}}g' \
    .github/workflows/*.yml actions/*/action.yml
  git add .github/workflows actions
  git -c user.name="release" -c user.email="release@users.noreply.github.com" \
    commit -q -m "release: ${TAG}"
fi

git -c user.name="release" -c user.email="release@users.noreply.github.com" \
  tag -fa "${TAG}" -m "release ${TAG}"
echo "tagged ${TAG} -> $(git rev-parse "${TAG}^{commit}")"

git checkout -q "${START}"

if [ "${PUSH}" = "--push" ]; then
  git push -f origin "refs/tags/${TAG}"
fi
