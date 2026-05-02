#!/bin/bash
# Bootstrap qBittorrent: set WebUI credentials.
# Auth bypass (subnet whitelist + reverse proxy) is pre-configured via the
# config template rendered by qbittorrent-pre-start.sh, so setPreferences
# can be called unauthenticated from 127.0.0.1.
# Runs as ExecStartPost after docker compose up. Idempotent.

set -euo pipefail

. "$(dirname "$0")/lib.sh"

MAX_RETRIES=60
RETRY_INTERVAL=5
QB_CONTAINER="${QB_CONTAINER:-pi-qbittorrent}"
QB_API="http://127.0.0.1:8080/api/v2"

qb_curl() {
    docker exec "$QB_CONTAINER" curl -sS "$@"
}

wait_for_qbittorrent() {
    log "Waiting for qBittorrent WebUI to be ready..."
    for i in $(seq 1 $MAX_RETRIES); do
        if qb_curl -f "$QB_API/app/webapiVersion" >/dev/null 2>&1; then
            log "qBittorrent WebUI is ready"
            return 0
        fi
        sleep "$RETRY_INTERVAL"
    done
    log "ERROR: qBittorrent WebUI did not become ready in time"
    return 1
}

# Returns 0 when expected credentials are persisted in qBittorrent.conf.
# We intentionally avoid auth/login checks here because localhost bypass can
# make login checks return false positives.
credentials_configured() {
    local username="$1"
    local conf
    conf=$(docker exec "$QB_CONTAINER" cat /config/qBittorrent/qBittorrent.conf 2>/dev/null) || return 1
    printf '%s\n' "$conf" | grep -Fq "WebUI\\Username=$username" || return 1
    printf '%s\n' "$conf" | grep -Fq 'WebUI\Password_PBKDF2=' || return 1
    return 0
}

# Set credentials via the API without authentication.
# Works because the config template enables auth bypass for 127.0.0.1.
set_credentials() {
    local username="$1"
    local password="$2"
    local prefs_file http_code
    prefs_file=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f $prefs_file" EXIT
    printf 'json={"web_ui_username":"%s","web_ui_password":"%s"}' \
        "$username" "$password" > "$prefs_file"
    http_code=$(docker exec -i "$QB_CONTAINER" curl -sS \
        -X POST \
        -H "Referer: http://127.0.0.1:8080" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -w "%{http_code}" \
        -o /dev/null \
        --data @- \
        "$QB_API/app/setPreferences" < "$prefs_file")
    rm -f "$prefs_file"
    [ "$http_code" = "200" ] || die "setPreferences returned HTTP $http_code"
    log "Credentials set"
}

main() {
    wait_for_qbittorrent

    local username password
    username="$(get_env_value USER)"
    password="$(get_env_value PASSWORD)"
    [ -n "$username" ] && [ -n "$password" ] || die "USER or PASSWORD not set in .env"

    # Fast path: credentials already persisted from a previous run.
    if credentials_configured "$username"; then
        log "Credentials already configured, skipping"
        return 0
    fi

    log "Setting credentials..."
    set_credentials "$username" "$password"
    log "qBittorrent bootstrap complete"
}

main
