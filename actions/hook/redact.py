#!/usr/bin/env python3
"""redact — copy a hook output, replacing the values of secret-looking environment variables.

  redact.py RAW OUT

A variable is secret-looking when its name matches PASSWORD|PASS|PWD|SECRET|TOKEN|KEY|URL|DSN|CREDENTIAL|AUTH|COOKIE|PRIVATE
(case-insensitive), except the public GitHub URLs and the shell directories PWD and OLDPWD; only values of at least 8 characters are replaced.
"""

import os
import re
import sys

MIN_LENGTH = 8
SECRET_NAME = re.compile(r"PASSWORD|PASS|PWD|SECRET|TOKEN|KEY|URL|DSN|CREDENTIAL|AUTH|COOKIE|PRIVATE", re.IGNORECASE)
PUBLIC_NAMES = ("GITHUB_SERVER_URL", "GITHUB_API_URL", "GITHUB_GRAPHQL_URL", "PWD", "OLDPWD")
PLACEHOLDER = "<redacted>"


def secret_values(environ):
    values = {value for name, value in environ.items() if name not in PUBLIC_NAMES and SECRET_NAME.search(name) and len(value) >= MIN_LENGTH}
    return sorted(values, key=len, reverse=True)


def redact(text, environ):
    for value in secret_values(environ):
        text = text.replace(value, PLACEHOLDER)
    return text


def main(argv):
    raw, out = argv
    with open(raw, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    with open(out, "w", encoding="utf-8") as handle:
        handle.write(redact(text, os.environ))


if __name__ == "__main__":
    main(sys.argv[1:])
