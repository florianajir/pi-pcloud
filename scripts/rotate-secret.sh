#!/bin/sh
# Rotate one independent per-service secret, and propagate it to every consumer.
#
# rotate-password.sh owns the shared PASSWORD; its header lists these secrets as
# deliberately out of scope, because none of them is derived from PASSWORD. What
# earns them a command of their own is not generating a value - lib.sh's
# generate_secret is one line - but knowing every place the value has to land.
# Every failure this command exists to prevent was a forgotten consumer, not a
# bad secret:
#
#   - BACKREST_AUTH_PASSWORD rotated, config/homepage/secrets/backrest_password
#     left behind: the Homepage widget answered 401.
#   - A restic password rotated in the repository, config.json left behind:
#     "wrong password or no key found", and Backrest locked out of its own repo.
#   - S3 keys rotated for Backrest, Beszel's PocketBase settings left behind:
#     its nightly database backup would have failed silently.
#
# So each target below states its source of truth, its consumers, and a check
# that proves the rotation reached them. --check runs those checks alone, which
# also catches drift that no rotation caused.
#
# Usage: sh scripts/rotate-secret.sh <target> [--yes] [--check]
#        sh scripts/rotate-secret.sh --list

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

BACKREST_CONTAINER="pi-backrest"
REDIS_CONTAINER="pi-redis"
BACKREST_CONFIG="${PROJECT_DIR}/config/backrest/config.json"
HOMEPAGE_BACKREST_SECRET="${PROJECT_DIR}/config/homepage/secrets/backrest_password"

ASSUME_YES=0
CHECK_ONLY=0
TARGET=""

for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=1 ;;
        --check) CHECK_ONLY=1 ;;
        --list) TARGET="--list" ;;
        -*) die "unknown option: $arg" ;;
        *) [ -z "$TARGET" ] && TARGET="$arg" || die "only one target at a time (got '$TARGET' and '$arg')" ;;
    esac
done

usage() {
    cat <<'EOF'
Usage: sh scripts/rotate-secret.sh <target> [--yes] [--check]

Targets:
  backrest-auth   Backrest's API password        -> backrest.env, config.json, Homepage's copy
  restic-s3       restic password, s3 repo       -> .env, the repository itself, config.json
  restic-usb      restic password, usb repo      -> .env, the repository itself, config.json
  s3-keys         propagate only, never generates (the keys come from the S3 provider)
                                                 -> config.json, Beszel's PocketBase settings
  beszel-token    Beszel agent universal token   -> agent.env, the agent container
  n8n-runner      n8n task-broker token          -> config/n8n/n8n.env, n8n + n8n-runners
  comet           Comet's admin/configure logins -> config/comet/comet.env
  vaultwarden     Vaultwarden /admin token       -> the secrets dir, vaultwarden
  ntfy            every ntfy password and token  -> ntfy.env and every publisher
  redis-auth      the shared Redis password      -> the secrets dir, valkey's included
                                                    conf, authelia + immich + nextcloud

Options:
  --check   report drift between a secret and its consumers; change nothing
  --yes     skip the confirmation prompt
  --list    print the target names, one per line
EOF
}

case "$TARGET" in
    "") usage; exit 1 ;;
    --list) printf '%s\n' backrest-auth restic-s3 restic-usb s3-keys beszel-token n8n-runner comet vaultwarden ntfy redis-auth; exit 0 ;;
esac

# --- Rollback bookkeeping -----------------------------------------------------
#
# Every file this script is about to edit is copied first, and restored as a set
# if a verification fails. The exception is spelled out where it applies: once
# `restic key passwd` has run, the repository only accepts the *new* password,
# so putting the old one back in .env would be the opposite of a repair.

BACKUP_SUFFIX=".rotate-secret.bak"
BACKED_UP=""
ROLLBACK_ENABLED=1

