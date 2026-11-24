#!/usr/bin/env python3
"""critical — open or update a Critical issue for a failed promote or production deploy.

Subcommands:
  open      --module M --hook H --tag T [--failures FILE] [--run-url URL]
  incident  --module M --tag T [--run-url URL]

A Critical issue is labelled `urgency:critical` and `module:<m>`. The label
`autofix:blocked` is added when a pull request labelled `autofix` was merged
between the last tag recorded as `promoted` for the module and the failing tag,
and always for an incident (the agent never touches infrastructure).
An open issue with the same title prefix gets a comment instead of a new issue.

Output (GITHUB_OUTPUT): `issue`.
Environment: GITHUB_REPOSITORY, GH_TOKEN, GITHUB_OUTPUT.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

LIMIT = 20000
OUTPUT_LINES = 300
LABEL_COLORS = {"urgency:critical": "B60205", "autofix:blocked": "FBCA04"}
MODULE_COLOR = "1D76DB"
NO_FAILURES = "no failures.md was written; see the run"

EMAIL = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")
IPV4 = re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b")
HEX = r"[0-9A-Fa-f]{1,4}"
IPV6 = re.compile(
    rf"(?<![\w:])(?:(?:{HEX}:){{7}}{HEX}|(?:{HEX}:){{0,6}}:(?:{HEX}(?::{HEX}){{0,6}})?)(?![\w:])"
)
TOKEN = re.compile(r"[A-Za-z0-9_\-]{32,}")


MENTION = re.compile(r"@(?=[A-Za-z])")


def defang(text):
    return MENTION.sub("@ ", text)


def mask(text):
    text = EMAIL.sub("<email>", text)
    text = IPV6.sub("<ip>", text)
    text = IPV4.sub("<ip>", text)
    return defang(TOKEN.sub("<token>", text))


def repo():
    return os.environ["GITHUB_REPOSITORY"]


def gh(*args, check=True):
    res = subprocess.run(["gh", *args], capture_output=True, text=True)
    if check and res.returncode != 0:
        sys.exit(f"failed: gh {' '.join(args[:3])}\n{res.stderr.strip()}")
    return res.stdout


def gh_json(path):
    return json.loads(gh("api", path) or "null")


def emit(name, value):
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(f"{name}={value}\n")


def payload(deployment):
    value = deployment.get("payload") or {}
    if isinstance(value, str):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return {}
    return value


def last_promoted(module):
    for deployment in gh_json(f"repos/{repo()}/deployments?environment=promoted&per_page=100") or []:
        data = payload(deployment)
        if data.get("module") == module and data.get("tag"):
            return data["tag"]
    return ""


def blocked(module, tag):
    base = last_promoted(module)
    if not base:
        return False
    compare = gh_json(f"repos/{repo()}/compare/{base}...{tag}") or {}
    for commit in compare.get("commits", []):
        for pull in gh_json(f"repos/{repo()}/commits/{commit['sha']}/pulls") or []:
            labels = {label.get("name") for label in pull.get("labels", [])}
            if "autofix" in labels and pull.get("merged_at"):
                return True
    return False


def ensure_labels(names):
    for name in names:
        color = LABEL_COLORS.get(name, MODULE_COLOR)
        gh("label", "create", name, "--force", "--color", color, "-R", repo(), check=False)


def find_open(prefix):
    out = gh("issue", "list", "-R", repo(), "--state", "open", "--search", prefix, "--json", "number,title", "--limit", "100")
    for issue in json.loads(out or "[]"):
        if issue["title"].startswith(prefix):
            return issue["number"]
    return None


def body_file(text):
    handle = tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8")
    handle.write(text)
    handle.close()
    return handle.name


def publish(prefix, title, text, labels):
    existing = find_open(prefix)
    path = body_file(defang(text))
    try:
        if existing:
            gh("issue", "comment", str(existing), "-R", repo(), "--body-file", path)
            return existing
        ensure_labels(labels)
        args = ["issue", "create", "-R", repo(), "--title", title, "--body-file", path]
        for label in labels:
            args += ["--label", label]
        url = gh(*args).strip()
        return int(url.rstrip("/").rsplit("/", 1)[-1])
    finally:
        os.unlink(path)


def read_failures(path):
    if not path or not os.path.isfile(path):
        return NO_FAILURES
    with open(path, encoding="utf-8", errors="replace") as handle:
        text = handle.read(LIMIT)
    return mask(text) if text.strip() else NO_FAILURES


def read_output(path):
    if not path or not os.path.isfile(path):
        return ""
    with open(path, encoding="utf-8", errors="replace") as handle:
        lines = handle.read().splitlines()[-OUTPUT_LINES:]
    return mask("\n".join(lines))[-LIMIT:]


def longest_backtick_run(text):
    return max((len(run) for run in re.findall(r"`+", text)), default=0)


def failure_section(args):
    failures = read_failures(args.failures)
    if failures != NO_FAILURES:
        return ["## failures", "", failures]
    output = read_output(args.output)
    if not output.strip():
        return ["## failures", "", failures]
    fence = "`" * max(3, longest_backtick_run(output) + 1)
    return ["## output", "", fence, output, fence]


def labels_for(module, is_blocked):
    labels = ["urgency:critical", f"module:{module}"]
    return labels + ["autofix:blocked"] if is_blocked else labels


def open_issue(args):
    prefix = f"bug: {args.module} {args.hook} failed on "
    text = "\n".join(
        [
            f"The `{args.hook}` hook failed for `{args.tag}`.",
            "",
            f"- run: {args.run_url}",
            f"- hook: {args.hook}",
            f"- tag: {args.tag}",
            "",
            *failure_section(args),
            "",
        ]
    )
    return publish(prefix, prefix + args.tag, text, labels_for(args.module, blocked(args.module, args.tag)))


def incident(args):
    prefix = f"bug: {args.module} production deploy failed on "
    text = "\n".join(
        [
            f"The production deploy of `{args.tag}` failed.",
            "",
            f"- run: {args.run_url}",
            f"- tag: {args.tag}",
            "",
            "Infrastructure is out of the autofix scope: a person has to look at it.",
            "",
        ]
    )
    return publish(prefix, prefix + args.tag, text, labels_for(args.module, True))


def parse(argv):
    parser = argparse.ArgumentParser(prog="critical")
    sub = parser.add_subparsers(dest="command", required=True)
    opened = sub.add_parser("open")
    opened.add_argument("--module", required=True)
    opened.add_argument("--hook", required=True)
    opened.add_argument("--tag", required=True)
    opened.add_argument("--failures", default="")
    opened.add_argument("--output", default="")
    opened.add_argument("--run-url", default="")
    inc = sub.add_parser("incident")
    inc.add_argument("--module", required=True)
    inc.add_argument("--tag", required=True)
    inc.add_argument("--run-url", default="")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse(sys.argv[1:] if argv is None else argv)
    number = open_issue(args) if args.command == "open" else incident(args)
    print(f"issue #{number}")
    emit("issue", number)


if __name__ == "__main__":
    main()
