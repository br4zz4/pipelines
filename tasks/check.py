#!/usr/bin/env python3
"""check — validate the pipeline definitions against each other.

Catches the failures that only show up at run time:
  - a `with:`/`secrets:` key the called workflow or action does not declare
  - a required input/secret the caller forgets
  - a `uses:` target that does not exist
  - a relative `uses:` (resolves against the caller's repository, never ours)
  - a `matrix.*` reference the planner never emits
  - a shell script that is missing, not executable or fails `sh -n`
  - a platform-specific token inside the workflows or actions (examples are free)

Usage: check.py [--consumers <project-dir> ...]
"""

import glob
import json
import os
import re
import subprocess
import sys
import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOWS = sorted(glob.glob(f"{ROOT}/.github/workflows/*.yml"))
ACTIONS = sorted(glob.glob(f"{ROOT}/actions/*/action.yml"))
PROJECT_SETUP = "./.github/actions/setup"
MATRIX_KEYS = {
    "module", "module_dir", "code_dir", "deploy_dir", "steps", "steps_matrix",
    "package", "changed", "url", "environment", "tag", "step", "rollback",
}
PLATFORM = re.compile(r"\b(gcloud|kubectl|aws|docr|ecr|gar)\b", re.IGNORECASE)
PLATFORM_ROOTS = (".github/workflows", "actions")
PLATFORM_SUFFIXES = (".yml", ".yaml", ".sh", ".py")

problems = []


def fail(origin, message):
    problems.append(f"{origin}: {message}")


def load(path):
    with open(path, encoding="utf-8") as handle:
        return yaml.safe_load(handle) or {}


def declared(node, kind):
    # PyYAML reads the `on` key as the boolean True (YAML 1.1).
    trigger = node.get("on") or node.get(True) or {}
    return (trigger.get("workflow_call") or {}).get(kind) or {}


def required(node, kind):
    return {name for name, spec in declared(node, kind).items() if (spec or {}).get("required")}


def check_reusable(origin, target, with_keys, secret_keys):
    name = target.rsplit("/", 1)[-1].split("@")[0].removesuffix(".yml")
    path = f"{ROOT}/.github/workflows/{name}.yml"
    if not os.path.exists(path):
        return fail(origin, f"reusable workflow not found: {target}")
    node = load(path)
    inputs, secrets = declared(node, "inputs"), declared(node, "secrets")
    for key in with_keys - set(inputs):
        fail(origin, f"`with: {key}` is not an input of {name}.yml")
    for key in secret_keys - set(secrets):
        fail(origin, f"`secrets: {key}` is not declared by {name}.yml")
    for key in required(node, "inputs") - with_keys:
        fail(origin, f"required input `{key}` of {name}.yml is missing")
    for key in required(node, "secrets") - secret_keys:
        fail(origin, f"required secret `{key}` of {name}.yml is missing")


def check_action(origin, target, with_keys):
    name = target.split("/actions/", 1)[1].split("@")[0]
    path = f"{ROOT}/actions/{name}/action.yml"
    if not os.path.exists(path):
        return fail(origin, f"action not found: {target}")
    node = load(path)
    inputs = node.get("inputs") or {}
    for key in with_keys - set(inputs):
        fail(origin, f"`with: {key}` is not an input of action {name}")
    for key, spec in inputs.items():
        if (spec or {}).get("required") and key not in with_keys:
            fail(origin, f"required input `{key}` of action {name} is missing")


def matrix_refs(origin, node):
    text = json.dumps(node)
    for token in ("matrix.",):
        start = 0
        while (index := text.find(token, start)) != -1:
            start = index + len(token)
            key = ""
            while start < len(text) and (text[start].isalnum() or text[start] in "_-"):
                key += text[start]
                start += 1
            if key and key not in MATRIX_KEYS:
                fail(origin, f"`matrix.{key}` is never emitted by the planner")


def check_workflow(path):
    origin = os.path.relpath(path, ROOT)
    node = load(path)
    matrix_refs(origin, node)
    for job_id, job in (node.get("jobs") or {}).items():
        uses = job.get("uses")
        if not uses:
            continue
        where = f"{origin}#{job_id}"
        if uses == PROJECT_SETUP:
            continue
        if uses.startswith("./"):
            fail(where, f"relative `uses: {uses}` resolves against the caller's repository")
            continue
        if not uses.startswith("br4zz4/pipelines/"):
            continue
        with_keys = set((job.get("with") or {}).keys())
        secret_keys = set((job.get("secrets") or {}).keys())
        if "/.github/workflows/" in uses:
            check_reusable(where, uses, with_keys, secret_keys)
        elif "/actions/" in uses:
            check_action(where, uses, with_keys)


def check_platforms():
    for root in PLATFORM_ROOTS:
        for path in sorted(glob.glob(f"{ROOT}/{root}/**/*", recursive=True)):
            if not os.path.isfile(path) or not path.endswith(PLATFORM_SUFFIXES):
                continue
            origin = os.path.relpath(path, ROOT)
            if origin.startswith("examples/"):
                continue
            with open(path, encoding="utf-8") as handle:
                for number, line in enumerate(handle, 1):
                    if PLATFORM.search(line):
                        fail(origin, f"platform-specific token on line {number}: {line.strip()}")


def check_scripts():
    for path in sorted(glob.glob(f"{ROOT}/actions/*/*.sh")):
        result = subprocess.run(["sh", "-n", path], capture_output=True, text=True)
        if result.returncode != 0:
            fail(os.path.relpath(path, ROOT), result.stderr.strip())
    for path in glob.glob(f"{ROOT}/actions/*/action.yml"):
        node = load(path)
        origin = os.path.relpath(path, ROOT)
        for step in ((node.get("runs") or {}).get("steps") or []):
            script = step.get("run") or ""
            marker = "${{ github.action_path }}/"
            if marker not in script:
                fail(origin, f"composite step without a script: {script}")
                continue
            referenced = script.split(marker, 1)[1].split('"')[0].split()[0]
            if not os.path.exists(f"{os.path.dirname(path)}/{referenced}"):
                fail(origin, f"script referenced but missing: {referenced}")


def check_consumers(directory):
    paths = sorted(glob.glob(f"{directory}/.github/workflows/*.yml"))
    if not paths:
        fail(directory, "no workflows found")
    for path in paths:
        for job_id, job in (load(path).get("jobs") or {}).items():
            uses = job.get("uses") or ""
            if not uses.startswith("br4zz4/pipelines/.github/workflows/"):
                continue
            where = f"{path}#{job_id}"
            check_reusable(where, uses,
                           set((job.get("with") or {}).keys()),
                           set((job.get("secrets") or {}).keys()))
    print(f"checked {len(paths)} consumer workflows in {directory}")


def main():
    consumers = [sys.argv[i + 1] for i, arg in enumerate(sys.argv) if arg == "--consumers"]
    for path in WORKFLOWS:
        check_workflow(path)
    check_platforms()
    check_scripts()
    for directory in consumers:
        check_consumers(directory)
    if problems:
        print("\n".join(f"::error::{problem}" for problem in problems))
        return 1
    print(f"ok: {len(WORKFLOWS)} workflows, {len(ACTIONS)} actions")
    return 0


if __name__ == "__main__":
    sys.exit(main())
