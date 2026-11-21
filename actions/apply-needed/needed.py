#!/usr/bin/env python3
"""needed — does a deploy need the apply hook?

The apply hook reconciles infrastructure, syncs secrets and, in production, promotes
the image. When nothing it reads changed since the last release that went green in the
environment, it only costs a job. This script answers `needed=false` only when it can
prove that:

  FORCE=true           always `true` (a rollback re-applies what the release it returns to expects)
  production           always `true` (the image is promoted and the restricted vault read)
  no previous release  `true`
  previous == tag      `true` (a re-run)
  otherwise            the `infra` side of MODULE, as `detect` computes it for the range
                       previous..tag: infra dir and `shared` paths, documentation ignored

Any doubt, or any error computing the range, answers `true`.

Environment: ENVIRONMENT, MODULE, TAG, PREVIOUS (tag of the last green release, may be
empty), INPUT_REGISTRY (default .github/modules.json), GITHUB_OUTPUT.
"""

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DETECT = os.path.join(os.path.dirname(HERE), "detect", "detect.py")


def emit(value):
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
        handle.write(f"needed={'true' if value else 'false'}\n")


def commit_of(tag):
    res = subprocess.run(["git", "rev-parse", "--verify", f"{tag}^{{commit}}"], capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"tag {tag} is not in the repository")
    return res.stdout.strip()


def current_head():
    branch = subprocess.run(["git", "symbolic-ref", "-q", "--short", "HEAD"], capture_output=True, text=True)
    if branch.returncode == 0:
        return branch.stdout.strip()
    return subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()


def detect_range(before):
    with tempfile.NamedTemporaryFile("r", suffix=".out") as out:
        env = {**os.environ, "GITHUB_EVENT_NAME": "push", "EVENT_BEFORE": before, "GITHUB_OUTPUT": out.name}
        env.pop("GITHUB_STEP_SUMMARY", None)
        res = subprocess.run([sys.executable, DETECT], env=env, capture_output=True, text=True)
        if res.returncode != 0:
            raise RuntimeError(res.stderr.strip())
        return next(line.split("=", 1)[1] for line in out.read().splitlines() if line.startswith("changes="))


def infra_changed(module, previous, tag):
    before = commit_of(previous)
    head = commit_of(tag)
    original = current_head()
    subprocess.run(["git", "checkout", "-q", "--detach", head], check=True, capture_output=True)
    try:
        changes = detect_range(before)
    finally:
        subprocess.run(["git", "checkout", "-q", original], capture_output=True)
    return bool(json.loads(changes)[module]["infra"])


def main():
    environment = os.environ.get("ENVIRONMENT", "")
    module = os.environ.get("MODULE", "")
    tag = os.environ.get("TAG", "")
    previous = os.environ.get("PREVIOUS", "")
    if os.environ.get("FORCE") == "true" or environment == "production" or not previous or previous == tag:
        return emit(True)
    try:
        emit(infra_changed(module, previous, tag))
    except (RuntimeError, KeyError, StopIteration, ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"apply needed: could not prove nothing changed ({error})")
        emit(True)


if __name__ == "__main__":
    main()
