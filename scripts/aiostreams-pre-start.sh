#!/bin/sh
# Renders config/aiostreams/aiostreams.env: the values AIOStreams can only take
# from its environment, or that have to be discovered from another service.
# Everything else is plain `environment:` in compose/compose-media.yaml.
#
#   SECRET_KEY   encrypts every stored addon configuration and CANNOT change - a
#                new one makes existing configs undecryptable, i.e. every
#                installed addon URL in the household stops resolving. Minted
#                once, then carried forward verbatim.
#   AIOSTREAMS_AUTH
#                the local operator account. SSO covers the dashboard and the
#                configuration page, but the built-in proxy and usenet engine
#                authenticate with HTTP Basic, which an SSO identity has not
#                got. Not an interactive fallback: the login route checks
#                AIOSTREAMS_OIDC_ALLOW_LOCAL_LOGIN alone, and it is false, so
#                the way back in is flipping that flag, not this value.
#   AIOSTREAMS_OIDC_CLIENT_SECRET
#                environment-only upstream, so it cannot follow the stack's
#                usual "mount the secret as a file" pattern (docs/SECURITY.md).
#   BUILTIN_PROWLARR_URL / _API_KEY
#                our own Prowlarr as a scrape source, which is the only way the
#                French trackers this stack indexes reach a Stremio result list.
#                Unlike the three above these are *runtime* settings, so pinning
#                them makes both dashboard fields read-only - the point, for a
#                discovered credential.
#
#                Two things these cannot do, because both are per-user config
#                rather than instance settings: the Prowlarr addon still has to
#                be added in Dashboard -> Addons (the values here only prefill
#                it), and its "Timeout (ms)" has to be raised above
#                DEFAULT_TIMEOUT (15000 here, 7000 upstream). Measured, a live
#                tracker search is 11-13s once AIOStreams expands a request into
#                season-pack, episode and alternative-title queries, and the
#                anime preamble alone took 15.2s - under-budgeted, the fetcher
#                aborts before Prowlarr answers and Stremio gets zero streams,
#                with the only symptom a "timeout" line in the log. 30000 is
#                comfortable; the UI ceiling is MAX_TIMEOUT (50000).
#
# Not lib.sh's ensure_env_secrets, which is otherwise this hook's shape: only
# SECRET_KEY is generated. The rest are derived, and have to be reapplied every
# run so a rotation propagates - the opposite of what that helper does.
#
# Every derived value falls back to what is already in the file when its source
# cannot be read. Without that, one unreadable source rewrites the file *without*
# the value - still non-empty, so write_file_atomic reports success - and the
# next `up -d` recreates the container with SSO silently gone.
#
# It also seeds config/aiostreams/addons-config.env once, for the one value only
# stremio-addons.net can issue.
#
# A pre-start hook (scripts/run-hooks.sh), after authelia-pre-start.sh, which
# mints oidc_aiostreams_secret.txt. Idempotent.

set -eu

. "$(dirname "$0")/lib.sh"

CONFIG_DIR="$PROJECT_DIR/config/aiostreams"
OUTPUT_FILE="$CONFIG_DIR/aiostreams.env"
ADDONS_CONFIG_FILE="$CONFIG_DIR/addons-config.env"

# What the previous render left behind, for the fallbacks below.
previous_value() {
    read_env_value_from_file "$OUTPUT_FILE" "$1"
}

# Nothing, or both keys. An empty BUILTIN_PROWLARR_URL is worse than an absent
# one: compose makes it an empty string, which pins the dashboard field to blank
# *and* read-only, leaving the addon fixable from nowhere.
#
# BUILTIN_PROWLARR_INDEXERS is deliberately unset - that means every indexer
# Prowlarr holds, and narrowing it is a preference the dashboard should own.
write_prowlarr() {
    local key=""
    service_enabled prowlarr || { log "Prowlarr is not enabled; leaving its scrape source off"; return 0; }

    key="$(prowlarr_api_key)"
    if [ -z "$key" ]; then
        # The previous key, not nothing: dropping it here would disable a scrape
        # source that works, and Prowlarr only mints a new key on a reinstall.
        key="$(previous_value BUILTIN_PROWLARR_API_KEY)"
        if [ -z "$key" ]; then
            log "WARNING: could not read the Prowlarr API key; leaving its scrape source off (retried next start)"
            return 0
        fi
        log "WARNING: could not read the Prowlarr API key; keeping the one already rendered"
        printf 'BUILTIN_PROWLARR_URL=%s\n' 'http://prowlarr:9696'
        printf 'BUILTIN_PROWLARR_API_KEY=%s\n' "$key"
        return 0
    fi

    # Both on `frontend`, so Docker's DNS answers the service name. Prowlarr's
    # AuthenticationMethod=External covers the browser path only; /api/v1 still
    # authenticates on this key.
    printf 'BUILTIN_PROWLARR_URL=%s\n' 'http://prowlarr:9696'
    printf 'BUILTIN_PROWLARR_API_KEY=%s\n' "$(escape_compose_env_value "$key")"
}

