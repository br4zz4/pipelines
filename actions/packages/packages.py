#!/usr/bin/env python3
"""Resolve the system packages a hook needs.

Prints two lines for $GITHUB_OUTPUT: `missing=` (declared packages not installed yet)
and `key=` (cache key from the sorted declared list).
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys


def read_registry(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError) as error:
        print(f"::warning::packages: cannot read {path} ({error})", file=sys.stderr)
        return {}


def declared(registry, module, hooks):
    packages = ((registry.get("modules") or {}).get(module) or {}).get("code", {}) or {}
    by_hook = packages.get("packages") or {}
    names = set()
    for hook in hooks:
        names.update(by_hook.get(hook) or [])
    return sorted(names)


def installed(package):
    try:
        result = subprocess.run(
            ["dpkg-query", "-W", "-f=${Status}", package],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return False
    return "install ok installed" in result.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--registry", required=True)
    parser.add_argument("--module", required=True)
    parser.add_argument("--hooks", required=True)
    args = parser.parse_args()
    hooks = [hook for hook in args.hooks.split(",") if hook]
    names = declared(read_registry(args.registry), args.module, hooks)
    missing = [name for name in names if not installed(name)]
    image = f"{os.environ.get('ImageOS') or 'local'}-{os.environ.get('ImageVersion') or 'local'}"
    digest = hashlib.sha256("\n".join(names).encode()).hexdigest()
    print(f"missing={' '.join(missing)}")
    print(f"key=system-packages-{image}-{digest}")


if __name__ == "__main__":
    main()
