#!/bin/sh
set -eu

. "$(dirname "$0")/lib.sh"

OUTPUT_FILE="${PROJECT_DIR}/config/ntfy/ntfy.env"
OUTPUT_DIR="$(dirname "$OUTPUT_FILE")"
# The image this hook shells into for `ntfy user hash` and `ntfy token
# generate`, read from the rendered compose file rather than pinned a second
# time here. The second pin sat at v2.17.0 while the server moved to v2.28.0 -
# harmless, because both outputs are format-stable, but it is a tag nobody
# bumps and a whole extra image pulled on every fresh host.
#
# Piped straight into jq: the render inlines the contents of every env_file, so
# only the image name is ever read out of it. Lazy on purpose - the expansion
# below runs this only when NTFY_IMAGE is not already set.
resolve_ntfy_image() {
    compose config --format json 2>/dev/null | jq -r '.services.ntfy.image // empty'
}
NTFY_IMAGE="${NTFY_IMAGE:-$(resolve_ntfy_image)}"
[ -n "$NTFY_IMAGE" ] || die "could not read ntfy's image out of the compose files"
# Built by compose from config/backrest/Dockerfile, which installs apache2-utils.
BCRYPT_IMAGE="${BCRYPT_IMAGE:-pi-backrest:local}"
# One topic per reading mode, so each can be muted, scheduled or given its own
# do-not-disturb rule on the phone independently. Publishers only ever get
# access to the topic they belong to (see AUTH_ACCESS_VALUE below).
#   monitoring - service health: uptime-kuma, beszel, dockhand, backrest
#   downloads  - grabs and completed downloads: prowlarr, qbittorrent, shelfmark
#   security   - authelia failed logins and regulation bans
NTFY_MONITORING_TOPIC="monitoring"
NTFY_DOWNLOADS_TOPIC="downloads"
NTFY_SECURITY_TOPIC="security"

hash_password() {
    _password="$1"
    printf '%s\n%s\n' "$_password" "$_password" | \
    docker run -i --rm --entrypoint sh "$NTFY_IMAGE" -lc 'ntfy user hash'
}

generate_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 24 | tr -d '\r\n'
        return
    fi

    head -c 24 /dev/urandom | base64 | tr -d '\r\n'
}

generate_token() {
    docker run --rm --entrypoint sh "$NTFY_IMAGE" -c 'ntfy token generate'
}

escape_compose_env_value() {
    printf '%s' "$1" | sed 's/[$]/$$/g'
}

unescape_compose_env_value() {
    printf '%s' "$1" | sed 's/[$][$]/$/g'
}

# bcrypt salts are random, so re-hashing rewrites NTFY_AUTH_USERS every run and a
# changed env_file value makes compose recreate pi-ntfy on every boot. Reuse a
# stored hash while it still verifies. htpasswd is the only bcrypt verifier this
# stack has (config/backrest/auth-entrypoint.sh uses it too); if the image is
# missing, verification fails and we re-hash, as before.
bcrypt_matches() {
    _stored="$1"
    _plain="$2"
    [ -n "$_stored" ] || return 1
    case "$_stored" in '$2'*) ;; *) return 1 ;; esac
    printf '%s\n' "$_plain" | docker run -i --rm --entrypoint sh "$BCRYPT_IMAGE" -c '
        IFS= read -r plain
        printf "u:%s\n" "$1" > /tmp/verify
        htpasswd -vb /tmp/verify u "$plain" >/dev/null 2>&1
    ' _ "$_stored" >/dev/null 2>&1
}

# hash_password_cached <stored_hash> <plaintext>
hash_password_cached() {
    if bcrypt_matches "$1" "$2"; then
        printf '%s' "$1"
        return 0
    fi
    hash_password "$2"
}

