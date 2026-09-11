#!/bin/sh
# Generate Authelia secrets and render configuration from template.
# Idempotent: existing secrets and configuration are preserved.

set -eu

. "$(dirname "$0")/lib.sh"

CONFIG_TEMPLATE="$PROJECT_DIR/config/authelia/configuration.yml.template"
IMMICH_OAUTH_TEMPLATE="$PROJECT_DIR/config/immich/oauth-config.yaml.template"
IMMICH_CONFIG="$PROJECT_DIR/config/immich/config.yaml"

# Generate a plaintext secret file and its PBKDF2 hash companion.
# Usage: generate_oidc_secret <name>  (e.g. "oidc_nextcloud_secret")
# Creates: <name>.txt  (plaintext, for OIDC clients)
#          <name>_hash (PBKDF2, for Authelia config)
generate_oidc_secret() {
    local name="$1"
    local txt_file="$SECRETS_DIR/${name}.txt"
    local hash_file="$SECRETS_DIR/${name}_hash"

    # -s, not -f, like vaultwarden-pre-start.sh: write_file_atomic stops NEW
    # empty files, but a zero-byte leftover from an older install must be
    # regenerated, not accepted forever.
    if [ ! -s "$txt_file" ]; then
        write_file_atomic "$txt_file" generate_secret \
            || die "Failed to generate $name"
        safe_chmod 600 "$txt_file"
        log "Generated $name"
    fi

    if [ ! -s "$hash_file" ]; then
        local plaintext
        plaintext="$(cat "$txt_file")"
        # Through write_file_atomic: a plain redirect creates the hash file
        # before hash_pbkdf2 runs, so a host without python3 leaves an empty
        # one that the `[ ! -f ]` guard above then accepts forever — and
        # Authelia rejects every OIDC login for the client with no error.
        write_file_atomic "$hash_file" hash_pbkdf2 "$plaintext" \
            || die "Failed to hash $name (is python3 installed?)"
        safe_chmod 600 "$hash_file"
        log "Generated ${name}_hash"
    fi
}

# The two secrets that are not generated but copied from PASSWORD.
# Usage: write_password_secret <name>
#
# Through write_file_atomic like everything else here: `printf > file` truncates
# before it writes, so an interruption leaves a zero-byte secret in a directory
# Authelia mounts read-only and reads at start. The `-s` guard would regenerate
# it on the next run, but the window in between is a start where Authelia cannot
# bind to lldap or reach Postgres, with an empty file as the only evidence.
write_password_secret() {
    local name="$1"
    local file="$SECRETS_DIR/$name"

    [ ! -s "$file" ] || return 0
    write_file_atomic "$file" printf '%s' "$PASSWORD" \
        || die "Failed to write $name"
    safe_chmod 600 "$file"
    log "Written $name"
}

# openssl writes progress to stderr; only the key on stdout matters here.
openssl_genrsa_2048() {
    openssl genrsa 2048 2>/dev/null
}

generate_rsa_key() {
    local keyfile="$1"
    if ! command -v openssl >/dev/null 2>&1; then
        die "openssl is required to generate the OIDC RSA private key. Please install openssl."
    fi
    # `genrsa -out` writes in place, leaving a truncated key behind if openssl
    # dies mid-write; that key is then never regenerated.
    write_file_atomic "$keyfile" openssl_genrsa_2048 \
        || die "openssl genrsa failed; no OIDC private key written to $keyfile"
    log "Generated RSA private key at $keyfile"
}

