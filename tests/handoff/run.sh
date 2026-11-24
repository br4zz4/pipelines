#!/bin/sh
set -u

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="${ROOT}/actions/handoff/handoff.sh"
WORKFLOW="${ROOT}/.github/workflows/autofix.yml"
ACTION="${ROOT}/actions/handoff/action.yml"
WORK="$(cd -P "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0
STATUS=0
TOKEN=ghp_SECRETtoken0123456789
LOG="${WORK}/log"
CALLS="${WORK}/calls"
TOKENS="${WORK}/tokens"
BODIES="${WORK}/bodies"

mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gh" <<'GH'
#!/bin/sh
printf '%s\n' "$*" >> "${GH_CALLS}"
printf '%s\n' "${GH_TOKEN:-}" >> "${GH_TOKENS}"
mkdir -p "${GH_BODIES}"
prev=""
for arg in "$@"; do
  case "${prev}" in
    --body) printf '%s\n' "${arg}" >> "${GH_BODIES}/comment" ;;
    --body-file) if [ "${arg}" = "-" ]; then cat >> "${GH_BODIES}/comment"; else cat "${arg}" >> "${GH_BODIES}/comment"; fi ;;
  esac
  prev="${arg}"
done
if [ -n "${GH_FAIL_ON:-}" ] && [ "${1:-} ${2:-}" = "${GH_FAIL_ON}" ]; then
  echo "HTTP 403" >&2
  exit 1
fi
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

setup() {
  : > "${LOG}"
  : > "${CALLS}"
  : > "${TOKENS}"
  rm -rf "${BODIES}"
  ISSUE=7
  TOKEN_IN="${TOKEN}"
  FAIL_ON=""
}

run() {
  STATUS=0
  env PATH="${WORK}/bin:${PATH}" \
    GH_CALLS="${CALLS}" GH_TOKENS="${TOKENS}" GH_BODIES="${BODIES}" GH_FAIL_ON="${FAIL_ON}" \
    ISSUE="${ISSUE}" GH_TOKEN="${TOKEN_IN}" GITHUB_REPOSITORY=o/r \
    sh "${SCRIPT}" > "${LOG}" 2>&1 || STATUS=$?
}

run_without() {
  STATUS=0
  env -u ISSUE -u GH_TOKEN PATH="${WORK}/bin:${PATH}" \
    GH_CALLS="${CALLS}" GH_TOKENS="${TOKENS}" GH_BODIES="${BODIES}" GH_FAIL_ON="" \
    GITHUB_REPOSITORY=o/r \
    "${1}=${2}" \
    sh "${SCRIPT}" > "${LOG}" 2>&1 || STATUS=$?
}

status_zero() { [ "${STATUS}" -eq 0 ]; }
status_nonzero() { [ "${STATUS}" -ne 0 ]; }
calls_match() { grep -Eq -- "$1" "${CALLS}"; }
calls_lack() { ! grep -Fq -- "$1" "${CALLS}"; }
calls_none() { [ ! -s "${CALLS}" ]; }
comment_is() { [ "$(cat "${BODIES}/comment" 2>/dev/null)" = "$1" ]; }
tokens_all() { [ -s "${TOKENS}" ] && [ "$(sort -u "${TOKENS}")" = "$1" ]; }
no_leak() { ! grep -Fq "${TOKEN}" "${LOG}"; }

line_of() {
  grep -nE -- "$1" "${CALLS}" | head -n 1 | cut -d: -f1
}

ordered() {
  a="$(line_of "$1")"
  b="$(line_of "$2")"
  c="$(line_of "$3")"
  [ -n "${a}" ] && [ -n "${b}" ] && [ -n "${c}" ] && [ "${a}" -lt "${b}" ] && [ "${b}" -lt "${c}" ]
}

setup
run
ok "handoff: exits zero" status_zero
ok "handoff: creates the label" calls_match '^label create fix:requested --force .*-R o/r|^label create fix:requested .*--force .*-R o/r'
ok "handoff: applies the label to the issue" calls_match '^issue edit 7 .*--add-label fix:requested|^issue edit 7 --add-label fix:requested'
ok "handoff: comments on the issue" calls_match '^issue comment 7 .*-R o/r.*--body-file'
ok "handoff: label, edit, comment in order" ordered '^label create' '^issue edit' '^issue comment'
ok "handoff: comment text" comment_is "[autofix] handed off to fix"
ok "handoff: token propagated to every call" tokens_all "${TOKEN}"
ok "handoff: token never leaks" no_leak
ok "handoff: three gh calls" test "$(wc -l < "${CALLS}" | tr -d ' ')" = 3

setup
FAIL_ON="label create"
run
ok "label create failure: tolerated" status_zero
ok "label create failure: still edits" calls_match '^issue edit 7'
ok "label create failure: still comments" calls_match '^issue comment 7'
ok "label create failure: comment text" comment_is "[autofix] handed off to fix"

setup
FAIL_ON="issue edit"
run
ok "edit failure: exits non-zero" status_nonzero
ok "edit failure: no comment" calls_lack "issue comment"
ok "edit failure: token never leaks" no_leak

setup
TOKEN_IN=""
run
ok "no token: exits non-zero" status_nonzero
ok "no token: no gh call" calls_none

setup
ISSUE=""
run
ok "no issue: exits non-zero" status_nonzero
ok "no issue: no gh call" calls_none

setup
run_without GH_TOKEN "${TOKEN}"
ok "unset issue: exits non-zero" status_nonzero
ok "unset issue: no gh call" calls_none

setup
run_without ISSUE 7
ok "unset token: exits non-zero" status_nonzero
ok "unset token: no gh call" calls_none

yq() {
  python3 -I -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
sys.exit(0 if eval(sys.argv[2]) else 1)' "$1" "$2"
}

