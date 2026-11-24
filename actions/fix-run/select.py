#!/usr/bin/env python3
"""select — decide whether a Fix run starts and which module it works on.

  select.py --max-per-day M --modules JSON

Starts (outcome `run`) on a mention (issue_comment, pull_request_review_comment,
pull_request_review) with no cap, or on the label `fix:requested` applied to an open issue
while fewer than M Fix runs started in the last 24 hours (M = 0 means no cap). Anything
else is `skip`. Who may mention is checked by the claude-code-action itself.

Outputs (GITHUB_OUTPUT): outcome, reason, number, module, code_dir, services.
Environment: GITHUB_EVENT_NAME, GITHUB_EVENT_PATH, GITHUB_REPOSITORY, GH_TOKEN, GITHUB_OUTPUT.
"""

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone

LABEL = "fix:requested"
MODULE_PREFIX = "module:"
MENTIONS = ("issue_comment", "pull_request_review_comment", "pull_request_review")
WINDOW = timedelta(hours=24)
JOB = "fix"
STEP = "agent"


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


def finish(outcome, reason, number="", module=None):
    spec = module or {}
    emit("outcome", outcome)
    emit("reason", reason)
    emit("number", number)
    emit("module", spec.get("name", ""))
    emit("code_dir", spec.get("code", ""))
    emit("services", spec.get("services", ""))
    print(f"fix: {outcome}" + (f" ({reason})" if reason else ""))


def comment(number, text):
    path = f"fix-comment-{os.getpid()}.md"
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    try:
        gh("issue", "comment", str(number), "-R", repo(), "--body-file", path)
    finally:
        os.unlink(path)


PAGE_SIZE = 100
MAX_PAGES = 5


class ApiError(RuntimeError):
    pass


def gh_data(path):
    res = gh("api", path)
    if res.returncode != 0:
        raise ApiError(path)
    return json.loads(res.stdout or "null") or {}


def started_runs(since):
    stamp = since.strftime("%Y-%m-%dT%H:%M:%SZ")
    current = os.environ.get("GITHUB_RUN_ID", "")
    for page in range(1, MAX_PAGES + 1):
        data = gh_data(
            f"repos/{repo()}/actions/workflows/fix.yml/runs?event=issues&created=%3E%3D{stamp}&per_page={PAGE_SIZE}&page={page}"
        )
        runs = data.get("workflow_runs", [])
        for run in runs:
            if str(run.get("id")) != current:
                yield run
        if len(runs) < PAGE_SIZE:
            return


def runs_started(since):
    count = 0
    for run in started_runs(since):
        if run.get("event") != "issues":
            continue
        jobs = gh_data(f"repos/{repo()}/actions/runs/{run['id']}/jobs?per_page=100").get("jobs", [])
        for job in jobs:
            if job.get("name") != JOB:
                continue
            steps = [s for s in job.get("steps", []) if s.get("name") == STEP]
            if any(s.get("conclusion") != "skipped" for s in steps):
                count += 1
    return count


def label_names(items):
    return [item.get("name", "") for item in items or []]


def pick_module(labels, modules):
    named = [label[len(MODULE_PREFIX):] for label in labels if label.startswith(MODULE_PREFIX)]
    known = [name for name in named if name in modules]
    if len(known) == 1:
        name = known[0]
    elif not named and len(modules) == 1:
        name = next(iter(modules))
    else:
        return None
    spec = modules[name]
    return {"name": name, "code": spec.get("code", ""), "services": spec.get("services", "")}


def select(args):
    event_name = os.environ.get("GITHUB_EVENT_NAME", "")
    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as handle:
        event = json.load(handle)
    modules = json.loads(args.modules)
    issue = event.get("issue") or {}
    pull = event.get("pull_request") or {}
    carrier = issue or pull
    number = carrier.get("number", "")
    module = pick_module(label_names(carrier.get("labels")), modules)

    if event_name in MENTIONS:
        return finish("run", "", number, module)

    if event_name != "issues" or event.get("action") != "labeled" or (event.get("label") or {}).get("name") != LABEL:
        return finish("skip", "not a fix request", number)
    if issue.get("state") != "open":
        return finish("skip", "issue is not open", number)

    if args.max_per_day > 0:
        try:
            started = runs_started(datetime.now(timezone.utc) - WINDOW)
        except ApiError:
            return finish("skip", "could not read the Fix runs of the last 24 hours", number)
        if started >= args.max_per_day:
            reason = f"daily cap reached ({started}/{args.max_per_day})"
            comment(number, f"[fix] skipped: {reason}")
            return finish("skip", reason, number)
    return finish("run", "", number, module)


def parse(argv):
    parser = argparse.ArgumentParser(prog="select")
    parser.add_argument("--max-per-day", type=int, default=0)
    parser.add_argument("--modules", required=True)
    return parser.parse_args(argv)


def main(argv=None):
    select(parse(sys.argv[1:] if argv is None else argv))


if __name__ == "__main__":
    main()
