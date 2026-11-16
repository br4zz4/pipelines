#!/bin/sh
set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "${HERE}/../.." && pwd)"
RELEASE="${ROOT}/tasks/release.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

GIT_AUTHOR_NAME=t
GIT_AUTHOR_EMAIL=t@t
GIT_COMMITTER_NAME=t
GIT_COMMITTER_EMAIL=t@t
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

PASSED=0
FAILED=0
STATUS=0

pass() {
  echo "PASS ${1}"
  PASSED=$(( PASSED + 1 ))
}

fail() {
  echo "FAIL ${1}"
  FAILED=$(( FAILED + 1 ))
}

check() {
  scenario="${1}"
  shift
  if "$@"; then
    pass "${scenario}"
  else
    fail "${scenario}"
  fi
}

new_repo() {
  repo="${WORK}/${1}"
  bare="${WORK}/${1}.git"
  rm -rf "${repo}" "${bare}"
  git init -q --bare "${bare}"
  mkdir -p "${repo}/.github/workflows" "${repo}/actions/x"
  (
    cd "${repo}"
    git init -q
    git checkout -q -b main
    printf 'jobs:\n  a:\n    steps:\n      - uses: br4zz4/pipelines/actions/hook@v1\n      - uses: br4zz4/pipelines/.github/workflows/pr.yml@v1\n      - uses: br4zz4/setup-ward@v1\n' > .github/workflows/a.yml
    printf 'runs:\n  steps:\n    - uses: br4zz4/pipelines/actions/hook@v1\n    - uses: br4zz4/pipelines/.github/workflows/pr.yml@v1\n    - uses: br4zz4/setup-ward@v1\n' > actions/x/action.yml
    git add -A
    git commit -qm base
    git remote add origin "${bare}"
  )
}

release() {
  repo="${1}"
  shift
  STATUS=0
  (cd "${repo}" && sh "${RELEASE}" "$@") >"${WORK}/out" 2>"${WORK}/err" || STATUS=$?
}

head_of() {
  git -C "${1}" rev-parse HEAD
}

tag_commit() {
  git -C "${1}" rev-parse "${2}^{commit}"
}

tag_type() {
  git -C "${1}" cat-file -t "refs/tags/${2}"
}

is_clean() {
  [ -z "$(git -C "${1}" status --porcelain)" ]
}

branch_of() {
  git -C "${1}" rev-parse --abbrev-ref HEAD
}

echo "# a: stable tag"
new_repo a
before="$(head_of "${WORK}/a")"
count="$(git -C "${WORK}/a" rev-list --count HEAD)"
release "${WORK}/a" v1
check "v1 exits 0" [ "${STATUS}" -eq 0 ]
check "v1 is an annotated tag" [ "$(tag_type "${WORK}/a" v1)" = "tag" ]
check "v1 points at HEAD" [ "$(tag_commit "${WORK}/a" v1)" = "${before}" ]
check "v1 creates no commit" [ "$(git -C "${WORK}/a" rev-list --count HEAD)" = "${count}" ]
check "v1 leaves the tree clean and the branch in place" sh -c '[ -z "$(git -C "$1" status --porcelain)" ] && [ "$(git -C "$1" rev-parse --abbrev-ref HEAD)" = main ]' _ "${WORK}/a"
check "v1 keeps @v1 in the files" grep -q 'pipelines/actions/hook@v1$' "${WORK}/a/.github/workflows/a.yml"

echo "# b: pre-release tag"
new_repo b
before="$(head_of "${WORK}/b")"
release "${WORK}/b" v1-beta
check "v1-beta exits 0" [ "${STATUS}" -eq 0 ]
check "v1-beta is an annotated tag" [ "$(tag_type "${WORK}/b" v1-beta)" = "tag" ]
beta="$(tag_commit "${WORK}/b" v1-beta)"
check "v1-beta is a new commit" [ "${beta}" != "${before}" ]
check "v1-beta commit is a child of HEAD" [ "$(git -C "${WORK}/b" rev-parse "${beta}^")" = "${before}" ]
check "v1-beta commit message" [ "$(git -C "${WORK}/b" log -1 --format=%s "${beta}")" = "release: v1-beta" ]
for file in .github/workflows/a.yml actions/x/action.yml; do
  git -C "${WORK}/b" show "v1-beta:${file}" > "${WORK}/tagged"
  check "${file}: pipelines refs say @v1-beta" sh -c \
    'grep -q "pipelines/actions/hook@v1-beta\$" "$1" && grep -q "pipelines/.github/workflows/pr.yml@v1-beta\$" "$1" && ! grep -q "br4zz4/pipelines/[^ ]*@v1\$" "$1"' _ "${WORK}/tagged"
  check "${file}: setup-ward stays @v1" grep -q 'br4zz4/setup-ward@v1$' "${WORK}/tagged"
