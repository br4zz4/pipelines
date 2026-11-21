#!/bin/sh
set -u

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="${ROOT}/actions/issue/issue.py"
FIX="${ROOT}/tests/issue/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0
OUT="${WORK}/output"
LOG="${WORK}/log"
CALLS="${WORK}/calls"
BODIES="${WORK}/bodies"
SUMMARY="${WORK}/summary"
CWD="${WORK}/cwd"
STATUS=0
MODULES='{"core":{"code":"modules/core/code","services":"postgres"},"web":{"code":"modules/web/code"}}'

mkdir -p "${WORK}/bin" "${CWD}" "${WORK}/jobs"
cat > "${WORK}/bin/gh" <<'GH'
#!/bin/sh
printf '%s\n' "$*" >> "${GH_CALLS}"
prev=""
for arg in "$@"; do
  case "${prev}" in
    --body) printf '%s\n' "${arg}" >> "${GH_BODIES}" ;;
    --body-file) if [ "${arg}" = "-" ]; then cat >> "${GH_BODIES}"; else cat "${arg}" >> "${GH_BODIES}"; fi ;;
  esac
  prev="${arg}"
done
case "${1:-} ${2:-}" in
  "issue comment") exit 0 ;;
  "api repos/o/r/issues/"*"/comments"*) cat "${GH_COMMENTS}" ;;
  "api repos/o/r/issues/"*) cat "${GH_ISSUE}" ;;
  "api repos/o/r/collaborators/"*)
    login="${2#repos/o/r/collaborators/}"
    login="${login%%/*}"
    if [ -f "${GH_PERMS}/${login}.json" ]; then cat "${GH_PERMS}/${login}.json"; else echo '{"message":"Not Found"}' >&2; exit 1; fi ;;
  "api repos/o/r/pulls"*) cat "${GH_PULLS}" ;;
  "api repos/o/r/actions/workflows/autofix.yml/runs"*) cat "${GH_RUNS}" ;;
  "api repos/o/r/actions/runs/"*)
    id="${2#repos/o/r/actions/runs/}"
    id="${id%%/*}"
    cat "${GH_JOBS}/${id}.json" ;;
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

mkissue() {
  python3 - "$@" <<'PY' > "${ISSUE}"
import json, sys
state, title, body, *labels = sys.argv[1:]
print(json.dumps({
    "number": 7,
    "state": state,
    "title": title,
    "body": body,
    "html_url": "https://github.com/o/r/issues/7",
    "labels": [{"name": name} for name in labels],
}))
PY
}

mkcomments() {
  python3 - "$@" <<'PY' > "${COMMENTS}"
import json, sys
out = []
for spec in sys.argv[1:]:
    assoc, body = spec.split(":", 1)
    out.append({
        "author_association": assoc,
        "body": body,
        "created_at": "2026-11-21T10:00:%02dZ" % len(out),
        "user": {"login": "u%d" % len(out)},
    })
print(json.dumps(out))
PY
}

mkruns() {
  python3 - "$1" "$2" "${WORK}/jobs" > "${RUNS}" <<'PY'
import json, sys
count, statuses, jobs = int(sys.argv[1]), sys.argv[2].split(","), sys.argv[3]
runs = []
for index in range(count):
    run_id = 100 + index
    runs.append({"id": run_id, "created_at": "2026-11-21T09:00:00Z"})
    status = statuses[index % len(statuses)]
    jobset = [{"name": "autofix / conform", "conclusion": "success"}, {"name": "autofix / select", "conclusion": "success"}]
    jobset.append({"name": "autofix / fix", "conclusion": status})
    with open("%s/%d.json" % (jobs, run_id), "w") as handle:
        json.dump({"jobs": jobset}, handle)
print(json.dumps({"workflow_runs": runs}))
PY
}

setup() {
  unset SENDER ACTOR EVENT MAX MODS
  : > "${OUT}"
  : > "${LOG}"
  : > "${CALLS}"
  : > "${BODIES}"
  : > "${SUMMARY}"
  rm -rf "${CWD}/.autofix" "${WORK}/jobs"
  mkdir -p "${WORK}/jobs"
  ISSUE="${WORK}/issue.json"
  COMMENTS="${WORK}/comments.json"
  RUNS="${WORK}/runs.json"
  cp "${FIX}/runs_empty.json" "${RUNS}"
  PULLS="${FIX}/pulls_none.json"
  mkissue open "bug: core broke" "it breaks" urgency:critical module:core
  echo '[]' > "${COMMENTS}"
}