backup_path() {
    _bp="$1"
    [ -e "$_bp" ] || return 0
    cp -a "$_bp" "${_bp}${BACKUP_SUFFIX}" || die "could not back up $_bp"
    safe_chmod 600 "${_bp}${BACKUP_SUFFIX}"
    BACKED_UP="$BACKED_UP$_bp
"
}

restore_backups() {
    [ "$ROLLBACK_ENABLED" -eq 1 ] || { log "rollback disabled past this point; leaving files as they are"; return 0; }
    [ -n "$BACKED_UP" ] || return 0
    printf '%s' "$BACKED_UP" | while IFS= read -r _rb; do
        [ -n "$_rb" ] || continue
        [ -e "${_rb}${BACKUP_SUFFIX}" ] || continue
        cp -a "${_rb}${BACKUP_SUFFIX}" "$_rb" && log "restored $_rb"
    done
}

drop_backups() {
    printf '%s' "$BACKED_UP" | while IFS= read -r _db; do
        [ -n "$_db" ] || continue
        rm -f "${_db}${BACKUP_SUFFIX}"
    done
    BACKED_UP=""
}

fail() {
    log "ERROR: $*"
    log "Rolling back."
    restore_backups
    die "rotation aborted; nothing should have changed"
}

confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    printf 'Rotate %s? Type yes to confirm: ' "$TARGET"
    read -r _answer
    [ "$_answer" = "yes" ] || die "aborted"
}

fingerprint() {
    printf '%s' "$1" | sha256sum | cut -c1-12
}

# --- .env ---------------------------------------------------------------------

env_set_key() {
    # env_set_key <KEY> <value>; verifies by reading the value back.
    _key="$1"
    _val="$2"
    grep -q "^${_key}=" "$ENV_FILE" || fail "${_key}= not found in .env"
    sed -i "s|^${_key}=.*|${_key}=$(sed_escape "$_val")|" "$ENV_FILE" ||
        fail "could not write ${_key} to .env"
    [ "$(get_env_value "$_key")" = "$_val" ] ||
        fail "${_key} did not read back as written - .env may be corrupt"
    log "wrote ${_key} to .env ($(fingerprint "$_val"))"
}

# --- Backrest -----------------------------------------------------------------

backrest_repo_json() {
    docker exec "$BACKREST_CONTAINER" jq -cer --arg r "$1" \
        '.repos[] | select(.id==$r)' /config/backrest/config.json
}

backrest_repo_password() {
    jq -r --arg r "$1" '.repos[]|select(.id==$r)|.password' "$BACKREST_CONFIG"
}

backrest_repo_env_value() {
    jq -r --arg r "$1" --arg k "$2" \
        '.repos[]|select(.id==$r)|.env[]?|select(startswith($k+"="))' "$BACKREST_CONFIG" |
        sed "s/^$2=//"
}

backrest_config_patch() {
    # backrest_config_patch <jq filter> <jq args...>; writes atomically, keeps 0600.
    _filter="$1"
    shift
    _tmp="$(mktemp "${BACKREST_CONFIG}.XXXXXX")" || fail "mktemp failed"
    if ! jq "$@" "$_filter" "$BACKREST_CONFIG" > "$_tmp" ||
       [ ! -s "$_tmp" ] ||
       ! jq -e '(.repos|length) > 0' "$_tmp" >/dev/null; then
        rm -f "$_tmp"
        fail "refusing to write a config.json that lost its repos"
    fi
    chmod 600 "$_tmp"
    mv "$_tmp" "$BACKREST_CONFIG"
    fix_ownership "$BACKREST_CONFIG"
}

enabled_services() {
    compose config --services 2>/dev/null
}

