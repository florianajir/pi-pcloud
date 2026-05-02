#!/bin/bash
# Auto-initialization script for Headscale + Tailscale + Headplane
# Runs automatically on first start, creates user and performs one-time Tailscale bootstrap with a short-lived preauthkey, then initializes Headplane config with a long-lived reusable preauthkey.

set -euo pipefail

. "$(dirname "$0")/lib.sh"

MAX_RETRIES=60
RETRY_INTERVAL=2
HEADSCALE_BIN="/ko-app/headscale"
HEADPLANE_OIDC_KEY_UPDATED=0

check_headscale_ready() {
    docker exec pi-headscale "$HEADSCALE_BIN" users list >/dev/null 2>&1
}

wait_for_headscale() {
    log "Waiting for Headscale to be ready..."
    for i in $(seq 1 $MAX_RETRIES); do
        if check_headscale_ready; then
            log "Headscale is ready"
            return 0
        fi
        sleep $RETRY_INTERVAL
    done
    log "ERROR: Headscale did not become ready in time"
    return 1
}

user_exists() {
    docker exec pi-headscale "$HEADSCALE_BIN" users list --output json 2>/dev/null | \
        grep -q "\"name\": \"${HEADSCALE_USER}\""
}

get_user_id() {
    docker exec pi-headscale "$HEADSCALE_BIN" users list --output json 2>/dev/null | \
        grep "\"name\": \"${HEADSCALE_USER}\"" -B 1 | grep '"id"' | sed 's/[^0-9]*\([0-9]\+\).*/\1/' | head -1
}

create_user() {
    if user_exists; then
        log "User '${HEADSCALE_USER}' already exists"
    else
        log "Creating user '${HEADSCALE_USER}'..."
        docker exec pi-headscale "$HEADSCALE_BIN" users create "$HEADSCALE_USER"
        log "User created"
    fi
}

create_preauthkey() {
    local user_id="$1"
    log "Creating one-time preauthkey (expires in 30m) with tag:router..."
    docker exec pi-headscale "$HEADSCALE_BIN" preauthkeys create --user "$user_id" --expiration 30m --tags tag:router --output json 2>/dev/null | \
        grep -o '"key": *"[^"]*"' | sed 's/"key": *"\([^"]*\)"/\1/'
}

create_headscale_api_key() {
    raw_output=$(docker exec pi-headscale "$HEADSCALE_BIN" apikeys create --expiration 8760h --output json 2>/dev/null | tr -d '\r\n')
    api_key=$(printf '%s' "$raw_output" | sed -n -E 's/^"([^"]+)"$/\1/p')
    if [ -z "$api_key" ]; then
        api_key=$(printf '%s' "$raw_output" | grep -oE '"(api_key|apiKey|key)"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/^"[^"]+"[[:space:]]*:[[:space:]]*"([^"]+)"$/\1/')
    fi
    printf '%s' "$api_key"
}

ensure_headplane_oidc_api_key() {
    local key_file="$PROJECT_DIR/config/headplane/headscale_api_key"
    local current_key=""
    local new_key=""

    mkdir -p "$(dirname "$key_file")"

    if [ -f "$key_file" ]; then
        current_key=$(tr -d '\r\n' < "$key_file")
    fi

    if [ -n "$current_key" ] && [ "$current_key" != "pending-headscale-api-key" ]; then
        log "Headplane OIDC Headscale API key already exists"
        return 0
    fi

    log "Creating Headscale API key for Headplane OIDC (expires in 1 year)..."
    new_key=$(create_headscale_api_key)

    if [ -z "$new_key" ]; then
        log "ERROR: Failed to create Headscale API key for Headplane OIDC"
        return 1
    fi

    printf '%s\n' "$new_key" > "$key_file"
    chmod 600 "$key_file" 2>/dev/null || true
    HEADPLANE_OIDC_KEY_UPDATED=1
    log "Stored Headplane OIDC Headscale API key at $key_file"
}

