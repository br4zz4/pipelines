#!/bin/sh
# sentry_release.sh — create the Sentry release of a build and mark its deploys; a Sentry failure only warns and never fails the job.
set -u

COMMAND="${COMMAND:-}"
ORG="${SENTRY_ORG:-}"
PROJECT="${SENTRY_PROJECT:-}"
BASE_URL="${SENTRY_URL:-https://sentry.io}"
TAG="${TAG_INPUT:-}"
ENV_NAME="${ENVIRONMENT:-}"
APP_URL="${APP_URL:-}"
TOKEN="${SENTRY_AUTH_TOKEN:-}"
REPO="${GITHUB_REPOSITORY:-}"
SHA="${GITHUB_SHA:-}"
VAULT_NAME="${VAULT:-<ns>}"

VERSION="${PROJECT}@${TAG}"
API="${BASE_URL}/api/0/organizations/${ORG}"
LINK="${BASE_URL}/organizations/${ORG}/releases/${VERSION}/"
CODE=""
RELEASE_RESULT=""

summary() {
  echo "$1"
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "$1" >> "${GITHUB_STEP_SUMMARY}"
}

escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

call() {
  CODE="$(curl -fsS --max-time 15 --retry 2 -X "$1" \
    -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    -d "$3" -o /dev/null -w '%{http_code}' "$2" 2>/dev/null)" || true
  [ -n "${CODE}" ] || CODE=000
}

ok() {
  case "${CODE}" in 2??) return 0 ;; *) return 1 ;; esac
}

status_text() {
  if [ "${CODE}" = 000 ]; then
    echo "HTTP 000, no answer"
  else
    echo "HTTP ${CODE}"
  fi
}

release_body() {
  if [ "$1" = refs ]; then
    printf '{"version":"%s","projects":["%s"],"refs":[{"repository":"%s","commit":"%s"}]}' \
      "$(escape "${VERSION}")" "$(escape "${PROJECT}")" "$(escape "${REPO}")" "$(escape "${SHA}")"
  else
    printf '{"version":"%s","projects":["%s"]}' "$(escape "${VERSION}")" "$(escape "${PROJECT}")"
  fi
}

create_release() {
  RELEASE_RESULT=failed
  call POST "${API}/releases/" "$(release_body refs)"
  if [ "${CODE}" = 400 ]; then
    echo "::warning::sentry: release created without commits (no GitHub integration for ${REPO})"
    call POST "${API}/releases/" "$(release_body plain)"
  fi
  case "${CODE}" in
    409 | 208) RELEASE_RESULT=exists ;;
    2??) RELEASE_RESULT=created ;;
    *)
      echo "::warning::sentry: release ${VERSION} was not created ($(status_text))"
      summary "Sentry release ${VERSION}: failed"
      return 1
      ;;
  esac
  call PUT "${API}/releases/${VERSION}/" "{\"dateReleased\":\"$(now)\"}"
  ok || echo "::warning::sentry: release ${VERSION} was not finalized ($(status_text))"
  summary "Sentry release ${VERSION}: ${RELEASE_RESULT} (${LINK})"
}

deploy_body() {
  if [ -n "${APP_URL}" ]; then
    printf '{"environment":"%s","name":"%s","url":"%s","dateFinished":"%s"}' \
      "$(escape "${ENV_NAME}")" "$(escape "${TAG}")" "$(escape "${APP_URL}")" "$(now)"
  else
    printf '{"environment":"%s","name":"%s","dateFinished":"%s"}' \
      "$(escape "${ENV_NAME}")" "$(escape "${TAG}")" "$(now)"
  fi
}

mark_deploy() {
  call POST "${API}/releases/${VERSION}/deploys/" "$(deploy_body)"
  if [ "${CODE}" = 404 ]; then
    create_release || true
    call POST "${API}/releases/${VERSION}/deploys/" "$(deploy_body)"
  fi
  if ok; then
    summary "Sentry deploy ${ENV_NAME}: marked (${LINK})"
  else
    echo "::warning::sentry: deploy ${ENV_NAME} of ${VERSION} was not marked ($(status_text))"
    summary "Sentry deploy ${ENV_NAME}: failed"
  fi
}

if [ -z "${TOKEN}" ]; then
  echo "::warning::sentry: SENTRY_AUTH_TOKEN missing in ${VAULT_NAME}:secrets.ci.common"
  exit 0
fi
echo "::add-mask::${TOKEN}"

case "${COMMAND}" in
  release) create_release || true ;;
  deploy) mark_deploy ;;
  *) echo "::warning::sentry: unknown command '${COMMAND}'" ;;
esac
exit 0