main() {
    HOST_NAME="${HOST_NAME:-$(get_env_value HOST_NAME)}"
    DATA_LOCATION="${DATA_LOCATION:-$(get_env_value DATA_LOCATION)}"
    PASSWORD="${PASSWORD:-$(get_env_value PASSWORD)}"

    HOST_NAME="${HOST_NAME:-pi.lan}"
    DATA_LOCATION="${DATA_LOCATION:-./data}"
    case "$DATA_LOCATION" in
        /*) : ;;
        *)  DATA_LOCATION="$PROJECT_DIR/$DATA_LOCATION" ;;
    esac

    if [ -z "$PASSWORD" ]; then
        die "PASSWORD is not set in .env"
    fi

    AUTHELIA_DATA_DIR="$DATA_LOCATION/authelia-config"
    CONFIG_FILE="$AUTHELIA_DATA_DIR/configuration.yml"
    SECRETS_DIR="$DATA_LOCATION/authelia-config/secrets"
    mkdir -p "$AUTHELIA_DATA_DIR"
    mkdir -p "$SECRETS_DIR"
    safe_chmod 700 "$SECRETS_DIR"

    for secret in jwt_secret session_secret storage_encryption_key oidc_hmac_secret; do
        if [ ! -s "$SECRETS_DIR/$secret" ]; then
            write_file_atomic "$SECRETS_DIR/$secret" generate_secret \
                || die "Failed to generate $secret"
            safe_chmod 600 "$SECRETS_DIR/$secret"
            log "Generated $secret"
        fi
    done

    # Authelia binds to lldap as its admin, whose password is PASSWORD.
    write_password_secret ldap_password

    # The credential Authelia actually reads; AUTHELIA_DB_PASSWORD in compose.yaml
    # is not.
    write_password_secret db_password

    if [ ! -s "$SECRETS_DIR/oidc_private_key.pem" ]; then
        generate_rsa_key "$SECRETS_DIR/oidc_private_key.pem"
        safe_chmod 600 "$SECRETS_DIR/oidc_private_key.pem"
    fi

    # Add a client here when declaring one in configuration.yml.template.
    for client in nextcloud immich beszel dockhand headplane headscale open-webui kavita vaultwarden shelfmark audiobookshelf agentgateway freshrss homepage trilium; do
        generate_oidc_secret "oidc_${client}_secret"
    done

    # Overridable for CI and helper containers, which mount the project read-only.
    LLDAP_CONFIG_DIR="${LLDAP_CONFIG_DIR:-$PROJECT_DIR/config/lldap}"
    mkdir -p "$LLDAP_CONFIG_DIR"
    LLDAP_ENV_FILE="$LLDAP_CONFIG_DIR/lldap.env"

    # Same reasoning as write_password_secret, and it matters more here: compose
    # reads this as an env_file at container-create time, so a truncated one is a
    # lldap that starts with no JWT secret at all.
    if [ ! -s "$LLDAP_ENV_FILE" ]; then
        LLDAP_JWT_SECRET=$(generate_secret)
        write_file_atomic "$LLDAP_ENV_FILE" \
            printf 'LLDAP_JWT_SECRET=%s\n' "$LLDAP_JWT_SECRET" \
            || die "Failed to write $LLDAP_ENV_FILE"
        safe_chmod 600 "$LLDAP_ENV_FILE"
        log "Generated lldap JWT secret at $LLDAP_ENV_FILE"
    fi

    # Silences lldap's key_seed/key_file warning on every start.
    LLDAP_DATA_DIR="$DATA_LOCATION/lldap"
    LLDAP_CONFIG="$LLDAP_DATA_DIR/lldap_config.toml"
    if [ -f "$LLDAP_CONFIG" ] && ! grep -q '^key_file' "$LLDAP_CONFIG"; then
        sed -i '/^key_seed/i key_file = ""' "$LLDAP_CONFIG"
        log "Added key_file override to lldap_config.toml"
    fi

    if [ ! -f "$CONFIG_TEMPLATE" ]; then
        die "Authelia config template not found at $CONFIG_TEMPLATE"
    fi

    ensure_config_target_is_file "$CONFIG_FILE"

    TMP_RENDERED="$(mktemp)"
    TMP_KEY_INDENTED="$(mktemp)"
    trap 'rm -f "$TMP_RENDERED" "$TMP_KEY_INDENTED"' EXIT INT TERM

    sed -e "s|__HOST_NAME__|$(sed_escape "$HOST_NAME")|g" "$CONFIG_TEMPLATE" > "$TMP_RENDERED"
    sed 's/^/          /' "$SECRETS_DIR/oidc_private_key.pem" > "$TMP_KEY_INDENTED"

    RENDERED=$(awk -v key_file="$TMP_KEY_INDENTED" '
        $0 == "__OIDC_PRIVATE_KEY__" {
            while ((getline line < key_file) > 0) print line
            close(key_file)
            next
        }
        { print }
    ' "$TMP_RENDERED")

    rm -f "$TMP_RENDERED" "$TMP_KEY_INDENTED"
    trap - EXIT INT TERM

    if [ -f "$CONFIG_FILE" ] && [ "$RENDERED" = "$(cat "$CONFIG_FILE")" ]; then
        log "configuration.yml already up to date"
    else
        # Atomic, so a half-written config can never be what Authelia parses on
        # the start that follows. Swapping the inode under the single-file bind
        # mount is fine: Authelia only reads this at start, and Docker re-resolves
        # the host path every time the container starts.
        write_file_atomic "$CONFIG_FILE" printf '%s\n' "$RENDERED" \
            || die "Failed to render configuration.yml to $CONFIG_FILE"
        log "Rendered configuration.yml to $CONFIG_FILE"
        # Authelia reads this file once, at startup, and `compose up -d` only
        # recreates a container whose *definition* changed - which a new OIDC
        # client or access rule is not. Without this an update renders the new
        # config and every client added by it fails to authenticate until
        # someone restarts Authelia by hand.
        if container_is_running "pi-authelia"; then
            log "Restarting Authelia to load the new configuration"
            compose restart authelia >/dev/null || log "WARNING: could not restart Authelia"
        fi
    fi

    if [ ! -f "$IMMICH_OAUTH_TEMPLATE" ]; then
        die "Immich OAuth config template not found at $IMMICH_OAUTH_TEMPLATE"
    fi
    if [ ! -f "$IMMICH_CONFIG" ]; then
        die "Immich config not found at $IMMICH_CONFIG"
    fi

    IMMICH_OAUTH_CONFIG_FILE="$AUTHELIA_DATA_DIR/immich-oauth-config.yaml"
    IMMICH_OAUTH_SECRET="$(cat "$SECRETS_DIR/oidc_immich_secret.txt")"
    # Both values go through sed_escape, like the configuration.yml render
    # above: an unescaped '&' in HOST_NAME is replaced by the whole match (so
    # every rendered URL silently points at a nonexistent issuer), and a '\' or
    # '|' corrupts or terminates the expression.
    IMMICH_OAUTH_RENDERED=$(
        sed \
            -e "s|__HOST_NAME__|$(sed_escape "$HOST_NAME")|g" \
            -e "s|__OIDC_IMMICH_SECRET__|$(sed_escape "$IMMICH_OAUTH_SECRET")|g" \
            "$IMMICH_OAUTH_TEMPLATE"
        printf '\n'
        cat "$IMMICH_CONFIG"
    )

    if [ -f "$IMMICH_OAUTH_CONFIG_FILE" ] && [ "$IMMICH_OAUTH_RENDERED" = "$(cat "$IMMICH_OAUTH_CONFIG_FILE")" ]; then
        log "immich-oauth-config.yaml already up to date"
    else
        write_file_atomic "$IMMICH_OAUTH_CONFIG_FILE" \
            printf '%s\n' "$IMMICH_OAUTH_RENDERED" \
            || die "Failed to render immich-oauth-config.yaml to $IMMICH_OAUTH_CONFIG_FILE"
        safe_chmod 600 "$IMMICH_OAUTH_CONFIG_FILE"
        log "Rendered immich-oauth-config.yaml to $IMMICH_OAUTH_CONFIG_FILE"

        # Immich reads IMMICH_CONFIG_FILE at boot and caches it, and a bind
        # mount whose content changed is no reason for compose to recreate the
        # container, so without this the new values sit on disk unread. Only
        # reached when the render differed; a fresh install skips it and reads
        # the file when it starts.
        if container_is_running "${IMMICH_CONTAINER:-pi-immich}"; then
            log "Restarting Immich so it re-reads the rendered OAuth config"
            docker restart "${IMMICH_CONTAINER:-pi-immich}" >/dev/null 2>&1 \
                || log "WARNING: could not restart Immich; it keeps the previously loaded OAuth config"
        fi
    fi

    fix_ownership "$SECRETS_DIR"
    fix_ownership "$AUTHELIA_DATA_DIR"
    fix_ownership "$LLDAP_DATA_DIR"

    log "Authelia pre-start complete"
}

main "$@"
