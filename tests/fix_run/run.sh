#!/bin/sh
set -u

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="${ROOT}/actions/fix-run/select.py"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0
OUT="${WORK}/output"
LOG="${WORK}/log"
CALLS="${WORK}/calls"
BODIES="${WORK}/bodies"
SUMMARY="${WORK}/summary"
EVENT_FILE="${WORK}/event.json"
RUNS="${WORK}/runs.json"
STATUS=0
MODULES='{"core":{"code":"modules/core/code","services":"postgres"},"web":{"code":"modules/web/code"}}'
SOLO='{"core":{"code":"modules/core/code","services":"postgres"}}'

mkdir -p "${WORK}/bin" "${WORK}/jobs"
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
  "api repos/o/r/actions/workflows/fix.yml/runs"*) cat "${GH_RUNS}" ;;
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

mkevent() {
  python3 - "$@" <<'PY' > "${EVENT_FILE}"
import json, sys
kind, action, label, state, *labels = sys.argv[1:]
holder = {"issue": "issue", "pr": "pull_request"}[kind]
data = {"action": action, holder: {"number": 7, "state": state, "labels": [{"name": n} for n in labels]}}
if label:
    data["label"] = {"name": label}
print(json.dumps(data))
PY
}

mkruns() {
  python3 - "${1}" "${2}" "${3:-issues}" "${WORK}/jobs" > "${RUNS}" <<'PY'
import json, sys
count, conclusions, event, jobs = int(sys.argv[1]), sys.argv[2].split(","), sys.argv[3], sys.argv[4]
runs = []
for index in range(count):
    run_id = 100 + index
    kind = event.split(",")[index % len(event.split(","))]
    runs.append({"id": run_id, "event": kind})
    conclusion = conclusions[index % len(conclusions)]
    jobset = [{"name": "fix", "steps": [{"name": "select", "conclusion": "success"}, {"name": "agent", "conclusion": conclusion}]}]
    with open("%s/%d.json" % (jobs, run_id), "w") as handle:
        json.dump({"jobs": jobset}, handle)
print(json.dumps({"workflow_runs": runs}))
PY
}

setup() {
  unset MAX MODS ENAME
  : > "${OUT}"
  : > "${LOG}"
  : > "${CALLS}"
  : > "${BODIES}"
  : > "${SUMMARY}"
  rm -rf "${WORK}/jobs"
  mkdir -p "${WORK}/jobs"
  echo '{"workflow_runs":[]}' > "${RUNS}"
  mkevent issue labeled fix:requested open module:core
}

