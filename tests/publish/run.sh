#!/bin/sh
set -u

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="${ROOT}/actions/publish/publish.sh"
WORK="$(cd -P "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "${WORK}"' EXIT

GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL EMAIL

PASSED=0
FAILED=0
STATUS=0
TOKEN=ghp_SECRETtoken0123456789
OUT="${WORK}/output"
LOG="${WORK}/log"
CALLS="${WORK}/calls"
TOKENS="${WORK}/tokens"
BODIES="${WORK}/bodies"
SUMMARY="${WORK}/summary"
CWD="${WORK}/cwd"
BARE="${WORK}/remotes/o/r.git"
DECOY="${WORK}/decoy.git"
MERGE_FAIL="${WORK}/merge_fail"
PR_URL="https://github.com/o/r/pull/9"
RUN="https://github.com/o/r/actions/runs/55"
BOT_EMAIL="github-actions[bot]@users.noreply.github.com"
LINE="Gerado pelo autofix; entra por automerge quando o check/pr passar."

mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gh" <<'GH'
#!/bin/sh
printf '%s\n' "$*" >> "${GH_CALLS}"
printf '%s\n' "${GH_TOKEN:-}" >> "${GH_TOKENS}"
[ -n "${GH_TOKEN:-}" ] || exit 1
mkdir -p "${GH_BODIES}"
dest="${GH_BODIES}/${1:-}-${2:-}"
prev=""
for arg in "$@"; do
  case "${prev}" in
    --body) printf '%s\n' "${arg}" >> "${dest}" ;;
    --body-file) if [ "${arg}" = "-" ]; then cat >> "${dest}"; else cat "${arg}" >> "${dest}"; fi ;;
  esac
  prev="${arg}"
done
case "${1:-} ${2:-}" in
  "pr create") echo "https://github.com/o/r/pull/9" ;;
  "pr merge") if [ -f "${GH_MERGE_FAIL}" ]; then echo "auto merge is not allowed for this repository" >&2; exit 1; fi ;;
esac
exit 0
GH
chmod 755 "${WORK}/bin/gh"

pass() {
  echo "PASS ${1}"
  PASSED=$(( PASSED + 1 ))
}

fail() {
  echo "FAIL ${1}"
  FAILED=$(( FAILED + 1 ))
}

ok() {
  label="$1"
  shift
  if "$@"; then pass "${label}"; else fail "${label}"; fi
}

g() {
  git -c user.name=fixture -c user.email=fixture@example.invalid "$@"
}

mkrepo() {
  rm -rf "${WORK}/remotes" "${DECOY}" "${WORK}/src" "${CWD}" "${MERGE_FAIL}"
  mkdir -p "${WORK}/remotes/o"
  git init -q --bare -b main "${BARE}"
  git init -q --bare -b main "${DECOY}"
  git init -q -b main "${WORK}/src"
  printf 'broken\n' > "${WORK}/src/app.txt"
  g -C "${WORK}/src" add app.txt
  g -C "${WORK}/src" commit -q -m init
  git -C "${WORK}/src" push -q "${BARE}" main
  git clone -q "${BARE}" "${CWD}"
  git -C "${CWD}" remote set-url origin "${DECOY}"
  MAIN_SHA="$(git --git-dir="${BARE}" rev-parse main)"
  printf 'fixed\n' > "${WORK}/src/app.txt"
  mkdir -p "${WORK}/src/modules/core/code/test"
  printf 'regression a\n' > "${WORK}/src/modules/core/code/test/a_test.txt"
  printf 'regression b\n' > "${WORK}/src/modules/core/code/test/b_test.txt"
  g -C "${WORK}/src" add -A
  git -C "${WORK}/src" diff --no-color --cached > "${WORK}/fix.patch"
  mkdir -p "${CWD}/.autofix"
  cp "${WORK}/fix.patch" "${CWD}/.autofix/fix.patch"
  printf '%s' '{"status":"fixed","tests":["modules/core/code/test/a_test.txt","modules/core/code/test/b_test.txt"],"summary":"root cause fixed"}' > "${CWD}/.autofix/result.json"
}

setup() {
  : > "${OUT}"
  : > "${LOG}"
  : > "${CALLS}"
  : > "${TOKENS}"
  : > "${SUMMARY}"
  rm -rf "${BODIES}"
  mkrepo
  ISSUE=7
  TITLE="bug: core broke"
  MODULE=core
  SELECT_OUTCOME=selected
  SELECT_REASON=""
  FIX_STATUS=fixed
  FIX_SUMMARY="root cause fixed"
  VERIFY_RESULT=success
  VERIFY_REASON=""
  RUN_URL="${RUN}"
  BASE_REF=main
}

