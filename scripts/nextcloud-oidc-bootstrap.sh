#!/bin/sh
# Configure Nextcloud OIDC provider for Authelia integration.
# A post-start hook (scripts/stack-up.sh), so it runs after docker compose up.
# Safe to run multiple times (idempotent).

set -eu

. "$(dirname "$0")/lib.sh"

MAX_RETRIES=60
RETRY_INTERVAL=5
NEXTCLOUD_CONTAINER="${NEXTCLOUD_CONTAINER:-pi-nextcloud}"
OIDC_PROVIDER_ID="${OIDC_PROVIDER_ID:-authelia}"
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-nextcloud}"

wait_for_occ() {
    log "Waiting for Nextcloud OCC to be ready..."
    if wait_for_cmd "$MAX_RETRIES" "$RETRY_INTERVAL" docker exec "$NEXTCLOUD_CONTAINER" php occ status; then
        log "Nextcloud OCC is ready"
        return 0
    fi

    log "ERROR: Nextcloud OCC did not become ready in time"
    return 1
}

wait_for_nextcloud_upgrade() {
    log "Waiting for Nextcloud upgrade to complete..."
    
    # A minute at most: this script is idempotent, so a slow upgrade is better
    # retried on the next start than waited out here.
    local upgrade_wait_retries=12
    local upgrade_check_interval=5
    
    for i in $(seq 1 $upgrade_wait_retries); do
        local status_output
        status_output="$(docker exec "$NEXTCLOUD_CONTAINER" php occ status 2>&1 || true)"
        
        if ! echo "$status_output" | grep -q "Nextcloud or one of the apps require upgrade"; then
            log "Nextcloud upgrade is complete"
            return 0
        fi
        
        log "Nextcloud is still upgrading, waiting... ($i/$upgrade_wait_retries)"
        sleep "$upgrade_check_interval"
    done

    log "WARNING: Nextcloud upgrade still in progress after $(($upgrade_wait_retries * $upgrade_check_interval)) seconds"
    log "WARNING: OIDC bootstrap will skip for now and retry on next service start"
    return 0
}

ensure_user_oidc_app() {
    # `app:list` prints Enabled and Disabled in the same "  - <appid>: <ver>"
    # shape, so grepping its plain output matches a *disabled* user_oidc too —
    # the app:enable below would then be skipped and configure_provider would
    # die against a disabled app on every start. --enabled --output=json
    # distinguishes the two.
    if docker exec "$NEXTCLOUD_CONTAINER" php occ app:list --enabled --output=json 2>/dev/null \
        | jq -e '.enabled | has("user_oidc")' >/dev/null 2>&1; then
        log "user_oidc app already enabled"
        return 0
    fi

    if docker exec "$NEXTCLOUD_CONTAINER" php occ app:install user_oidc >/dev/null 2>&1; then
        log "Installed and enabled user_oidc app"
        return 0
    fi

    if docker exec "$NEXTCLOUD_CONTAINER" php occ app:enable user_oidc >/dev/null 2>&1; then
        log "Enabled already-installed user_oidc app"
        return 0
    fi

    log "ERROR: Unable to install or enable Nextcloud app 'user_oidc'"
    return 1
}

# Unconditional, and it has to stay that way. `occ user_oidc:provider <id>
# --output=json` returns id, identifier, clientId, discoveryEndpoint, scope and
# settings - and no client secret, because Nextcloud does not hand it back. So
# there is no way to compare the one field most likely to have changed, and
# skipping the write when everything readable matches would leave a regenerated
# Authelia client secret sitting in authelia-config/secrets/ while Nextcloud
# kept the old one. SSO would break with nothing to say why.
#
# Rewriting every boot is the propagation path, not an oversight: it looks like
# a missing idempotence check in the log and it is load-bearing.
# Authelia implements no OIDC logout mechanism at all - not RP-initiated,
# front-channel or back-channel - so its discovery document carries no
# end_session_endpoint. user_oidc then falls back to redirecting to the
# Nextcloud root, where the still-valid Authelia cookie logs the user straight
# back in: logging out appeared to reload the same page.
#
# Its *portal* logout route is not OIDC, but a browser redirected there does
# carry the session cookie, so the session ends. `rd` sends the browser back
# afterwards; nextcloud.$HOST_NAME sits under the session cookie domain, so
# Authelia's safe-redirection check accepts it.
#
# The trailing `&ignored=` is load-bearing, not a typo. user_oidc appends
# `?post_logout_redirect_uri=...&client_id=...` unconditionally, which would
# otherwise land a second `?` inside the `rd` value and corrupt it; the empty
# parameter absorbs that suffix and leaves `rd` clean. Keep `rd` percent-encoded
# for the same reason.
end_session_endpoint_uri() {
    local return_to="https%3A%2F%2Fnextcloud.${HOST_NAME}%2F"

    printf 'https://auth.%s/logout?rd=%s&ignored=' "$HOST_NAME" "$return_to"
}

