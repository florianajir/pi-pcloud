#!/bin/sh
# Bootstrap Homepage service widgets: extracts/creates the API keys that
# gethomepage.dev's built-in widgets need, and writes them as single-line
# secret files under config/homepage/secrets/. Every widget secret lives there,
# including the one nobody can mint (Immich), so there is a single place to look
# and no env_file for Homepage at all. That directory is already
# visible inside the homepage container at /app/config/secrets (it's a
# subpath of the existing ./config/homepage:/app/config mount), and is
# referenced from compose/monitoring.yaml via HOMEPAGE_FILE_* env vars, which Homepage
# substitutes as {{HOMEPAGE_FILE_x}} in widget labels.
#
# Runs last in the post-start chain (after Prowlarr/Headscale are already
# bootstrapped by their own scripts). Idempotent: only (re)writes a secret
# file if the value changed, and only restarts homepage if something did.

set -eu

. "$(dirname "$0")/lib.sh"

SECRETS_DIR="$PROJECT_DIR/config/homepage/secrets"
CHANGED=0

# Write $2 to file $1 if different from its current content. Sets CHANGED=1 on write.
write_secret() {
    file="$1"
    value="$2"
    current=""

    [ -n "$value" ] || return 1

    if [ -f "$file" ]; then
        current="$(tr -d '\r\n' < "$file")"
    fi

    if [ "$current" = "$value" ]; then
        return 0
    fi

    printf '%s' "$value" > "$file"
    safe_chmod 600 "$file"
    CHANGED=1
}

# --- Prowlarr: read the API key already generated in its config.xml ---
sync_prowlarr_key() {
    if ! container_is_running "pi-prowlarr"; then
        log "WARNING: pi-prowlarr not running; skipping Prowlarr widget key"
        return 0
    fi

    key=$(docker exec pi-prowlarr sh -c "grep -oE '<ApiKey>[^<]+</ApiKey>' /config/config.xml" 2>/dev/null \
        | sed -e 's|<ApiKey>||' -e 's|</ApiKey>||' | tr -d '\r\n')

    if [ -z "$key" ]; then
        log "WARNING: Could not read Prowlarr API key from config.xml"
        return 1
    fi

    write_secret "$SECRETS_DIR/prowlarr_api_key" "$key"
    log "Prowlarr API key ready for Homepage widget"
}

# --- Headscale: dedicated API key (can't be re-read once created, so only
# make one the first time) + the tailscale client's node ID (can change if
# the node re-registers, so refresh it every run). ---
sync_headscale() {
    if ! container_is_running "pi-headscale"; then
        log "WARNING: pi-headscale not running; skipping Headscale widget key"
        return 0
    fi

    key_file="$SECRETS_DIR/headscale_api_key"
    key=""
    [ -f "$key_file" ] && key="$(tr -d '\r\n' < "$key_file")"

    if [ -z "$key" ]; then
        log "Creating dedicated Headscale API key for the Homepage widget (expires in 1 year)..."
        key="$(create_headscale_api_key)"
        if [ -z "$key" ]; then
            log "WARNING: Failed to create Headscale API key for Homepage widget"
        else
            write_secret "$key_file" "$key"
            log "Headscale API key ready for Homepage widget"
        fi
    fi

    node_id=$(docker exec pi-headscale headscale nodes list --output json 2>/dev/null \
        | jq -r '.[] | select(.name=="tailscale") | .id' | head -1)
    if [ -n "$node_id" ]; then
        write_secret "$SECRETS_DIR/headscale_node_id" "$node_id"
        log "Headscale node ID ($node_id) ready for Homepage widget"
    else
        log "WARNING: Could not find Headscale node 'tailscale' to read its node ID"
    fi
}

# --- Kavita: the widget authenticates with an API key, not a login ---
# Kavita's OIDC config sets DisablePasswordAuthentication, so /api/Account/login
# refuses every password; only apiKey logins are exempt. Homepage sends widget.key
# as apiKey when no username/password is configured.
sync_kavita_key() {
    if ! container_is_running "pi-kavita"; then
        log "WARNING: pi-kavita not running; skipping Kavita widget key"
        return 0
    fi

    key="$(kavita_admin_api_key)"

    if [ -z "$key" ]; then
        # Expected before anyone has registered the first Kavita admin.
        log "WARNING: no Kavita admin API key found yet; skipping Kavita widget key"
        return 0
    fi

    write_secret "$SECRETS_DIR/kavita_api_key" "$key"
    log "Kavita API key ready for Homepage widget"
}

# --- Audiobookshelf: mint a dedicated API key ---
# Audiobookshelf returns a new key's value once, at creation, and stores only the
# record afterwards - so the secret file is the only copy and the key on the
# server is the only way to tell whether that copy is still valid. Both have to
# agree: a key with no file cannot be recovered, and a file with no key is dead.
ABS_KEY_NAME="homepage"

