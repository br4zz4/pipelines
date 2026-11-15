#!/bin/sh
# plan.sh — Heroku has nothing to plan: config vars are applied key by key and
# a release is a slug swap. The hook exists because every hook is mandatory.
set -eu

echo "nothing to plan: heroku applies config vars directly"
