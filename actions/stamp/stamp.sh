#!/bin/sh
# stamp.sh — annotate and push the release tag of a module. The tag is the only
# channel a deploy needs to know what to deploy.
set -eu

TAG="${TAG_INPUT:?TAG_INPUT is not set}"
SHA="$(git rev-parse HEAD)"

if [ -z "${GH_TAG_TOKEN:-}" ]; then
  echo "::error::missing token: a release tag needs a PAT with the 'workflow' scope"
  exit 1
fi

git remote set-url origin "https://x-access-token:${GH_TAG_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"

# A tag pushed with GITHUB_TOKEN does not trigger workflows. actions/checkout
# writes an http.extraheader with its own token, which wins over the URL above;
# drop it so the push authenticates as the PAT.
git config --local --get-regexp '^http\..*\.extraheader$' 2>/dev/null | while read -r KEY _; do
  git config --local --unset-all "${KEY}" || true
done

MESSAGE="release ${TAG}"

git -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    tag -fa "${TAG}" -m "${MESSAGE}"

if ! git push origin "${TAG}" --force; then
  echo "::error::could not push ${TAG}. The token needs the 'workflow' scope: GitHub refuses a tag whose tree differs from the default branch tip in .github/workflows."
  exit 1
fi

echo "tag ${TAG} -> ${SHA}"
echo "${MESSAGE}"