run() {
  STATUS=0
  ( cd "${CWD}" && PATH="${WORK}/bin:${PATH}" GH_CALLS="${CALLS}" GH_BODIES="${BODIES}" \
    GH_ISSUE="${ISSUE}" GH_COMMENTS="${COMMENTS}" GH_PERMS="${FIX}/perms" GH_PULLS="${PULLS}" \
    GH_RUNS="${RUNS}" GH_JOBS="${WORK}/jobs" \
    GITHUB_REPOSITORY=o/r GH_TOKEN=tok GITHUB_OUTPUT="${OUT}" GITHUB_STEP_SUMMARY="${SUMMARY}" \
    GITHUB_ACTOR="${ACTOR:-alice}" \
    python3 "${SCRIPT}" "$@" > "${LOG}" 2>&1 ) || STATUS=$?
}

run_select() {
  run select --issue 7 --event "${EVENT:-issues}" --sender "${SENDER:-alice}" --max-per-day "${MAX:-0}" --modules "${MODS:-${MODULES}}"
  unset SENDER ACTOR EVENT MAX MODS
}

expect_ok() {
  if [ "${STATUS}" -ne 0 ]; then
    fail "${1}: exit ${STATUS}: $(cat "${LOG}")"
    return 1
  fi
  return 0
}

out_is() {
  grep -qxF -- "${2}" "${OUT}" && pass "${1}" || fail "${1}: want '${2}' in: $(cat "${OUT}")"
}

out_lacks() {
  if grep -q -- "^${2}=" "${OUT}"; then
    fail "${1}: unexpected '${2}' in: $(cat "${OUT}")"
  else
    pass "${1}"
  fi
}

calls_have() {
  grep -qF -- "${2}" "${CALLS}" && pass "${1}" || fail "${1}: missing '${2}' in: $(cat "${CALLS}")"
}

no_comment() {
  if grep -q '^issue comment' "${CALLS}"; then
    fail "${1}: unexpected comment: $(cat "${CALLS}")"
  else
    pass "${1}"
  fi
}

body_have() {
  grep -qF -- "${2}" "${BODIES}" && pass "${1}" || fail "${1}: comment lacks '${2}': $(cat "${BODIES}")"
}

summary_have() {
  grep -qF -- "${2}" "${SUMMARY}" && pass "${1}" || fail "${1}: summary lacks '${2}': $(cat "${SUMMARY}")"
}

no_issue_json() {
  [ ! -e "${CWD}/.autofix/issue.json" ] && pass "${1}" || fail "${1}: issue.json written"
}

jcheck() {
  python3 - "${CWD}/.autofix/issue.json" "${2}" <<'PY' && pass "${1}" || fail "${1}"
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if eval(sys.argv[2]) else 1)
PY
}

skipped() {
  name="${1}"
  reason="${2}"
  if expect_ok "${name}"; then
    out_is "${name}: outcome" "outcome=skipped"
    out_is "${name}: reason" "reason=${reason}"
    summary_have "${name}: summary" "${reason}"
    out_lacks "${name}: no module output" "module"
    no_issue_json "${name}: no issue.json"
  fi
}

setup
run_select
if expect_ok "selected"; then
  out_is "selected: outcome" "outcome=selected"
  out_is "selected: issue" "issue=7"
  out_is "selected: title" "title=bug: core broke"
  out_is "selected: url" "url=https://github.com/o/r/issues/7"
  out_is "selected: module" "module=core"
  out_is "selected: code_dir" "code_dir=modules/core/code"
  out_is "selected: services" "services=postgres"
  no_comment "selected: no comment"
  jcheck "selected: issue.json number" "d['number'] == 7"
  jcheck "selected: issue.json title" "d['title'] == 'bug: core broke'"
  jcheck "selected: issue.json body" "d['body'] == 'it breaks'"
  jcheck "selected: issue.json labels" "sorted(d['labels']) == ['module:core', 'urgency:critical']"
  jcheck "selected: issue.json comments empty" "d['comments'] == []"
