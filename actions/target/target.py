#!/usr/bin/env python3
"""target — what a build tag asks to build.

The Build starts on `build/<module>.YYYY-MM-DD.NNN`. This reads the module and
its directories from the registry and decides which sides need their checks: the
sides the `detect` computes for the range last release..HEAD, where the last
release is the newest release tag of the module that is an ancestor of HEAD.
Without one, or on any error, both sides are `true`.

Environment: REF_NAME, REGISTRY (default .github/modules.json), GITHUB_OUTPUT,
GITHUB_STEP_SUMMARY (optional).
"""

import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DETECT = os.path.join(os.path.dirname(HERE), "detect", "detect.py")
BUILD_TAG = re.compile(r"^build/([a-z][a-z0-9_]*)\.(\d{4}-\d{2}-\d{2})\.(\d{3,})$")
RELEASE_TAG = re.compile(r"^([a-z][a-z0-9_]*)\.(\d{4}-\d{2}-\d{2})\.(\d{3,})$")


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True)


def emit(values):
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
        for key, value in values.items():
            handle.write(f"{key}={value}\n")


def summary(text):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(text + "\n")


def last_release(module):
    found = []
    for name in git("tag", "-l", f"{module}.*").stdout.split():
        match = RELEASE_TAG.match(name)
        if match and match.group(1) == module:
            if git("merge-base", "--is-ancestor", f"refs/tags/{name}", "HEAD").returncode == 0:
                found.append(((match.group(2), int(match.group(3))), name))
    return max(found)[1] if found else ""


def sides_since(module, release):
    before = git("rev-parse", "--verify", f"{release}^{{commit}}")
    if before.returncode != 0:
        raise RuntimeError(f"tag {release} is not in the repository")
    with tempfile.NamedTemporaryFile("r", suffix=".out") as out:
        env = {**os.environ, "GITHUB_EVENT_NAME": "push", "EVENT_BEFORE": before.stdout.strip(), "GITHUB_OUTPUT": out.name}
        env.pop("GITHUB_STEP_SUMMARY", None)
        res = subprocess.run([sys.executable, DETECT], env=env, capture_output=True, text=True)
        if res.returncode != 0:
            raise RuntimeError(res.stderr.strip())
        line = next(item for item in out.read().splitlines() if item.startswith("changes="))
    side = json.loads(line.split("=", 1)[1])[module]
    return bool(side["code"]), bool(side["infra"])


def main():
    ref = os.environ.get("REF_NAME", "")
    registry_path = os.environ.get("REGISTRY", ".github/modules.json")
    match = BUILD_TAG.match(ref)
    if not match:
        print(f"::error::invalid build tag '{ref}' (expected build/<module>.YYYY-MM-DD.NNN)")
        return 1
    module = match.group(1)
    with open(registry_path, encoding="utf-8") as handle:
        modules = json.load(handle).get("modules") or {}
    if module not in modules:
        print(f"::error::build tag {ref} names module {module}, which is not in .github/modules.json")
        return 1

    spec = modules[module] or {}
    code_dir = (spec.get("code") or {}).get("dir") or f"modules/{module}/code"
    infra_dir = (spec.get("infra") or {}).get("dir") or f"modules/{module}/infra"
    release = last_release(module)
    code = infra = True
    if release:
        try:
            code, infra = sides_since(module, release)
        except (RuntimeError, KeyError, StopIteration, ValueError, OSError) as error:
            print(f"target: could not compute the range since {release} ({error})")
            code = infra = True
    flag = lambda value: "true" if value else "false"
    summary(f"last release: {release or 'none'}; code={flag(code)} infra={flag(infra)}")
    emit(
        {
            "module": module,
            "tag": ref[len("build/"):],
            "code_dir": code_dir,
            "infra_dir": infra_dir,
            "services": ",".join(spec.get("services") or []),
            "code": flag(code),
            "infra": flag(infra),
        }
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
