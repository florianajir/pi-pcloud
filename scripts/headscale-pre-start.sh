#!/bin/sh
# Render Headscale policy from template using EMAIL

set -e

. "$(dirname "$0")/lib.sh"

POLICY_TEMPLATE_FILE="$PROJECT_DIR/config/headscale/policy.hujson.template"
POLICY_FILE="$PROJECT_DIR/config/headscale/policy.hujson"
CONFIG_TEMPLATE_FILE="$PROJECT_DIR/config/headscale/config.yaml.template"
CONFIG_FILE="$PROJECT_DIR/config/headscale/config.yaml"

main() {
    # Ensure headplane config.yaml exists as a file before docker compose up.
    # If the file is missing, Docker would create a directory at the bind-mount path
    # causing headplane to crash with EISDIR on startup.
    HEADPLANE_CONFIG="$PROJECT_DIR/config/headplane/config.yaml"
    HEADPLANE_API_KEY_FILE="$PROJECT_DIR/config/headplane/headscale_api_key"
    mkdir -p "$(dirname "$HEADPLANE_CONFIG")"
    if [ -d "$HEADPLANE_CONFIG" ]; then
        log "WARNING: headplane config.yaml is a directory (Docker bind-mount artifact). Removing..."
        rm -rf "$HEADPLANE_CONFIG"
    fi
    if [ ! -e "$HEADPLANE_CONFIG" ]; then
        touch "$HEADPLANE_CONFIG"
        log "Created placeholder $HEADPLANE_CONFIG (will be populated by headscale-init.sh)"
    fi

    # Ensure the Headscale API key file bind-mounted by Headplane is a file.
    if [ -d "$HEADPLANE_API_KEY_FILE" ]; then
        log "WARNING: headplane headscale_api_key is a directory (Docker bind-mount artifact). Removing..."
        rm -rf "$HEADPLANE_API_KEY_FILE"
    fi
    if [ ! -e "$HEADPLANE_API_KEY_FILE" ]; then
        printf 'pending-headscale-api-key\n' > "$HEADPLANE_API_KEY_FILE"
        chmod 600 "$HEADPLANE_API_KEY_FILE" 2>/dev/null || true
        log "Created placeholder $HEADPLANE_API_KEY_FILE (will be populated by headscale-init.sh)"
    fi

    if [ ! -f "$POLICY_TEMPLATE_FILE" ]; then
        die "policy template not found at $POLICY_TEMPLATE_FILE"
    fi

    if [ ! -f "$CONFIG_TEMPLATE_FILE" ]; then
        die "config template not found at $CONFIG_TEMPLATE_FILE"
    fi

    EMAIL="$(get_env_value EMAIL)"
    HOST_NAME="$(get_env_value HOST_NAME)"
    DATA_LOCATION="$(get_env_value DATA_LOCATION)"
    HOST_LAN_SUBNET="$(get_env_value HOST_LAN_SUBNET)"

    if [ -z "$EMAIL" ]; then
        die "EMAIL is not set in .env"
    fi

    HOST_NAME="${HOST_NAME:-pi.lan}"
    DATA_LOCATION="${DATA_LOCATION:-./data}"
    HOST_LAN_SUBNET="${HOST_LAN_SUBNET:-192.168.1.0/24}"
    case "$DATA_LOCATION" in
        /*) : ;;
        *)  DATA_LOCATION="$PROJECT_DIR/$DATA_LOCATION" ;;
    esac

    # Read OIDC client secret for Headscale node registration
    OIDC_SECRET_FILE="$DATA_LOCATION/authelia-config/secrets/oidc_headscale_secret.txt"
    OIDC_HEADSCALE_SECRET=""
    if [ -f "$OIDC_SECRET_FILE" ]; then
        OIDC_HEADSCALE_SECRET=$(cat "$OIDC_SECRET_FILE")
    else
        log "WARNING: OIDC secret not found at $OIDC_SECRET_FILE (run authelia-pre-start.sh first)"
    fi

    UPDATED_POLICY=$(sed \
        -e "s|__HEADSCALE_USER__|$EMAIL|g" \
        -e "s|__HOST_LAN_SUBNET__|$HOST_LAN_SUBNET|g" \
        "$POLICY_TEMPLATE_FILE")

    if [ -f "$POLICY_FILE" ] && [ "$UPDATED_POLICY" = "$(cat "$POLICY_FILE")" ]; then
        log "Policy already up to date"
    else
        printf '%s\n' "$UPDATED_POLICY" > "$POLICY_FILE"
        log "Rendered policy to $POLICY_FILE"
    fi

    UPDATED_CONFIG=$(sed \
        -e "s|__HOST_NAME__|$HOST_NAME|g" \
        -e "s|__OIDC_HEADSCALE_SECRET__|$OIDC_HEADSCALE_SECRET|g" \
        "$CONFIG_TEMPLATE_FILE")

    if [ -f "$CONFIG_FILE" ] && [ "$UPDATED_CONFIG" = "$(cat "$CONFIG_FILE")" ]; then
        log "Config already up to date"
        exit 0
    fi

    printf '%s\n' "$UPDATED_CONFIG" > "$CONFIG_FILE"
    log "Rendered config to $CONFIG_FILE"
}

main "$@"