fi

setup
mkissue open "bug: web broke" "b" urgency:critical module:web
run_select
if expect_ok "module without services"; then
  out_is "module without services: outcome" "outcome=selected"
  out_is "module without services: module" "module=web"
  out_is "module without services: code_dir" "code_dir=modules/web/code"
  out_is "module without services: services empty" "services="
fi

setup
mkissue closed "bug: core broke" "b" urgency:critical module:core
run_select
skipped "closed issue" "not an open critical issue"
no_comment "closed issue: no comment"

setup
mkissue open "bug: core broke" "b" module:core
run_select
skipped "no urgency label" "not an open critical issue"
no_comment "no urgency label: no comment"

setup
mkissue open "bug: core broke" "b" urgency:critical module:core autofix:blocked
run_select
skipped "blocked" "blocked: needs a human"
no_comment "blocked: no comment"

setup
mkissue closed "bug: core broke" "b" urgency:critical module:core autofix:blocked
run_select
skipped "closed wins over blocked" "not an open critical issue"

setup
mkissue open "bug: core broke" "b" urgency:critical module:core autofix:blocked
SENDER=bob run_select
skipped "blocked wins over permission" "blocked: needs a human"
no_comment "blocked wins over permission: no comment"

for who in alice mona root; do
  setup
  SENDER="${who}" run_select
  if expect_ok "permission ${who}"; then
    out_is "permission ${who}: selected" "outcome=selected"
    no_comment "permission ${who}: no comment"
  fi
done

for who in bob tri eve ghost; do
  setup
  SENDER="${who}" run_select
  if expect_ok "permission ${who}"; then
    out_is "permission ${who}: outcome" "outcome=skipped"
    calls_have "permission ${who}: comment call" "issue comment 7"
    body_have "permission ${who}: comment body" "[autofix] ignored: ${who} cannot trigger the autofix"
    no_issue_json "permission ${who}: no issue.json"
  fi
done

setup
SENDER=bob run_select
calls_have "permission read: queried the sender" "repos/o/r/collaborators/bob/permission"

setup
SENDER=bob ACTOR=alice EVENT=workflow_dispatch run_select
if expect_ok "dispatch uses actor"; then
  out_is "dispatch uses actor: selected" "outcome=selected"
  calls_have "dispatch uses actor: queried the actor" "repos/o/r/collaborators/alice/permission"
  no_comment "dispatch uses actor: no comment"
fi

setup
SENDER=alice ACTOR=bob EVENT=workflow_dispatch run_select
if expect_ok "dispatch actor without write"; then
  out_is "dispatch actor without write: outcome" "outcome=skipped"
  body_have "dispatch actor without write: comment" "[autofix] ignored: bob cannot trigger the autofix"
fi

setup
mkissue open "bug: core broke" "b" urgency:critical
run_select
if expect_ok "missing module label"; then
  out_is "missing module label: outcome" "outcome=rejected"
  calls_have "missing module label: comment call" "issue comment 7"
  body_have "missing module label: comment body" "[autofix] rejected: missing module:<m> label"
  no_issue_json "missing module label: no issue.json"
fi

setup
mkissue open "bug: core broke" "b" urgency:critical module:ghost
run_select
if expect_ok "unknown module"; then
  out_is "unknown module: outcome" "outcome=rejected"
  calls_have "unknown module: comment call" "issue comment 7"
  body_have "unknown module: comment body" "[autofix] rejected: unknown module 'ghost'"
  no_issue_json "unknown module: no issue.json"
fi

setup
mkissue open "bug: core broke" "b" urgency:critical module:core module:web
run_select
if expect_ok "two module labels"; then
  out_is "two module labels: outcome" "outcome=rejected"
  body_have "two module labels: comment prefix" "[autofix] rejected:"
  no_issue_json "two module labels: no issue.json"
fi

setup
mkissue open "bug: core broke" "b" urgency:critical module:core
MODS='{"core":{"code":"modules/core/code"}}' run_select
if expect_ok "single-module project with the label"; then
  out_is "single-module project with the label: selected" "outcome=selected"
fi

