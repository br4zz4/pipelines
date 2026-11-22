#!/bin/sh
set -u

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="${ROOT}/actions/sentry/sentry.py"
HERE="${ROOT}/tests/sentry"
FIX="${HERE}/fixtures"
WORK="$(mktemp -d)"
STUB_PID=""
trap '[ -z "${STUB_PID}" ] || { kill "${STUB_PID}" 2>/dev/null; wait "${STUB_PID}" 2>/dev/null; }; rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0
OUT="${WORK}/output"
LOG="${WORK}/log"
CALLS="${WORK}/calls"
SUMMARY="${WORK}/summary"
STATE="${WORK}/state"
REQS="${WORK}/requests"
CREATED="${WORK}/created"
GHLIST="${WORK}/ghlist.json"
PORTFILE="${WORK}/port"
CWD="${WORK}/cwd"
STATUS=0
MODULES='{"core":{"code":"modules/core/code"},"web":{"code":"modules/web/code"}}'

mkdir -p "${WORK}/bin" "${CWD}" "${STATE}"
cat > "${WORK}/bin/gh" <<'GH'
#!/bin/sh
printf '%s\n' "$*" >> "${GH_CALLS}"
case "${1:-} ${2:-}" in
  "issue list") cat "${GH_LIST}" ;;
  "issue create")
    n=$(( 100 + $(find "${GH_CREATED}" -name '*.args' | wc -l) ))
    printf '%s\n' "$@" > "${GH_CREATED}/${n}.args"
    printf '%s' "${GH_TOKEN:-}" > "${GH_CREATED}/${n}.token"
    : > "${GH_CREATED}/${n}.body"
    prev=""
    for arg in "$@"; do
      case "${prev}" in
        --body) printf '%s' "${arg}" >> "${GH_CREATED}/${n}.body" ;;
        --body-file) if [ "${arg}" = "-" ]; then cat >> "${GH_CREATED}/${n}.body"; else cat "${arg}" >> "${GH_CREATED}/${n}.body"; fi ;;
      esac
      prev="${arg}"
    done
    echo "https://github.com/o/r/issues/${n}" ;;
esac
exit 0
GH
chmod 755 "${WORK}/bin/gh"

python3 "${HERE}/stub.py" "${STATE}" "${PORTFILE}" "${REQS}" &
STUB_PID=$!
tries=0
while [ ! -s "${PORTFILE}" ] && [ "${tries}" -lt 100 ]; do
  sleep 0.1
  tries=$(( tries + 1 ))
done
PORT="$(cat "${PORTFILE}" 2>/dev/null || true)"

pass() {
  echo "PASS ${1}"
  PASSED=$(( PASSED + 1 ))
}

fail() {
  echo "FAIL ${1}"
  FAILED=$(( FAILED + 1 ))
}

setup() {
  unset ENVS MIN MODS
  : > "${OUT}"
  : > "${LOG}"
  : > "${CALLS}"
  : > "${SUMMARY}"
  : > "${REQS}"
  rm -rf "${STATE}" "${CREATED}" "${CWD}/.autofix"
  mkdir -p "${STATE}/events" "${STATE}/comments" "${CREATED}"
  echo '[]' > "${GHLIST}"
}

mkissues() {
  python3 - "${STATE}" "${FIX}/event_base.json" "$@" <<'PY'
import copy, json, os, sys
state, base_path, *specs = sys.argv[1:]
base = json.load(open(base_path))
issues = []
for spec in specs:
    ident, short, count, title, release, env = spec.split("|")
    issues.append({
        "id": ident,
        "shortId": short,
        "title": title,
        "culprit": "app/models/billing.rb in total",
        "level": "error",
        "platform": "ruby",
        "count": count,
        "firstSeen": "2026-11-21T08:00:00Z",
        "lastSeen": "2026-11-21T09:00:00Z",
        "permalink": "https://sentry.example.com/organizations/o/issues/%s/" % ident,
        "project": {"slug": "p"},
    })
    event = copy.deepcopy(base)
    if release == "-":
        event["release"] = None
    else:
        event["release"] = {"version": release}
    for tag in event["tags"]:
        if tag["key"] == "environment":
            tag["value"] = env
    with open(os.path.join(state, "events", ident + ".json"), "w") as handle:
        json.dump(event, handle)
with open(os.path.join(state, "issues.json"), "w") as handle:
    json.dump(issues, handle)
PY
}

mknote() {
  python3 - "${STATE}/comments/${1}.json" "${2}" <<'PY'
import json, sys
json.dump([{"id": "9", "type": "note", "data": {"text": sys.argv[2]}, "dateCreated": "2026-11-21T09:00:00Z"}], open(sys.argv[1], "w"))
PY
}

