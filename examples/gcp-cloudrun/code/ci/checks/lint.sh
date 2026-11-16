#!/bin/sh
# lint.sh — point bundle at CI_CACHE_DIR so gems survive between runs, then
# delegate to the Makefile (same target runs on a laptop and in CI).
#
# Environment: MODULE, CI_CACHE_DIR.
set -eu

export BUNDLE_PATH="${CI_CACHE_DIR:?CI_CACHE_DIR is not set}/bundle"
exec make "${MODULE:?MODULE is not set}.lint"
