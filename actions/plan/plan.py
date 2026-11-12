#!/usr/bin/env python3
"""plan — resolve which modules and steps a run carries into GitHub Actions matrices.

Modes
  check    modules touched by the event's change set. push = EVENT_BEFORE..HEAD
           (a missing before or HEAD^ means everything), pull_request =
           merge-base(EVENT_BASE or origin/<base>)..HEAD, any other event =
           everything. A shared path touches every subtrack.
  release  modules carried by a release tag, with the per-environment deploy
           parameters. An empty ref resolves the newest release recorded green in
           `environment`. The tag's `tracks:` line lists modules; a lightweight
           tag (no message) carries every module. `modules` narrows the result.

Subtracks
  code     scripts in <code.dir>/ci/*.sh, except setup and package
  infra    `check` and `plan` scripts present in <deploy.dir>/ci/

Outputs (GITHUB_OUTPUT)
  code     matrix of code subtracks    (mode=check)
  infra    matrix of infra subtracks   (mode=check)
  release  matrix of modules in the release: any subtrack touched (mode=check)
  modules  matrix of module deploys    (mode=release)
  tracks   comma list of module names, e.g. `main,checkout`
  tag      resolved release tag        (mode=release)
  any      `true` when at least one module is in the run

In check mode a matrix carries only the legs that changed. When nothing changed
it carries a single sentinel leg (`module=none`, `changed=false`), so a caller
can fan out without special-casing an empty matrix. The summary still lists
every module of the registry.

Registry: .github/modules.json of the calling repository. Paths default to
`modules/<name>/code` and `modules/<name>/deploy`; `url` is the `url` of the
module's `environments.<environment>` entry.
"""

import glob
import json
import os
import subprocess
import sys

CODE_EXCLUDED = {"setup", "package"}
INFRA_STEPS = ("check", "plan")
DEFAULT_SHARED = (".github/", ".project/", "Makefile", "compose.yml")


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


