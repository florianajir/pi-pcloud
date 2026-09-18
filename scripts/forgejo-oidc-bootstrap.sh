#!/bin/sh
# Register Authelia as Forgejo's OAuth2 authentication source.
#
# This is the one piece of Forgejo's configuration that compose cannot carry.
# Every other setting is an app.ini key, and the image re-renders app.ini from
# the FORGEJO__* environment on each start - but an auth source is a row in the
# `login_source` table, with no ini equivalent and no REST endpoint. The only
# supported way in is the `forgejo admin auth` CLI, which is why this runs as a
# post-start hook rather than a pre-start one: the container has to be up.
#
# Safe to run multiple times. The source is created once; afterwards this
# updates it (and restarts Forgejo) only when the secret, the issuer or the
# group mapping actually changed, which it detects from a fingerprint file
# rather than by reading back - `forgejo admin auth list` prints the id, the
# name and the type, and nothing that would reveal a stale client secret.
#
# The restart is not optional on a change: Forgejo builds its goth providers
# once at startup (services/auth/source/oauth2), so a row written underneath a
# running instance is not picked up until it comes back.

set -eu

. "$(dirname "$0")/lib.sh"

MAX_RETRIES=120
RETRY_INTERVAL=2
FORGEJO_CONTAINER="${FORGEJO_CONTAINER:-pi-forgejo}"
# Load-bearing, not cosmetic: Forgejo derives the callback URL from this name
# (AppURL + "user/oauth2/" + PathEscape(name) + "/callback"), and Authelia only
# accepts the redirect_uris it was given. Renaming it here means renaming it in
# config/authelia/configuration.yml.template too.
SOURCE_NAME="authelia"
# `admin` is the LLDAP group, the same one Grafana and the Authelia access
# rules key off. Forgejo re-evaluates administrator status from this claim on
# every sign-in, so promoting someone is an LLDAP change, not a Forgejo one.
ADMIN_GROUP="admin"

# The CLI runs as the `git` user; as root it would write files into /data that
# the server process (uid 1000) cannot then read.
forgejo_admin() {
    docker exec -u git "$FORGEJO_CONTAINER" forgejo admin "$@"
}

# The secret never appears in the host's argv: `docker exec -e NAME` passes the
# variable name, and the daemon takes the value from this process's own
# environment. Inside the container it is an argument to `forgejo`, readable
# only by that container's processes - the same trade rotate-password.sh makes
# for FreshRSS.
forgejo_admin_with_secret() {
    FORGEJO_OIDC_SECRET="$CLIENT_SECRET" docker exec -e FORGEJO_OIDC_SECRET -u git \
        "$FORGEJO_CONTAINER" sh -ec '
            exec forgejo admin "$@" --secret "$FORGEJO_OIDC_SECRET"
        ' sh "$@"
}

# Empty when the source does not exist yet. `auth list` prints a header row and
# then tab-separated id/name/type/enabled.
source_id() {
    forgejo_admin auth list 2>/dev/null \
        | awk -F'\t' -v name="$SOURCE_NAME" 'NR > 1 && $2 == name { print $1; exit }'
}

main() {
    if ! container_is_running "$FORGEJO_CONTAINER"; then
        log "Forgejo is not running; skipping OIDC bootstrap"
        return 0
    fi

    ensure_authelia_oidc_materials "forgejo" "Forgejo" "$MAX_RETRIES" "$RETRY_INTERVAL" || {
        log "WARNING: Authelia OIDC materials for Forgejo are not ready; skipping"
        return 0
    }

    CLIENT_SECRET="$(get_oidc_secret forgejo)" || CLIENT_SECRET=""
    if [ -z "$CLIENT_SECRET" ]; then
        log "WARNING: could not read the Forgejo OIDC client secret; skipping"
        return 0
    fi

    host_name="$(get_env_value HOST_NAME)"
    [ -n "$host_name" ] || host_name="pi.lan"
    discovery_url="https://auth.${host_name}/.well-known/openid-configuration"

    # Forgejo fetches and parses the discovery document while *creating* the
    # source and refuses the command outright on a non-200, so this wait is not
    # a nicety: on a cold boot Traefik and Authelia are still coming up, and the
    # hook would otherwise fail on the first start of every fresh install.
    wait_for_health "$FORGEJO_CONTAINER" "$MAX_RETRIES" "$RETRY_INTERVAL" || {
        log "WARNING: Forgejo did not become healthy; skipping OIDC bootstrap"
        return 0
    }
    wait_for_http_endpoint "$discovery_url" "Authelia OIDC discovery" "$MAX_RETRIES" "$RETRY_INTERVAL" || {
        log "WARNING: Authelia discovery document is not reachable; skipping OIDC bootstrap"
        return 0
    }

    data_root="$(resolve_data_location_path)"
    fingerprint_file="$data_root/forgejo/.oidc-source-fingerprint"
    # Everything a change would have to be applied for. The secret is hashed
    # with the rest rather than stored, so this file leaks nothing if the data
    # directory is read.
    fingerprint="$(printf '%s\n%s\n%s\n%s\n%s\n' \
        "$SOURCE_NAME" "$discovery_url" "forgejo" "$ADMIN_GROUP" "$CLIENT_SECRET" \
        | sha256sum | cut -d' ' -f1)"

    existing_id="$(source_id)"

    if [ -n "$existing_id" ] && [ -r "$fingerprint_file" ] &&
        [ "$(cat "$fingerprint_file")" = "$fingerprint" ]; then
        log "Forgejo OIDC source '$SOURCE_NAME' is already up to date"
        return 0
    fi

    set -- --name "$SOURCE_NAME" \
        --provider openidConnect \
        --key forgejo \
        --auto-discover-url "$discovery_url" \
        --scopes openid --scopes profile --scopes email --scopes groups \
        --group-claim-name groups \
        --admin-group "$ADMIN_GROUP"

    if [ -n "$existing_id" ]; then
        log "Updating Forgejo OIDC source '$SOURCE_NAME' (id $existing_id)"
        forgejo_admin_with_secret auth update-oauth --id "$existing_id" "$@" || {
            log "WARNING: failed to update the Forgejo OIDC source"
            return 1
        }
    else
        log "Creating Forgejo OIDC source '$SOURCE_NAME'"
        forgejo_admin_with_secret auth add-oauth "$@" || {
            log "WARNING: failed to create the Forgejo OIDC source"
            return 1
        }
    fi

    ensure_config_target_is_file "$fingerprint_file" || return 1
    printf '%s\n' "$fingerprint" > "$fingerprint_file"
    safe_chmod 600 "$fingerprint_file"
    # Root-run from the systemd unit, and this lands inside the volume the
    # container (uid 1000) and backrest both read.
    fix_ownership "$fingerprint_file"

    log "Restarting Forgejo to load the OIDC source"
    if compose restart forgejo >/dev/null; then
        wait_for_health "$FORGEJO_CONTAINER" "$MAX_RETRIES" "$RETRY_INTERVAL" || true
    else
        log "WARNING: failed to restart Forgejo; the OIDC source is written but not loaded"
    fi
}

main "$@"