sync_audiobookshelf_key() {
    abs_url="http://pi-audiobookshelf"
    file="$SECRETS_DIR/audiobookshelf_api_key"

    if ! container_is_running "pi-audiobookshelf"; then
        log "WARNING: pi-audiobookshelf not running; skipping Audiobookshelf widget key"
        return 0
    fi

    # Almost always the API key scripts/audiobookshelf-bootstrap.sh stored, since
    # that hook runs earlier in the chain and switches local logins off - the
    # password fallback only covers the one run where it has not got there yet.
    token="$(audiobookshelf_token "$abs_url" || true)"
    if [ -z "$token" ]; then
        # Expected until scripts/audiobookshelf-bootstrap.sh has created the root account.
        log "WARNING: could not authenticate to Audiobookshelf; skipping its widget key"
        return 0
    fi

    keys="$(docker_curl -H "Authorization: Bearer $token" "$abs_url/api/api-keys" 2>/dev/null)" || {
        log "WARNING: could not list Audiobookshelf API keys; skipping"
        return 0
    }
    existing_id="$(printf '%s' "$keys" | jq -r --arg n "$ABS_KEY_NAME" \
        'first(.apiKeys[]? | select(.name == $n) | .id) // empty')"

    if [ -n "$existing_id" ] && [ -s "$file" ]; then
        log "Audiobookshelf API key already present for the Homepage widget"
        return 0
    fi

    # Either half is missing, so the pair is unusable: drop the orphan record and
    # mint a matching one. Deleting is what makes this safe to repeat - without
    # it every run would add another "homepage" key nobody holds.
    if [ -n "$existing_id" ]; then
        docker_curl -X DELETE -H "Authorization: Bearer $token" \
            "$abs_url/api/api-keys/$existing_id" >/dev/null 2>&1 \
            || log "WARNING: could not remove the stale Audiobookshelf API key"
    fi

    user_id="$(docker_curl -H "Authorization: Bearer $token" "$abs_url/api/me" 2>/dev/null \
        | jq -r '.id // empty')"
    [ -n "$user_id" ] || { log "WARNING: could not read the Audiobookshelf user id; skipping"; return 0; }

    # isActive must be sent explicitly: the API stores !!req.body.isActive, so an
    # omitted field creates a key that authenticates nothing.
    key="$(jq -cn --arg n "$ABS_KEY_NAME" --arg u "$user_id" \
            '{name: $n, userId: $u, isActive: true}' \
        | docker_curl_stdin -X POST -H "Authorization: Bearer $token" \
            -H 'Content-Type: application/json' "$abs_url/api/api-keys" 2>/dev/null \
        | jq -r '.apiKey.apiKey // empty')"

    if [ -z "$key" ]; then
        log "WARNING: could not create an Audiobookshelf API key"
        return 0
    fi

    write_secret "$file" "$key"
    log "Audiobookshelf API key ready for Homepage widget"
}

# --- Backrest: mirror the API password generated by backrest-pre-start.sh ---
# Not read from .env: the Backrest API is the one credential that is worth the
# backups themselves, so it is per-service rather than ${PASSWORD}. Homepage is the
# only other holder, and the widget needs the plaintext.
sync_backrest_password() {
    src="$PROJECT_DIR/config/backrest/backrest.env"

    if [ ! -f "$src" ]; then
        log "WARNING: $src not found; skipping Backrest widget password"
        return 0
    fi

    password="$(read_env_value_from_file "$src" BACKREST_AUTH_PASSWORD)"

    if [ -z "$password" ]; then
        log "WARNING: BACKREST_AUTH_PASSWORD is empty in $src"
        return 1
    fi

    write_secret "$SECRETS_DIR/backrest_password" "$password"
    log "Backrest API password ready for Homepage widget"
}

# --- Immich: the only key that cannot be minted ---
# Its admin password is chosen at signup and is not in .env, and api_key.key is
# stored hashed, so neither the API nor the database can hand one back. All this can
# do is guarantee the file exists, so HOMEPAGE_FILE_IMMICH_API_KEY always resolves;
# paste the key in (Immich > Account Settings > API Keys, "server.statistics").
# Never overwrites: a filled-in key must survive every run.
ensure_immich_key_placeholder() {
    file="$SECRETS_DIR/immich_api_key"

    [ -e "$file" ] && return 0

    : > "$file"
    safe_chmod 600 "$file"
    log "Created empty $file - paste an Immich API key there to enable its widget"
}

main() {
    log "=== Homepage Widgets Bootstrap ==="
    mkdir -p "$SECRETS_DIR"

    wait_for_container "pi-homepage" 60 2 || log "WARNING: pi-homepage did not appear in time"

    sync_prowlarr_key || true
    sync_headscale || true
    sync_kavita_key || true
    sync_audiobookshelf_key || true
    sync_backrest_password || true
    ensure_immich_key_placeholder || true

    fix_ownership "$SECRETS_DIR"

    if [ "$CHANGED" -eq 1 ] && container_is_running "pi-homepage"; then
        log "Secret(s) changed; restarting Homepage to pick them up..."
        docker restart pi-homepage >/dev/null 2>&1 || log "WARNING: Failed to restart Homepage"
    fi

    log "Homepage widgets bootstrap completed"
}

main "$@"