recreate_enabled() {
    # `compose up -d <svc>` STARTS a service whose profile is not selected, which
    # would quietly re-enable something the operator turned off. Only touch what
    # COMPOSE_PROFILES already includes.
    #
    # --force is for a secret that lives in a *bind-mounted file*: rotating it
    # leaves the service definition byte-identical, so compose finds a container
    # whose config hash already matches and does nothing at all. Secrets carried
    # by an env_file or an environment value do change the hash, and those
    # callers must not pass it - a needless recreate is not free.
    _force=""
    if [ "${1:-}" = "--force" ]; then
        _force="--force-recreate"
        shift
    fi
    _wanted=""
    _skipped=""
    for _svc in "$@"; do
        if enabled_services | grep -qx "$_svc"; then
            _wanted="$_wanted $_svc"
        else
            _skipped="$_skipped $_svc"
        fi
    done
    [ -z "$_skipped" ] || log "not enabled, left alone:$_skipped"
    [ -n "$_wanted" ] || { log "none of the affected services are enabled; nothing to recreate"; return 0; }
    # up -d, never restart: env_file values are frozen when the container is created.
    # shellcheck disable=SC2086  # deliberate word splitting into a service list
    compose up -d $_force $_wanted >/dev/null 2>&1 || return 1
    log "recreated:$_wanted"
}

restic_run() {
    # restic_run <repo_id> <restic args...>, with the repo's own env and password.
    _repo="$1"
    shift
    RS_ARGS="$*"
    export RS_ARGS
    RS_REPO="$_repo" docker exec -i -e RS_REPO -e RS_ARGS "$BACKREST_CONTAINER" sh -s <<'INNEREOF'
set -eu
rj=$(jq -cer --arg r "$RS_REPO" '.repos[] | select(.id==$r)' /config/backrest/config.json)
while IFS= read -r kv; do case "$kv" in *=*) export "${kv?}" ;; esac; done <<ENVEOF
$(printf '%s' "$rj" | jq -r '.env[]? // empty')
ENVEOF
RESTIC_PASSWORD="$(printf '%s' "$rj" | jq -r .password)"
RESTIC_REPOSITORY="$(printf '%s' "$rj" | jq -r .uri)"
export RESTIC_PASSWORD RESTIC_REPOSITORY
# shellcheck disable=SC2086  # RS_ARGS is a command line, split on purpose
restic $RS_ARGS
INNEREOF
}

restic_key_passwd() {
    # The new password reaches the container through the environment and a 0600
    # file, never through argv.
    _repo="$1"
    _new="$2"
    RS_REPO="$_repo" RS_NEW="$_new" docker exec -i -e RS_REPO -e RS_NEW "$BACKREST_CONTAINER" sh -s <<'INNEREOF'
set -eu
rj=$(jq -cer --arg r "$RS_REPO" '.repos[] | select(.id==$r)' /config/backrest/config.json)
while IFS= read -r kv; do case "$kv" in *=*) export "${kv?}" ;; esac; done <<ENVEOF
$(printf '%s' "$rj" | jq -r '.env[]? // empty')
ENVEOF
RESTIC_PASSWORD="$(printf '%s' "$rj" | jq -r .password)"
RESTIC_REPOSITORY="$(printf '%s' "$rj" | jq -r .uri)"
export RESTIC_PASSWORD RESTIC_REPOSITORY
umask 077
npw=$(mktemp)
trap 'rm -f "$npw"' EXIT INT TERM
printf '%s' "$RS_NEW" > "$npw"
restic key passwd --new-password-file "$npw"
INNEREOF
}

require_backrest() {
    container_is_running "$BACKREST_CONTAINER" || die "$BACKREST_CONTAINER is not running"
}

# In --check, a stopped Backrest means "cannot tell", not "drifted". Reporting
# drift there makes `make doctor` print `run: make rotate-secret TARGET=restic-s3`,
# and following that advice on a healthy repository runs an irreversible
# `restic key passwd`.
backrest_available() {
    container_is_running "$BACKREST_CONTAINER"
}

# --- Targets ------------------------------------------------------------------