setup
mkissue open "bug: core broke" "b" urgency:critical
MODS='{"core":{"code":"modules/core/code"}}' run_select
if expect_ok "single-module project without the label"; then
  out_is "single-module project without the label: rejected" "outcome=rejected"
  body_have "single-module project without the label: comment" "[autofix] rejected: missing module:<m> label"
fi

setup
mkissue open "bug: core broke" "b" urgency:critical
SENDER=bob run_select
if expect_ok "permission before module"; then
  out_is "permission before module: skipped" "outcome=skipped"
  body_have "permission before module: ignored comment" "[autofix] ignored: bob cannot trigger the autofix"
fi

for pulls in pulls_closed pulls_open pulls_merged; do
  setup
  PULLS="${FIX}/${pulls}.json"
  run_select
  skipped "dedup ${pulls}" "already attempted"
  no_comment "dedup ${pulls}: no comment"
done

setup
run_select
calls_have "dedup: queries all states" "state=all"
calls_have "dedup: queries the head branch" "fix/issue-7"

setup
PULLS="${FIX}/pulls_closed.json"
EVENT=workflow_dispatch run_select
if expect_ok "dispatch ignores dedup"; then
  out_is "dispatch ignores dedup: selected" "outcome=selected"
  out_is "dispatch ignores dedup: issue" "issue=7"
fi

setup
mkruns 20 success
MAX=20 run_select
skipped "cap 20/20" "daily cap reached (20/20)"
no_comment "cap 20/20: no comment"

setup
mkruns 3 success,failure,cancelled
MAX=3 run_select
skipped "cap counts every non-skipped conclusion" "daily cap reached (3/3)"

setup
mkruns 3 success,failure,skipped
MAX=3 run_select
if expect_ok "cap below with skipped runs"; then
  out_is "cap below with skipped runs: selected" "outcome=selected"
fi

setup
mkruns 5 skipped
MAX=1 run_select
if expect_ok "cap only skipped runs"; then
  out_is "cap only skipped runs: selected" "outcome=selected"
fi

setup
mkruns 30 success
MAX=0 run_select
if expect_ok "cap disabled with 0"; then
  out_is "cap disabled with 0: selected" "outcome=selected"
fi

setup
mkruns 25 success
MAX=26 run_select
if expect_ok "cap not reached"; then
  out_is "cap not reached: selected" "outcome=selected"
fi

setup
mkruns 20 success
MAX=20 run_select
calls_have "cap: queries the autofix workflow runs" "actions/workflows/autofix.yml/runs"
calls_have "cap: queries the jobs of a run" "actions/runs/100/jobs"

setup
mkruns 20 success
PULLS="${FIX}/pulls_closed.json"
MAX=20 run_select
skipped "dedup before cap" "already attempted"

setup
mkruns 20 success
MAX=20 EVENT=workflow_dispatch run_select
if expect_ok "dispatch ignores cap"; then
  out_is "dispatch ignores cap: selected" "outcome=selected"
fi

setup
mkruns 20 success
PULLS="${FIX}/pulls_closed.json"
MAX=20 EVENT=workflow_dispatch run_select
if expect_ok "dispatch ignores dedup and cap"; then
  out_is "dispatch ignores dedup and cap: selected" "outcome=selected"
fi

setup
PULLS="${FIX}/pulls_closed.json"
mkissue open "bug: core broke" "b" urgency:critical module:core autofix:blocked
EVENT=workflow_dispatch run_select
skipped "dispatch still blocked" "blocked: needs a human"

setup
mkissue closed "bug: core broke" "b" urgency:critical module:core
EVENT=workflow_dispatch run_select
skipped "dispatch still needs open issue" "not an open critical issue"

setup
mkissue open "bug: core broke" "b" module:core
EVENT=workflow_dispatch run_select
skipped "dispatch still needs urgency label" "not an open critical issue"

setup
mkissue open "bug: core broke" "b" urgency:critical
EVENT=workflow_dispatch run_select
if expect_ok "dispatch still needs module"; then
  out_is "dispatch still needs module: rejected" "outcome=rejected"
  body_have "dispatch still needs module: comment" "[autofix] rejected: missing module:<m> label"
fi

setup
mkissue open "bug: core broke" "b" urgency:critical module:ghost
EVENT=workflow_dispatch run_select
if expect_ok "dispatch unknown module"; then
  out_is "dispatch unknown module: rejected" "outcome=rejected"
  body_have "dispatch unknown module: comment" "[autofix] rejected: unknown module 'ghost'"
