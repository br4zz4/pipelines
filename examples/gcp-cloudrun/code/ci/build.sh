#!/bin/sh
# build.sh — the hook is the contract with the pipeline, the Makefile is the
# implementation: the same target runs on a laptop and in CI.
#
# Environment: MODULE.
set -eu

exec make "${MODULE:?MODULE is not set}.build"