configure_provider() {
    local client_secret="$1"
    local discovery_uri="https://auth.${HOST_NAME}/.well-known/openid-configuration"
    local end_session_uri
    end_session_uri="$(end_session_endpoint_uri)"

    docker exec \
        -e OIDC_CLIENT_SECRET="$client_secret" \
        "$NEXTCLOUD_CONTAINER" \
        php occ user_oidc:provider "$OIDC_PROVIDER_ID" \
        --clientid="$OIDC_CLIENT_ID" \
        --clientsecret-env=OIDC_CLIENT_SECRET \
        --discoveryuri="$discovery_uri" \
        --endsessionendpointuri="$end_session_uri" \
        --scope="openid email profile groups" \
        --mapping-uid="email" \
        --mapping-display-name="name" \
        --mapping-email="email" \
        --mapping-groups="groups" \
        --group-provisioning=1 \
        --group-restrict-login-to-whitelist=0 \
        --unique-uid=0 \
        --resolve-nested-claims=1 \
        --check-bearer=0 \
        --bearer-provisioning=0 \
        >/dev/null

    log "OIDC provider '$OIDC_PROVIDER_ID' reasserted (the client secret cannot be read back to compare)"
}

verify_provider() {
    docker exec "$NEXTCLOUD_CONTAINER" php occ user_oidc:provider "$OIDC_PROVIDER_ID" --output=json >/dev/null 2>&1
}

configure_oidc_only_login() {
    docker exec "$NEXTCLOUD_CONTAINER" \
        php occ --no-interaction config:app:set user_oidc allow_multiple_user_backends --type=string --value=0 \
        >/dev/null

    log "Configured Nextcloud for OIDC-only login redirect"
}

verify_oidc_only_login() {
    app_value="$(docker exec "$NEXTCLOUD_CONTAINER" php occ config:app:get user_oidc allow_multiple_user_backends 2>/dev/null | tr -d '\r\n')"
    system_value="$(docker exec "$NEXTCLOUD_CONTAINER" php occ config:system:get hide_login_form 2>/dev/null | tr -d '\r\n')"

    [ "$app_value" = "0" ] && [ "$system_value" = "true" ]
}

main() {
    log "=== Nextcloud OIDC Bootstrap ==="

    if [ ! -f "$ENV_FILE" ]; then
        die ".env missing at $ENV_FILE"
    fi

    HOST_NAME="$(get_env_value HOST_NAME)"
    HOST_NAME="${HOST_NAME:-pi.lan}"

    if ! wait_for_container "$NEXTCLOUD_CONTAINER" "$MAX_RETRIES" "$RETRY_INTERVAL"; then
        exit 1
    fi

    if ! wait_for_occ; then
        exit 1
    fi

    wait_for_nextcloud_upgrade

    # wait_for_nextcloud_upgrade returns 0 on timeout too, so re-check before
    # touching the OIDC config.
    local status_output
    status_output="$(docker exec "$NEXTCLOUD_CONTAINER" php occ status 2>&1 || true)"
    if echo "$status_output" | grep -q "Nextcloud or one of the apps require upgrade"; then
        log "Nextcloud is still in upgrade mode, skipping OIDC configuration"
        log "Bootstrap will retry on next service start"
        exit 0
    fi

    ensure_user_oidc_app || exit 1

    OIDC_CLIENT_SECRET="$(get_oidc_secret "nextcloud" "NEXTCLOUD_OIDC_CLIENT_SECRET")" || {
        die "Could not read Nextcloud OIDC client secret"
    }

    if [ -z "$OIDC_CLIENT_SECRET" ]; then
        die "Nextcloud OIDC client secret is empty"
    fi

    configure_provider "$OIDC_CLIENT_SECRET"

    if ! verify_provider; then
        die "OIDC provider verification failed"
    fi

    configure_oidc_only_login

    if ! verify_oidc_only_login; then
        die "OIDC-only login verification failed"
    fi

    log "Nextcloud OIDC configured successfully"
}

main "$@"
