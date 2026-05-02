#!/bin/bash
set -euo pipefail

NTFY_BASE_URL="${NTFY_BASE_URL:-https://ntfy.${HOST_NAME:-pi.lan}}"
NTFY_TOPIC="${BACKREST_NTFY_TOPIC:-pi}"
BACKREST_EVENT_KIND="${1:-}"
NTFY_USER="backrest"
NTFY_PASSWORD="${NTFY_BACKREST_PASSWORD:-}"

log() {
  echo "[backrest-post-hook] $*" >&2
}

set_ntfy_metadata() {
  case "${BACKREST_EVENT_KIND}" in
    errors)
      NTFY_TITLE="${BACKREST_NTFY_ERROR_TITLE:-Backrest backup error}"
      NTFY_PRIORITY="high"
      NTFY_TAGS="${BACKREST_NTFY_ERROR_TAGS:-backup_failed}"
      ;;
    info)
      NTFY_TITLE="${BACKREST_NTFY_INFO_TITLE:-Backrest backup success}"
      NTFY_PRIORITY="${BACKREST_NTFY_INFO_PRIORITY:-default}"
      NTFY_TAGS="${BACKREST_NTFY_INFO_TAGS:-backup_finished}"
      ;;
    *)
      log "invalid event kind '${BACKREST_EVENT_KIND}'. Valid values: info, errors"
      exit 2
      ;;
  esac
}

if [ "$#" -lt 2 ]; then
  log "usage: $0 <info|errors> <summary>"
  exit 2
fi

set_ntfy_metadata

if [ -z "${NTFY_PASSWORD}" ]; then
  log "NTFY_BACKREST_PASSWORD is empty; skipping ntfy notification"
  exit 0
fi

shift
message="$*"

if [ -z "${message}" ]; then
  log "empty summary message; skipping ntfy notification"
  exit 0
fi

ntfy_url="${NTFY_BASE_URL%/}/${NTFY_TOPIC}"

if ! curl -fsS --retry 3 --max-time 15 \
  -u "${NTFY_USER}:${NTFY_PASSWORD}" \
  -H "Title: ${NTFY_TITLE}" \
  -H "Priority: ${NTFY_PRIORITY}" \
  -H "Tags: ${NTFY_TAGS}" \
  --data-binary "${message}" \
  "${ntfy_url}" >/dev/null; then
  log "failed to publish ntfy message to ${ntfy_url}"
fi

exit 0