mkevent() {
  python3 - "${STATE}/events/${1}.json" "${2}" <<'PY'
import json, sys
path, source = sys.argv[1:3]
json.dump(json.load(open(source)), open(path, "w"))
PY
}

mklong() {
  python3 - "${STATE}/events/${1}.json" <<'PY'
import json, sys
path = sys.argv[1]
event = json.load(open(path))
event["entries"][0]["data"]["values"][0]["value"] = "y " * 3000
event["entries"].append({"type": "breadcrumbs", "data": {"values": [{"timestamp": "t", "category": "c", "level": "info", "message": "z " * 1000}]}})
json.dump(event, open(path, "w"))
PY
}

run() {
  STATUS=0
  ( cd "${CWD}" && PATH="${WORK}/bin:${PATH}" GH_CALLS="${CALLS}" GH_CREATED="${CREATED}" GH_LIST="${GHLIST}" \
    SENTRY_AUTH_TOKEN=tok GH_TOKEN=pat-token GITHUB_REPOSITORY=o/r GIT_CONFIG_GLOBAL=/dev/null \
    GITHUB_OUTPUT="${OUT}" GITHUB_STEP_SUMMARY="${SUMMARY}" \
    python3 "${SCRIPT}" intake --org o --project p --url "http://127.0.0.1:${PORT}" \
      --environments "${ENVS:-production,staging}" --min-events "${MIN:-5}" \
      --modules "${MODS:-${MODULES}}" > "${LOG}" 2>&1 ) || STATUS=$?
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

summary_have() {
  grep -qF -- "${2}" "${SUMMARY}" && pass "${1}" || fail "${1}: summary lacks '${2}': $(cat "${SUMMARY}")"
}

log_have() {
  grep -qF -- "${2}" "${LOG}" && pass "${1}" || fail "${1}: log lacks '${2}': $(cat "${LOG}")"
}

chk() {
  python3 - "${WORK}" "${2}" <<'PY' && pass "${1}" || fail "${1}"
import glob, json, os, re, sys
work, expr = sys.argv[1:3]
created = []
for path in glob.glob(os.path.join(work, "created", "*.args")):
    n = int(os.path.basename(path).split(".")[0])
    args = open(path).read().split("\n")
    if args and args[-1] == "":
        args.pop()
    body = open(path[:-5] + ".body").read()
    token = open(path[:-5] + ".token").read()
    labels = []
    for index, arg in enumerate(args):
        if arg in ("--label", "-l") and index + 1 < len(args):
            labels.extend(part for part in args[index + 1].split(",") if part)
    title = args[args.index("--title") + 1] if "--title" in args else None
    block = re.search(r"```json\n(.*?)\n```", body, re.S)
    created.append({"n": n, "args": args, "title": title, "labels": labels, "body": body, "token": token,
                    "json": json.loads(block.group(1)) if block else None})
c = sorted(created, key=lambda item: item["n"])
r = [json.loads(line) for line in open(os.path.join(work, "requests")) if line.strip()]
calls = open(os.path.join(work, "calls")).read().splitlines()
out = open(os.path.join(work, "output")).read()
summary = open(os.path.join(work, "summary")).read()
log = open(os.path.join(work, "log")).read()
posts = [x for x in r if x["method"] == "POST"]
gets = [x for x in r if x["method"] == "GET"]


def notes(ident):
    path = "/api/0/organizations/o/issues/%s/comments/" % ident
    return [x["body"]["text"] for x in posts if x["path"] == path]


def keys(value):
    found = set()
    if isinstance(value, dict):
        for key, item in value.items():
            found.add(key)
            found |= keys(item)
    elif isinstance(value, list):
        for item in value:
            found |= keys(item)
    return found


sys.exit(0 if eval(expr) else 1)
PY
}

setup
mkissues "1002|CORE-B|12|B title|core.2026-11-21.002|staging" \
         "1001|CORE-A|40|A title|core.2026-11-21.001|production" \
         "1003|WEB-C|6|C title|web.2026-11-21.003|production"
run
if expect_ok "happy path"; then
  out_is "happy: opened output" "opened=3"
  chk "happy: three issues in frequency order" "[x['title'] for x in c] == ['bug: CORE-A A title', 'bug: CORE-B B title', 'bug: WEB-C C title']"
  chk "happy: labels of the core issues" "all(sorted(c[i]['labels']) == ['module:core', 'sentry', 'urgency:critical'] for i in (0, 1))"
  chk "happy: labels of the web issue" "sorted(c[2]['labels']) == ['module:web', 'sentry', 'urgency:critical']"
  chk "happy: issues opened with the PAT" "all(x['token'] == 'pat-token' for x in c)"
  chk "happy: labels created with --force before issues are opened" "all(any(l.startswith('label create ' + n + ' ') or l == 'label create ' + n for l in calls) for n in ('urgency:critical', 'module:core', 'module:web', 'sentry')) and all('--force' in l for l in calls if l.startswith('label create')) and min(i for i, l in enumerate(calls) if l.startswith('label create')) < min(i for i, l in enumerate(calls) if l.startswith('issue create'))"
  chk "happy: body links the sentry permalink" "all('https://sentry.example.com/organizations/o/issues/%s/' % i in x['body'] for x, i in zip(c, ('1001', '1002', '1003')))"
  chk "happy: body names the environment" "['environment: production' in c[0]['body'], 'environment: staging' in c[1]['body'], 'environment: production' in c[2]['body']] == [True, True, True]"
  chk "happy: body carries a json block" "all(isinstance(x['json'], dict) for x in c)"
  chk "happy: note written on each sentry issue" "[notes(i) for i in ('1001', '1002', '1003')] == [['[intake] #100 https://github.com/o/r/issues/100'], ['[intake] #101 https://github.com/o/r/issues/101'], ['[intake] #102 https://github.com/o/r/issues/102']]"
  chk "happy: note posted as a json text field" "all(set(x['body']) == {'text'} for x in posts)"
  chk "happy: no nothing-to-intake" "'nothing to intake' not in summary"
fi

setup
mkissues "1001|CORE-A|40|A title|core.2026-11-21.001|production"
run
if expect_ok "request shape"; then
  chk "request: listing path and project" "[x['path'] for x in gets][:1] == ['/api/0/organizations/o/issues/'] and gets[0]['query']['project'] == ['p']"
  chk "request: listing query" "gets[0]['query']['query'] == ['is:unresolved level:[error,fatal] firstSeen:-24h times_seen:>=5']"
  chk "request: one environment parameter per item" "gets[0]['query']['environment'] == ['production', 'staging']"
  chk "request: stats period and sort" "gets[0]['query']['statsPeriod'] == ['24h'] and gets[0]['query']['sort'] == ['freq']"
  chk "request: latest event" "any(x['path'] == '/api/0/organizations/o/issues/1001/events/latest/' for x in gets)"
  chk "request: bearer token on every call" "all(x['auth'] == 'Bearer tok' for x in r)"
  chk "request: no project-scoped endpoint" "all('/projects/' not in x['path'] for x in r)"
fi

setup
ENVS=production MIN=12
mkissues "1001|CORE-A|40|A title|core.2026-11-21.001|production"
run
if expect_ok "options reach the query"; then
  chk "options: min events in the query" "gets[0]['query']['query'] == ['is:unresolved level:[error,fatal] firstSeen:-24h times_seen:>=12']"
  chk "options: single environment" "gets[0]['query']['environment'] == ['production']"
fi

setup
mkissues "2003|CORE-N3|50|t3|core.2026-11-21.001|production" "2001|CORE-N1|70|t1|core.2026-11-21.001|production" \
         "2007|CORE-N7|10|t7|core.2026-11-21.001|production" "2002|CORE-N2|60|t2|core.2026-11-21.001|production" \
         "2005|CORE-N5|30|t5|core.2026-11-21.001|production" "2004|CORE-N4|40|t4|core.2026-11-21.001|production" \
         "2006|CORE-N6|20|t6|core.2026-11-21.001|production"
run
if expect_ok "cap of five"; then
  out_is "cap: opened five" "opened=5"
  chk "cap: the five most frequent, in order" "[x['title'] for x in c] == ['bug: CORE-N%d t%d' % (i, i) for i in (1, 2, 3, 4, 5)]"
  chk "cap: nothing written for the sixth and seventh" "notes('2006') == [] and notes('2007') == []"
fi

setup
mkissues "1001|CORE-A|40|A title|core.2026-11-21.001|production" "1002|CORE-B|12|B title|core.2026-11-21.002|staging" \
         "1003|WEB-C|6|C title|web.2026-11-21.003|production"
cat > "${GHLIST}" <<'JSON'
[{"number": 11, "title": "bug: CORE-A A title"}, {"number": 12, "title": "bug: CORE-B2 something else"}, {"number": 13, "title": "Investigate crash"}]
JSON
run
if expect_ok "dedup by github issue"; then
  out_is "dedup github: opened" "opened=2"
  chk "dedup github: the issue that already has one is skipped" "[x['title'] for x in c] == ['bug: CORE-B B title', 'bug: WEB-C C title']"
  chk "dedup github: skipped issue gets no note" "notes('1001') == []"
  chk "dedup github: a longer short id does not match" "any('CORE-B ' in x['title'] for x in c)"
  chk "dedup github: searches the short id by title in every state" "any(l.startswith('issue list') and '--state all' in l and 'CORE-A in:title' in l and '--json number,title' in l for l in calls)"
fi

setup
mkissues "1001|CORE-A|40|A title|core.2026-11-21.001|production"
cat > "${GHLIST}" <<'JSON'
[{"number": 11, "title": "Fix CORE-A crash on billing"}]
JSON
run
if expect_ok "dedup by title containing the short id"; then
  out_is "dedup github title: opened" "opened=0"
  chk "dedup github title: nothing created" "c == []"
fi

setup
mkissues "1001|CORE-A|40|A title|core.2026-11-21.001|production" "1002|CORE-B|12|B title|core.2026-11-21.002|staging" \
         "1003|WEB-C|6|C title|web.2026-11-21.003|production"
mknote 1002 "[intake] #12 https://github.com/o/r/issues/12"
run
if expect_ok "dedup by note"; then
  out_is "dedup note: opened" "opened=2"
  chk "dedup note: issue with an intake note is skipped" "[x['title'] for x in c] == ['bug: CORE-A A title', 'bug: WEB-C C title']"
  chk "dedup note: skipped issue gets no new note" "notes('1002') == []"
  chk "dedup note: notes were read" "any(x['path'] == '/api/0/organizations/o/issues/1002/comments/' for x in gets)"
fi

setup
mkissues "1001|CORE-A|40|A title|core.2026-11-21.001|production" "1002|CORE-B|12|B title|core.2026-11-21.002|staging"
mknote 1001 "see [intake] docs"
mknote 1002 "[intake] skipped: release 'x' names no module"
run
if expect_ok "note prefix"; then
  chk "note prefix: only a leading [intake] counts" "[x['title'] for x in c] == ['bug: CORE-A A title']"
  chk "note prefix: a skipped note also dedups" "notes('1002') == []"
fi

setup
mkissues "1001|CORE-A|40|A title|core.2026-11-21.001|production"
echo 500 > "${STATE}/comments_status"
run
if expect_ok "comments read failure"; then
  out_is "comments failure: opened" "opened=1"
  chk "comments failure: ignored, issue still opened" "[x['title'] for x in c] == ['bug: CORE-A A title']"
fi

setup
mkissues "1001|CORE-A|40|A title|core.2026-11-21.001|production" "1002|WEB-B|12|B title|web-00094-8qb|production" \
         "1003|CORE-C|6|C title|-|production"
run
if expect_ok "release without module"; then
  out_is "no module: opened" "opened=1"
  chk "no module: only the issue with a module opens" "[x['title'] for x in c] == ['bug: CORE-A A title']"
  chk "no module: release annotated" "notes('1002') == [\"[intake] skipped: release 'web-00094-8qb' names no module\"]"
  chk "no module: missing release annotated" "len(notes('1003')) == 1 and notes('1003')[0].startswith('[intake] skipped:')"
  chk "no module: the good issue still gets its note" "notes('1001') == ['[intake] #100 https://github.com/o/r/issues/100']"
fi

setup
mkissues "1001|CORE-A|40|A title|core.2026-11-21.001|production"
echo 403 > "${STATE}/post_status"
run
if expect_ok "note forbidden"; then
  out_is "note 403: opened" "opened=1"
  chk "note 403: issue still opened" "[x['title'] for x in c] == ['bug: CORE-A A title']"
  log_have "note 403: warning" "::warning::sentry: could not write the intake note on CORE-A (HTTP 403)"
fi

setup
mkissues "3001|CORE-P|42|Crash for dev@example.com|core.2026-11-21.001|production"
mkevent 3001 "${FIX}/event_pii.json"
run
if expect_ok "pii"; then
  out_is "pii: opened" "opened=1"
  chk "pii: no sensitive value anywhere" "not any(s in c[0]['body'] or s in c[0]['title'] for s in ('user.secret@example.com', '203.0.113.7', 'jdoe-secret', 'cookie-secret', 'header-secret', 'request-data-secret', 'vars-secret', 'crumb-data-secret', 'mechanism-data-secret', 'host-secret-1', 'Chrome-secret', 'device-secret', 'abs-secret', 'dev@example.com', 'owner@example.com', 'ops@example.com', 'ctx@example.com', '192.168.1.20', '2001:db8::1', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcd'))"
  chk "pii: no forbidden key" "not (keys(c[0]['json']) & {'user', 'ip_address', 'cookies', 'headers', 'request', 'vars', 'data', 'email', 'username', 'absPath', 'contexts', 'sdk'})"
  chk "pii: top-level shape" "set(c[0]['json']) == {'issue', 'event'} and set(c[0]['json']['event']) == {'release', 'environment', 'tags', 'exceptions', 'breadcrumbs'}"
  chk "pii: issue allow-list with masked title" "c[0]['json']['issue'] == {'shortId': 'CORE-P', 'title': 'Crash for <email>', 'culprit': 'app/models/billing.rb in total', 'level': 'error', 'platform': 'ruby', 'count': '42', 'firstSeen': '2026-11-21T08:00:00Z', 'lastSeen': '2026-11-21T09:00:00Z'}"
  chk "pii: event release and environment" "c[0]['json']['event']['release'] == 'core.2026-11-21.001' and c[0]['json']['event']['environment'] == 'production'"
  chk "pii: only the allowed tags" "c[0]['json']['event']['tags'] == {'transaction': 'POST /billing', 'handled': 'no', 'mechanism': 'generic', 'level': 'error', 'runtime': 'ruby 3.3.0', 'runtime.name': 'ruby'}"
  chk "pii: exception fields" "len(c[0]['json']['event']['exceptions']) == 1 and c[0]['json']['event']['exceptions'][0]['type'] == 'ZeroDivisionError' and c[0]['json']['event']['exceptions'][0]['mechanism'] == {'type': 'generic'}"
  chk "pii: exception keys" "set(c[0]['json']['event']['exceptions'][0]) == {'type', 'value', 'mechanism', 'frames'}"
  chk "pii: value masks email, ip and token" "c[0]['json']['event']['exceptions'][0]['value'] == 'divided by 0 for <email> from <ip> and <ip> token <token>'"
  chk "pii: frame keys without vars" "all(set(f) == {'filename', 'module', 'function', 'lineno', 'colno', 'in_app', 'context_line', 'pre_context', 'post_context'} for f in c[0]['json']['event']['exceptions'][0]['frames'])"
  chk "pii: frame values" "c[0]['json']['event']['exceptions'][0]['frames'][0] == {'filename': 'app/models/billing.rb', 'module': 'Billing', 'function': 'total', 'lineno': 10, 'colno': 3, 'in_app': True, 'context_line': 'x / y # <email>', 'pre_context': ['a = 1', 'b = 2'], 'post_context': ['c = 3']}"
  chk "pii: second frame kept" "c[0]['json']['event']['exceptions'][0]['frames'][1]['filename'] == 'lib/boot.rb' and c[0]['json']['event']['exceptions'][0]['frames'][1]['in_app'] is False"
  chk "pii: last 30 breadcrumbs without data" "c[0]['json']['event']['breadcrumbs'] == [{'timestamp': '2026-11-21T09:00:%02dZ' % i, 'category': 'app', 'level': 'info', 'message': 'login <email>' if i == 10 else 'm%02d' % i} for i in range(3, 33)]"
  chk "pii: title masked" "c[0]['title'] == 'bug: CORE-P Crash for <email>'"
fi

setup
mkissues "3002|CORE-L|42|L title|core.2026-11-21.001|production"
mklong 3002
run
if expect_ok "truncation"; then
  chk "truncation: value capped at 2000" "1900 < len(c[0]['json']['event']['exceptions'][0]['value']) <= 2000"
  chk "truncation: message capped at 500" "400 < len(c[0]['json']['event']['breadcrumbs'][-1]['message']) <= 500"
fi

setup
mkissues "3003|CORE-T|42|$(python3 -c "print('ab ' * 60, end='')")|core.2026-11-21.001|production"
run
if expect_ok "title length"; then
  chk "title: 80 characters in total" "len(c[0]['title']) == 80 and c[0]['title'].startswith('bug: CORE-T ab ab')"
fi

setup
mkissues "3004|CORE-S|42|Short title|core.2026-11-21.001|production"
run
if expect_ok "short title"; then
  chk "short title: untouched" "c[0]['title'] == 'bug: CORE-S Short title'"
  chk "short title: json block is fenced" "'\`\`\`json' in c[0]['body']"
fi

setup
run
if expect_ok "nothing to intake"; then
  out_is "nothing: opened" "opened=0"
  summary_have "nothing: summary" "nothing to intake"
  chk "nothing: no issue and no note" "c == [] and posts == []"
fi

echo "${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ]