done
check "branch still on the same commit" [ "$(git -C "${WORK}/b" rev-parse main)" = "${before}" ]
check "HEAD is back on the branch" [ "$(branch_of "${WORK}/b")" = "main" ]
check "working tree has no differences" is_clean "${WORK}/b"
check "working file still says @v1" grep -q 'pipelines/actions/hook@v1$' "${WORK}/b/.github/workflows/a.yml"

echo "# c: re-running moves the tag"
release "${WORK}/b" v1-beta
check "v1-beta again exits 0" [ "${STATUS}" -eq 0 ]
check "v1-beta again still points at a child of HEAD" [ "$(git -C "${WORK}/b" rev-parse "v1-beta^{commit}^")" = "${before}" ]
(cd "${WORK}/b" && printf 'x\n' > extra.txt && git add extra.txt && git commit -qm second)
release "${WORK}/b" v1
check "v1 exits 0 on first run" [ "${STATUS}" -eq 0 ]
(cd "${WORK}/b" && printf 'y\n' > extra2.txt && git add extra2.txt && git commit -qm third)
new_head="$(head_of "${WORK}/b")"
release "${WORK}/b" v1
check "v1 again exits 0" [ "${STATUS}" -eq 0 ]
check "v1 moved to the new HEAD" [ "$(tag_commit "${WORK}/b" v1)" = "${new_head}" ]

echo "# d: push"
new_repo d
release "${WORK}/d" v1 --push
check "v1 --push exits 0" [ "${STATUS}" -eq 0 ]
check "remote has v1 at HEAD" [ "$(git -C "${WORK}/d.git" rev-parse "refs/tags/v1^{commit}")" = "$(head_of "${WORK}/d")" ]
release "${WORK}/d" v1-beta --push
check "v1-beta --push exits 0" [ "${STATUS}" -eq 0 ]
check "remote has v1-beta at the release commit" [ "$(git -C "${WORK}/d.git" rev-parse "refs/tags/v1-beta^{commit}")" = "$(tag_commit "${WORK}/d" v1-beta)" ]
release "${WORK}/d" v1-beta --push
check "pushing a moved v1-beta exits 0" [ "${STATUS}" -eq 0 ]
check "remote follows the moved v1-beta" [ "$(git -C "${WORK}/d.git" rev-parse "refs/tags/v1-beta^{commit}")" = "$(tag_commit "${WORK}/d" v1-beta)" ]
new_repo d2
release "${WORK}/d2" v1
check "without --push the remote has no tag" [ -z "$(git -C "${WORK}/d2.git" tag -l)" ]

echo "# e: refusals"
new_repo e
printf 'dirty\n' > "${WORK}/e/untracked.txt"
release "${WORK}/e" v1
check "dirty tree exits 1" [ "${STATUS}" -eq 1 ]
check "dirty tree creates no tag" [ -z "$(git -C "${WORK}/e" tag -l)" ]
rm "${WORK}/e/untracked.txt"
printf '# edit\n' >> "${WORK}/e/.github/workflows/a.yml"
release "${WORK}/e" v1-beta
check "modified tracked file exits 1" [ "${STATUS}" -eq 1 ]
check "modified tree creates no tag" [ -z "$(git -C "${WORK}/e" tag -l)" ]
new_repo e2
for bad in foo 1; do
  release "${WORK}/e2" "${bad}"
  check "tag '${bad}' exits 2" [ "${STATUS}" -eq 2 ]
  check "tag '${bad}' creates no tag" [ -z "$(git -C "${WORK}/e2" tag -l)" ]
done

echo
echo "passed=${PASSED} failed=${FAILED}"
[ "${FAILED}" -eq 0 ] || exit 1
