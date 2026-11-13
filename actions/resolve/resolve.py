#!/usr/bin/env python3
"""resolve — the release tag of one module in one environment.

Every successful deploy is recorded as a GitHub Deployment whose payload carries
`{module, tag}`. This action reads those records:

  tag given     fail unless that tag is recorded green for the module there
  tag empty     the newest tag recorded green there for the module

A deployment that GitHub later marks `inactive` (a newer deploy entered the
same environment) is still green; a failure after the success is not.

Output (GITHUB_OUTPUT): `tag`.

Environment: INPUT_ENVIRONMENT, INPUT_MODULE, INPUT_TAG, GITHUB_REPOSITORY,
GH_TOKEN.
"""

import json
import os
import subprocess
import sys

PAGE = 100


def emit(name, value):
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
        handle.write(f"{name}={value}\n")


def gh(path):
    res = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit(f"failed: gh api {path}\n{res.stderr.strip()}")
    return json.loads(res.stdout or "[]")


def payload(deployment):
    value = deployment.get("payload") or {}
    if isinstance(value, str):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return {}
    return value


def recorded(environment, module, tag):
    """Deployments of the environment, newest first, as (id, module, tag)."""
    repo = os.environ["GITHUB_REPOSITORY"]
    rows = []
    for deployment in gh(f"repos/{repo}/deployments?environment={environment}&per_page={PAGE}"):
        data = payload(deployment)
        dep_module, dep_tag = data.get("module", ""), data.get("tag", "")
        if module and dep_module != module:
            continue
        if tag and dep_tag != tag:
            continue
        rows.append((deployment["id"], dep_module, dep_tag))
    return rows


def green(deployment_id):
    repo = os.environ["GITHUB_REPOSITORY"]
    statuses = gh(f"repos/{repo}/deployments/{deployment_id}/statuses?per_page=100")
    # GitHub marks an older deployment as `inactive` when a newer one enters the
    # same environment — that is housekeeping, not a failed release. Walk from
    # the newest status: a failure wins, an inactive/in_progress one is ignored,
    # and a success below it makes the deployment green.
    for status in statuses:
        state = status.get("state")
        if state in ("failure", "error"):
            return state
        if state == "success":
            return "success"
    return None


def main():
    environment = os.environ.get("INPUT_ENVIRONMENT") or "production"
    tag = os.environ.get("INPUT_TAG", "")
    module = os.environ.get("INPUT_MODULE", "") or (tag.split(".", 1)[0] if tag else "")
    if not tag and not module:
        sys.exit("resolve needs a tag or a module: nothing to look up")

    candidates = recorded(environment, module, tag)
    for deployment_id, dep_module, dep_tag in candidates:
        if not dep_tag:
            continue
        if green(deployment_id) == "success":
            print(f"resolved: {dep_module or module} {dep_tag} in {environment}")
            emit("tag", dep_tag)
            return

    if tag:
        sys.exit(f"{module or 'release'} {tag} is not recorded green in {environment}: nothing to promote")
    sys.exit(f"no release recorded green in {environment} for {module}: nothing to promote")


if __name__ == "__main__":
    main()
