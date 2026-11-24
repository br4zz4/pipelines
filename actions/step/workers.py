#!/usr/bin/env python3
"""Print how many test workers a module's hooks may use (TEST_WORKERS).

Reads modules.<module>.code.test_workers from the registry; the default is 4.
A missing or unreadable registry warns and falls back to the default.
"""
import argparse
import json
import sys

DEFAULT = 4


def read_registry(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError) as error:
        print(f"::warning::workers: cannot read {path} ({error}); using {DEFAULT}", file=sys.stderr)
        return {}


def workers(registry, module):
    spec = (registry.get("modules") or {}).get(module) or {}
    value = (spec.get("code") or {}).get("test_workers")
    if isinstance(value, int) and not isinstance(value, bool) and value >= 1:
        return value
    return DEFAULT


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--registry", required=True)
    parser.add_argument("--module", required=True)
    args = parser.parse_args()
    print(workers(read_registry(args.registry), args.module))


if __name__ == "__main__":
    main()