ok "action: file exists" test -f "${ACTION}"
ok "action: script exists" test -f "${SCRIPT}"
ok "action: composite" yq "${ACTION}" "d['runs']['using'] == 'composite'"
ok "action: token input required" yq "${ACTION}" "d['inputs']['token']['required'] is True"
ok "action: issue input required" yq "${ACTION}" "d['inputs']['issue']['required'] is True"

ok "workflow: handoff input is boolean default false" yq "${WORKFLOW}" \
  "d[True]['workflow_call']['inputs']['handoff']['type'] == 'boolean' and d[True]['workflow_call']['inputs']['handoff']['default'] is False"
ok "workflow: publish exports outcome" yq "${WORKFLOW}" \
  "'outcome' in d['jobs']['publish']['outputs']"
ok "workflow: publish skips blocked" yq "${WORKFLOW}" \
  "'blocked' in d['jobs']['publish']['if'] and 'skipped' in d['jobs']['publish']['if']"
ok "workflow: handoff needs select and publish" yq "${WORKFLOW}" \
  "sorted(d['jobs']['handoff']['needs']) == ['publish', 'select']"
ok "workflow: handoff requires the input" yq "${WORKFLOW}" \
  "'inputs.handoff' in d['jobs']['handoff']['if']"
ok "workflow: handoff runs on blocked" yq "${WORKFLOW}" \
  "\"needs.select.outputs.outcome == 'blocked'\" in d['jobs']['handoff']['if']"
ok "workflow: handoff runs on selected with a failed publish" yq "${WORKFLOW}" \
  "\"needs.select.outputs.outcome == 'selected'\" in d['jobs']['handoff']['if'] and all(x in d['jobs']['handoff']['if'] for x in ('gave up', 'rejected', 'failed')) and 'needs.publish.outputs.outcome' in d['jobs']['handoff']['if']"
ok "workflow: handoff scopes ci.common" yq "${WORKFLOW}" \
  "any(s.get('uses', '').startswith('br4zz4/setup-ward@') and s['with']['scopes'] == '\${{ inputs.vault }}:secrets.ci.common' for s in d['jobs']['handoff']['steps'])"
ok "workflow: ward step precedes the handoff action" yq "${WORKFLOW}" \
  "[i for i, s in enumerate(d['jobs']['handoff']['steps']) if s.get('uses', '').startswith('br4zz4/setup-ward@')][0] < [i for i, s in enumerate(d['jobs']['handoff']['steps']) if s.get('uses', '').startswith('br4zz4/pipelines/actions/handoff@v2')][0]"
ok "workflow: handoff uses the PAT" yq "${WORKFLOW}" \
  "any(s.get('uses', '') == 'br4zz4/pipelines/actions/handoff@v2' and s['with']['token'] == '\${{ env.GH_PIPELINES_TOKEN }}' and s['with'].get('issue') for s in d['jobs']['handoff']['steps'])"

ok "workflow: handoff uses contains with a JSON list" yq "${WORKFLOW}" \
  "\"contains(fromJSON('[\\\"gave up\\\",\\\"rejected\\\",\\\"failed\\\"]'), needs.publish.outputs.outcome)\" in d['jobs']['handoff']['if']"

table() {
  python3 -I - "${WORKFLOW}" <<'PY'
import json
import re
import sys

import yaml

condition = yaml.safe_load(open(sys.argv[1]))["jobs"]["handoff"]["if"].strip()
condition = re.sub(r"^\$\{\{\s*|\s*\}\}$", "", condition)
condition = re.sub(r"contains\(fromJSON\('(\[.*?\])'\),\s*([^)]+)\)", lambda m: "(%s in %s)" % (m.group(2), json.loads(m.group(1)).__repr__()), condition)
condition = condition.replace("&&", " and ").replace("||", " or ")
condition = condition.replace("always()", "True")
condition = condition.replace("needs.select.outputs.outcome", "select_outcome")
condition = condition.replace("needs.publish.outputs.outcome", "publish_outcome")
condition = condition.replace("inputs.handoff", "handoff")

rows = [
    (True, "blocked", "", True),
    (True, "blocked", "opened", True),
    (True, "selected", "gave up", True),
    (True, "selected", "rejected", True),
    (True, "selected", "failed", True),
    (True, "selected", "opened", False),
    (True, "selected", "", False),
    (True, "rejected", "rejected", False),
    (True, "rejected", "", False),
    (True, "skipped", "", False),
    (True, "skipped", "failed", False),
    (False, "blocked", "", False),
    (False, "selected", "gave up", False),
    (False, "selected", "failed", False),
]
bad = 0
for handoff, select_outcome, publish_outcome, want in rows:
    got = bool(eval(condition, {}, {"handoff": handoff, "select_outcome": select_outcome, "publish_outcome": publish_outcome}))
    label = "handoff=%s select=%r publish=%r" % (handoff, select_outcome, publish_outcome)
    if got == want:
        print("PASS table: %s -> %s" % (label, "yes" if want else "no"))
    else:
        print("FAIL table: %s -> %s, want %s" % (label, got, want))
        bad += 1
sys.exit(1 if bad else 0)
PY
}

table_out="$(table 2>&1)"
table_status=$?
printf '%s\n' "${table_out}"
table_pass="$(printf '%s\n' "${table_out}" | grep -c '^PASS table')"
table_fail="$(printf '%s\n' "${table_out}" | grep -c '^FAIL table')"
PASSED=$(( PASSED + table_pass ))
FAILED=$(( FAILED + table_fail ))
if [ "${table_status}" -ne 0 ] && [ "${table_fail}" -eq 0 ]; then fail "table: evaluator crashed"; fi

echo "${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ]