# Carried forward if present, minted otherwise. generate_secret is
# `openssl rand -hex 32` - exactly the 64-char hex AIOStreams requires. Returns
# an already-escaped value either way: escaping the stored one twice would
# change it.
secret_key() {
    local existing=""
    existing="$(previous_value SECRET_KEY)"
    if [ -n "$existing" ]; then
        printf '%s' "$existing"
        return 0
    fi
    escape_compose_env_value "$(generate_secret)"
}

render() {
    local key="" user="" password="" oidc_secret=""

    key="$(secret_key)"
    [ -n "$key" ] || die "Could not obtain an AIOStreams SECRET_KEY"

    printf '# Managed by scripts/aiostreams-pre-start.sh\n'
    printf 'SECRET_KEY=%s\n' "$key"

    user="$(get_env_value ADMIN_USER)"
    password="$(get_env_value PASSWORD)"
    if [ -n "$user" ] && [ -n "$password" ]; then
        # user:pass pairs, comma separated. One entry, and no
        # AIOSTREAMS_AUTH_PERMISSIONS beside it: an unlisted user defaults to
        # every permission, which is what this account is for.
        printf 'AIOSTREAMS_AUTH=%s:%s\n' \
            "$(escape_compose_env_value "$user")" \
            "$(escape_compose_env_value "$password")"
    else
        log "WARNING: ADMIN_USER/PASSWORD not set; leaving the local operator account off (SSO only)"
    fi

    # The host copy, not `docker exec`: on a cold boot no container is up yet
    # and a container read would come back empty.
    oidc_secret="$(get_oidc_secret aiostreams)" || oidc_secret=""
    if [ -n "$oidc_secret" ]; then
        printf 'AIOSTREAMS_OIDC_CLIENT_SECRET=%s\n' "$(escape_compose_env_value "$oidc_secret")"
    else
        # AIOSTREAMS_OIDC_ENABLED stays true in compose/compose-media.yaml
        # whatever happens here, so a dropped secret is not "SSO off" but SSO
        # answering invalid_client on every login.
        oidc_secret="$(previous_value AIOSTREAMS_OIDC_CLIENT_SECRET)"
        if [ -n "$oidc_secret" ]; then
            log "WARNING: could not read the AIOStreams OIDC client secret; keeping the one already rendered"
            printf 'AIOSTREAMS_OIDC_CLIENT_SECRET=%s\n' "$oidc_secret"
        else
            log "WARNING: could not read the AIOStreams OIDC client secret; leaving SSO unconfigured (retried next start)"
        fi
    fi

    write_prowlarr
}

# Written once and never rewritten: stremio-addons.net issues this JWT against a
# claimed manifest URL, so it is not something this stack can mint. Ships
# commented out - an empty signature suppresses the manifest field exactly as an
# absent one does, so a blank line here would look configured and do nothing.
addons_config_template() {
    cat << 'EOF'
# STREMIO_ADDONS_CONFIG_SIGNATURE for AIOStreams. NOT managed by any script -
# yours to edit.
#
# The manifest only advertises the stremio-addons.net verification badge when
# this is set alongside STREMIO_ADDONS_CONFIG_ISSUER, which
# compose/compose-media.yaml already pins. To get it: sign in at
# https://stremio-addons.net, claim this instance by its manifest URL, and paste
# the signed JWT it hands back.
#
# After editing: `docker compose up -d aiostreams`, never `restart` - env_file
# values are frozen at container creation.

#STREMIO_ADDONS_CONFIG_SIGNATURE=
EOF
}

seed_addons_config() {
    [ -e "$ADDONS_CONFIG_FILE" ] && return 0

    addons_config_template | write_secret_file "$ADDONS_CONFIG_FILE" \
        || die "Failed to seed $ADDONS_CONFIG_FILE"
    safe_chmod 600 "$ADDONS_CONFIG_FILE"
    fix_ownership "$ADDONS_CONFIG_FILE"
    log "Seeded $ADDONS_CONFIG_FILE - paste the stremio-addons.net signature there"
}

main() {
    [ -f "$ENV_FILE" ] || die ".env not found at $ENV_FILE"

    mkdir -p "$CONFIG_DIR"
    # The directory too, not just the file: root-owned, the next non-root `make
    # update` cannot create write_file_atomic's mktemp in it, so the hook dies
    # and takes the whole blocking pre-start phase with it.
    fix_ownership "$CONFIG_DIR"

    # An unreadable file reads back as "no value at all", and secret_key() would
    # mint a fresh SECRET_KEY over a good one - silently, since the running
    # container froze the old value at creation. lib.sh's ensure_env_secrets
    # refuses for the same reason.
    if [ -e "$OUTPUT_FILE" ] && [ ! -r "$OUTPUT_FILE" ]; then
        die "$OUTPUT_FILE exists but is not readable - refusing to mint a new SECRET_KEY over it"
    fi

    write_file_atomic "$OUTPUT_FILE" render || die "Failed to render $OUTPUT_FILE"
    safe_chmod 600 "$OUTPUT_FILE"
    # write_file_atomic renames a mktemp into place, so the file is owned by
    # whoever ran the script - root, from the systemd unit. At 0600 that leaves
    # the repo owner unable to read their own generated env, and every invariant
    # behind `docker compose config` fails. tests/stack-up-test.sh enforces it.
    fix_ownership "$OUTPUT_FILE"
    seed_addons_config

    log "Rendered AIOStreams env to $OUTPUT_FILE"
}

main "$@"
