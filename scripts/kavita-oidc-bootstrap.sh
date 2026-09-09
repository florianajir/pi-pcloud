#!/bin/sh
# Wire Kavita's OpenID Connect settings (Authelia) into the two places Kavita keeps
# them, because neither one covers the other:
#
#   - appsettings.json holds Authority, ClientId, Secret and CustomScopes, and Kavita
#     copies exactly those four into its database at every startup
#     (Seed.SetOidcSettingsFromDisk). `Enabled` is derived from them, so this file is
#     what turns SSO on and what a secret rotation has to reach.
#   - the database holds the *behaviour* - account provisioning, role sync, default
#     roles - and nothing copies it from disk. Reachable only through /api/Settings,
#     which is why it used to be a documented click in the admin UI and why a rebuilt
#     host silently came back with Kavita's defaults instead of ours.
#
# A post-start hook (scripts/stack-up.sh). Safe to run multiple times: appsettings.json
# is written (and Kavita restarted) only when it actually changed, and the API is called
# only when the settings this script owns have drifted.
#
# Two fields are deliberately left to the admin UI: DisablePasswordAuthentication,
# because imposing it from a hook can strand a fresh install with no way in if SSO is
# not working yet, and DefaultLibraries, which scripts/kavita-library-bootstrap.sh owns.

set -eu

. "$(dirname "$0")/lib.sh"

MAX_RETRIES=120
RETRY_INTERVAL=2
KAVITA_CONTAINER="${KAVITA_CONTAINER:-pi-kavita}"
KAVITA_URL_DOCKER="${KAVITA_URL_DOCKER:-http://pi-kavita:5000}"
APPSETTINGS_PATH="/config/appsettings.json"
API="http://localhost:5000/api"

# Role sync is deliberately off, and this is the one setting worth spelling out.
# With it on, Kavita derives every permission from the groups claim on each login and
# refresh: CreateNewAccount refuses any account whose claim carries neither `Login` nor
# `Admin`, and SyncRoles then replaces the user's roles with whatever the claim matched
# (removing the rest). `admin` is the only group anybody has in this stack, so the two
# admins worked and every other family account was refused outright - with password
# login disabled there was no second way in, so Kavita was admin-only without looking
# broken.
#
# Off, Kavita applies DefaultRoles at account creation instead. DefaultRoles must never
# contain `Admin`: it is handed to every auto-provisioned SSO account. Admin stays a
# click in Kavita's own UI for the one or two people who need it.
#
# Turning sync back on means creating LLDAP groups named after Kavita's own roles
# (`Login`, `Admin`, `library-<Name>`, `age-restriction-<Rating>`), ideally behind a
# rolesPrefix, *and* restoring the `groups` scope on both sides - see CUSTOM_SCOPES.
DESIRED_OIDC_POLICY='{
  "provisionAccounts": true,
  "requireVerifiedEmail": true,
  "autoLogin": true,
  "syncUserSettings": false,
  "rolesClaim": "groups",
  "rolesPrefix": "",
  "defaultRoles": ["Login", "Change Password", "Bookmark", "Download"]
}'

# Empty because role sync is off: the claim would be fetched and ignored. Kavita appends
# CustomScopes to the authorization request *without* checking the provider's
# scopes_supported (it only filters its own defaults), so a scope listed here but not on
# the Authelia client is an `invalid_scope` error and nobody can log in. Keep this and
# the kavita client's `scopes` in config/authelia/configuration.yml.template in step.
CUSTOM_SCOPES='[]'

kv_curl() {
    docker exec "$KAVITA_CONTAINER" curl -sS "$@"
}

# Reconciles the OIDC settings that live in Kavita's database. Best-effort: a fresh
# install has no admin, so no API key, so no way to reach the API at all.
sync_oidc_policy() {
    local token="" settings="" desired="" code=""

    token="$(kavita_token "$KAVITA_CONTAINER" || true)"
    if [ -z "$token" ]; then
        log "WARNING: no Kavita admin API key yet; leaving provisioning and role settings alone"
        return 0
    fi

    settings="$(kv_curl -H "Authorization: Bearer $token" "$API/Settings" 2>/dev/null)"
    printf '%s' "$settings" | jq -e '.oidcConfig' >/dev/null 2>&1 || {
        log "WARNING: could not read Kavita settings; skipping OIDC policy"
        return 0
    }

    # The GET masks the secret as a run of asterisks and Kavita patches the real one
    # back in when it receives that same run - so the whole payload can be round-tripped
    # without this script ever handling the secret. Anything not in $DESIRED_OIDC_POLICY
    # keeps its current value, including the fields the admin UI owns.
    desired="$(printf '%s' "$settings" | jq -c --argjson p "$DESIRED_OIDC_POLICY" \
        '.oidcConfig += $p')"

    if [ "$(printf '%s' "$settings" | jq -S -c .)" = "$(printf '%s' "$desired" | jq -S -c .)" ]; then
        log "Kavita OIDC provisioning and role settings already correct"
        return 0
    fi

    code="$(printf '%s' "$desired" | docker exec -i "$KAVITA_CONTAINER" curl -sS \
        -o /dev/null -w '%{http_code}' -X POST \
        -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
        --data @- "$API/Settings")"
    case "$code" in
        20*) log "Applied Kavita OIDC policy (role sync off, no Admin in default roles)" ;;
        *)   log "WARNING: updating Kavita settings returned HTTP $code" ;;
    esac
}

