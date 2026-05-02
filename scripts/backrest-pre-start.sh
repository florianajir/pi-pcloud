#!/bin/bash
set -euo pipefail

. "$(dirname "$0")/lib.sh"

CONFIG_DIR="${BACKREST_CONFIG_DIR:-$PROJECT_DIR/config/backrest}"
CONFIG_FILE="${CONFIG_DIR}/config.json"
TEMPLATE_FILE="${BACKREST_TEMPLATE:-$PROJECT_DIR/config/backrest/config.json.template}"
ENV_FILE="${BACKREST_ENV_FILE:-$PROJECT_DIR/.env}"

# For manual runs (e.g. `sh scripts/backrest-pre-start.sh`), load .env if present
# and if required variables are not already exported by the current environment.
if [ -f "${ENV_FILE}" ]; then
  if [ -z "${BACKREST_S3_URI:-}" ] || [ -z "${BACKREST_S3_REPO_PASSWORD:-}" ] || \
     { [ -z "${S3_ACCESS_KEY_ID:-}" ] && [ -z "${BACKREST_S3_ACCESS_KEY_ID:-}" ]; } || \
     { [ -z "${S3_SECRET_ACCESS_KEY:-}" ] && [ -z "${BACKREST_S3_SECRET_ACCESS_KEY:-}" ]; }; then
    set -a
    . "${ENV_FILE}"
    set +a
  fi
fi

# Shared S3 credentials (fall back to legacy BACKREST_S3_* for backward compat)
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_BUCKET="${S3_BUCKET:-}"
S3_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:-${BACKREST_S3_ACCESS_KEY_ID:-}}"
S3_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:-${BACKREST_S3_SECRET_ACCESS_KEY:-}}"
S3_REGION="${S3_REGION:-${BACKREST_S3_REGION:-fr-par}}"

# Backrest-specific (derive URI from shared S3 vars if not set explicitly)
if [ -z "${BACKREST_S3_URI:-}" ] && [ -n "${S3_ENDPOINT}" ] && [ -n "${S3_BUCKET}" ]; then
  BACKREST_S3_URI="s3:${S3_ENDPOINT}/${S3_BUCKET}/restic"
fi
BACKREST_S3_URI="${BACKREST_S3_URI:-}"
BACKREST_S3_REPO_PASSWORD="${BACKREST_S3_REPO_PASSWORD:-}"
BACKREST_INSTANCE="${BACKREST_INSTANCE:-${HOST_NAME:-$(hostname 2>/dev/null || echo pi-pcloud)}}"

if [ ! -f "${TEMPLATE_FILE}" ]; then
  die "template not found at ${TEMPLATE_FILE}"
fi

# Idempotent: if config already exists and has content, skip
if [ -f "${CONFIG_FILE}" ]; then
  if [ -s "${CONFIG_FILE}" ]; then
    if jq -e 'has("instance") and (.instance | type == "string") and (.instance | length > 0)' "${CONFIG_FILE}" >/dev/null 2>&1; then
      log "config already exists at ${CONFIG_FILE}; skipping initialization"
      fix_ownership "${CONFIG_DIR}"
      exit 0
    fi

    tmp_patch="$(mktemp)"
    trap 'rm -f "${tmp_file:-}" "${tmp_patch:-}"' EXIT INT TERM
    if ! jq --arg instance "${BACKREST_INSTANCE}" '.instance = $instance' "${CONFIG_FILE}" > "${tmp_patch}"; then
      die "failed to patch missing instance in existing config"
    fi
    mv "${tmp_patch}" "${CONFIG_FILE}"
    fix_ownership "${CONFIG_DIR}"
    log "patched existing config with instance=${BACKREST_INSTANCE}"
    exit 0
  fi
fi

# Ensure directory exists
mkdir -p "${CONFIG_DIR}"

# Check for required S3 credentials if we're going to initialize
if [ -z "${BACKREST_S3_URI}" ] || [ -z "${BACKREST_S3_REPO_PASSWORD}" ] || \
   [ -z "${S3_ACCESS_KEY_ID}" ] || [ -z "${S3_SECRET_ACCESS_KEY}" ]; then
  log "WARNING: S3 credentials incomplete; Backrest will start but S3 repo may not be available"
  log "Set: BACKREST_S3_URI, BACKREST_S3_REPO_PASSWORD, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY"
fi

# Render template with sed
tmp_file="$(mktemp)"
trap 'rm -f "${tmp_file}" "${tmp_patch:-}"' EXIT INT TERM

sed \
  -e "s|__BACKREST_INSTANCE__|${BACKREST_INSTANCE}|g" \
  -e "s|__BACKREST_S3_URI__|${BACKREST_S3_URI}|g" \
  -e "s|__BACKREST_S3_REPO_PASSWORD__|${BACKREST_S3_REPO_PASSWORD}|g" \
  -e "s|__BACKREST_S3_ACCESS_KEY_ID__|${S3_ACCESS_KEY_ID}|g" \
  -e "s|__BACKREST_S3_SECRET_ACCESS_KEY__|${S3_SECRET_ACCESS_KEY}|g" \
  -e "s|__BACKREST_S3_REGION__|${S3_REGION}|g" \
  "${TEMPLATE_FILE}" > "${tmp_file}"

# Validate JSON
if ! jq empty "${tmp_file}" 2>/dev/null; then
  die "generated config is not valid JSON"
fi

mv "${tmp_file}" "${CONFIG_FILE}"
fix_ownership "${CONFIG_DIR}"
log "Backrest config initialized at ${CONFIG_FILE}"
