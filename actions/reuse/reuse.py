#!/usr/bin/env python3
"""reuse — may main skip the steps a green pull request already proved?

A commit that landed through a pull request carries the change that request
tested, so main would run the same steps a second time. This action answers
"may main skip them?" and says why.

It never compares shas: a squash or rebase merge writes a new one. The pull
request is found through the API, and the steps count as proved only when the
merge landed and every step is green on the request's head **and** every file
of the landed commit has the same content the request tested. A doubt of any
kind answers `false`, and an error answers `false`, so the steps run.
"""

import json
import os
import urllib.error
import urllib.request

API = "https://api.github.com"
TOKEN = os.environ.get("TOKEN", "")
REPOSITORY = os.environ["REPOSITORY"]
SHA = os.environ["SHA"]
MODULE = os.environ["MODULE"]
STEPS = os.environ.get("STEPS", "")
CHECK_PREFIX = os.environ.get("CHECK_PREFIX", "")


def call(path):
    request = urllib.request.Request(
        f"{API}{path}",
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "br4zz4-pipelines-reuse",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def pages(path):
    separator = "&" if "?" in path else "?"
    items, page = [], 1
    while page <= 30:
        chunk = call(f"{path}{separator}per_page=100&page={page}")
        if not isinstance(chunk, list) or not chunk:
            break
        items.extend(chunk)
        if len(chunk) < 100:
            break
        page += 1
    return items


def check_names():
    prefix = CHECK_PREFIX or f"{MODULE} / check"
    return [f"{prefix} / {step}" for step in STEPS.split(",") if step]


def conclusions(head):
    page = 1
    state = {}
    while page <= 30:
        chunk = call(f"/repos/{REPOSITORY}/commits/{head}/check-runs?filter=latest&per_page=100&page={page}")
        runs = chunk.get("check_runs") or []
        for run in runs:
            state.setdefault(run["name"], run.get("conclusion"))
        if len(runs) < 100:
            break
        page += 1
    return state


def commit_blobs(commit):
    files = call(f"/repos/{REPOSITORY}/commits/{commit}").get("files") or []
    return {entry["filename"]: entry.get("sha") for entry in files}


def request_blobs(number):
    return {entry["filename"]: entry.get("sha") for entry in pages(f"/repos/{REPOSITORY}/pulls/{number}/files")}


def decide():
    """Return ({step: bool}, reason): a step is proved when the merged pull
    request is green on it and tested exactly the content that landed."""
    steps = [step for step in STEPS.split(",") if step]
    landed = commit_blobs(SHA)
    merged = [request for request in call(f"/repos/{REPOSITORY}/commits/{SHA}/pulls") if request.get("merged_at")]
    proved = {step: False for step in steps}
    if not merged:
        return proved, f"no merged pull request delivered {SHA[:7]}"

    reasons = []
    prefix = CHECK_PREFIX or f"{MODULE} / check"
    for request in merged:
        number, head = request["number"], request["head"]["sha"]
        tested = request_blobs(number)
        if tested != landed:
            differing = sorted(set(tested) ^ set(landed)) or [path for path in landed if tested[path] != landed[path]]
            reasons.append(f"PR #{number} tested other content ({', '.join(differing[:3])})")
            continue
        state = conclusions(head)
        for step in steps:
            proved[step] = proved[step] or state.get(f"{prefix} / {step}") == "success"
        missing = [step for step in steps if not proved[step]]
        if missing:
            reasons.append(f"PR #{number} is not green on {', '.join(missing)}")
        else:
            return proved, f"PR #{number} is green on {', '.join(steps)} for this content"
    return proved, "; ".join(reasons)


def main():
    steps = [step for step in STEPS.split(",") if step]
    try:
        proved, reason = decide()
    except (urllib.error.URLError, KeyError, ValueError, TimeoutError) as error:
        proved, reason = {step: False for step in steps}, f"could not prove the pull request ({error})"

    everything = bool(steps) and all(proved.values())
    print(f"reuse={str(everything).lower()} — {reason}")
    for step in steps:
        print(f"  {step}={str(proved[step]).lower()}")
    with open(os.environ.get("GITHUB_OUTPUT", os.devnull), "a", encoding="utf-8") as output:
        output.write(f"reuse={str(everything).lower()}\n")
        output.write(f"reason={reason}\n")
        for step in steps:
            output.write(f"{step}={str(proved[step]).lower()}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