init_headplane_config() {
    local user_id="$1"
    local config_dir="$PROJECT_DIR/config/headplane"
    local template="$config_dir/config.yaml.template"
    local config="$config_dir/config.yaml"

    if [ -f "$config" ] && [ -s "$config" ]; then
        log "Headplane config already exists, skipping"
        return 0
    fi

    log "Initializing Headplane config from template..."
    COOKIE_SECRET=$(openssl rand -hex 16)
    HEADSCALE_URL="https://headscale.${HOST_NAME}"

    log "Creating preauthkey for Headplane agent (reusable, expires in 1 year)..."
    HEADPLANE_AUTHKEY=$(docker exec pi-headscale "$HEADSCALE_BIN" preauthkeys create \
        --user "$user_id" \
        --reusable \
        --expiration 8760h \
        --output json 2>/dev/null | \
        grep -o '"key": *"[^"]*"' | sed 's/"key": *"\([^"]*\)"/\1/')

    if [ -z "$HEADPLANE_AUTHKEY" ]; then
        log "ERROR: Failed to create Headplane agent preauthkey"
        return 1
    fi

    sed \
        -e "s|__COOKIE_SECRET__|${COOKIE_SECRET}|g" \
        -e "s|__HEADSCALE_URL__|${HEADSCALE_URL}|g" \
        -e "s|__HEADPLANE_AGENT__PRE_AUTHKEY__|${HEADPLANE_AUTHKEY}|g" \
        "$template" > "$config"

    log "Headplane config written to $config"
    log "Restarting Headplane container to apply new config..."
    docker restart pi-headplane
    log "Headplane restarted"
}

connect_tailscale_if_needed() {
    local user_id="$1"
    local key=""

    if docker exec pi-tailscale tailscale status --peers=false >/dev/null 2>&1; then
        log "Tailscale already connected"
        return 0
    fi

    key=$(create_preauthkey "$user_id")
    if [ -z "$key" ]; then
        log "ERROR: Failed to create one-time preauthkey"
        return 1
    fi

    log "Bootstrapping Tailscale with one-time auth key..."
    docker exec pi-tailscale tailscale up \
        --login-server="https://headscale.${HOST_NAME}" \
        --auth-key="$key" \
        --accept-dns=true \
        --advertise-exit-node \
        --advertise-routes=192.168.1.0/24 \
        --accept-routes \
        --hostname="tailscale"

    if docker exec pi-tailscale tailscale status --peers=false >/dev/null 2>&1; then
        log "Tailscale bootstrap successful"
        return 0
    fi

    log "ERROR: Tailscale bootstrap failed"
    return 1
}

main() {
    log "=== Headscale Auto-Init ==="

    HOST_NAME="$(get_env_value HOST_NAME)"
    EMAIL="$(get_env_value EMAIL)"
    HOST_NAME="${HOST_NAME:-pi.lan}"
    HEADSCALE_USER="${EMAIL}"
    if [ -z "$HEADSCALE_USER" ]; then
        die "HEADSCALE_USER (EMAIL) is not set."
    fi

    if ! wait_for_container "pi-headscale" "$MAX_RETRIES" "$RETRY_INTERVAL"; then
        die "Headscale container did not become ready"
    fi

    if ! wait_for_headscale; then
        die "Failed to connect to Headscale"
    fi

    create_user

    USER_ID=$(get_user_id)
    if [ -z "$USER_ID" ]; then
        die "Failed to get user ID"
    fi
    log "Using user ID: $USER_ID"

    if ! ensure_headplane_oidc_api_key; then
        log "WARNING: Headplane OIDC key initialization failed; API-token login may still be required"
    fi

    init_headplane_config "$USER_ID"

    if [ "$HEADPLANE_OIDC_KEY_UPDATED" -eq 1 ]; then
        log "Restarting Headplane container to apply OIDC Headscale API key..."
        docker restart pi-headplane >/dev/null 2>&1 || true
        log "Headplane restarted"
    fi

    if ! wait_for_container "pi-tailscale" "$MAX_RETRIES" "$RETRY_INTERVAL"; then
        die "Tailscale container did not become ready"
    fi

    connect_tailscale_if_needed "$USER_ID"
}

main "$@"
