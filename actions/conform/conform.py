#!/usr/bin/env python3
"""conform — fail when a project drifts from the pipelines standard.

Modes:
  check  report violations; exit 1 when there is any.
  fix    write the rendered workflows; with GH_PIPELINES_TOKEN, commit and push
         them, then exit 1 so the run restarts on the new commit. Without the
         token it behaves as check.

Usage: conform.py --root <project> --mode check|fix
"""

import argparse
import difflib
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import render  # noqa: E402

HOOK_DIRS = {
    "code":  {"checks": ("lint", "audit", "test", "regression", "e2e", "build")},
    "infra": {"checks": ("validate", "plan"), "deploy": ("apply", "deployment", "migrate", "rollout", "verify")},
}
OPTIONAL_HOOKS = ("migrate", "rollout")
PROMOTE_HOOKS = ("regression", "e2e")
GENERATED = set(render.FILES)
COMMIT_MESSAGE = "ci: render workflows"
RERENDERED = "workflows re-rendered; a new run was triggered"


def read(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except FileNotFoundError:
        return None


def workflow_dir(root):
    return os.path.join(root, ".github", "workflows")


def drift(root, expected):
    problems, diffs = [], []
    for name, text in expected.items():
        path = os.path.join(workflow_dir(root), name)
        current = read(path)
        if current == text:
            continue
        shown = f".github/workflows/{name}"
        problems.append(f"{shown} differs from the render (missing)" if current is None else f"{shown} differs from the render")
        diff = difflib.unified_diff(
            (current or "").splitlines(keepends=True), text.splitlines(keepends=True), f"a/{shown}", f"b/{shown}"
        )
        diffs.append("".join(diff))
    return problems, diffs


def workflow_files(root):
    directory = workflow_dir(root)
    if not os.path.isdir(directory):
        return []
    return sorted(f for f in os.listdir(directory) if f.endswith((".yml", ".yaml")))


def check_workflows(root, project):
    problems = []
    allowed = GENERATED | set(project["extra"])
    if project["promote"] is not None:
        allowed.add(render.PROMOTE_FILE)
    for name in workflow_files(root):
        shown = f".github/workflows/{name}"
        if name not in allowed:
            problems.append(f"{shown} is not part of the standard (declare it in extra_workflows)")
        if name != "deploy.yml" and "_RESTRICTED" in (read(os.path.join(workflow_dir(root), name)) or ""):
            problems.append(f"{shown} mentions a restricted ward key outside deploy.yml")
    return problems


RUN_HOOKS = ("lint", "audit", "test", "regression", "e2e")


def check_hooks(root, directory, side, module, promote=False):
    problems = []
    base = os.path.join(root, directory)
    if not os.path.isfile(os.path.join(base, "mise.toml")):
        problems.append(f"module {module}: {directory}/mise.toml is missing")
    for context, hooks in HOOK_DIRS[side].items():
        ctx_dir = os.path.join(base, "ci", context)
        present = sorted(f for f in os.listdir(ctx_dir) if f.endswith(".sh")) if os.path.isdir(ctx_dir) else []
        for hook in hooks:
            if f"{hook}.sh" in present:
                continue
            if side == "infra" and hook in OPTIONAL_HOOKS:
                continue
            if side == "code" and hook in PROMOTE_HOOKS and not promote:
                continue
            if side == "code" and hook in RUN_HOOKS and os.path.isfile(os.path.join(base, "run", hook)):
                continue
            problems.append(f"module {module}: {directory}/ci/{context}/{hook}.sh is missing ({context} hook)")
        for name in present:
            if name == "rollback.sh" and context == "deploy":
                problems.append(f"module {module}: {directory}/ci/{context}/rollback.sh is retired in v2: a failed deploy dispatches a deploy of the previous release")
            elif name[:-3] not in hooks:
                problems.append(f"module {module}: {directory}/ci/{context}/{name} is outside the {context} vocabulary ({', '.join(hooks)})")
    return problems


def check_modules(root, project):
    problems = []
    for module in project["modules"]:
        problems += check_hooks(root, module["code"], "code", module["name"], project["promote"] is not None)
        problems += check_hooks(root, module["infra"], "infra", module["name"])
    if not os.path.isfile(os.path.join(root, ".github", "actions", "setup", "action.yml")):
        problems.append(".github/actions/setup/action.yml is missing")
    return problems


def summarize(diffs):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path or not diffs:
        return
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("## conform\n\nThe workflows differ from the render:\n\n```diff\n" + "\n".join(diffs) + "\n```\n")


def git(root, *args):
    return subprocess.run(["git", "-C", root, *args], capture_output=True, text=True)


def push_url(token):
    override = os.environ.get("CONFORM_PUSH_URL")
    if override:
        return override
    repository = os.environ.get("GITHUB_REPOSITORY")
    if repository:
        return f"https://x-access-token:{token}@github.com/{repository}"
    return "origin"


def commit_and_push(root, token):
    if git(root, "rev-parse", "--git-dir").returncode != 0:
        return False
    branch = os.environ.get("GITHUB_HEAD_REF") or git(root, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
    steps = [
        ["add", ".github/workflows"],
        ["-c", "user.name=github-actions", "-c", "user.email=github-actions@users.noreply.github.com", "commit", "-q", "-m", COMMIT_MESSAGE],
        ["push", "-q", push_url(token), f"HEAD:refs/heads/{branch}"],
    ]
    for step in steps:
        result = git(root, *step)
        if result.returncode != 0:
            print(f"::error::git {step[-3] if step[0] == '-c' else step[0]} failed: {result.stderr.strip().replace(token, '***')}")
            return False
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", required=True)
    parser.add_argument("--mode", choices=("check", "fix"), default="check")
    parser.add_argument("--ref", default=render.DEFAULT_REF, help="ref of br4zz4/pipelines the workflows call")
    args = parser.parse_args(argv)
    root = os.path.abspath(args.root)

    try:
        project = render.load_project(root)
    except render.RenderError as error:
        print(f"::error::{error}")
        return 1

    expected = render.render(project, args.ref)
    problems, diffs = drift(root, expected)
    summarize(diffs)
    token = os.environ.get("GH_PIPELINES_TOKEN", "")

    if args.mode == "fix" and problems and token:
        os.makedirs(workflow_dir(root), exist_ok=True)
        for name, text in expected.items():
            with open(os.path.join(workflow_dir(root), name), "w", encoding="utf-8", newline="\n") as handle:
                handle.write(text)
        if commit_and_push(root, token):
            print(f"::error::{RERENDERED}")
            return 1
        problems = ["could not push the re-rendered workflows"]

    problems += check_workflows(root, project)
    problems += check_modules(root, project)
    for problem in problems:
        print(f"::error::{problem}")
    if problems:
        return 1
    print(f"ok: {len(project['modules'])} modules, namespace {project['ns']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
