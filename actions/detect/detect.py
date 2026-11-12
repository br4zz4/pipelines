#!/usr/bin/env python3
"""detect — turn the event's change set into matrices and per-module booleans.

Event change set
  push               EVENT_BEFORE..HEAD; a missing before or HEAD^ means everything
  pull_request       merge-base(EVENT_BASE or origin/<base>)..HEAD
  any other event    everything

A path under `modules.<name>.code.dir` touches the code subtrack of `<name>`; a
path under `modules.<name>.infra.dir` touches its infra subtrack. A `shared`
path touches both of every module. Anything else touches nothing.

Outputs (GITHUB_OUTPUT)
  code             matrix of code subtracks that changed
  infra            matrix of infra subtracks that changed
  modules          matrix of modules that changed, one leg each
  tracks           comma list of module names that changed
  any              `true` when at least one module changed
  <module>_code    `true` when the code subtrack of <module> changed
  <module>_infra   `true` when the infra subtrack of <module> changed

A matrix with nothing changed carries one sentinel leg (`module=none`,
`changed=false`, `steps_matrix={"include":[{"step":"none"}]}`), so a caller can
fan out unconditionally. `changed=false` lets the reusable workflow skip it.

Registry: `.github/modules.json` of the calling repository. Paths default to
`modules/<name>/code` and `modules/<name>/infra`. Only `shared`,
`modules.<name>.code.dir` and `modules.<name>.infra.dir` are read.
"""

import glob
import json
import os
import re
import subprocess
import sys

CODE_EXCLUDED = {"setup", "build"}
INFRA_STEPS = ("check", "prepare")
DEFAULT_SHARED = (".github/", ".project/", "Makefile", "compose.yml")
NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*$")


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


def scripts(directory):
    return [os.path.basename(path)[:-3] for path in sorted(glob.glob(f"{directory}/ci/*.sh"))]


def code_steps(directory):
    return [step for step in scripts(directory) if step not in CODE_EXCLUDED]


def infra_steps(directory):
    return [step for step in INFRA_STEPS if step in scripts(directory)]


def steps_matrix(steps):
    return json.dumps({"include": [{"step": step} for step in steps] or [{"step": "none"}]})


def leg(name, directory, steps, changed):
    return {
        "module": name,
        "dir": directory,
        "steps": ",".join(steps),
        "steps_matrix": steps_matrix(steps),
        "changed": changed,
    }


def sentinel():
    return leg("none", "", [], "false")


def matrix(legs):
    return json.dumps({"include": legs or [sentinel()]})


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
    shared = tuple(reg.get("shared") or DEFAULT_SHARED)
    modules = reg.get("modules") or {}
    code, infra, changed, rows = [], [], [], []
    for name, spec in modules.items():
        if not NAME.match(name):
            sys.exit(f"module name '{name}' is not a valid output key (use letters, digits, _ and -)")
        code_dir, infra_dir = dirs(name, spec)
        code_changed = touched(paths, shared, code_dir)
        infra_changed = touched(paths, shared, infra_dir)
        if code_changed:
            code.append(leg(name, code_dir, code_steps(code_dir), "true"))
        if infra_changed:
            infra.append(leg(name, infra_dir, infra_steps(infra_dir), "true"))
        if code_changed or infra_changed:
            changed.append(name)
        emit(f"{name}_code", "true" if code_changed else "false")
        emit(f"{name}_infra", "true" if infra_changed else "false")
        rows.append({
            "module": name,
            "code": "changed" if code_changed else "-",
            "infra": "changed" if infra_changed else "-",
        })
    emit("code", matrix(code))
    emit("infra", matrix(infra))
    emit("modules", json.dumps({"include": [{"module": name} for name in changed] or [{"module": "none"}]}))
    emit("tracks", ",".join(changed))
    emit("any", "true" if changed else "false")
    report(rows, changed)


if __name__ == "__main__":
    main()