# The four fields Kavita reads off disk at every startup.
sync_appsettings() {
    local authority="$1" secret="$2" current="" desired=""

    # Absent is fine (fresh install); unreadable is not. Treating a failed exec as
    # {} makes the merge below write back a file holding only OpenIdConnectSettings,
    # and Kavita keeps TokenKey there - every session dies with it.
    if docker exec "$KAVITA_CONTAINER" sh -c '[ -e "$1" ]' _ "$APPSETTINGS_PATH" 2>/dev/null; then
        current="$(docker exec "$KAVITA_CONTAINER" cat "$APPSETTINGS_PATH")" ||
            die "Could not read $APPSETTINGS_PATH from $KAVITA_CONTAINER"
        printf '%s' "$current" | jq -e 'type == "object"' >/dev/null 2>&1 ||
            die "$APPSETTINGS_PATH is not a JSON object - refusing to overwrite it"
    else
        current='{}'
    fi

    desired="$(printf '%s' "$current" | jq \
        --arg authority "$authority" \
        --arg secret "$secret" \
        --argjson scopes "$CUSTOM_SCOPES" \
        '.OpenIdConnectSettings = ((.OpenIdConnectSettings // {}) + {
            Authority: $authority,
            ClientId: "kavita",
            Secret: $secret,
            CustomScopes: $scopes,
            Enabled: true
         })')"

    if [ "$(printf '%s' "$current" | jq -S .)" = "$(printf '%s' "$desired" | jq -S .)" ]; then
        log "Kavita OIDC client already configured in $APPSETTINGS_PATH"
        return 0
    fi

    # Write the patched file back into the container, then restart so Kavita loads it.
    printf '%s' "$desired" | docker exec -i "$KAVITA_CONTAINER" sh -c "cat > $APPSETTINGS_PATH" || {
        die "Failed to write $APPSETTINGS_PATH in $KAVITA_CONTAINER"
    }

    log "Configured Kavita OIDC client (authority=$authority); restarting to apply"
    (cd "$PROJECT_DIR" && docker compose restart kavita >/dev/null) || {
        die "Failed to restart Kavita after OIDC configuration"
    }

    wait_for_http_endpoint "$KAVITA_URL_DOCKER/api/health" "Kavita HTTP API" "$MAX_RETRIES" "$RETRY_INTERVAL" || true
}

main() {
    local enabled host_name authority secret

    log "=== Kavita OIDC Bootstrap ==="

    if [ ! -f "$ENV_FILE" ]; then
        die ".env missing at $ENV_FILE"
    fi

    enabled="$(get_env_value KAVITA_OIDC_ENABLED)"
    [ -n "$enabled" ] || enabled="true"
    if ! is_truthy "$enabled"; then
        log "KAVITA_OIDC_ENABLED is disabled, skipping bootstrap"
        exit 0
    fi

    host_name="$(get_env_value HOST_NAME)"
    host_name="${host_name:-pi.lan}"
    authority="https://auth.${host_name}"

    ensure_authelia_oidc_materials "kavita" "Kavita" "$MAX_RETRIES" "$RETRY_INTERVAL" || {
        die "Kavita OIDC prerequisites are missing in Authelia configuration"
    }

    wait_for_container "$KAVITA_CONTAINER" "$MAX_RETRIES" "$RETRY_INTERVAL" || exit 1
    # Kavita writes appsettings.json during startup; wait until its HTTP API answers.
    wait_for_http_endpoint "$KAVITA_URL_DOCKER/api/health" "Kavita HTTP API" "$MAX_RETRIES" "$RETRY_INTERVAL" || exit 1

    secret="$(get_oidc_secret "kavita")" || die "Could not read Kavita OIDC client secret"
    [ -n "$secret" ] || die "Kavita OIDC client secret is empty"

    # Order matters: the database copy of Authority/ClientId/Secret/CustomScopes is
    # re-seeded from disk on the restart above, so the API round-trip below has to
    # happen after it or it would POST the pre-restart values straight back.
    sync_appsettings "$authority" "$secret"
    sync_oidc_policy

    log "Kavita OIDC bootstrap complete"
}

main "$@"
