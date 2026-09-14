#!/bin/sh
# Render config/shelfmark/shelfmark.env, the half of Shelfmark's configuration
# that has to be discovered from other services: the Prowlarr API key, the
# qBittorrent login, the ntfy route and SMTP. The rest is plain `environment:`
# on the service in compose/media.yaml, and the OIDC client is
# shelfmark-settings-bootstrap.sh (its secret must not travel in an env var).
#
# Shelfmark resolves every setting from its environment first and only then from
# /config (shelfmark/core/settings_registry.py get_setting_value), so what is
# written here wins over the web UI and is reapplied on every start — which is
# what makes this idempotent without reading Shelfmark's own state.
#
# That precedence is stronger than it looks: core/config.py get() checks
# is_value_from_env *before* any per-account override, so a setting rendered
# here is frozen for every user, not merely locked in the admin UI. Only put a
# value here when that is what you want — a discovered credential, a service
# URL. Anything a user is meant to be able to change belongs in
# shelfmark-settings-bootstrap.sh as a seeded default instead.
#
# A pre-start hook (scripts/stack-up.sh): compose reads env_file at `up`, so the
# file has to exist before the containers start.

set -eu

. "$(dirname "$0")/lib.sh"

OUTPUT_FILE="$PROJECT_DIR/config/shelfmark/shelfmark.env"
NTFY_ENV_FILE="$PROJECT_DIR/config/ntfy/ntfy.env"
PROWLARR_URL="http://prowlarr:9696"
# qBittorrent lives in gluetun's network namespace, so its WebUI answers on the
# gluetun container, the same host Prowlarr's download client points at.
QBITTORRENT_URL="http://gluetun:8080"
NTFY_TOPIC="downloads"

service_enabled() {
    /bin/sh "$SCRIPT_DIR/run-if-enabled.sh" "$1"
}

# Compose interpolates env_file values, so a literal '$' has to be doubled or it
# would be eaten as the start of a variable reference.
escape_compose_env_value() {
    printf '%s' "$1" | sed 's/[$]/$$/g'
}

# From the host copy, not `docker exec`: this is a pre-start hook, so on a cold
# boot no container is up yet and a container read would come back empty - and
# render() would then rewrite the file *without* the Prowlarr block, turning off
# a release source that was working. prowlarr-pre-start.sh runs earlier in the
# same sequence and is what puts the key in this file.
prowlarr_api_key() {
    local config_file=""
    config_file="$(resolve_data_location_path)/prowlarr/config.xml"
    [ -r "$config_file" ] || return 0
    grep -oE '<ApiKey>[^<]+</ApiKey>' "$config_file" 2>/dev/null \
        | sed -e 's|<ApiKey>||' -e 's|</ApiKey>||' | tr -d '\r\n'
}

# Apprise's ntfy plugin reads the token out of the userinfo field; mode and auth
# are spelled out rather than left to its hostname/`tk_` heuristics.
ntfy_route_json() {
    local token=""
    token="$(read_env_value_from_file "$NTFY_ENV_FILE" NTFY_SHELFMARK_TOKEN)"
    [ -n "$token" ] || return 1
    jq -cn --arg url "ntfy://${token}@ntfy/${NTFY_TOPIC}?mode=private&auth=token" \
        '[{event: ["all"], url: $url}]'
}

write_prowlarr() {
    local key=""
    service_enabled prowlarr || { log "Prowlarr is not enabled; leaving its release source off"; return 0; }

    key="$(prowlarr_api_key)"
    if [ -z "$key" ]; then
        log "WARNING: could not read the Prowlarr API key; leaving its release source off (retried next start)"
        return 0
    fi

    printf 'PROWLARR_ENABLED=true\n'
    printf 'PROWLARR_URL=%s\n' "$PROWLARR_URL"
    printf 'PROWLARR_API_KEY=%s\n' "$(escape_compose_env_value "$key")"
}

