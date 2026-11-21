#!/usr/bin/env python3
"""issue — decide whether the autofix runs on one Critical issue and prepare its input.

  select --issue N --event issues|workflow_dispatch --sender LOGIN --max-per-day M --modules JSON

Checks, in order; each refusal writes `outcome` and `reason` (GITHUB_OUTPUT, step summary):
  1. the issue is open and labelled `urgency:critical`
  2. it is not labelled `autofix:blocked`
  3. whoever asked has write, maintain or admin permission (a comment otherwise)
  4. exactly one `module:<m>` label names a module of the project (a comment otherwise)
  5. no pull request `fix/issue-<n>` exists (skipped on dispatch)
  6. fewer than M autofix runs started in the last 24 hours (skipped on dispatch)
Selected: writes `.autofix/issue.json` (masked, trusted comments only) and the outputs
issue, title, url, module, code_dir, services, outcome.

Environment: GITHUB_REPOSITORY, GH_TOKEN, GITHUB_OUTPUT, GITHUB_STEP_SUMMARY, GITHUB_ACTOR.
"""

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "critical"))
from critical import mask  # noqa: E402

CRITICAL = "urgency:critical"
BLOCKED = "autofix:blocked"
MODULE_PREFIX = "module:"
ALLOWED_PERMISSIONS = ("write", "maintain", "admin")
TRUSTED = ("OWNER", "MEMBER", "COLLABORATOR")
BODY_LIMIT = 20000
COMMENT_LIMIT = 4000
COMMENT_COUNT = 20
WINDOW = timedelta(hours=24)
FIX_JOB = "autofix / fix"
OUT_DIR = ".autofix"


def repo():
    return os.environ["GITHUB_REPOSITORY"]


def gh(*args):
    return subprocess.run(["gh", *args], capture_output=True, text=True)


def gh_json(path, default):
    res = gh("api", path)
    if res.returncode != 0:
        return default
    return json.loads(res.stdout or "null") or default


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


def finish(outcome, reason):
    emit("outcome", outcome)
    emit("reason", reason)
    summary(reason)


def comment(number, text):
    path = f"{OUT_DIR}-comment.md"
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    try:
        gh("issue", "comment", str(number), "-R", repo(), "--body-file", path)
    finally:
        os.unlink(path)


def permitted(login):
    if not login:
        return False
    data = gh_json(f"repos/{repo()}/collaborators/{login}/permission", {})
    return data.get("permission") in ALLOWED_PERMISSIONS


def already_attempted(number):
    pulls = gh_json(f"repos/{repo()}/pulls?state=all&head={repo().split('/')[0]}:fix/issue-{number}", [])
    return bool(pulls)


def runs_started(since):
    stamp = since.strftime("%Y-%m-%dT%H:%M:%SZ")
    data = gh_json(f"repos/{repo()}/actions/workflows/autofix.yml/runs?created=%3E%3D{stamp}&per_page=100", {})
    count = 0
    for run in data.get("workflow_runs", []):
        jobs = gh_json(f"repos/{repo()}/actions/runs/{run['id']}/jobs?per_page=100", {}).get("jobs", [])
        if any(job.get("name") == FIX_JOB and job.get("conclusion") != "skipped" for job in jobs):
            count += 1
    return count


def clip(text, limit):
    return mask(text or "")[:limit]


def trusted_comments(number):
    items = gh_json(f"repos/{repo()}/issues/{number}/comments?per_page=100", [])
    kept = [item for item in items if item.get("author_association") in TRUSTED]
    return [
        {"body": clip(item.get("body"), COMMENT_LIMIT), "created_at": item.get("created_at", "")}
        for item in kept[-COMMENT_COUNT:]
    ]


def write_input(number, issue, labels):
    os.makedirs(OUT_DIR, exist_ok=True)
    data = {
        "number": number,
        "title": clip(issue.get("title"), BODY_LIMIT),
        "body": clip(issue.get("body"), BODY_LIMIT),
        "labels": labels,
        "comments": trusted_comments(number),
    }
    with open(os.path.join(OUT_DIR, "issue.json"), "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)


def module_labels(labels):
    return [label[len(MODULE_PREFIX):] for label in labels if label.startswith(MODULE_PREFIX)]


def select(args):
    number = args.issue
    issue = gh_json(f"repos/{repo()}/issues/{number}", {})
    labels = [label.get("name", "") for label in issue.get("labels", [])]
    dispatch = args.event == "workflow_dispatch"

    if issue.get("state") != "open" or CRITICAL not in labels:
        return finish("skipped", "not an open critical issue")
    if BLOCKED in labels:
        return finish("skipped", "blocked: needs a human")

    requester = os.environ.get("GITHUB_ACTOR", "") if dispatch else args.sender
    if not permitted(requester):
        comment(number, f"[autofix] ignored: {requester} cannot trigger the autofix")
        return finish("skipped", f"ignored: {requester} cannot trigger the autofix")

    modules = json.loads(args.modules)
    names = module_labels(labels)
    if len(names) != 1:
        reason = "missing module:<m> label" if not names else "more than one module:<m> label"
        comment(number, f"[autofix] rejected: {reason}")
        return finish("rejected", reason)
    module = names[0]
    if module not in modules:
        comment(number, f"[autofix] rejected: unknown module '{module}'")
        return finish("rejected", f"unknown module '{module}'")

    if not dispatch:
        if already_attempted(number):
            return finish("skipped", "already attempted")
        if args.max_per_day > 0:
            started = runs_started(datetime.now(timezone.utc) - WINDOW)
            if started >= args.max_per_day:
                return finish("skipped", f"daily cap reached ({started}/{args.max_per_day})")

    write_input(number, issue, labels)
    spec = modules[module]
    emit("outcome", "selected")
    emit("issue", number)
    emit("title", mask(issue.get("title") or ""))
    emit("url", issue.get("html_url", ""))
    emit("module", module)
    emit("code_dir", spec.get("code", ""))
    emit("services", spec.get("services", ""))
    summary(f"selected: #{number} in module {module}")


def parse(argv):
    parser = argparse.ArgumentParser(prog="issue")
    sub = parser.add_subparsers(dest="command", required=True)
    sel = sub.add_parser("select")
    sel.add_argument("--issue", type=int, required=True)
    sel.add_argument("--event", default="issues")
    sel.add_argument("--sender", default="")
    sel.add_argument("--max-per-day", type=int, default=0)
    sel.add_argument("--modules", required=True)
    return parser.parse_args(argv)


def main(argv=None):
    select(parse(sys.argv[1:] if argv is None else argv))


if __name__ == "__main__":
    main()
