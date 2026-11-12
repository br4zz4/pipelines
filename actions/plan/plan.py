#!/usr/bin/env python3
"""plan — resolve which tracks a run carries into GitHub Actions matrices.

Modes
  check    tracks touched by the event's change set (PR, push, manual = all)
  release  tracks of a release tag, with per-environment deploy parameters;
           an empty ref resolves the newest release recorded green in `environment`

Outputs (GITHUB_OUTPUT)
  code     matrix for the `code` facet    (mode=check)
  infra    matrix for the `infra` facet   (mode=check)
  modules  matrix for module deploys      (mode=release)
  tracks   comma list, e.g. `main/code,checkout/infra`
  tag      resolved release tag           (mode=release)
  any      `true` when at least one track is in the run

Registry: .github/modules.json of the calling repository. Facet paths default
to `modules/<name>/code` and `modules/<name>/deploy`; a facet accepts `paths`
to override them and `dir` to point at its directory.
"""

import glob
import json
import os
import subprocess
import sys

FACETS = ("code", "infra")
FACET_DIR = {"code": "code", "infra": "deploy"}
RESERVED_STEPS = {"setup", "e2e"}
DEFAULT_SHARED = (".github/", "tasks/", ".project/", "Makefile", "compose.yml")


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


def report(legs, tracks):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    lines = ["## tracks", ""]
    if not legs:
        lines += ["nenhuma trilha afetada", ""]
    else:
        lines += ["| module | facet | in release |", "|---|---|---|"]
        for leg in legs:
            state = "yes" if leg.get("changed", "true") == "true" else "no"
            lines.append(f"| {leg['module']} | {leg['facets']} | {state} |")
        lines.append("")
    lines.append(f"`{','.join(tracks) or '-'}`")
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def registry(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def fill(value, environment):
    return value.replace("{env}", environment) if isinstance(value, str) else value


def env_config(spec, environment):
    return (spec.get("environments") or {}).get(environment) or {}


def image_of(region, config):
    if not config:
        return ""
    if config.get("image"):
        return config["image"]
    return f"{region}-docker.pkg.dev/{config['project']}/{config['repository']}/web"


def code_steps(code_dir):
    if not code_dir:
        return []
    names = [os.path.basename(path)[:-3] for path in sorted(glob.glob(f"{code_dir}/ci/*.sh"))]
    return [n for n in names if n not in RESERVED_STEPS and not n.startswith(("pre-", "post-"))]


def steps_matrix(steps):
    legs = [{"step": step} for step in steps] or [{"step": "none"}]
    return json.dumps({"include": legs})


def leg(reg, name, spec, environment, facets):
    config = env_config(spec, environment)
    source = env_config(spec, config.get("source", ""))
    code = spec.get("code") or {}
    infra = spec.get("infra") or {}
    state = infra.get("state") or {}
    package = code.get("package") or {}
    region = reg.get("region", "us-west1")
    code_dir = code.get("dir") or f"modules/{name}/code"
    steps = code_steps(code_dir)
    return {
        "module": name,
        "module_dir": f"modules/{name}",
        "facets": ",".join(sorted(facets)),
        "code": "true" if "code" in facets else "false",
        "infra": "true" if "infra" in facets else "false",
        "code_dir": code_dir,
        "steps": ",".join(steps),
        "steps_matrix": steps_matrix(steps),
        "e2e": "true" if steps and os.path.exists(f"{code_dir}/ci/e2e.sh") else "false",
        "package": "true" if package else "false",
        "package_context": package.get("context", code_dir),
        "package_target": package.get("target", ""),
        "cache_scope": name,
        "region": region,
        "image": image_of(region, config),
        "source_image": image_of(region, source) or image_of(region, config),
        "url": config.get("url", ""),
        "prefix": config.get("prefix", name),
        "tf_check_dir": infra.get("check_dir", ""),
        "tf_dir": fill(infra.get("dir", ""), environment),
        "tf_bucket": fill(state.get("bucket", ""), environment),
        "tf_state_prefix": state.get("prefix", ""),
        "tf_vars": json.dumps(infra.get("vars") or {}),
    }


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
        return []
    return None


def touched(name, facet, spec, paths, shared):
    if paths is None:
        return True
    if any(path == s or path.startswith(s) for path in paths for s in shared):
        return True
    roots = (spec.get(facet) or {}).get("paths") or [f"modules/{name}/{FACET_DIR[facet]}"]
    return any(path.startswith(root.rstrip("/") + "/") for path in paths for root in roots)


def check(reg, environment):
    paths = diff_paths()
    shared = tuple(reg.get("shared") or DEFAULT_SHARED)
    legs, tracks = [], []
    for name, spec in (reg.get("modules") or {}).items():
        for facet in FACETS:
            if facet not in spec:
                continue
            entry = leg(reg, name, spec, environment, {facet})
            entry["changed"] = "true" if touched(name, facet, spec, paths, shared) else "false"
            legs.append(entry)
            if entry["changed"] == "true":
                tracks.append(f"{name}/{facet}")
    code = [l for l in legs if l["facets"] == "code"]
    infra = [l for l in legs if l["facets"] == "infra"]
    emit("code", json.dumps({"include": code}))
    emit("infra", json.dumps({"include": infra}))
    emit("tracks", ",".join(tracks))
    emit("any", "true" if tracks else "false")
    report(legs, tracks)


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
    tracks = tag_tracks(tag)
    modules = reg.get("modules") or {}
    if tracks is None:
        tracks = {f"{name}/{facet}" for name, spec in modules.items() for facet in FACETS if facet in spec}
    names = scope or sorted({track.split("/")[0] for track in tracks})
    legs = []
    for name in names:
        spec = modules.get(name)
        if not spec:
            sys.exit(f"module '{name}' is not in the registry")
        facets = {facet for facet in FACETS if f"{name}/{facet}" in tracks and facet in spec}
        if not facets:
            continue
        entry = leg(reg, name, spec, environment, facets)
        entry["tag"] = tag
        entry["environment"] = environment
        entry["changed"] = "true"
        legs.append(entry)
    if not legs:
        sys.exit(f"release {tag} carries no track of {','.join(names)}")
    emit("modules", json.dumps({"include": legs}))
    emit("tracks", ",".join(sorted(tracks)))
    emit("tag", tag)
    emit("any", "true")
    report(legs, sorted(tracks))


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