check_backrest_auth() {
    _src="$(read_env_value_from_file "${PROJECT_DIR}/config/backrest/backrest.env" BACKREST_AUTH_PASSWORD)"
    _hp="$(tr -d '\r\n' < "$HOMEPAGE_BACKREST_SECRET" 2>/dev/null || true)"
    [ -n "$_src" ] || { log "DRIFT: BACKREST_AUTH_PASSWORD is empty in backrest.env"; return 1; }
    if [ "$_src" = "$_hp" ]; then
        log "OK: backrest.env and Homepage's copy agree ($(fingerprint "$_src"))"
        return 0
    fi
    log "DRIFT: Homepage's copy differs from backrest.env - its widget will answer 401"
    return 1
}

rotate_backrest_auth() {
    backup_path "${PROJECT_DIR}/config/backrest/backrest.env"
    backup_path "$HOMEPAGE_BACKREST_SECRET"
    rm -f "${PROJECT_DIR}/config/backrest/backrest.env"
    sh "${SCRIPT_DIR}/backrest-pre-start.sh" >/dev/null || fail "backrest-pre-start.sh failed"
    recreate_enabled backrest || fail "could not recreate backrest"
    wait_for_health "$BACKREST_CONTAINER" 60 2 || fail "backrest did not become healthy"
    sh "${SCRIPT_DIR}/homepage-widgets-bootstrap.sh" >/dev/null ||
        fail "homepage-widgets-bootstrap.sh failed"
    check_backrest_auth || fail "Homepage's copy still disagrees after the bootstrap"
}

check_restic() {
    _repo="$1"
    _envkey="$2"
    backrest_available || { log "UNKNOWN: $BACKREST_CONTAINER is not running"; return 2; }
    _cfg="$(backrest_repo_password "$_repo")"
    _env="$(get_env_value "$_envkey")"
    _ok=0
    if [ "$_cfg" != "$_env" ]; then
        log "DRIFT: config.json repo '$_repo' and .env ${_envkey} differ"
        _ok=1
    fi
    if restic_run "$_repo" snapshots --latest 1 >/dev/null 2>&1; then
        log "OK: repository '$_repo' opens with the password in config.json"
    else
        log "DRIFT: repository '$_repo' does NOT open with the password in config.json"
        _ok=1
    fi
    return "$_ok"
}

rotate_restic() {
    _repo="$1"
    _envkey="$2"
    require_backrest

    restic_run "$_repo" snapshots --latest 1 >/dev/null 2>&1 ||
        die "repository '$_repo' does not open with the current password; fix that before rotating"

    _new="$(generate_secret)"
    [ -n "$_new" ] || die "generate_secret produced nothing"

    backup_path "$ENV_FILE"
    backup_path "$BACKREST_CONFIG"

    # .env first, deliberately: `restic key passwd` removes the old key, so from
    # that moment the new value is the only way into the repository. Persisted
    # before it can be lost is the whole safety property of this target.
    env_set_key "$_envkey" "$_new"

    if ! restic_key_passwd "$_repo" "$_new"; then
        fail "restic key passwd failed on '$_repo'"
    fi
    log "repository '$_repo' now holds the new key"

    # Past this line a rollback must NOT restore the old password: the repository
    # would no longer accept it. Everything below is repair, not undo. The backup
    # files stay tracked so drop_backups still deletes them - they hold the old
    # secret, and nothing should keep that around.
    ROLLBACK_ENABLED=0

    backrest_config_patch '(.repos[] | select(.id==$r) | .password) = $p' --arg r "$_repo" --arg p "$_new"
    recreate_enabled backrest ||
        die "config.json is updated but backrest would not restart - run: docker compose up -d backrest"
    wait_for_health "$BACKREST_CONTAINER" 60 2 || log "WARNING: backrest is slow to report healthy"

    if ! check_restic "$_repo" "$_envkey"; then
        die "The new password is in .env and in the repository, but verification failed.
     Do NOT restore an old .env: the repository only accepts the new value.
     Check config.json's repo '$_repo' against ${_envkey} in .env."
    fi
}

