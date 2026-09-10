#!/bin/sh
set -eu

. "$(dirname "$0")/lib.sh"

CONFIG_DIR="${BACKREST_CONFIG_DIR:-$PROJECT_DIR/config/backrest}"
CONFIG_FILE="${CONFIG_DIR}/config.json"
TEMPLATE_FILE="${BACKREST_TEMPLATE:-$PROJECT_DIR/config/backrest/config.json.template}"

# For manual runs (e.g. `sh scripts/backrest-pre-start.sh`), fall back to .env for
# any value the environment does not already provide — key by key via
# get_env_value, never by dot-sourcing: .env is not shell, so an unquoted `;` or
# `#` in a value (PIHOLE_DNS_UPSTREAMS has both) executes as a command under `.`.
# systemd's EnvironmentFile parses it without a shell, which hid this on boot.
env_value() {
  local var="$1" val
  eval "val=\"\${$var:-}\""
  [ -n "$val" ] || val="$(get_env_value "$var")"
  printf '%s' "$val"
}

# Shared S3 credentials (fall back to legacy BACKREST_S3_* for backward compat)
S3_ENDPOINT="$(env_value S3_ENDPOINT)"
S3_BUCKET="$(env_value S3_BUCKET)"
S3_ACCESS_KEY_ID="$(env_value S3_ACCESS_KEY_ID)"
[ -n "$S3_ACCESS_KEY_ID" ] || S3_ACCESS_KEY_ID="$(env_value BACKREST_S3_ACCESS_KEY_ID)"
S3_SECRET_ACCESS_KEY="$(env_value S3_SECRET_ACCESS_KEY)"
[ -n "$S3_SECRET_ACCESS_KEY" ] || S3_SECRET_ACCESS_KEY="$(env_value BACKREST_S3_SECRET_ACCESS_KEY)"
S3_REGION="$(env_value S3_REGION)"
[ -n "$S3_REGION" ] || S3_REGION="$(env_value BACKREST_S3_REGION)"
[ -n "$S3_REGION" ] || S3_REGION="fr-par"

# Backrest-specific (derive URI from shared S3 vars if not set explicitly)
BACKREST_S3_URI="$(env_value BACKREST_S3_URI)"
if [ -z "${BACKREST_S3_URI}" ] && [ -n "${S3_ENDPOINT}" ] && [ -n "${S3_BUCKET}" ]; then
  BACKREST_S3_URI="s3:${S3_ENDPOINT}/${S3_BUCKET}/restic"
fi
BACKREST_S3_REPO_PASSWORD="$(env_value BACKREST_S3_REPO_PASSWORD)"
BACKREST_INSTANCE="$(env_value BACKREST_INSTANCE)"
[ -n "$BACKREST_INSTANCE" ] || BACKREST_INSTANCE="$(env_value HOST_NAME)"
[ -n "$BACKREST_INSTANCE" ] || BACKREST_INSTANCE="$(hostname 2>/dev/null || echo pi-pcloud)"

# --- Local .env repository on the data disk ---
#
# The S3 repo already snapshots /userdata/pi-web-env, but opening it needs
# BACKREST_S3_REPO_PASSWORD, and that value lives *inside* the .env you would
# be restoring. This second repo closes that loop. It sits on DATA_LOCATION,
# which is a different physical disk from .env itself (.env is on the root
# filesystem), holds nothing but the .env history, and keeps its own password
# in cleartext right next to it so the disk alone is enough to restore.
#
# The cleartext password is deliberate, not an oversight: the same disk already
# carries every service's live data plus a cleartext .env under
# backrest/env-snapshot/, so anyone holding it has everything regardless. A
# password stored off-disk would only make the repo unreadable in the exact
# scenario it exists for.
LOCAL_REPO_ID="usb"
LOCAL_PLAN_ID="usb-env"
# Container-side path. ${DATA_LOCATION}/backrest/repos is bind-mounted at
# /repos in compose.yaml, so restic sees a plain local repository here.
LOCAL_REPO_URI="/repos/env"

# Trailing slash stripped so the host paths below don't come out with "//" in
# every log line (DATA_LOCATION is commonly written "/mnt/usbdrive/").
LOCAL_REPOS_DIR="$(resolve_data_location_path)"
LOCAL_REPOS_DIR="${LOCAL_REPOS_DIR%/}/backrest/repos"
LOCAL_PW_FILE="${LOCAL_REPOS_DIR}/env-repo-password"
LOCAL_README="${LOCAL_REPOS_DIR}/env-RESTORE.txt"