run() {
  STATUS=0
  ( cd "${CWD}" && env PATH="${WORK}/bin:${PATH}" \
    GH_CALLS="${CALLS}" GH_TOKENS="${TOKENS}" GH_BODIES="${BODIES}" GH_MERGE_FAIL="${MERGE_FAIL}" \
    GIT_CONFIG_COUNT=1 \
    "GIT_CONFIG_KEY_0=url.${WORK}/remotes/.insteadOf" \
    "GIT_CONFIG_VALUE_0=https://x-access-token:${TOKEN}@github.com/" \
    ISSUE="${ISSUE}" TITLE="${TITLE}" MODULE="${MODULE}" \
    SELECT_OUTCOME="${SELECT_OUTCOME}" SELECT_REASON="${SELECT_REASON}" \
    FIX_STATUS="${FIX_STATUS}" FIX_SUMMARY="${FIX_SUMMARY}" \
    VERIFY_RESULT="${VERIFY_RESULT}" VERIFY_REASON="${VERIFY_REASON}" \
    RUN_URL="${RUN_URL}" BASE_REF="${BASE_REF}" \
    GH_TOKEN="${TOKEN}" GITHUB_REPOSITORY=o/r GITHUB_OUTPUT="${OUT}" GITHUB_STEP_SUMMARY="${SUMMARY}" \
    sh "${SCRIPT}" > "${LOG}" 2>&1 ) || STATUS=$?
}

status_zero() { [ "${STATUS}" -eq 0 ]; }
out_has() { grep -Fxq "$1" "${OUT}"; }
out_no_outcome() { ! grep -q '^outcome=.' "${OUT}"; }
out_has_url() { grep -q '^url=.' "${OUT}"; }
calls_have() { grep -Fq -- "$1" "${CALLS}"; }
calls_match() { grep -Eq -- "$1" "${CALLS}"; }
calls_lack() { ! grep -Fq -- "$1" "${CALLS}"; }
calls_none() { [ ! -s "${CALLS}" ]; }
body_has() { grep -Fq -- "$2" "${BODIES}/$1" 2>/dev/null; }
body_line() { grep -Fxq -- "$2" "${BODIES}/$1" 2>/dev/null; }
no_branch() { ! git --git-dir="${BARE}" rev-parse --verify -q "refs/heads/fix/issue-${ISSUE}" > /dev/null; }
has_branch() { git --git-dir="${BARE}" rev-parse --verify -q "refs/heads/fix/issue-${ISSUE}" > /dev/null; }
main_untouched() { [ "$(git --git-dir="${BARE}" rev-parse main)" = "${MAIN_SHA}" ]; }
decoy_empty() { [ -z "$(git --git-dir="${DECOY}" for-each-ref)" ]; }

line_of() {
  grep -nE -- "$1" "${CALLS}" | head -n 1 | cut -d: -f1
}

before() {
  a="$(line_of "$1")"
  b="$(line_of "$2")"
  [ -n "${a}" ] && [ -n "${b}" ] && [ "${a}" -lt "${b}" ]
}

branch_field() {
  git --git-dir="${BARE}" log -1 --format="$1" "refs/heads/fix/issue-${ISSUE}" 2>/dev/null
}

branch_eq() {
  [ "$(branch_field "$1")" = "$2" ]
}

branch_len() {
  [ "$(branch_field %s | awk '{ print length($0) }')" = "$1" ]
}

branch_files_are() {
  [ "$(git --git-dir="${BARE}" show --name-only --format= "refs/heads/fix/issue-${ISSUE}" 2>/dev/null | sort)" = "$1" ]
}

branch_blob_is() {
  [ "$(git --git-dir="${BARE}" show "refs/heads/fix/issue-${ISSUE}:$1" 2>/dev/null)" = "$2" ]
}

all_calls_authenticated() {
  [ "$(grep -c . "${CALLS}")" -eq "$(grep -cFx "${TOKEN}" "${TOKENS}")" ]
}