check_s3_keys() {
    backrest_available || { log "UNKNOWN: $BACKREST_CONTAINER is not running"; return 2; }
    _ok=0
    for _k in ACCESS_KEY_ID SECRET_ACCESS_KEY; do
        _cfg="$(backrest_repo_env_value s3 "AWS_$_k")"
        _env="$(get_env_value "S3_$_k")"
        if [ "$_cfg" = "$_env" ] && [ -n "$_env" ]; then
            log "OK: AWS_$_k in config.json matches S3_$_k in .env ($(fingerprint "$_env"))"
        else
            log "DRIFT: AWS_$_k in config.json differs from S3_$_k in .env"
            _ok=1
        fi
    done
    if restic_run s3 snapshots --latest 1 >/dev/null 2>&1; then
        log "OK: the s3 repository is reachable with the keys in config.json"
    else
        log "DRIFT: the s3 repository is NOT reachable with the keys in config.json"
        _ok=1
    fi
    return "$_ok"
}

rotate_s3_keys() {
    require_backrest
    _ak="$(get_env_value S3_ACCESS_KEY_ID)"
    _sk="$(get_env_value S3_SECRET_ACCESS_KEY)"
    [ -n "$_ak" ] && [ -n "$_sk" ] ||
        die "S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY are empty in .env - put the new keys there first"

    log "This target propagates .env; it never generates. Create the new key at your S3 provider first."

    # Prove the keys work before committing them, using the repo's own password
    # but the candidate credentials. A key with read but not write access is a
    # backup that fails at 4am, so the check writes: `check` takes a lock.
    log "testing the keys in .env against the bucket (read, then write)"
    NAK="$_ak" NSK="$_sk" docker exec -i -e NAK -e NSK "$BACKREST_CONTAINER" sh -s <<'INNEREOF' >/dev/null 2>&1 ||
set -eu
rj=$(jq -cer '.repos[] | select(.id=="s3")' /config/backrest/config.json)
while IFS= read -r kv; do
  case "$kv" in AWS_ACCESS_KEY_ID=*|AWS_SECRET_ACCESS_KEY=*) ;; *=*) export "${kv?}" ;; esac
done <<ENVEOF
$(printf '%s' "$rj" | jq -r '.env[]? // empty')
ENVEOF
AWS_ACCESS_KEY_ID="$NAK"; AWS_SECRET_ACCESS_KEY="$NSK"
RESTIC_PASSWORD="$(printf '%s' "$rj" | jq -r .password)"
RESTIC_REPOSITORY="$(printf '%s' "$rj" | jq -r .uri)"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_PASSWORD RESTIC_REPOSITORY
restic check
INNEREOF
        die "the keys in .env cannot read and write the bucket - nothing was changed"
    log "the keys in .env can read and write the bucket"

    backup_path "$BACKREST_CONFIG"
    backrest_config_patch '
        (.repos[] | select(.id=="s3") | .env) |= map(
            if startswith("AWS_ACCESS_KEY_ID=")     then "AWS_ACCESS_KEY_ID=" + $ak
          elif startswith("AWS_SECRET_ACCESS_KEY=") then "AWS_SECRET_ACCESS_KEY=" + $sk
          else . end)' --arg ak "$_ak" --arg sk "$_sk"
    recreate_enabled backrest || fail "could not recreate backrest"
    wait_for_health "$BACKREST_CONTAINER" 60 2 || log "WARNING: backrest is slow to report healthy"

    # Beszel keeps its own copy for its nightly database backup, and reads it
    # from nowhere else - this is the consumer that failed silently.
    if container_is_running pi-beszel; then
        sh "${SCRIPT_DIR}/beszel-agent-bootstrap.sh" >/dev/null 2>&1 ||
            log "WARNING: beszel-agent-bootstrap.sh failed; Beszel may still hold the old keys"
    fi

    check_s3_keys || fail "verification failed after propagating the keys"
}