write_local_restore_note() {
  cat <<NOTE
Restoring pi-web's .env from this disk
======================================

The "env" directory next to this file is a restic repository. Backrest writes
one snapshot into it every day at 02:00 (repo id "${LOCAL_REPO_ID}", plan id
"${LOCAL_PLAN_ID}"), and it contains exactly one thing: the pi-web stack's .env
file, with its history.

Repository password: ${LOCAL_REPO_PASSWORD}

The password is here in cleartext on purpose. This disk already holds every
service's live data and a cleartext copy of .env under ../env-snapshot/, so
keeping the password elsewhere would buy no secrecy while making this
repository unreadable in the one situation it exists for: the machine's root
filesystem is gone and this disk is all that is left.

To restore, from any machine with restic installed:

    export RESTIC_PASSWORD='${LOCAL_REPO_PASSWORD}'
    restic -r <this-directory>/env snapshots
    restic -r <this-directory>/env restore latest --target /tmp/env-restore
    # the file lands at /tmp/env-restore/userdata/pi-web-env/.env

This is NOT the off-site repository. That one is "s3", its password is
BACKREST_S3_REPO_PASSWORD, and it must be kept off this machine entirely --
see docs/MONITORING.md.
NOTE
}

# Adds the local repo and its plan to config.json when absent, and keeps the
# password in sync when present. Called from every exit path below, because
# the script returns early whenever config.json already exists -- which is the
# normal case on an established install, and the case that needs this most.
ensure_local_env_repo() {
  local tmp_local

  [ -f "${CONFIG_FILE}" ] || return 0

  if ! mkdir -p "${LOCAL_REPOS_DIR}" 2>/dev/null; then
    log "WARNING: cannot create ${LOCAL_REPOS_DIR}; skipping the local .env repo"
    return 0
  fi

  # An explicit value in .env wins, so an externally managed or rotated
  # password is honoured; otherwise the password exists only on this disk.
  LOCAL_REPO_PASSWORD="$(env_value BACKREST_LOCAL_REPO_PASSWORD)"
  if [ -z "${LOCAL_REPO_PASSWORD}" ]; then
    if [ ! -s "${LOCAL_PW_FILE}" ]; then
      if ! (umask 077; write_file_atomic "${LOCAL_PW_FILE}" generate_secret); then
        log "WARNING: could not generate ${LOCAL_PW_FILE}; skipping the local .env repo"
        return 0
      fi
      log "generated a repository password at ${LOCAL_PW_FILE}"
    fi
    LOCAL_REPO_PASSWORD="$(tr -d '\r\n' < "${LOCAL_PW_FILE}")"
  fi

  if [ -z "${LOCAL_REPO_PASSWORD}" ]; then
    log "WARNING: local .env repo password is empty; skipping"
    return 0
  fi

  safe_chmod 600 "${LOCAL_PW_FILE}"
  write_file_atomic "${LOCAL_README}" write_local_restore_note \
    || log "WARNING: could not write ${LOCAL_README}"
  safe_chmod 600 "${LOCAL_README}"
  fix_ownership "${LOCAL_PW_FILE}"
  fix_ownership "${LOCAL_README}"

  tmp_local="$(mktemp)" || return 0
  # Same reason as the render below: the password is a secret going into JSON
  # that also defines shell hook commands, so it must be escaped by jq.
  if jq \
      --arg repo "${LOCAL_REPO_ID}" \
      --arg plan "${LOCAL_PLAN_ID}" \
      --arg uri "${LOCAL_REPO_URI}" \
      --arg password "${LOCAL_REPO_PASSWORD}" \
      '.repos = ((.repos // []) as $r
         | if ($r | map(.id) | index($repo)) then
             $r | map(if .id == $repo then .uri = $uri | .password = $password else . end)
           else
             $r + [{
               id: $repo,
               uri: $uri,
               password: $password,
               env: [],
               autoInitialize: true,
               commandPrefix: {},
               autoUnlock: true,
               prunePolicy: {
                 schedule: { cron: "30 2 * * 0", clock: "CLOCK_LOCAL" },
                 maxUnusedPercent: 25
               },
               checkPolicy: {
                 schedule: { cron: "0 1 1 * *", clock: "CLOCK_LAST_RUN_TIME" },
                 readDataSubsetPercent: 100
               }
             }]
           end)
       | .plans = ((.plans // []) as $p
         | if ($p | map(.id) | index($plan)) then $p
           else
             $p + [{
               id: $plan,
               repo: $repo,
               paths: ["/userdata/pi-web-env"],
               excludes: ["/userdata/pi-web-env/.env.tmp"],
               schedule: { cron: "0 2 * * *", clock: "CLOCK_LOCAL" },
               retention: {
                 policyTimeBucketed: { daily: 30, weekly: 12, monthly: 12 }
               },
               hooks: [
                 {
                   conditions: ["CONDITION_SNAPSHOT_START"],
                   onError: "ON_ERROR_IGNORE",
                   actionCommand: { command: ("/bin/sh /hooks/backrest-unlock.sh " + $repo) }
                 },
                 {
                   conditions: ["CONDITION_SNAPSHOT_START"],
                   onError: "ON_ERROR_FATAL",
                   actionCommand: { command: "/bin/sh /hooks/backrest-env-snapshot.sh" }
                 },
                 {
                   conditions: ["CONDITION_ANY_ERROR"],
                   onError: "ON_ERROR_IGNORE",
                   actionCommand: { command: "/bin/sh /hooks/backrest-post-hook.sh errors {{ .ShellEscape .Summary }}" }
                 }
               ]
             }]
           end)' \
      "${CONFIG_FILE}" > "${tmp_local}" && [ -s "${tmp_local}" ]; then
    mv "${tmp_local}" "${CONFIG_FILE}"
    safe_chmod 600 "${CONFIG_FILE}"
    log "local .env repo '${LOCAL_REPO_ID}' and plan '${LOCAL_PLAN_ID}' present in ${CONFIG_FILE}"
  else
    rm -f "${tmp_local}"
    log "WARNING: failed to patch the local .env repo into ${CONFIG_FILE}; leaving it unchanged"
  fi
}

