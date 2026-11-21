#!/bin/sh
# install.sh — install the pinned Claude Code CLI.
set -eu

VERSION=2.1.330

npm install -g "@anthropic-ai/claude-code@${VERSION}"
