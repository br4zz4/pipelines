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
  workflow_dispatch:tag)
    case "${ENVIRONMENT_INPUT:-}" in
      staging | production) ENVIRONMENT="${ENVIRONMENT_INPUT}" ;;
      '') ENVIRONMENT=staging ;;
      *) echo "::error::invalid environment '${ENVIRONMENT_INPUT}' (staging | production)"; exit 1 ;;
    esac
    ;;
  workflow_dispatch:branch)
    echo "::error::dispatch requires a release tag — select a tag ref (e.g. checkout.YYYY-MM-DD.NNN), not a branch"
    exit 1
    ;;
  *)
    echo "::error::a deploy runs on a tag push or a dispatch on a tag, not on ${EVENT_NAME} of a ${REF_TYPE}"
    exit 1
    ;;
esac

if ! printf '%s\n' "${REF_NAME}" | grep -Eq "${RELEASE_TAG}"; then
  echo "::error::invalid release tag '${REF_NAME}' (expected <module>.YYYY-MM-DD.NNN)"
  exit 1
fi
TAGS="${REF_NAME}"
ROLLBACK_OF=""
if [ "${EVENT_NAME}" = "workflow_dispatch" ] && [ -n "${ROLLBACK_TO:-}" ]; then
  if ! printf '%s\n' "${ROLLBACK_TO}" | grep -Eq "${RELEASE_TAG}"; then
    echo "::error::invalid release tag '${ROLLBACK_TO}' (expected <module>.YYYY-MM-DD.NNN)"
    exit 1
  fi
  if [ "${ROLLBACK_TO%%.*}" != "${REF_NAME%%.*}" ]; then
    echo "::error::rollback_to ${ROLLBACK_TO} is not a release of ${REF_NAME%%.*}"
    exit 1
  fi
  ROLLBACK_OF="${REF_NAME}"
  TAGS="${ROLLBACK_TO}"
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
spec = (modules_cfg.get(module) or {}) if module else {}
services = ",".join(spec.get("services") or [])
code_dir = ((spec.get("code") or {}).get("dir") or f"modules/{module}/code") if module else ""
infra_dir = ((spec.get("infra") or {}).get("dir") or f"modules/{module}/infra") if module else ""
print(json.dumps({"releases": releases, "module": module, "services": services, "code_dir": code_dir, "infra_dir": infra_dir}, separators=(",", ":")))' "${REGISTRY}")"

RELEASES="$(printf '%s' "${RESULT}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d["releases"],separators=(",",":")))')"
MODULE="$(printf '%s' "${RESULT}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["module"])')"
SERVICES="$(printf '%s' "${RESULT}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"])')"

TAG="$(printf '%s' "${RESULT}" | python3 -c 'import json,sys; d=json.load(sys.stdin); m=d["module"]; print(d["releases"].get(m,"") if m else "")')"

CODE_DIR="$(printf '%s' "${RESULT}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["code_dir"])')"
INFRA_DIR="$(printf '%s' "${RESULT}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["infra_dir"])')"

echo "code_dir=${CODE_DIR}" >> "${OUT}"
echo "infra_dir=${INFRA_DIR}" >> "${OUT}"
echo "rollback_of=${ROLLBACK_OF}" >> "${OUT}"
echo "releases=${RELEASES}" >> "${OUT}"
echo "environment=${ENVIRONMENT}" >> "${OUT}"
echo "module=${MODULE}" >> "${OUT}"
echo "services=${SERVICES}" >> "${OUT}"
echo "tag=${TAG}" >> "${OUT}"
echo "${ENVIRONMENT}: ${RELEASES} module=${MODULE} tag=${TAG}"