# --- The API credential ---
#
# Backrest's :9898 API hands out repos[].password (the restic key) and repos[].env
# (the S3 keys) to any authenticated caller, so this credential is exactly as
# valuable as the backups themselves. It used to be ${PASSWORD}, which eight other
# containers carry in their environment - a leak from any one of them reached every
# snapshot. Generated per-service here instead, like the Vaultwarden admin token,
# and rotate-password.sh leaves it alone.
#
# Deliberately above every early return below: an install whose config.json already
# exists must still get the file, and config/backrest/auth-entrypoint.sh re-hashes
# whatever it finds here on each start, so a rotation is picked up by itself.
AUTH_ENV_FILE="${CONFIG_DIR}/backrest.env"
AUTH_PASSWORD_VALUE="$(read_env_value_from_file "$AUTH_ENV_FILE" BACKREST_AUTH_PASSWORD)"

if [ -z "$AUTH_PASSWORD_VALUE" ]; then
  AUTH_PASSWORD_VALUE="$(generate_secret)"
  log "Generated BACKREST_AUTH_PASSWORD for the Backrest API"
fi

# Docker materialises a bind-mount source it cannot find, as root:root. backrest
# is a core service and mounts one data directory per *optional* service, so on a
# host where that service is not enabled yet, `up -d` creates its data directory
# before its own hook has ever run - and enabling it later dies with "mkdir:
# cannot create directory: Permission denied" inside a blocking pre-start hook.
# Which is a supported workflow: `make enable` and `make config` exist for it.
#
# Created here instead, where the hook always runs and before any `up -d`. The
# list is read out of compose.yaml rather than kept here, because a copy of it
# would be the one nobody updates. Only backrest mounts into /userdata.
ensure_backrest_mount_dirs() {
  local data_root=""
  local dir=""
  data_root="$(resolve_data_location_path)"

  grep -oE '\$\{DATA_LOCATION[^}]*\}/[a-z0-9/-]+:/userdata/' "$PROJECT_DIR/compose.yaml" |
    sed -E 's|.*\}/([a-z0-9/-]+):/userdata/|\1|' | sort -u |
    while read -r name; do
      [ -n "$name" ] || continue
      dir="$data_root/$name"
      [ -d "$dir" ] && continue
      if mkdir -p "$dir" 2>/dev/null; then
        fix_ownership "$dir"
      else
        log "WARNING: could not create $dir; Docker will create it as root:root"
      fi
    done
}

ensure_backrest_mount_dirs

mkdir -p "${CONFIG_DIR}"

# generate_secret emits hex, so no value here needs Compose's $$ escaping.
# write_secret_file, not `> file` + chmod: the redirect creates the file 0644 with
# the password already in it, and only the next line narrows it.
{
  printf '# Managed by scripts/backrest-pre-start.sh\n'
  printf 'BACKREST_AUTH_PASSWORD=%s\n' "$AUTH_PASSWORD_VALUE"
} | write_secret_file "$AUTH_ENV_FILE" || die "could not write $AUTH_ENV_FILE"
fix_ownership "$AUTH_ENV_FILE"

if [ ! -f "${TEMPLATE_FILE}" ]; then
  die "template not found at ${TEMPLATE_FILE}"
fi