write_qbittorrent() {
    local user="" password=""
    service_enabled qbittorrent || { log "qBittorrent is not enabled; leaving the torrent client unset"; return 0; }

    user="$(get_env_value ADMIN_USER)"
    password="$(get_env_value PASSWORD)"
    [ -n "$user" ] && [ -n "$password" ] || { log "WARNING: ADMIN_USER/PASSWORD not set; leaving the torrent client unset"; return 0; }

    # qBittorrent 5.x rejects usernames under 3 characters, so qbittorrent-bootstrap.sh
    # leaves the WebUI on its generated default login in that case. Writing these
    # credentials anyway would point Shelfmark at an account that does not exist.
    if [ "${#user}" -lt 3 ]; then
        log "WARNING: ADMIN_USER is under qBittorrent's 3-char minimum, so its WebUI kept its default login; leaving the torrent client unset"
        return 0
    fi

    printf 'PROWLARR_TORRENT_CLIENT=qbittorrent\n'
    printf 'QBITTORRENT_URL=%s\n' "$QBITTORRENT_URL"
    printf 'QBITTORRENT_USERNAME=%s\n' "$(escape_compose_env_value "$user")"
    printf 'QBITTORRENT_PASSWORD=%s\n' "$(escape_compose_env_value "$password")"
}

write_notifications() {
    local route=""
    route="$(ntfy_route_json)" || {
        log "WARNING: NTFY_SHELFMARK_TOKEN not found in $NTFY_ENV_FILE; leaving notifications unset"
        return 0
    }
    printf 'ADMIN_NOTIFICATION_ROUTES=%s\n' "$(escape_compose_env_value "$route")"
}

# Only the transport: whether anything is sent is a per-user recipient the
# account owner sets in Shelfmark itself.
write_smtp() {
    local host="" port="" username="" password="" sender=""
    host="$(get_env_value SMTP_HOST)"
    [ -n "$host" ] || return 0

    port="$(get_env_value SMTP_PORT)"
    username="$(get_env_value SMTP_USERNAME)"
    password="$(get_env_value SMTP_PASSWORD)"
    sender="$(get_env_value EMAIL)"

    printf 'EMAIL_SMTP_HOST=%s\n' "$(escape_compose_env_value "$host")"
    printf 'EMAIL_SMTP_PORT=%s\n' "$(escape_compose_env_value "${port:-587}")"
    [ -n "$username" ] && printf 'EMAIL_SMTP_USERNAME=%s\n' "$(escape_compose_env_value "$username")"
    [ -n "$password" ] && printf 'EMAIL_SMTP_PASSWORD=%s\n' "$(escape_compose_env_value "$password")"
    [ -n "$sender" ] && printf 'EMAIL_FROM=%s\n' "$(escape_compose_env_value "$sender")"
    return 0
}

# BOOK_LANGUAGE is deliberately absent. It used to be rendered here, which made
# it unchangeable: Shelfmark's environment wins over a per-account setting, not
# just over the web UI (core/config.py get), so an env value froze the language
# for everyone - while the field's own description promises "Users can override
# this for their own account". It is seeded as a plain default by
# shelfmark-settings-bootstrap.sh instead.
render() {
    printf '# Managed by scripts/shelfmark-pre-start.sh\n'
    write_prowlarr
    write_qbittorrent
    write_notifications
    write_smtp
}

# Docker creates a missing bind source as root:root, which Shelfmark (PUID 1000)
# could not then write into. Same reasoning, and the same "only chown what this
# run created", as scripts/kavita-pre-start.sh - which already covers
# download/books.
ensure_directories() {
    local data_location="" dir=""
    data_location="$(resolve_data_location_path)"

    # download/books is INGEST_DIR, this service's own destination. kavita-pre-start.sh
    # also creates it, but that hook is gated on the kavita profile and Shelfmark
    # runs without it.
    for dir in "$data_location/download" \
               "$data_location/download/books" \
               "$data_location/download/audiobooks" \
               "$data_location/download/shelfmark" \
               "$data_location/shelfmark"; do
        [ -d "$dir" ] && continue
        mkdir -p "$dir"
        fix_ownership "$dir"
    done
}

main() {
    [ -f "$ENV_FILE" ] || die ".env not found at $ENV_FILE"

    ensure_directories

    mkdir -p "$(dirname "$OUTPUT_FILE")"
    write_file_atomic "$OUTPUT_FILE" render || die "Failed to render $OUTPUT_FILE"
    safe_chmod 600 "$OUTPUT_FILE"
    # write_file_atomic renames a fresh mktemp into place, so the file takes the
    # ownership of whoever ran the script - root, from the systemd unit. At 0600
    # that leaves the repo owner unable to read their own generated env, and
    # `docker compose config` (so `make test` and every invariant behind it)
    # fails with "permission denied" until someone chowns it by hand.
    fix_ownership "$OUTPUT_FILE"
    log "Rendered Shelfmark env to $OUTPUT_FILE"
}

main "$@"