check_secret_file() {
    # For secrets stored as a bare file rather than KEY=VALUE. "I cannot read it"
    # and "it is not there" are different answers: the Authelia secrets directory
    # is root:root 0700, so a non-root run sees nothing and must say so rather
    # than report drift that is not there.
    if [ -s "$1" ]; then
        log "OK: $2 is present ($(fingerprint "$(cat "$1")"))"
        return 0
    fi
    if [ "$(id -u)" -ne 0 ] && [ ! -r "$(dirname "$1")" ]; then
        log "UNKNOWN: $(dirname "$1") is not readable as $(id -un); re-run with sudo"
        return 2
    fi
    log "DRIFT: $2 is missing or empty"
    return 1
}

check_generated_env_file() {
    # check_generated_env_file <file> <key> <label> [container]
    #
    # Presence alone proves nothing: env_file values are frozen when a container
    # is created, so the file can hold a value the running container never saw -
    # which is the drift this tool exists to catch. When a container is named and
    # running, compare against what it actually holds.
    _v="$(read_env_value_from_file "$1" "$2")"
    if [ -n "$_v" ]; then
        _ctr="${4:-}"
        if [ -n "$_ctr" ] && container_is_running "$_ctr"; then
            _live="$(docker inspect "$_ctr" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
                sed -n "s/^$2=//p" | head -n1)"
            if [ -z "$_live" ]; then
                log "DRIFT: $2 is in $3 but $_ctr does not carry it"
                return 1
            fi
            # The file carries Compose's `$$` escaping; the container's environment
            # carries the single `$` Compose produced from it. Comparing the raw
            # forms reports drift for every bcrypt hash in ntfy.env.
            _vu="$(printf '%s' "$_v" | sed 's/[$][$]/$/g')"
            if [ "$_live" != "$_v" ] && [ "$_live" != "$_vu" ]; then
                log "DRIFT: $3 holds $(fingerprint "$_v") but $_ctr is running with $(fingerprint "$_live") - recreate it with up -d"
                return 1
            fi
            log "OK: $2 in $3 matches the running $_ctr ($(fingerprint "$_v"))"
            return 0
        fi
        log "OK: $2 present in $3 ($(fingerprint "$_v"))"
        return 0
    fi
    log "DRIFT: $2 is missing or empty in $3"
    return 1
}

rotate_generated_env_file() {
    # rotate_generated_env_file <file> <pre-start script> <services to recreate...>
    _file="$1"
    _script="$2"
    shift 2
    backup_path "$_file"
    rm -f "$_file"
    sh "${SCRIPT_DIR}/${_script}" >/dev/null || fail "${_script} failed"
    [ -s "$_file" ] || fail "${_script} did not recreate $_file"
    recreate_enabled "$@" || fail "could not recreate: $*"
}

# --- Dispatch -----------------------------------------------------------------

do_check() {
    case "$TARGET" in
        backrest-auth) check_backrest_auth ;;
        restic-s3)     check_restic s3 BACKREST_S3_REPO_PASSWORD ;;
        restic-usb)    check_restic usb BACKREST_LOCAL_REPO_PASSWORD ;;
        s3-keys)       check_s3_keys ;;
        beszel-token)  check_generated_env_file "${PROJECT_DIR}/config/beszel-agent/agent.env" TOKEN "agent.env" pi-beszel-agent ;;
        n8n-runner)    check_generated_env_file "${PROJECT_DIR}/config/n8n/n8n.env" N8N_RUNNERS_AUTH_TOKEN "n8n.env" pi-n8n ;;
        comet)         check_generated_env_file "${PROJECT_DIR}/config/comet/comet.env" ADMIN_DASHBOARD_PASSWORD "comet.env" pi-comet ;;
        vaultwarden)   check_secret_file "$(resolve_data_location_path)/authelia-config/secrets/vaultwarden_admin_token" "the Vaultwarden admin token" ;;
        redis-auth)    check_redis_auth ;;
        ntfy)          check_generated_env_file "${PROJECT_DIR}/config/ntfy/ntfy.env" NTFY_AUTH_USERS "ntfy.env" pi-ntfy ;;
        *) die "unknown target '$TARGET' (see --list)" ;;
    esac
}

