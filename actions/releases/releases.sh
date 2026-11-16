#!/bin/sh
# releases.sh — which release each module raises in this run.
#   push of a tag          staging     that tag, in the module its prefix names
#   dispatch on a tag      production  that tag, in the module its prefix names
#   dispatch on a branch   production  every release tag pointing at HEAD, the newest per module
# Anything else is not a deploy. A branch commit with no release tag fails: a
# deploy only raises a release that already exists.
set -eu

REGISTRY="${REGISTRY:-.github/modules.json}"
EVENT_NAME="${EVENT_NAME:?EVENT_NAME is not set}"
REF_TYPE="${REF_TYPE:?REF_TYPE is not set}"
REF_NAME="${REF_NAME:?REF_NAME is not set}"
OUT="${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"

RELEASE_TAG='^[a-z][a-z0-9_]*\.[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]{3,}$'

case "${EVENT_NAME}:${REF_TYPE}" in
  push:tag)
    ENVIRONMENT=staging
    ;;
  workflow_dispatch:tag | workflow_dispatch:branch)
    case "${ENVIRONMENT_INPUT:-}" in
      staging | production) ENVIRONMENT="${ENVIRONMENT_INPUT}" ;;
      '') ENVIRONMENT=staging ;;
      *) echo "::error::invalid environment '${ENVIRONMENT_INPUT}' (staging | production)"; exit 1 ;;
    esac
    ;;
  *)
    echo "::error::a deploy runs on a tag push or a dispatch, not on ${EVENT_NAME} of a ${REF_TYPE}"
    exit 1
    ;;
esac

if [ "${REF_TYPE}" = "tag" ]; then
  TAGS="${REF_NAME}"
  if ! printf '%s\n' "${TAGS}" | grep -Eq "${RELEASE_TAG}"; then
    echo "::error::invalid release tag '${REF_NAME}' (expected <module>.YYYY-MM-DD.NNN)"
    exit 1
  fi
else
  git fetch --tags --force origin >/dev/null 2>&1 || true
  TAGS="$(git tag --points-at HEAD | grep -E "${RELEASE_TAG}" | sort -V || true)"
  if [ -z "${TAGS}" ]; then
    echo "::error::this commit has no release tag; a deploy only raises a release (push to main first)"
    exit 1
  fi
fi

RESULT="$(printf '%s\n' "${TAGS}" | python3 -c 'import json, sys
registry, = sys.argv[1:]
reg = json.load(open(registry))
modules_cfg = reg.get("modules") or {}
all_modules = sorted(modules_cfg)
releases = {name: "" for name in all_modules}
for tag in (line.strip() for line in sys.stdin if line.strip()):
    module = tag.split(".", 1)[0]
    if module not in releases:
        sys.exit(f"::error::release {tag} names module {module}, which is not in {registry}")
    releases[module] = tag
active = [m for m, t in releases.items() if t]
module = active[0] if len(active) == 1 else ""
services = ",".join(modules_cfg.get(module, {}).get("services", [])) if module else ""
print(json.dumps({"releases": releases, "module": module, "services": services}, separators=(",", ":")))' "${REGISTRY}")"

RELEASES="$(printf '%s' "${RESULT}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d["releases"],separators=(",",":")))')"
MODULE="$(printf '%s' "${RESULT}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["module"])')"
SERVICES="$(printf '%s' "${RESULT}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"])')"

echo "releases=${RELEASES}" >> "${OUT}"
echo "environment=${ENVIRONMENT}" >> "${OUT}"
echo "module=${MODULE}" >> "${OUT}"
echo "services=${SERVICES}" >> "${OUT}"
echo "${ENVIRONMENT}: ${RELEASES} module=${MODULE} services=${SERVICES}"
