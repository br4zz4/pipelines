#!/usr/bin/env python3
"""promote — decide whether a release that is green in staging goes to production.

Subcommands:
  target  --tag T --event E --modules JSON
          Validates the release tag, finds its module and reads the staging record.
          Output (GITHUB_OUTPUT): module, tag, code_dir, services, release_url.
  decide  --tag T --module M --max-per-day N
          Runs after regression and e2e passed. First match wins:
            superseded  a newer tag is green in staging, or production already has a newer one
            capped      N > 0 and N releases were promoted in the last 24 hours
            promoted    records the release as `promoted` and dispatches the production deploy
          Output (GITHUB_OUTPUT): outcome.

Environment: GITHUB_REPOSITORY, GH_TOKEN, GITHUB_OUTPUT, GITHUB_STEP_SUMMARY.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

TAG = re.compile(r"^([a-z][a-z0-9_]*)\.(\d{4}-\d{2}-\d{2})\.(\d{3,})$")
PAGE = 100
WINDOW = timedelta(hours=24)


def repo():
    return os.environ["GITHUB_REPOSITORY"]


def gh(*args):
    res = subprocess.run(["gh", *args], capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit(f"failed: gh {' '.join(args[:3])}\n{res.stderr.strip()}")
    return res.stdout


def gh_json(path):
    return json.loads(gh("api", path) or "[]")


def emit(name, value):
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(f"{name}={value}\n")


def summary(text):
    print(text)
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(text + "\n")


def payload(deployment):
    value = deployment.get("payload") or {}
    if isinstance(value, str):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return {}
    return value


def parse_tag(tag):
    match = TAG.match(tag or "")
    if not match:
        sys.exit(f"::error::invalid release tag '{tag}': expected <module>.YYYY-MM-DD.NNN")
    return match.group(1), (match.group(2), int(match.group(3)))


def green(deployment_id):
    for status in gh_json(f"repos/{repo()}/deployments/{deployment_id}/statuses?per_page={PAGE}"):
        state = status.get("state")
        if state in ("failure", "error"):
            return False
        if state == "success":
            return True
    return False


def deployments(environment):
    return gh_json(f"repos/{repo()}/deployments?environment={environment}&per_page={PAGE}")


def latest_green(environment, module):
    for deployment in deployments(environment):
        data = payload(deployment)
        if data.get("module") == module and data.get("tag") and green(deployment["id"]):
            return data
    return None


def recorded_green(environment, module, tag):
    for deployment in deployments(environment):
        data = payload(deployment)
        if data.get("module") == module and data.get("tag") == tag and green(deployment["id"]):
            return data
    return None


def target(args):
    module, _ = parse_tag(args.tag)
    modules = json.loads(args.modules)
    if module not in modules:
        sys.exit(f"::error::unknown module '{module}' in tag {args.tag}")
    record = recorded_green("staging", module, args.tag)
    if record is None:
        sys.exit(f"::error::{args.tag} is not recorded green in staging")
    release_url = record.get("release_url", "")
    if not release_url:
        sys.exit(f"::error::verify wrote no release_url for {args.tag}")
    spec = modules[module]
    emit("module", module)
    emit("tag", args.tag)
    emit("code_dir", spec.get("code", ""))
    emit("services", spec.get("services", ""))
    emit("release_url", release_url)


def parse_time(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def promoted_last_day():
    now = datetime.now(timezone.utc)
    count = 0
    for deployment in deployments("promoted"):
        created = deployment.get("created_at")
        if created and now - parse_time(created) < WINDOW:
            count += 1
    return count


def record_promoted(module, tag):
    body = json.dumps({"module": module, "tag": tag}, separators=(",", ":"))
    created = json.loads(
        gh(
            "api", "-X", "POST", f"repos/{repo()}/deployments",
            "-f", f"ref={tag}", "-f", "environment=promoted", "-f", f"description={module} {tag}",
            "-f", f"payload={body}", "-F", "auto_merge=false", "-F", "transient_environment=false",
            "-F", "production_environment=false",
        )
    )
    gh(
        "api", "-X", "POST", f"repos/{repo()}/deployments/{created['id']}/statuses",
        "-f", "state=success", "-f", "environment=promoted",
    )


def decide(args):
    module, order = args.module, parse_tag(args.tag)[1]
    staging = latest_green("staging", module)
    if staging is None or staging["tag"] != args.tag:
        summary(f"superseded: {args.tag} is no longer the newest release green in staging")
        return emit("outcome", "superseded")
    production = latest_green("production", module)
    if production is not None and parse_tag(production["tag"])[1] > order:
        summary(f"superseded: production already runs {production['tag']}, newer than {args.tag}")
        return emit("outcome", "superseded")
    if args.max_per_day > 0:
        promoted = promoted_last_day()
        if promoted >= args.max_per_day:
            summary(f"promote capped ({promoted}/{args.max_per_day})")
            return emit("outcome", "capped")
    record_promoted(module, args.tag)
    gh("workflow", "run", "deploy.yml", "-R", repo(), "--ref", args.tag, "-f", "environment=production")
    summary(f"promoted: {args.tag} dispatched to production")
    return emit("outcome", "promoted")


def parse(argv):
    parser = argparse.ArgumentParser(prog="promote")
    sub = parser.add_subparsers(dest="command", required=True)
    tgt = sub.add_parser("target")
    tgt.add_argument("--tag", required=True)
    tgt.add_argument("--event", default="workflow_run")
    tgt.add_argument("--modules", required=True)
    dec = sub.add_parser("decide")
    dec.add_argument("--tag", required=True)
    dec.add_argument("--module", required=True)
    dec.add_argument("--max-per-day", type=int, default=0)
    return parser.parse_args(argv)


def main(argv=None):
    args = parse(sys.argv[1:] if argv is None else argv)
    target(args) if args.command == "target" else decide(args)


if __name__ == "__main__":
    main()