do_rotate() {
    case "$TARGET" in
        backrest-auth) rotate_backrest_auth ;;
        restic-s3)     rotate_restic s3 BACKREST_S3_REPO_PASSWORD ;;
        restic-usb)    rotate_restic usb BACKREST_LOCAL_REPO_PASSWORD ;;
        s3-keys)       rotate_s3_keys ;;
        beszel-token)  rotate_beszel_token ;;
        n8n-runner)    rotate_generated_env_file "${PROJECT_DIR}/config/n8n/n8n.env" n8n-pre-start.sh n8n n8n-runners ;;
        comet)         rotate_generated_env_file "${PROJECT_DIR}/config/comet/comet.env" comet-pre-start.sh comet ;;
        vaultwarden)   rotate_vaultwarden ;;
        ntfy)          rotate_ntfy ;;
        redis-auth)    rotate_redis_auth ;;
        *) die "unknown target '$TARGET' (see --list)" ;;
    esac
}

# Presence is not the question: the value has to be the one valkey is actually
# enforcing, because a stale copy is a cache every client is locked out of.
check_redis_auth() {
    _file="$(resolve_data_location_path)/authelia-config/secrets/redis_password"

    check_secret_file "$_file" "the Redis password" || return "$?"

    if ! container_is_running "$REDIS_CONTAINER"; then
        log "UNKNOWN: $REDIS_CONTAINER is not running"
        return 2
    fi

    # The password goes in on stdin, never argv: `valkey-cli -a <pw>` and
    # `docker exec -e REDISCLI_AUTH=<pw>` both put it in the host process table.
    if printf 'AUTH %s\nPING\n' "$(cat "$_file")" |
        docker exec -i "$REDIS_CONTAINER" valkey-cli 2>/dev/null | grep -q PONG; then
        log "OK: valkey accepts the password in the secrets directory"
        return 0
    fi

    log "DRIFT: valkey rejects the password in the secrets directory"
    return 1
}

rotate_redis_auth() {
    [ "$(id -u)" -eq 0 ] ||
        die "the Authelia secrets directory is root:root 0700 - re-run with sudo"
    _dir="$(resolve_data_location_path)/authelia-config/secrets"
    _conf="$(resolve_data_location_path)/redis/redis-auth.conf"
    _copy="$(resolve_data_location_path)/redis/redis-password"

    backup_path "$_dir/redis_password"
    backup_path "$_conf"
    backup_path "$_copy"
    rm -f "$_dir/redis_password" "$_conf" "$_copy"
    sh "${SCRIPT_DIR}/redis-pre-start.sh" >/dev/null || fail "redis-pre-start.sh failed"
    [ -s "$_dir/redis_password" ] || fail "the Redis password was not regenerated"

    # redis first, or every consumer is recreated against a server still
    # enforcing the old password. The hook above has already done this when redis
    # was running; this is the profile-aware pass that also covers it being down.
    recreate_enabled --force redis || fail "could not recreate redis"
    # All three read the secret from a bind-mounted file, so nothing here
    # changes the service definition and --force is what makes compose act.
    recreate_enabled --force authelia immich-server nextcloud ||
        fail "could not recreate the Redis consumers"
}

rotate_vaultwarden() {
    [ "$(id -u)" -eq 0 ] ||
        die "the Authelia secrets directory is root:root 0700 - re-run with sudo"
    _dir="$(resolve_data_location_path)/authelia-config/secrets"
    backup_path "$_dir/vaultwarden_admin_token"
    backup_path "$_dir/vaultwarden_admin_token_hash"
    rm -f "$_dir/vaultwarden_admin_token" "$_dir/vaultwarden_admin_token_hash"
    sh "${SCRIPT_DIR}/vaultwarden-pre-start.sh" >/dev/null || fail "vaultwarden-pre-start.sh failed"
    [ -s "$_dir/vaultwarden_admin_token" ] || fail "the token was not regenerated"
    recreate_enabled vaultwarden || fail "could not recreate vaultwarden"
}

