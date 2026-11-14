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
SUBTACK = os.environ["SUBTACK"]
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
    prefix = CHECK_PREFIX or f"{SUBTACK} / {MODULE} / "
    return [f"{prefix}{step}" for step in STEPS.split(",") if step]


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
    landed = commit_blobs(SHA)
    merged = [request for request in call(f"/repos/{REPOSITORY}/commits/{SHA}/pulls") if request.get("merged_at")]
    if not merged:
        return False, f"no merged pull request delivered {SHA[:7]}"

    names = check_names()
    reasons = []
    for request in merged:
        number, head = request["number"], request["head"]["sha"]
        state = conclusions(head)
        missing = [name for name in names if state.get(name) != "success"]
        if missing:
            reasons.append(f"PR #{number} is not green on {', '.join(missing)}")
            continue

        tested = request_blobs(number)
        if tested != landed:
            differing = sorted(set(tested) ^ set(landed)) or [path for path in landed if tested[path] != landed[path]]
            reasons.append(f"PR #{number} tested other content ({', '.join(differing[:3])})")
            continue

        return True, f"PR #{number} is green on {', '.join(names)} for this content"

    return False, "; ".join(reasons)


def main():
    try:
        reuse, reason = decide()
    except (urllib.error.URLError, KeyError, ValueError, TimeoutError) as error:
        reuse, reason = False, f"could not prove the pull request ({error})"

    print(f"reuse={str(reuse).lower()} — {reason}")
    with open(os.environ.get("GITHUB_OUTPUT", os.devnull), "a", encoding="utf-8") as output:
        output.write(f"reuse={str(reuse).lower()}\n")
        output.write(f"reason={reason}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