if [ -f "${CONFIG_FILE}" ]; then
  if [ -s "${CONFIG_FILE}" ]; then
    if jq -e 'has("instance") and (.instance | type == "string") and (.instance | length > 0)' "${CONFIG_FILE}" >/dev/null 2>&1; then
      log "config already exists at ${CONFIG_FILE}; skipping initialization"
      ensure_local_env_repo
      fix_ownership "${CONFIG_DIR}"
      exit 0
    fi

    tmp_patch="$(mktemp)"
    trap 'rm -f "${tmp_file:-}" "${tmp_patch:-}"' EXIT INT TERM
    if ! jq --arg instance "${BACKREST_INSTANCE}" '.instance = $instance' "${CONFIG_FILE}" > "${tmp_patch}"; then
      die "failed to patch missing instance in existing config"
    fi
    mv "${tmp_patch}" "${CONFIG_FILE}"
    ensure_local_env_repo
    fix_ownership "${CONFIG_DIR}"
    log "patched existing config with instance=${BACKREST_INSTANCE}"
    exit 0
  fi
fi

mkdir -p "${CONFIG_DIR}"

# Whether the off-site repository can be described at all. Without a URI the
# template renders `"uri": ""`, and backrest refuses the whole file for it -
# `validation after migration: repo s3: uri is required`, FATAL, on every
# start. The warning here used to promise the opposite ("Backrest will start
# but S3 repo may not be available"), and nothing rebuilt or restarted the
# container often enough to notice; CI starting it from an empty DATA_LOCATION
# is what did.
#
# Leaving the repo out is a real loss, not a formality, so the warning says so
# in as many words: 's3-backup' is the only plan whose paths include /userdata,
# and the only one whose hooks call db-backup.sh and sqlite-backup.sh. Dropping
# it means the install backs up its .env and nothing else. That is still better
# than the crash loop it replaces - a backrest that will not start backs up
# nothing at all, and says so nowhere.
S3_CONFIGURED=1
if [ -z "${BACKREST_S3_URI}" ] || [ -z "${BACKREST_S3_REPO_PASSWORD}" ] || \
   [ -z "${S3_ACCESS_KEY_ID}" ] || [ -z "${S3_SECRET_ACCESS_KEY}" ]; then
  S3_CONFIGURED=0
  log "WARNING: S3 credentials incomplete; leaving out the 's3' repo and the 's3-backup' plan"
  log "Set: BACKREST_S3_URI, BACKREST_S3_REPO_PASSWORD, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY"
  log "Until you do, NOTHING under /userdata is backed up. 's3-backup' is the only plan that"
  log "covers it and the only caller of db-backup.sh and sqlite-backup.sh, so no database dump"
  log "runs either. What is left is the '${LOCAL_PLAN_ID}' plan, which snapshots the .env file"
  log "into ${LOCAL_REPO_URI} and nothing else."
  log "To add the off-site repo later: set those four, delete ${CONFIG_FILE} and re-run."
  log "This script leaves an existing config alone, so it will not add the repo by itself."
fi

tmp_file="$(mktemp)"
trap 'rm -f "${tmp_file}" "${tmp_patch:-}"' EXIT INT TERM

# jq --arg rather than sed: the values are user-supplied secrets going into
# JSON that defines shell hook commands, so a " or \ in a password must become
# a JSON escape, never a structure change.
jq \
  --arg instance "${BACKREST_INSTANCE}" \
  --arg uri "${BACKREST_S3_URI}" \
  --arg password "${BACKREST_S3_REPO_PASSWORD}" \
  --arg access_key "${S3_ACCESS_KEY_ID}" \
  --arg secret_key "${S3_SECRET_ACCESS_KEY}" \
  --arg region "${S3_REGION}" \
  'walk(if type == "string" then
      gsub("__BACKREST_INSTANCE__"; $instance)
    | gsub("__BACKREST_S3_URI__"; $uri)
    | gsub("__BACKREST_S3_REPO_PASSWORD__"; $password)
    | gsub("__BACKREST_S3_ACCESS_KEY_ID__"; $access_key)
    | gsub("__BACKREST_S3_SECRET_ACCESS_KEY__"; $secret_key)
    | gsub("__BACKREST_S3_REGION__"; $region)
    else . end)' \
  "${TEMPLATE_FILE}" > "${tmp_file}" || die "failed to render config from template"

# Dropped rather than rendered empty, for the reason above. Both together:
# a plan whose repo is gone fails the same validation the repo would have.
if [ "${S3_CONFIGURED}" -eq 0 ]; then
  tmp_patch="$(mktemp)"
  if jq '.repos = ((.repos // []) | map(select(.id != "s3")))
       | .plans = ((.plans // []) | map(select(.repo != "s3")))' \
      "${tmp_file}" > "${tmp_patch}" && [ -s "${tmp_patch}" ]; then
    mv "${tmp_patch}" "${tmp_file}"
  else
    rm -f "${tmp_patch}"
    die "failed to drop the unconfigured S3 repo from the rendered config"
  fi
fi

mv "${tmp_file}" "${CONFIG_FILE}"
ensure_local_env_repo
fix_ownership "${CONFIG_DIR}"
log "Backrest config initialized at ${CONFIG_FILE}"