def report(mode, rows, tracks):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    if not rows:
        lines = ["## modules", "", "no module in the run"]
    elif mode == "check":
        lines = ["## modules", "", "| module | code | infra |", "|---|---|---|"]
        lines += [f"| {row['module']} | {row['code']} | {row['infra']} |" for row in rows]
    else:
        lines = ["## modules", "", "| module | environment | url |", "|---|---|---|"]
        lines += [f"| {row['module']} | {row['environment']} | {row['url'] or '-'} |" for row in rows]
    lines += ["", f"`{','.join(tracks) or '-'}`"]
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def registry(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def dirs(name, spec):
    code = (spec.get("code") or {}).get("dir") or f"modules/{name}/code"
    deploy = (spec.get("deploy") or {}).get("dir") or f"modules/{name}/deploy"
    return code, deploy


def scripts(directory):
    return [os.path.basename(path)[:-3] for path in sorted(glob.glob(f"{directory}/ci/*.sh"))]


def code_steps(code_dir):
    return [step for step in scripts(code_dir) if step not in CODE_EXCLUDED]


def infra_steps(deploy_dir):
    return [step for step in INFRA_STEPS if step in scripts(deploy_dir)]


def steps_matrix(steps):
    return json.dumps({"include": [{"step": step} for step in steps] or [{"step": "none"}]})


def url_of(spec, environment):
    return ((spec.get("environments") or {}).get(environment) or {}).get("url", "")


def leg(name, spec, environment, changed, tag, steps, code_changed=None):
    code_dir, deploy_dir = dirs(name, spec)
    return {
        "module": name,
        "module_dir": f"modules/{name}",
        "code_dir": code_dir,
        "deploy_dir": deploy_dir,
        "steps": ",".join(steps),
        "steps_matrix": steps_matrix(steps),
        "package": "true" if os.path.isfile(f"{code_dir}/ci/package.sh") else "false",
        "changed": changed,
        "code_changed": changed if code_changed is None else code_changed,
        "url": url_of(spec, environment),
        "environment": environment,
        "tag": tag,
    }


def sentinel(environment):
    return {
        "module": "none",
        "module_dir": "",
        "code_dir": "",
        "deploy_dir": "",
        "steps": "",
        "steps_matrix": steps_matrix([]),
        "package": "false",
        "changed": "false",
        "code_changed": "false",
        "url": "",
        "environment": environment,
        "tag": "",
    }


def matrix(legs, environment):
    return json.dumps({"include": legs or [sentinel(environment)]})


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


def check(reg, environment):
    paths = diff_paths()
    shared = tuple(reg.get("shared") or DEFAULT_SHARED)
    modules = reg.get("modules") or {}
    code, infra, release, rows, tracks = [], [], [], [], []
    for name, spec in modules.items():
        code_dir, deploy_dir = dirs(name, spec)
        code_changed = touched(paths, shared, code_dir)
        infra_changed = touched(paths, shared, deploy_dir)
        if code_changed:
            code.append(leg(name, spec, environment, "true", "", code_steps(code_dir), "true"))
        if infra_changed:
            infra.append(leg(name, spec, environment, "true", "", infra_steps(deploy_dir), "false"))
        if code_changed or infra_changed:
            release.append(leg(name, spec, environment, "true", "", code_steps(code_dir),
                               "true" if code_changed else "false"))
            tracks.append(name)
        rows.append({
            "module": name,
            "code": "changed" if code_changed else "-",
            "infra": "changed" if infra_changed else "-",
        })
    emit("code", matrix(code, environment))
    emit("infra", matrix(infra, environment))
    emit("release", matrix(release, environment))
    emit("tracks", ",".join(tracks))
    emit("any", "true" if tracks else "false")
    report("check", rows, tracks)


def tag_tracks(ref):
    if not ref:
        return None
    contents = run("git", "tag", "-l", "--format=%(contents)", ref).stdout
    for line in contents.splitlines():
        if line.strip().lower().startswith("tracks:"):
            return {item.strip() for item in line.split(":", 1)[1].split(",") if item.strip()}
    return None


def green_tag(environment):
    repo = os.environ["GITHUB_REPOSITORY"]
    ids = sh("gh", "api", f"repos/{repo}/deployments?environment={environment}&per_page=50",
             "--jq", ".[].id").split()
    for deployment in ids:
        tag = run("gh", "api", f"repos/{repo}/deployments/{deployment}",
                  "--jq", '(.payload | if type=="string" then fromjson else . end).tag // empty').stdout.strip()
        state = run("gh", "api", f"repos/{repo}/deployments/{deployment}/statuses?per_page=1",
                    "--jq", ".[0].state // empty").stdout.strip()
        if tag and state == "success":
            return tag
    sys.exit(f"no release recorded green in {environment}: nothing to promote")


def release(reg, environment, ref, scope):
    tag = ref or green_tag(environment)
    carried = tag_tracks(tag)
    modules = reg.get("modules") or {}
    names = sorted(carried) if carried is not None else sorted(modules)
    if scope:
        names = [name for name in names if name in scope]
    legs, rows = [], []
    for name in names:
        spec = modules.get(name)
        if not spec:
            sys.exit(f"module '{name}' is not in the registry")
        code_dir, _ = dirs(name, spec)
        entry = leg(name, spec, environment, "true", tag, code_steps(code_dir))
        legs.append(entry)
        rows.append({"module": name, "environment": environment, "url": entry["url"]})
    if not legs:
        sys.exit(f"release {tag} carries no module of {','.join(scope)}")
    emit("modules", json.dumps({"include": legs}))
    emit("tracks", ",".join(names))
    emit("tag", tag)
    emit("any", "true")
    report("release", rows, names)


def main():
    mode = os.environ.get("INPUT_MODE", "check")
    environment = os.environ.get("INPUT_ENVIRONMENT", "staging")
    ref = os.environ.get("INPUT_REF", "")
    scope = [item.strip() for item in os.environ.get("INPUT_MODULES", "").split(",") if item.strip()]
    reg = registry(os.environ.get("INPUT_REGISTRY", ".github/modules.json"))
    if mode == "release":
        release(reg, environment, ref, scope)
    else:
        check(reg, environment)


if __name__ == "__main__":
    main()
