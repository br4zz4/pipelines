#!/usr/bin/env python3
"""detect — turn the event's change set into one JSON of per-module changes.

Event change set
  push               EVENT_BEFORE..HEAD; a missing before or HEAD^ means everything
  pull_request       merge-base(EVENT_BASE or origin/<base>)..HEAD
  any other event    everything

A path under `modules.<name>.code.dir` touches the code side of `<name>`; a path
under `modules.<name>.infra.dir` touches its infra side. A `shared` path touches
both sides of every module. Anything else touches nothing. Documentation
(`*.md`, `docs/`, `.project/docs/`) is dropped from the change set before
matching, so a documentation-only change touches no module.

Output (GITHUB_OUTPUT)
  changes   {"<module>": {"any": bool, "code": bool, "infra": bool}, ...} with
            every module of the registry, read in a workflow as
            `fromJSON(needs.detect.outputs.changes).<module>.any`.

Registry: `.github/modules.json` of the calling repository. Paths default to
`modules/<name>/code` and `modules/<name>/infra`. Only `shared`,
`modules.<name>.code.dir` and `modules.<name>.infra.dir` are read.
"""

import json
import os
import re
import subprocess
import sys

DEFAULT_SHARED = (".github/", ".project/", "Makefile", "compose.yml")
NAME = re.compile(r"^[a-z][a-z0-9_]*$")
DOCUMENTATION_DIRS = (".project/docs/", "docs/")


def documentation(path):
    return path.endswith(".md") or path.startswith(DOCUMENTATION_DIRS)


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def sh(*cmd):
    res = run(*cmd)
    if res.returncode != 0:
        sys.exit(f"failed: {' '.join(cmd)}\n{res.stderr.strip()}")
    return res.stdout.strip()


def ok(*cmd):
    return run(*cmd).returncode == 0


def emit(name, value):
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
        handle.write(f"{name}={value}\n")


def report(rows, tracks):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    if not rows:
        lines = ["## modules", "", "no module changed"]
    else:
        lines = ["## modules", "", "| module | code | infra |", "|---|---|---|"]
        lines += [f"| {row['module']} | {row['code']} | {row['infra']} |" for row in rows]
    lines += ["", f"`{','.join(tracks) or '-'}`"]
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def registry(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def dirs(name, spec):
    code = (spec.get("code") or {}).get("dir") or f"modules/{name}/code"
    infra = (spec.get("infra") or {}).get("dir") or f"modules/{name}/infra"
    return code, infra


def diff_paths():
    event = os.environ.get("GITHUB_EVENT_NAME", "")
    if event == "pull_request":
        base = os.environ.get("EVENT_BASE") or f"origin/{os.environ.get('GITHUB_BASE_REF') or 'main'}"
        merge_base = sh("git", "merge-base", "HEAD", base)
        return sh("git", "diff", "--name-only", merge_base, "HEAD").splitlines()
    if event == "push":
        before = os.environ.get("EVENT_BEFORE", "")
        if before and set(before) != {"0"} and ok("git", "cat-file", "-e", f"{before}^{{commit}}"):
            return sh("git", "diff", "--name-only", before, "HEAD").splitlines()
        if ok("git", "rev-parse", "--verify", "HEAD^"):
            return sh("git", "diff", "--name-only", "HEAD^", "HEAD").splitlines()
        return None
    return None


def touched(paths, shared, root):
    if paths is None:
        return True
    root = root.rstrip("/")
    if any(path == root or path.startswith(root + "/") for path in paths):
        return True
    return any(path == entry or path.startswith(entry) for path in paths for entry in shared)


def main():
    reg = registry(os.environ.get("INPUT_REGISTRY", ".github/modules.json"))
    paths = diff_paths()
    if paths is not None:
        paths = [path for path in paths if not documentation(path)]
    shared = tuple(reg.get("shared") or DEFAULT_SHARED)
    modules = reg.get("modules") or {}
    changes, rows, changed = {}, [], []
    for name, spec in sorted(modules.items()):
        if not NAME.match(name):
            sys.exit(f"module name '{name}' must match [a-z][a-z0-9_]*")
        code_dir, infra_dir = dirs(name, spec)
        code = touched(paths, shared, code_dir)
        infra = touched(paths, shared, infra_dir)
        changes[name] = {"any": code or infra, "code": code, "infra": infra}
        if code or infra:
            changed.append(name)
        rows.append({"module": name, "code": "changed" if code else "-", "infra": "changed" if infra else "-"})
    emit("changes", json.dumps(changes, separators=(",", ":"), sort_keys=True))
    report(rows, changed)


if __name__ == "__main__":
    main()