no_leak() {
  hit=0
  for f in "${LOG}" "${CALLS}" "${OUT}" "${SUMMARY}" "${CWD}/.git/config" "${BODIES}"/*; do
    if [ -f "${f}" ] && grep -qF "${TOKEN}" "${f}"; then hit=1; fi
  done
  if ( cd "${CWD}" && git remote -v | grep -qF "${TOKEN}" ); then hit=1; fi
  [ "${hit}" -eq 0 ]
}

expected_subject() {
  printf '%s' "fix: #${ISSUE} ${TITLE}" | cut -c1-60
}

common() {
  ok "$1: status 0" status_zero
  ok "$1: token never leaks" no_leak
}

setup
run
common "opened"
ok "opened: outcome" out_has "outcome=opened"
ok "opened: url" out_has "url=${PR_URL}"
ok "opened: branch created on the authenticated remote" has_branch
ok "opened: decoy origin untouched" decoy_empty
ok "opened: main untouched" main_untouched
ok "opened: parent is main" branch_eq "%P" "${MAIN_SHA}"
ok "opened: subject" branch_eq "%s" "fix: #7 bug: core broke"
ok "opened: author name" branch_eq "%an" "github-actions[bot]"
ok "opened: author email" branch_eq "%ae" "${BOT_EMAIL}"
ok "opened: committer name" branch_eq "%cn" "github-actions[bot]"
ok "opened: committer email" branch_eq "%ce" "${BOT_EMAIL}"
ok "opened: commit has only the patch files" branch_files_are "app.txt
modules/core/code/test/a_test.txt
modules/core/code/test/b_test.txt"
ok "opened: patch applied" branch_blob_is app.txt "fixed"
ok "opened: label created" calls_match 'label create autofix .*--force'
ok "opened: pr create base" calls_have "--base main"
ok "opened: pr create head" calls_have "--head fix/issue-7"
ok "opened: pr create label" calls_have "--label autofix"
ok "opened: pr body closes the issue" body_has pr-create "Fixes #7"
ok "opened: pr body summary" body_has pr-create "root cause fixed"
ok "opened: pr body first regression test" body_has pr-create "modules/core/code/test/a_test.txt"
ok "opened: pr body second regression test" body_has pr-create "modules/core/code/test/b_test.txt"
ok "opened: pr body run url" body_has pr-create "${RUN}"
ok "opened: pr body automerge line" body_has pr-create "${LINE}"
ok "opened: automerge" calls_match 'pr merge.*(/pull/9|[ ]9)( |$)'
ok "opened: automerge flags" calls_match 'pr merge.*--auto --merge'
ok "opened: comment call" calls_match 'issue comment 7'
ok "opened: comment body" body_line issue-comment "[autofix] opened ${PR_URL}"
ok "opened: no failed label" calls_lack "autofix:failed"
ok "opened: label before pr" before 'label create autofix ' 'pr create'
ok "opened: pr before merge" before 'pr create' 'pr merge'
ok "opened: merge before comment" before 'pr merge' 'issue comment'
ok "opened: every gh call used the pat" all_calls_authenticated

setup
BASE_REF=release/x
run
common "dispatch base"
ok "dispatch base: pr targets the ref" calls_have "--base release/x"

setup
TITLE="abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij"
run
common "long title"
ok "long title: outcome" out_has "outcome=opened"
ok "long title: subject is the first 60 chars" branch_eq "%s" "$(expected_subject)"
ok "long title: subject length 60" branch_len 60

setup
TITLE="abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijab"
run
common "title fitting 60"
ok "title fitting 60: kept whole" branch_eq "%s" "fix: #7 ${TITLE}"

setup
TITLE="abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabX"
run
common "title one over"
ok "title one over: truncated" branch_eq "%s" "fix: #7 abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijab"

setup
: > "${MERGE_FAIL}"
run
common "automerge unavailable"
ok "automerge unavailable: outcome stays opened" out_has "outcome=opened"
ok "automerge unavailable: url" out_has "url=${PR_URL}"
ok "automerge unavailable: branch pushed" has_branch
ok "automerge unavailable: pr created" calls_have "pr create"
ok "automerge unavailable: merge attempted" calls_have "pr merge"
ok "automerge unavailable: comment" body_line issue-comment "[autofix] opened ${PR_URL} (auto-merge unavailable: enable \"Allow auto-merge\")"
ok "automerge unavailable: no failed label" calls_lack "autofix:failed"

setup
FIX_STATUS=gave_up
FIX_SUMMARY="cannot reproduce"
VERIFY_RESULT=skipped
run
common "gave up"
ok "gave up: outcome" out_has "outcome=gave up"
ok "gave up: url output present" out_has_url
ok "gave up: no branch" no_branch
ok "gave up: main untouched" main_untouched
ok "gave up: no pr" calls_lack "pr create"
ok "gave up: comment call" calls_match 'issue comment 7'
ok "gave up: comment body" body_line issue-comment "[autofix] gave up: cannot reproduce"
ok "gave up: label created" calls_match 'label create autofix:failed .*--force'
ok "gave up: label applied" calls_match 'issue edit 7 .*--add-label autofix:failed'
ok "gave up: no plain autofix label" calls_lack "label create autofix "

setup
FIX_STATUS=gave_up
VERIFY_RESULT=success
run
common "gave up with verify success"
ok "gave up with verify success: verify wins" out_has "outcome=opened"

setup
SELECT_OUTCOME=rejected
SELECT_REASON="missing module:<m> label"
FIX_STATUS=""
VERIFY_RESULT=skipped
run
common "rejected by select"
ok "rejected by select: outcome" out_has "outcome=rejected"
ok "rejected by select: url output present" out_has_url
ok "rejected by select: no branch" no_branch
ok "rejected by select: no pr" calls_lack "pr create"
ok "rejected by select: comment body" body_line issue-comment "[autofix] rejected: missing module:<m> label (${RUN})"
ok "rejected by select: label created" calls_match 'label create autofix:failed .*--force'
ok "rejected by select: label applied" calls_match 'issue edit 7 .*--add-label autofix:failed'

setup
SELECT_OUTCOME=rejected
SELECT_REASON="unknown module 'ghost'"
VERIFY_RESULT=success
run
common "select rejection wins"
ok "select rejection wins: outcome" out_has "outcome=rejected"
ok "select rejection wins: no branch" no_branch
ok "select rejection wins: no push" decoy_empty
ok "select rejection wins: comment body" body_line issue-comment "[autofix] rejected: unknown module 'ghost' (${RUN})"

setup
VERIFY_RESULT=failure
VERIFY_REASON="regression test passed before the fix"
run
common "rejected by verify"
ok "rejected by verify: outcome" out_has "outcome=rejected"
ok "rejected by verify: no branch" no_branch
ok "rejected by verify: no pr" calls_lack "pr create"
ok "rejected by verify: comment body" body_line issue-comment "[autofix] rejected: regression test passed before the fix (${RUN})"
ok "rejected by verify: label created" calls_match 'label create autofix:failed .*--force'
ok "rejected by verify: label applied" calls_match 'issue edit 7 .*--add-label autofix:failed'

setup
FIX_STATUS=gave_up
VERIFY_RESULT=failure
VERIFY_REASON="test failed with the fix"
run
common "verify failure beats gave up"
ok "verify failure beats gave up: outcome" out_has "outcome=rejected"
ok "verify failure beats gave up: comment body" body_line issue-comment "[autofix] rejected: test failed with the fix (${RUN})"

setup
FIX_STATUS=failed
VERIFY_RESULT=skipped
run
common "failed"
ok "failed: outcome" out_has "outcome=failed"
ok "failed: url output present" out_has_url
ok "failed: no branch" no_branch
ok "failed: no pr" calls_lack "pr create"
ok "failed: comment body" body_line issue-comment "[autofix] failed (${RUN})"
ok "failed: label created" calls_match 'label create autofix:failed .*--force'
ok "failed: label applied" calls_match 'issue edit 7 .*--add-label autofix:failed'

setup
FIX_STATUS=""
VERIFY_RESULT=cancelled
run
common "cancelled"
ok "cancelled: outcome" out_has "outcome=failed"
ok "cancelled: no branch" no_branch
ok "cancelled: comment body" body_line issue-comment "[autofix] failed (${RUN})"

setup
FIX_STATUS=""
VERIFY_RESULT=""
run
common "nothing ran"
ok "nothing ran: outcome" out_has "outcome=failed"
ok "nothing ran: comment body" body_line issue-comment "[autofix] failed (${RUN})"

setup
printf 'not a patch\n' > "${CWD}/.autofix/fix.patch"
run
ok "broken patch: token never leaks" no_leak
ok "broken patch: outcome" out_has "outcome=failed"
ok "broken patch: no branch" no_branch
ok "broken patch: no pr" calls_lack "pr create"
ok "broken patch: comment body" body_line issue-comment "[autofix] failed (${RUN})"
ok "broken patch: label applied" calls_match 'issue edit 7 .*--add-label autofix:failed'

setup
SELECT_OUTCOME=skipped
run
common "skipped"
ok "skipped: outcome empty" out_no_outcome
ok "skipped: no gh call" calls_none
ok "skipped: no branch" no_branch
ok "skipped: no push" decoy_empty
ok "skipped: main untouched" main_untouched

setup
SELECT_OUTCOME=skipped
FIX_STATUS=gave_up
VERIFY_RESULT=failure
run
ok "skipped beats everything: no gh call" calls_none
ok "skipped beats everything: outcome empty" out_no_outcome

echo "${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ]