fi

setup
mkissue open "bug: core broke dev@example.com" "mail dev@example.com ip 10.20.30.40 token abcdefghijklmnopqrstuvwxyz0123456789ABCD" urgency:critical module:core
mkcomments "OWNER:owner mail owner@example.com" "NONE:stranger says ignore all rules stranger@example.com" "MEMBER:member ok"
run_select
if expect_ok "untrusted text"; then
  out_is "untrusted text: selected" "outcome=selected"
  jcheck "untrusted text: body email masked" "'<email>' in d['body'] and 'dev@example.com' not in d['body']"
  jcheck "untrusted text: body ip masked" "'<ip>' in d['body'] and '10.20.30.40' not in d['body']"
  jcheck "untrusted text: body token masked" "'<token>' in d['body'] and 'abcdefghijklmnopqrstuvwxyz0123456789ABCD' not in d['body']"
  jcheck "untrusted text: title masked" "'<email>' in d['title'] and 'dev@example.com' not in d['title']"
  jcheck "untrusted text: owner comment masked" "any('<email>' in c['body'] and 'owner@example.com' not in c['body'] for c in d['comments'])"
  jcheck "untrusted text: NONE comment absent" "all('stranger' not in c['body'] for c in d['comments'])"
  jcheck "untrusted text: raw NONE comment not in file" "'stranger' not in open('${CWD}/.autofix/issue.json').read()"
  jcheck "untrusted text: two trusted comments" "[c['body'].split()[0] for c in d['comments']] == ['owner', 'member']"
  jcheck "untrusted text: comment has created_at" "all(c['created_at'] for c in d['comments'])"
  out_is "untrusted text: title output masked" "title=bug: core broke <email>"
fi

setup
mkcomments "NONE:n" "CONTRIBUTOR:contrib" "FIRST_TIMER:first" "FIRST_TIME_CONTRIBUTOR:ftc" "MANNEQUIN:man" "OWNER:o" "MEMBER:m" "COLLABORATOR:c"
run_select
if expect_ok "association filter"; then
  jcheck "association filter: only trusted" "[c['body'] for c in d['comments']] == ['o', 'm', 'c']"
fi

setup
python3 - "${COMMENTS}" <<'PY'
import json, sys
out = []
for index in range(1, 31):
    assoc = "NONE" if index % 5 == 0 else "MEMBER"
    out.append({"author_association": assoc, "body": "c%02d" % index, "created_at": "2026-11-21T10:00:%02dZ" % index})
json.dump(out, open(sys.argv[1], "w"))
PY
run_select
if expect_ok "last 20 comments"; then
  jcheck "last 20 comments: count" "len(d['comments']) == 20"
  jcheck "last 20 comments: newest kept, oldest dropped" "[c['body'] for c in d['comments']] == ['c%02d' % i for i in range(1, 31) if i % 5 != 0][-20:]"
fi

setup
python3 -c "print('y ' * 15000, end='')" > "${WORK}/big.txt"
python3 - "${ISSUE}" "${COMMENTS}" "${WORK}/big.txt" <<'PY'
import json, sys
big = open(sys.argv[3]).read()
issue = json.load(open(sys.argv[1]))
issue["body"] = big
json.dump(issue, open(sys.argv[1], "w"))
json.dump([{"author_association": "OWNER", "body": big, "created_at": "2026-11-21T10:00:00Z"}], open(sys.argv[2], "w"))
PY
run_select
if expect_ok "truncation"; then
  jcheck "truncation: body capped at 20000" "19000 < len(d['body']) <= 20000"
  jcheck "truncation: comment capped at 4000" "3500 < len(d['comments'][0]['body']) <= 4000"
fi

setup
python3 -c "print('z ' * 50, end='')" > "${WORK}/short.txt"
mkissue open "bug: core broke" "$(cat "${WORK}/short.txt")" urgency:critical module:core
run_select
if expect_ok "short body untouched"; then
  jcheck "short body untouched: full length" "len(d['body']) == 100"
fi

setup
run_select
if expect_ok "reason is skipped on selected"; then
  out_lacks "selected: no reason" "reason"
fi

echo "${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ]
