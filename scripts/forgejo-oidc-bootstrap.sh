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
# then id/name/type/enabled.
#
# The separator is a *run* of tabs, not one: the command renders through Go's
# text/tabwriter with --pad-char defaulting to '\t' and --tab-width to 8, so a
# cell narrower than its column by more than a tab stop is followed by two.
# Today's single row is one tab wide either way, but the header already prints
# `Name\t\t`, and a second auth source with a longer name would push this one
# into the same shape - `-F'\t'` would then read $2 as empty, report the source
# as absent, and send the caller into `add-oauth` on a name that already exists.
source_id() {
    forgejo_admin auth list 2>/dev/null \
        | awk -F'\t+' -v name="$SOURCE_NAME" 'NR > 1 && $2 == name { print $1; exit }'
}

# Curl from *inside* Forgejo. This is the only URL a hook here reaches by
# hostname rather than by container name, and Forgejo is the only container that
# resolves it: `extra_hosts` pins auth.<HOST_NAME> to Traefik for this container
# alone. lib.sh's wait_for_http_endpoint would run a throwaway curl on
# `frontend` instead, which gets whatever public DNS answers - in CI, where
# HOST_NAME is `test.local`, that is NXDOMAIN for the whole retry budget, twice
# per run, and the source is never created. Probing here also uses the trust
# store `forgejo admin` itself will, so a certificate it would reject shows up
# as an unreachable endpoint rather than as a failed command.
forgejo_can_reach() {
    docker exec -u git "$FORGEJO_CONTAINER" sh -ec '
        url="$1"
        set -- -fsS --connect-timeout 5 --max-time 30 -o /dev/null
        [ -z "${SSL_CERT_FILE:-}" ] || set -- "$@" --cacert "$SSL_CERT_FILE"
        exec curl "$@" "$url"
    ' sh "$1" >/dev/null 2>&1
}

# Usage: wait_for_forgejo_discovery <url>
wait_for_forgejo_discovery() {
    log "Waiting for Authelia's discovery document, as Forgejo resolves it..."
    _try=0
    while [ "$_try" -lt "$MAX_RETRIES" ]; do
        if forgejo_can_reach "$1"; then
            log "Authelia OIDC discovery is reachable from $FORGEJO_CONTAINER"
            return 0
        fi
        _try=$((_try + 1))
        sleep "$RETRY_INTERVAL"
    done
    log "ERROR: Authelia OIDC discovery is not reachable from $FORGEJO_CONTAINER"
    return 1
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
    wait_for_forgejo_discovery "$discovery_url" || {
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

    log "Restarting Forgejo to load the OIDC source"
    if ! compose restart forgejo >/dev/null; then
        # No fingerprint: the row is in the database but the running instance
        # has not built a provider from it, and writing the file here would make
        # every later run short-circuit on "already up to date" and never retry
        # the restart. Left unwritten, the next pass repeats the (idempotent)
        # update and the restart with it.
        log "WARNING: failed to restart Forgejo; the OIDC source is written but not loaded"
        return 1
    fi
    wait_for_health "$FORGEJO_CONTAINER" "$MAX_RETRIES" "$RETRY_INTERVAL" || true

    ensure_config_target_is_file "$fingerprint_file" || return 1
    printf '%s\n' "$fingerprint" > "$fingerprint_file"
    safe_chmod 600 "$fingerprint_file"
    # Root-run from the systemd unit, and this lands inside the volume the
    # container (uid 1000) and backrest both read.
    fix_ownership "$fingerprint_file"
}

main "$@"