rotate_beszel_token() {
    # Beszel's hub hands back whatever universal token is currently active, and
    # beszel-agent-bootstrap.sh reuses it. Clearing the local copy is therefore
    # not enough: the hub has to issue a new one first, which only its UI does.
    die "beszel-token cannot be rotated from here.
     The hub returns the active universal token and the bootstrap reuses it, so
     clearing agent.env just fetches the same value back.
     Disable and re-enable the universal token in the Beszel UI (Settings ->
     Universal token), then run: sh scripts/beszel-agent-bootstrap.sh
     Verify with: docker logs pi-beszel-agent | grep 'WebSocket connected'"
}

rotate_ntfy() {
    # ntfy.env holds every publisher's password and token. The three services
    # that read it as an env_file must be recreated, and the publishers that keep
    # their own copy re-bootstrapped.
    _nf="${PROJECT_DIR}/config/ntfy/ntfy.env"
    backup_path "$_nf"
    # Drop only the ntfy credentials, never the whole file. ntfy-pre-start.sh also
    # keeps UPTIME_KUMA_ADMIN_PASSWORD here, and that one is not ours to reissue:
    # Uptime Kuma stores its own hash in its database and its bootstrap has to log
    # in with the old value to disable auth. Regenerating it locks the bootstrap
    # out for good, with the only copy of the old password in a backup this script
    # deletes on success.
    if [ -s "$_nf" ]; then
        _keep="$(mktemp "${_nf}.XXXXXX")" || fail "mktemp failed"
        grep -v -E '^NTFY_[A-Z_]*(PASSWORD|TOKEN|HASH)=' "$_nf" > "$_keep" || true
        chmod 600 "$_keep"
        mv "$_keep" "$_nf"
        fix_ownership "$_nf"
    fi
    sh "${SCRIPT_DIR}/ntfy-pre-start.sh" >/dev/null || fail "ntfy-pre-start.sh failed"
    [ -s "${PROJECT_DIR}/config/ntfy/ntfy.env" ] || fail "ntfy.env was not recreated"
    recreate_enabled ntfy backrest uptime-kuma ||
        fail "could not recreate the services that read ntfy.env"
    for _b in beszel-agent-bootstrap.sh dockhand-oidc-bootstrap.sh prowlarr-bootstrap.sh \
              qbittorrent-bootstrap.sh shelfmark-settings-bootstrap.sh uptime-kuma-bootstrap.sh; do
        [ -f "${SCRIPT_DIR}/${_b}" ] || continue
        sh "${SCRIPT_DIR}/${_b}" >/dev/null 2>&1 ||
            log "WARNING: ${_b} failed; that publisher may still hold an old ntfy credential"
    done
    if container_is_running pi-authelia; then
        systemctl restart pi-pcloud-authelia-ntfy.service 2>/dev/null ||
            log "WARNING: could not restart the Authelia ntfy watcher"
    fi
}

# --- Main ---------------------------------------------------------------------

[ -f "$ENV_FILE" ] || die ".env missing at $ENV_FILE"

if [ "$CHECK_ONLY" -eq 1 ]; then
    log "=== checking $TARGET ==="
    _rc=0
    do_check || _rc=$?
    case "$_rc" in
        0) log "$TARGET: consistent" ;;
        2) log "$TARGET: could not be verified with these privileges" ;;
        *) log "$TARGET: drift found (nothing was changed)" ;;
    esac
    exit "$_rc"
fi

log "=== rotating $TARGET ==="
confirm
do_rotate
drop_backups
log "$TARGET: rotated and verified"