run_select() {
  STATUS=0
  ( PATH="${WORK}/bin:${PATH}" GH_CALLS="${CALLS}" GH_BODIES="${BODIES}" GH_RUNS="${RUNS}" GH_JOBS="${WORK}/jobs" \
    GITHUB_EVENT_NAME="${ENAME:-issues}" GITHUB_EVENT_PATH="${EVENT_FILE}" GITHUB_REPOSITORY=o/r GH_TOKEN=tok \
    GITHUB_OUTPUT="${OUT}" GITHUB_STEP_SUMMARY="${SUMMARY}" \
    python3 "${SCRIPT}" --max-per-day "${MAX:-0}" --modules "${MODS:-${MODULES}}" > "${LOG}" 2>&1 ) || STATUS=$?
  unset MAX MODS ENAME
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

out_empty() {
  if grep -qx -- "${2}=" "${OUT}" || ! grep -q -- "^${2}=" "${OUT}"; then
    pass "${1}"
  else
    fail "${1}: '${2}' not empty in: $(cat "${OUT}")"
  fi
}

calls_have() {
  grep -qF -- "${2}" "${CALLS}" && pass "${1}" || fail "${1}: missing '${2}' in: $(cat "${CALLS}")"
}

calls_lack() {
  if grep -qF -- "${2}" "${CALLS}"; then
    fail "${1}: unexpected '${2}' in: $(cat "${CALLS}")"
  else
    pass "${1}"
  fi
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

setup
run_select
if expect_ok "label event below the cap"; then
  out_is "label event: outcome" "outcome=run"
  out_is "label event: number" "number=7"
  out_is "label event: module" "module=core"
  out_is "label event: code_dir" "code_dir=modules/core/code"
  out_is "label event: services" "services=postgres"
  no_comment "label event: no comment"
fi

setup
mkevent issue labeled fix:requested open module:web
run_select
if expect_ok "module without services"; then
  out_is "module without services: outcome" "outcome=run"
  out_is "module without services: module" "module=web"
  out_is "module without services: code_dir" "code_dir=modules/web/code"
  out_empty "module without services: services empty" "services"
fi

setup
mkruns 10 success
MAX=10 run_select
if expect_ok "cap reached"; then
  out_is "cap reached: outcome" "outcome=skip"
  out_is "cap reached: reason" "reason=daily cap reached (10/10)"
  calls_have "cap reached: comments on the issue" "issue comment 7 -R o/r --body-file"
  body_have "cap reached: comment body" "[fix] skipped: daily cap reached (10/10)"
  calls_have "cap reached: queries the fix workflow runs" "actions/workflows/fix.yml/runs"
  calls_have "cap reached: queries the jobs of a run" "actions/runs/100/jobs"
fi

setup
mkruns 3 success,failure,cancelled
MAX=3 run_select
if expect_ok "cap counts every non-skipped conclusion"; then
  out_is "cap counts every non-skipped conclusion: reason" "reason=daily cap reached (3/3)"
fi

setup
mkruns 4 success
MAX=3 run_select
if expect_ok "cap exceeded"; then
  out_is "cap exceeded: outcome" "outcome=skip"
  out_is "cap exceeded: reason" "reason=daily cap reached (4/3)"
  body_have "cap exceeded: comment body" "[fix] skipped: daily cap reached (4/3)"
fi

setup
mkruns 3 success,failure,skipped
MAX=3 run_select
if expect_ok "skipped agent runs do not count"; then
  out_is "skipped agent runs do not count: outcome" "outcome=run"
  no_comment "skipped agent runs do not count: no comment"
fi

setup
mkruns 5 skipped
MAX=1 run_select
if expect_ok "only skipped runs"; then
  out_is "only skipped runs: outcome" "outcome=run"
fi

setup
mkruns 4 success issues,issue_comment
MAX=3 run_select
if expect_ok "only issues runs count"; then
  out_is "only issues runs count: outcome" "outcome=run"
  no_comment "only issues runs count: no comment"
fi

setup
mkruns 6 success issues,issue_comment
MAX=3 run_select
if expect_ok "issues runs counted among others"; then
  out_is "issues runs counted among others: reason" "reason=daily cap reached (3/3)"
fi

setup
mkruns 4 success
MAX=5 run_select
if expect_ok "cap not reached"; then
  out_is "cap not reached: outcome" "outcome=run"
fi

setup
mkruns 30 success
MAX=0 run_select
if expect_ok "cap disabled with 0"; then
  out_is "cap disabled with 0: outcome" "outcome=run"
  calls_lack "cap disabled with 0: no runs query" "actions/workflows"
  no_comment "cap disabled with 0: no comment"
fi

setup
mkevent issue labeled fix:requested closed module:core
mkruns 30 success
MAX=3 run_select
if expect_ok "closed issue"; then
  out_is "closed issue: outcome" "outcome=skip"
  out_is "closed issue: reason" "reason=issue is not open"
  no_comment "closed issue: no comment"
fi

setup
mkevent issue labeled other open module:core
run_select
if expect_ok "other label"; then
  out_is "other label: outcome" "outcome=skip"
  no_comment "other label: no comment"
fi

setup
mkevent issue opened "" open module:core
run_select
if expect_ok "unexpected action"; then
  out_is "unexpected action: outcome" "outcome=skip"
  no_comment "unexpected action: no comment"
fi

setup
mkevent issue unlabeled fix:requested open module:core
run_select
if expect_ok "unlabeled action"; then
  out_is "unlabeled action: outcome" "outcome=skip"
fi

setup
mkruns 30 success
mkevent issue created "" open module:core
ENAME=issue_comment MAX=3 run_select
if expect_ok "issue_comment mention"; then
  out_is "issue_comment mention: outcome" "outcome=run"
  out_is "issue_comment mention: number" "number=7"
  out_is "issue_comment mention: module" "module=core"
  calls_lack "issue_comment mention: no runs query" "actions/workflows"
  calls_lack "issue_comment mention: no jobs query" "/jobs"
  no_comment "issue_comment mention: no comment"
fi

setup
mkruns 30 success
mkevent pr created "" open module:web
ENAME=pull_request_review_comment MAX=3 run_select
if expect_ok "pull_request_review_comment mention"; then
  out_is "pull_request_review_comment mention: outcome" "outcome=run"
  out_is "pull_request_review_comment mention: module from the PR" "module=web"
  out_is "pull_request_review_comment mention: code_dir" "code_dir=modules/web/code"
  calls_lack "pull_request_review_comment mention: no runs query" "actions/workflows"
  no_comment "pull_request_review_comment mention: no comment"
fi

setup
mkruns 30 success
mkevent pr submitted "" open module:core
ENAME=pull_request_review MAX=3 run_select
if expect_ok "pull_request_review mention"; then
  out_is "pull_request_review mention: outcome" "outcome=run"
  out_is "pull_request_review mention: module from the PR" "module=core"
  out_is "pull_request_review mention: services" "services=postgres"
  calls_lack "pull_request_review mention: no runs query" "actions/workflows"
fi

setup
mkevent issue created "" open
ENAME=issue_comment run_select
if expect_ok "issue_comment without module label and two modules"; then
  out_is "issue_comment without module label and two modules: outcome" "outcome=run"
  out_empty "issue_comment without module label and two modules: module empty" "module"
  out_empty "issue_comment without module label and two modules: code_dir empty" "code_dir"
  out_empty "issue_comment without module label and two modules: services empty" "services"
fi

setup
mkevent issue labeled fix:requested open
run_select
if expect_ok "no label and two modules"; then
  out_is "no label and two modules: outcome" "outcome=run"
  out_empty "no label and two modules: module empty" "module"
  out_empty "no label and two modules: code_dir empty" "code_dir"
fi

setup
mkevent issue labeled fix:requested open
MODS="${SOLO}" run_select
if expect_ok "no label and a single module"; then
  out_is "no label and a single module: outcome" "outcome=run"
  out_is "no label and a single module: module" "module=core"
  out_is "no label and a single module: code_dir" "code_dir=modules/core/code"
  out_is "no label and a single module: services" "services=postgres"
fi

setup
mkevent issue labeled fix:requested open module:ghost
run_select
if expect_ok "unknown module label"; then
  out_is "unknown module label: outcome" "outcome=run"
  out_empty "unknown module label: module empty" "module"
  out_empty "unknown module label: code_dir empty" "code_dir"
  out_empty "unknown module label: services empty" "services"
fi

setup
mkevent issue labeled fix:requested open module:ghost
MODS="${SOLO}" run_select
if expect_ok "unknown module label with a single module"; then
  out_empty "unknown module label with a single module: module empty" "module"
fi

setup
mkevent issue labeled fix:requested open module:core module:web
run_select
if expect_ok "two module labels"; then
  out_is "two module labels: outcome" "outcome=run"
  out_empty "two module labels: module empty" "module"
fi

setup
mkevent issue labeled fix:requested open bug urgency:critical module:web
run_select
if expect_ok "module label among others"; then
  out_is "module label among others: module" "module=web"
fi

echo "${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ]