main() {
    if [ ! -f "$ENV_FILE" ]; then
        die ".env not found at $ENV_FILE"
    fi

    USER_VALUE=$(get_env_value ADMIN_USER)
    PASSWORD_VALUE=$(get_env_value PASSWORD)
    NTFY_BACKREST_PASSWORD_VALUE=""
    NTFY_BESZEL_PASSWORD_VALUE=""
    NTFY_DOCKHAND_PASSWORD_VALUE=""
    NTFY_UPTIME_KUMA_PASSWORD_VALUE=""
    NTFY_UPTIME_KUMA_TOKEN_VALUE=""
    UPTIME_KUMA_ADMIN_PASSWORD_VALUE=""
    NTFY_PROWLARR_PASSWORD_VALUE=""
    NTFY_QBITTORRENT_PASSWORD_VALUE=""
    NTFY_QBITTORRENT_TOKEN_VALUE=""
    NTFY_AUTHELIA_PASSWORD_VALUE=""
    NTFY_SHELFMARK_PASSWORD_VALUE=""
    NTFY_SHELFMARK_TOKEN_VALUE=""
    STORED_ADMIN_HASH=""; STORED_BACKREST_HASH=""; STORED_BESZEL_HASH=""
    STORED_DOCKHAND_HASH=""; STORED_UPTIME_KUMA_HASH=""; STORED_PROWLARR_HASH=""
    STORED_QBITTORRENT_HASH=""; STORED_AUTHELIA_HASH=""; STORED_SHELFMARK_HASH=""

    if [ -f "$OUTPUT_FILE" ]; then
        NTFY_BACKREST_PASSWORD_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_BACKREST_PASSWORD)
        if [ -z "$NTFY_BACKREST_PASSWORD_VALUE" ]; then
            NTFY_BACKREST_PASSWORD_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_PASSWORD)
        fi

        NTFY_BESZEL_PASSWORD_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_BESZEL_PASSWORD)
        NTFY_DOCKHAND_PASSWORD_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_DOCKHAND_PASSWORD)
        NTFY_UPTIME_KUMA_PASSWORD_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_UPTIME_KUMA_PASSWORD)
        NTFY_UPTIME_KUMA_TOKEN_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_UPTIME_KUMA_TOKEN)
        UPTIME_KUMA_ADMIN_PASSWORD_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" UPTIME_KUMA_ADMIN_PASSWORD)
        NTFY_PROWLARR_PASSWORD_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_PROWLARR_PASSWORD)
        NTFY_QBITTORRENT_PASSWORD_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_QBITTORRENT_PASSWORD)
        NTFY_QBITTORRENT_TOKEN_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_QBITTORRENT_TOKEN)
        NTFY_AUTHELIA_PASSWORD_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_AUTHELIA_PASSWORD)
        NTFY_SHELFMARK_PASSWORD_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_SHELFMARK_PASSWORD)
        NTFY_SHELFMARK_TOKEN_VALUE=$(read_env_value_from_file "$OUTPUT_FILE" NTFY_SHELFMARK_TOKEN)

        for _u in ADMIN BACKREST BESZEL DOCKHAND UPTIME_KUMA PROWLARR QBITTORRENT AUTHELIA SHELFMARK; do
            eval "STORED_${_u}_HASH=\"\$(unescape_compose_env_value \"\$(read_env_value_from_file \"\$OUTPUT_FILE\" NTFY_${_u}_HASH)\")\""
        done
    fi

    if [ -z "$USER_VALUE" ]; then
        die "ADMIN_USER is not set in .env"
    fi

    if [ -z "$PASSWORD_VALUE" ]; then
        die "PASSWORD is not set in .env"
    fi

    if [ -z "$NTFY_BACKREST_PASSWORD_VALUE" ]; then
        NTFY_BACKREST_PASSWORD_VALUE="$(generate_password)"
        log "Generated NTFY_BACKREST_PASSWORD for backrest ntfy user"
    fi

    if [ -z "$NTFY_BESZEL_PASSWORD_VALUE" ]; then
        NTFY_BESZEL_PASSWORD_VALUE="$(generate_password)"
        log "Generated NTFY_BESZEL_PASSWORD for beszel ntfy user"
    fi

    if [ -z "$NTFY_DOCKHAND_PASSWORD_VALUE" ]; then
        NTFY_DOCKHAND_PASSWORD_VALUE="$(generate_password)"
        log "Generated NTFY_DOCKHAND_PASSWORD for dockhand ntfy user"
    fi

    if [ -z "$NTFY_UPTIME_KUMA_PASSWORD_VALUE" ]; then
        NTFY_UPTIME_KUMA_PASSWORD_VALUE="$(generate_password)"
        log "Generated NTFY_UPTIME_KUMA_PASSWORD for uptime-kuma ntfy user"
    fi

    if [ -z "$NTFY_UPTIME_KUMA_TOKEN_VALUE" ]; then
        NTFY_UPTIME_KUMA_TOKEN_VALUE="$(generate_token)"
        log "Generated NTFY_UPTIME_KUMA_TOKEN for uptime-kuma ntfy user"
    fi

    if [ -z "$UPTIME_KUMA_ADMIN_PASSWORD_VALUE" ]; then
        UPTIME_KUMA_ADMIN_PASSWORD_VALUE="$(generate_password)"
        log "Generated UPTIME_KUMA_ADMIN_PASSWORD for uptime-kuma admin account"
    fi

    if [ -z "$NTFY_PROWLARR_PASSWORD_VALUE" ]; then
        NTFY_PROWLARR_PASSWORD_VALUE="$(generate_password)"
        log "Generated NTFY_PROWLARR_PASSWORD for prowlarr ntfy user"
    fi

    if [ -z "$NTFY_QBITTORRENT_PASSWORD_VALUE" ]; then
        NTFY_QBITTORRENT_PASSWORD_VALUE="$(generate_password)"
        log "Generated NTFY_QBITTORRENT_PASSWORD for qbittorrent ntfy user"
    fi

    if [ -z "$NTFY_QBITTORRENT_TOKEN_VALUE" ]; then
        NTFY_QBITTORRENT_TOKEN_VALUE="$(generate_token)"
        log "Generated NTFY_QBITTORRENT_TOKEN for qbittorrent ntfy user"
    fi

    if [ -z "$NTFY_AUTHELIA_PASSWORD_VALUE" ]; then
        NTFY_AUTHELIA_PASSWORD_VALUE="$(generate_password)"
        log "Generated NTFY_AUTHELIA_PASSWORD for authelia ntfy user"
    fi

    if [ -z "$NTFY_SHELFMARK_PASSWORD_VALUE" ]; then
        NTFY_SHELFMARK_PASSWORD_VALUE="$(generate_password)"
        log "Generated NTFY_SHELFMARK_PASSWORD for shelfmark ntfy user"
    fi

    # Shelfmark publishes through a token rather than the password above: the
    # credential travels inside an Apprise URL's userinfo field
    # (scripts/shelfmark-pre-start.sh), where generate_password's base64 would
    # need percent-encoding to survive.
    if [ -z "$NTFY_SHELFMARK_TOKEN_VALUE" ]; then
        NTFY_SHELFMARK_TOKEN_VALUE="$(generate_token)"
        log "Generated NTFY_SHELFMARK_TOKEN for shelfmark ntfy user"
    fi

    log "Resolving bcrypt hashes for ntfy predefined users"
    USER_HASH="$(hash_password_cached "$STORED_ADMIN_HASH" "$PASSWORD_VALUE")"
    BACKREST_HASH="$(hash_password_cached "$STORED_BACKREST_HASH" "$NTFY_BACKREST_PASSWORD_VALUE")"
    BESZEL_HASH="$(hash_password_cached "$STORED_BESZEL_HASH" "$NTFY_BESZEL_PASSWORD_VALUE")"
    DOCKHAND_HASH="$(hash_password_cached "$STORED_DOCKHAND_HASH" "$NTFY_DOCKHAND_PASSWORD_VALUE")"
    UPTIME_KUMA_HASH="$(hash_password_cached "$STORED_UPTIME_KUMA_HASH" "$NTFY_UPTIME_KUMA_PASSWORD_VALUE")"
    PROWLARR_HASH="$(hash_password_cached "$STORED_PROWLARR_HASH" "$NTFY_PROWLARR_PASSWORD_VALUE")"
    QBITTORRENT_HASH="$(hash_password_cached "$STORED_QBITTORRENT_HASH" "$NTFY_QBITTORRENT_PASSWORD_VALUE")"
    AUTHELIA_HASH="$(hash_password_cached "$STORED_AUTHELIA_HASH" "$NTFY_AUTHELIA_PASSWORD_VALUE")"
    SHELFMARK_HASH="$(hash_password_cached "$STORED_SHELFMARK_HASH" "$NTFY_SHELFMARK_PASSWORD_VALUE")"

    mkdir -p "$OUTPUT_DIR"

    AUTH_USERS_VALUE="${USER_VALUE}:${USER_HASH}:admin,backrest:${BACKREST_HASH}:user,beszel:${BESZEL_HASH}:user,dockhand:${DOCKHAND_HASH}:user,uptime-kuma:${UPTIME_KUMA_HASH}:user,prowlarr:${PROWLARR_HASH}:user,qbittorrent:${QBITTORRENT_HASH}:user,authelia:${AUTHELIA_HASH}:user,shelfmark:${SHELFMARK_HASH}:user"
    AUTH_ACCESS_VALUE="backrest:${NTFY_MONITORING_TOPIC}:rw,beszel:${NTFY_MONITORING_TOPIC}:rw,dockhand:${NTFY_MONITORING_TOPIC}:rw,uptime-kuma:${NTFY_MONITORING_TOPIC}:rw,prowlarr:${NTFY_DOWNLOADS_TOPIC}:rw,qbittorrent:${NTFY_DOWNLOADS_TOPIC}:rw,authelia:${NTFY_SECURITY_TOPIC}:rw,shelfmark:${NTFY_DOWNLOADS_TOPIC}:rw"
    AUTH_TOKENS_VALUE="uptime-kuma:${NTFY_UPTIME_KUMA_TOKEN_VALUE}:Uptime Kuma notification token,qbittorrent:${NTFY_QBITTORRENT_TOKEN_VALUE}:qBittorrent download notifications,shelfmark:${NTFY_SHELFMARK_TOKEN_VALUE}:Shelfmark download notifications"

    {
        printf '# Managed by scripts/ntfy-pre-start.sh\n'
        printf 'NTFY_BACKREST_PASSWORD=%s\n' "$(escape_compose_env_value "$NTFY_BACKREST_PASSWORD_VALUE")"
        printf 'NTFY_BESZEL_PASSWORD=%s\n' "$(escape_compose_env_value "$NTFY_BESZEL_PASSWORD_VALUE")"
        printf 'NTFY_DOCKHAND_PASSWORD=%s\n' "$(escape_compose_env_value "$NTFY_DOCKHAND_PASSWORD_VALUE")"
        printf 'NTFY_UPTIME_KUMA_PASSWORD=%s\n' "$(escape_compose_env_value "$NTFY_UPTIME_KUMA_PASSWORD_VALUE")"
        printf 'NTFY_UPTIME_KUMA_TOKEN=%s\n' "$(escape_compose_env_value "$NTFY_UPTIME_KUMA_TOKEN_VALUE")"
        printf 'NTFY_PROWLARR_PASSWORD=%s\n' "$(escape_compose_env_value "$NTFY_PROWLARR_PASSWORD_VALUE")"
        printf 'NTFY_QBITTORRENT_PASSWORD=%s\n' "$(escape_compose_env_value "$NTFY_QBITTORRENT_PASSWORD_VALUE")"
        printf 'NTFY_QBITTORRENT_TOKEN=%s\n' "$(escape_compose_env_value "$NTFY_QBITTORRENT_TOKEN_VALUE")"
        printf 'NTFY_AUTHELIA_PASSWORD=%s\n' "$(escape_compose_env_value "$NTFY_AUTHELIA_PASSWORD_VALUE")"
        printf 'NTFY_SHELFMARK_PASSWORD=%s\n' "$(escape_compose_env_value "$NTFY_SHELFMARK_PASSWORD_VALUE")"
        printf 'NTFY_SHELFMARK_TOKEN=%s\n' "$(escape_compose_env_value "$NTFY_SHELFMARK_TOKEN_VALUE")"
        printf 'NTFY_MONITORING_TOPIC=%s\n' "$(escape_compose_env_value "$NTFY_MONITORING_TOPIC")"
        printf 'NTFY_DOWNLOADS_TOPIC=%s\n' "$(escape_compose_env_value "$NTFY_DOWNLOADS_TOPIC")"
        printf 'NTFY_SECURITY_TOPIC=%s\n' "$(escape_compose_env_value "$NTFY_SECURITY_TOPIC")"
        printf 'NTFY_AUTHELIA_TOPIC=%s\n' "$(escape_compose_env_value "$NTFY_SECURITY_TOPIC")"
        printf 'NTFY_BESZEL_TOPIC=%s\n' "$(escape_compose_env_value "$NTFY_MONITORING_TOPIC")"
        printf 'NTFY_DOCKHAND_TOPIC=%s\n' "$(escape_compose_env_value "$NTFY_MONITORING_TOPIC")"
        # Read by scripts/backrest-post-hook.sh inside the backrest container,
        # which loads this file through the service's env_file.
        printf 'BACKREST_NTFY_TOPIC=%s\n' "$(escape_compose_env_value "$NTFY_MONITORING_TOPIC")"
        printf 'NTFY_ADMIN_HASH=%s\n' "$(escape_compose_env_value "$USER_HASH")"
        printf 'NTFY_BACKREST_HASH=%s\n' "$(escape_compose_env_value "$BACKREST_HASH")"
        printf 'NTFY_BESZEL_HASH=%s\n' "$(escape_compose_env_value "$BESZEL_HASH")"
        printf 'NTFY_DOCKHAND_HASH=%s\n' "$(escape_compose_env_value "$DOCKHAND_HASH")"
        printf 'NTFY_UPTIME_KUMA_HASH=%s\n' "$(escape_compose_env_value "$UPTIME_KUMA_HASH")"
        printf 'NTFY_PROWLARR_HASH=%s\n' "$(escape_compose_env_value "$PROWLARR_HASH")"
        printf 'NTFY_QBITTORRENT_HASH=%s\n' "$(escape_compose_env_value "$QBITTORRENT_HASH")"
        printf 'NTFY_AUTHELIA_HASH=%s\n' "$(escape_compose_env_value "$AUTHELIA_HASH")"
        printf 'NTFY_SHELFMARK_HASH=%s\n' "$(escape_compose_env_value "$SHELFMARK_HASH")"
        printf 'NTFY_AUTH_USERS=%s\n' "$(escape_compose_env_value "$AUTH_USERS_VALUE")"
        printf 'NTFY_AUTH_ACCESS=%s\n' "$(escape_compose_env_value "$AUTH_ACCESS_VALUE")"
        printf 'NTFY_AUTH_TOKENS=%s\n' "$(escape_compose_env_value "$AUTH_TOKENS_VALUE")"
        printf 'UPTIME_KUMA_ADMIN_PASSWORD=%s\n' "$(escape_compose_env_value "$UPTIME_KUMA_ADMIN_PASSWORD_VALUE")"
    } | write_secret_file "$OUTPUT_FILE" || die "could not write $OUTPUT_FILE"
    # write_secret_file replaces the inode, so a root-run start would otherwise
    # leave a file the login user cannot read (shelfmark-pre-start reads the
    # shelfmark token out of it).
    fix_ownership "$OUTPUT_FILE"

    log "Rendered ntfy env to $OUTPUT_FILE"
}

main "$@"
