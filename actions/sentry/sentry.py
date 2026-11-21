#!/usr/bin/env python3
"""sentry — turn recent production errors of a Sentry project into Critical issues.

  intake --org O --project P --url U --environments production,staging --min-events 5 --modules JSON

Lists the unresolved errors first seen in the last 24 hours with enough events, in order of
frequency, and opens at most five Critical issues per run. A Sentry issue is skipped when a
GitHub issue (open or closed) already carries its short id in the title, or when one of its
notes starts with `[intake]`. The module is the first part of the release of the latest event.
Only an allow-list of the event reaches the issue, every string masked.

The note `[intake] #<n> <url>` on the Sentry issue is best effort: organization tokens cannot
write notes, so a refusal is only a warning.

Output (GITHUB_OUTPUT): `opened`. Environment: SENTRY_AUTH_TOKEN, GH_TOKEN, GITHUB_REPOSITORY,
GITHUB_OUTPUT, GITHUB_STEP_SUMMARY.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "critical"))
from critical import mask  # noqa: E402

MAX_PER_RUN = 5
HTTP_TIMEOUT = 15
TITLE_LIMIT = 80
VALUE_LIMIT = 2000
MESSAGE_LIMIT = 500
BREADCRUMB_COUNT = 30
INTAKE_NOTE = "[intake]"
LABELS = ("urgency:critical", "sentry")
ISSUE_KEYS = ("shortId", "title", "culprit", "level", "platform", "count", "firstSeen", "lastSeen")
TAG_KEYS = ("transaction", "handled", "mechanism", "level", "runtime", "runtime.name")
FRAME_KEYS = ("filename", "module", "function", "lineno", "colno", "in_app", "context_line", "pre_context", "post_context")
BREADCRUMB_KEYS = ("timestamp", "category", "level", "message")


def emit(name, value):
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(f"{name}={value}\n")


def summary(text):
    print(text)
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(text + "\n")


def request(method, url, body=None):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {os.environ.get('SENTRY_AUTH_TOKEN', '')}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as response:
            payload = response.read().decode("utf-8")
            return response.status, json.loads(payload) if payload else None
    except urllib.error.HTTPError as error:
        return error.code, None
    except (urllib.error.URLError, OSError, ValueError):
        return 0, None


def gh(*args):
    return subprocess.run(["gh", *args], capture_output=True, text=True)


def repo():
    return os.environ["GITHUB_REPOSITORY"]


def scrub(value, limit=None):
    text = mask(str(value if value is not None else ""))
    return text[:limit] if limit else text


def listing_url(args):
    query = f"is:unresolved level:[error,fatal] firstSeen:-24h times_seen:>={args.min_events}"
    params = [("project", args.project), ("query", query)]
    params += [("environment", name) for name in args.environments.split(",") if name]
    params += [("statsPeriod", "24h"), ("sort", "freq"), ("limit", "100")]
    return f"{args.url}/api/0/organizations/{args.org}/issues/?{urllib.parse.urlencode(params)}"


def already_filed(short_id):
    res = gh("issue", "list", "--state", "all", "--search", f"{short_id} in:title", "--json", "number,title", "--limit", "100", "-R", repo())
    if res.returncode != 0:
        return False
    pattern = re.compile(rf"(?<![A-Za-z0-9_-]){re.escape(short_id)}(?![A-Za-z0-9_-])")
    return any(pattern.search(item.get("title", "")) for item in json.loads(res.stdout or "[]"))


def already_noted(args, issue_id):
    status, notes = request("GET", f"{args.url}/api/0/organizations/{args.org}/issues/{issue_id}/comments/")
    if status != 200 or not isinstance(notes, list):
        return False
    return any(str((note.get("data") or {}).get("text", "")).startswith(INTAKE_NOTE) for note in notes)


def write_note(args, issue, text):
    status, _ = request("POST", f"{args.url}/api/0/organizations/{args.org}/issues/{issue['id']}/comments/", {"text": text})
    if not 200 <= status < 300:
        print(f"::warning::sentry: could not write the intake note on {issue['shortId']} (HTTP {status})")


def frame(raw):
    kept = {key: raw[key] for key in FRAME_KEYS if key in raw}
    for key, value in kept.items():
        if isinstance(value, str):
            kept[key] = scrub(value)
        elif isinstance(value, list):
            kept[key] = [scrub(item) for item in value]
    return kept


def exceptions_of(event):
    found = []
    for entry in event.get("entries") or []:
        if entry.get("type") != "exception":
            continue
        for item in (entry.get("data") or {}).get("values") or []:
            frames = ((item.get("stacktrace") or {}).get("frames")) or []
            found.append(
                {
                    "type": scrub(item.get("type")),
                    "value": scrub(item.get("value"), VALUE_LIMIT),
                    "mechanism": {"type": scrub((item.get("mechanism") or {}).get("type"))},
                    "frames": [frame(raw) for raw in frames],
                }
            )
    return found


def breadcrumbs_of(event):
    found = []
    for entry in event.get("entries") or []:
        if entry.get("type") != "breadcrumbs":
            continue
        found += (entry.get("data") or {}).get("values") or []
    found = found[-BREADCRUMB_COUNT:]
    return [
        {key: scrub(crumb.get(key), MESSAGE_LIMIT) if key == "message" else scrub(crumb.get(key)) for key in BREADCRUMB_KEYS if key in crumb}
        for crumb in found
    ]


def tags_of(event):
    return {tag["key"]: scrub(tag.get("value")) for tag in event.get("tags") or [] if tag.get("key") in TAG_KEYS}


def release_of(event):
    release = event.get("release")
    return (release.get("version") if isinstance(release, dict) else release) or ""


def environment_of(event):
    for tag in event.get("tags") or []:
        if tag.get("key") == "environment":
            return tag.get("value") or ""
    return event.get("environment") or ""


def document(issue, event, release, environment):
    return {
        "issue": {key: scrub(issue.get(key)) for key in ISSUE_KEYS},
        "event": {
            "release": scrub(release),
            "environment": scrub(environment),
            "tags": tags_of(event),
            "exceptions": exceptions_of(event),
            "breadcrumbs": breadcrumbs_of(event),
        },
    }


def issue_title(issue):
    return scrub(f"bug: {issue['shortId']} {issue.get('title', '')}")[:TITLE_LIMIT]


def issue_body(issue, environment, doc):
    return "\n".join(
        [
            f"Sentry issue: {issue.get('permalink', '')}",
            f"environment: {environment}",
            "",
            "```json",
            json.dumps(doc, ensure_ascii=False, indent=2),
            "```",
            "",
        ]
    )


def open_issue(issue, module, environment, doc):
    for name in (*LABELS, f"module:{module}"):
        gh("label", "create", name, "--force", "-R", repo())
    handle = tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8")
    handle.write(issue_body(issue, environment, doc))
    handle.close()
    try:
        args = ["issue", "create", "-R", repo(), "--title", issue_title(issue), "--body-file", handle.name]
        for name in (*LABELS, f"module:{module}"):
            args += ["--label", name]
        res = gh(*args)
    finally:
        os.unlink(handle.name)
    if res.returncode != 0:
        print(f"::warning::sentry: could not open the issue for {issue['shortId']}")
        return None
    url = res.stdout.strip()
    return int(url.rstrip("/").rsplit("/", 1)[-1]), url


def intake(args):
    modules = json.loads(args.modules)
    status, issues = request("GET", listing_url(args))
    if status != 200 or not isinstance(issues, list):
        print(f"::warning::sentry: could not list the issues of {args.org}/{args.project} (HTTP {status})")
        issues = []
    issues.sort(key=lambda item: -int(item.get("count") or 0))

    opened = 0
    for issue in issues:
        if opened >= MAX_PER_RUN:
            break
        if already_filed(issue["shortId"]) or already_noted(args, issue["id"]):
            continue
        status, event = request("GET", f"{args.url}/api/0/organizations/{args.org}/issues/{issue['id']}/events/latest/")
        event = event if status == 200 and isinstance(event, dict) else {}
        release = release_of(event)
        module = release.split(".", 1)[0]
        if module not in modules:
            write_note(args, issue, f"{INTAKE_NOTE} skipped: release '{release}' names no module")
            continue
        environment = environment_of(event)
        created = open_issue(issue, module, environment, document(issue, event, release, environment))
        if created is None:
            continue
        number, url = created
        write_note(args, issue, f"{INTAKE_NOTE} #{number} {url}")
        opened += 1

    emit("opened", opened)
    if opened == 0:
        summary("nothing to intake")
    else:
        summary(f"intake: opened {opened} Critical issue(s)")


def parse(argv):
    parser = argparse.ArgumentParser(prog="sentry")
    sub = parser.add_subparsers(dest="command", required=True)
    cmd = sub.add_parser("intake")
    cmd.add_argument("--org", required=True)
    cmd.add_argument("--project", required=True)
    cmd.add_argument("--url", default="https://sentry.io")
    cmd.add_argument("--environments", default="production,staging")
    cmd.add_argument("--min-events", type=int, default=5)
    cmd.add_argument("--modules", required=True)
    return parser.parse_args(argv)


def main(argv=None):
    intake(parse(sys.argv[1:] if argv is None else argv))


if __name__ == "__main__":
    main()
