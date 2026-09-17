#!/bin/sh
# Renders config/aiometadata/aiometadata.env - the values AIOMetadata can only
# take from its environment or that come from another service - and seeds
# config/aiometadata/api-keys.env once, for the provider keys a person fetches.
#
#   REDIS_URL    the shared valkey needs a password and this addon has no *_FILE
#                variant, so it has to be inlined into the URL. Not optional:
#                sign-in sessions live there, so without it OIDC cannot work.
#   OIDC_CLIENT_SECRET
#                environment-only upstream, as with aiostreams.
#   ADMIN_KEY    guards the dashboard admin endpoints, and is the documented way
#                back in when AUTH_REQUIRE_SIGNIN is on and the provider is
#                unreachable. IMAGE_PROXY_SIGNING_SECRET falls back to it, which
#                is what stops the artwork proxy URLs being forgeable.
#
# Not lib.sh's ensure_env_secrets, and every derived value falls back to what the
# file already holds - the same two reasons as scripts/aiostreams-pre-start.sh.
# The fallback earns its keep here: the secrets directory is 0700, so a root-run
# start followed by a non-root `make update` is enough to lose a read.
#
# A pre-start hook (scripts/run-hooks.sh), after redis-pre-start.sh and
# authelia-pre-start.sh, which mint the two secrets it reads. Idempotent.

set -eu

. "$(dirname "$0")/lib.sh"

CONFIG_DIR="$PROJECT_DIR/config/aiometadata"
OUTPUT_FILE="$CONFIG_DIR/aiometadata.env"
API_KEYS_FILE="$CONFIG_DIR/api-keys.env"

# What the previous render left behind. Already escaped, so a carried-forward
# value is printed verbatim rather than escaped twice.
previous_value() {
    read_env_value_from_file "$OUTPUT_FILE" "$1"
}

admin_key() {
    local existing=""
    existing="$(previous_value ADMIN_KEY)"
    if [ -n "$existing" ]; then
        printf '%s' "$existing"
        return 0
    fi
    escape_compose_env_value "$(generate_secret)"
}

write_redis_url() {
    local password="" password_file="" previous=""

    # The host copy, for the same cold-boot reason as the OIDC secret below.
    # generate_secret is hex, so no percent-encoding is needed in the URL.
    password_file="$(resolve_data_location_path)/authelia-config/secrets/redis_password"
    if [ -r "$password_file" ]; then
        password="$(tr -d '\r\n' < "$password_file")"
    fi
    if [ -n "$password" ]; then
        # No username: valkey.conf sets `requirepass`, so the default user is
        # what authenticates, and an ACL user would be worthless while `default`
        # answers - see docs/SECURITY.md.
        printf 'REDIS_URL=redis://:%s@redis:6379\n' "$(escape_compose_env_value "$password")"
        return 0
    fi

    previous="$(previous_value REDIS_URL)"
    if [ -n "$previous" ]; then
        log "WARNING: could not read the Redis password; keeping the REDIS_URL already rendered"
        printf 'REDIS_URL=%s\n' "$previous"
        return 0
    fi
    log "WARNING: could not read the Redis password; leaving REDIS_URL unset - AIOMetadata will not serve (retried next start)"
}

write_oidc_secret() {
    local secret=""

    secret="$(get_oidc_secret aiometadata)" || secret=""
    if [ -n "$secret" ]; then
        printf 'OIDC_CLIENT_SECRET=%s\n' "$(escape_compose_env_value "$secret")"
        return 0
    fi

    # OIDC_ENABLED stays true in compose whatever happens here, so a dropped
    # secret is not "SSO off" but invalid_client on every login.
    secret="$(previous_value OIDC_CLIENT_SECRET)"
    if [ -n "$secret" ]; then
        log "WARNING: could not read the AIOMetadata OIDC client secret; keeping the one already rendered"
        printf 'OIDC_CLIENT_SECRET=%s\n' "$secret"
        return 0
    fi
    log "WARNING: could not read the AIOMetadata OIDC client secret; leaving SSO unconfigured (retried next start)"
}

render() {
    local key=""

    printf '# Managed by scripts/aiometadata-pre-start.sh\n'

    key="$(admin_key)"
    [ -n "$key" ] || die "Could not obtain an AIOMetadata ADMIN_KEY"
    printf 'ADMIN_KEY=%s\n' "$key"

    write_redis_url
    write_oidc_secret
}

# Written once and never rewritten: these are keys a person fetches from TMDB,
# TVDB, MDBList and Google, not anything this stack can mint. Every line ships
# commented out, because an empty value and an absent one are not the same thing
# to this addon.
#
# BUILT_IN_ rather than the bare names: TMDB_API_KEY, MDBLIST_API_KEY and friends
# are served in full to every visitor by /api/config so the configure page can
# prefill them, and that route stays open even with AUTH_REQUIRE_SIGNIN=true.
# The BUILT_IN_ half never leaves the server.
api_keys_template() {
    cat << 'EOF'
# Server-side provider keys for AIOMetadata. Uncomment and fill in what you
# have; they cover any user who has not supplied their own in the Integrations
# tab. NOT managed by any script - yours to edit.
#
# Do NOT use the bare names (TMDB_API_KEY, TVDB_API_KEY, MDBLIST_API_KEY,
# GEMINI_API_KEY, RPDB_API_KEY): those are published to every visitor by
# /api/config. These BUILT_IN_ ones never leave the server.
#
# After editing: `docker compose up -d aiometadata`, never `restart` - env_file
# values are frozen at container creation.

# Free, and the one thing the addon cannot work without.
#BUILT_IN_TMDB_API_KEY=

# Free. Series and most anime metadata; strongly recommended.
#BUILT_IN_TVDB_API_KEY=

# Free. Logos and background art.
#BUILT_IN_FANART_API_KEY=

# Billed past 1000 calls a day, and every user of this instance spends the same
# allowance - which is why the catalog warmers are off in
# compose/compose-media.yaml. Needed for MDBList catalogs (the curated lists the
# community configs are built around).
#BUILT_IN_MDBLIST_API_KEY=

# Billed per query. Only for AI search.
#BUILT_IN_GEMINI_API_KEY=

# Rating-overlaid posters. `t0-free-rpdb-rounded-blocks` is the free tier and
# needs no account.
#BUILT_IN_RPDB_API_KEY=
EOF
}

# Through write_secret_file, not `cat > file`: this file is where provider API
# keys end up, and a plain redirect creates it under the caller's umask - world
# readable until the chmod below, which docs/SECURITY.md rules out.
seed_api_keys() {
    [ -e "$API_KEYS_FILE" ] && return 0

    api_keys_template | write_secret_file "$API_KEYS_FILE" \
        || die "Failed to seed $API_KEYS_FILE"
    safe_chmod 600 "$API_KEYS_FILE"
    fix_ownership "$API_KEYS_FILE"
    log "Seeded $API_KEYS_FILE - add your TMDB/TVDB keys there"
}

main() {
    [ -f "$ENV_FILE" ] || die ".env not found at $ENV_FILE"

    mkdir -p "$CONFIG_DIR"
    # The directory too, not just the files below: the systemd unit runs this as
    # root, and a root-owned config/aiometadata is one the next non-root `make
    # update` cannot create write_file_atomic's mktemp in - so the hook dies and
    # takes the whole blocking pre-start phase with it.
    fix_ownership "$CONFIG_DIR"

    # An existing file we cannot read reads back as "no value at all", and every
    # carry-forward above would then silently lose its value while admin_key()
    # minted a fresh ADMIN_KEY - which is also IMAGE_PROXY_SIGNING_SECRET, so
    # every artwork URL already handed out stops verifying. lib.sh's
    # ensure_env_secrets refuses for the same reason.
    if [ -e "$OUTPUT_FILE" ] && [ ! -r "$OUTPUT_FILE" ]; then
        die "$OUTPUT_FILE exists but is not readable - refusing to overwrite it with new secrets"
    fi

    write_file_atomic "$OUTPUT_FILE" render || die "Failed to render $OUTPUT_FILE"
    safe_chmod 600 "$OUTPUT_FILE"
    # Unconditional, and for the reason tests/stack-up-test.sh enforces: the
    # unit runs this as root, and a root-owned 0600 file is one the next
    # non-root `make update` cannot read and compose cannot load as an env_file.
    fix_ownership "$OUTPUT_FILE"

    seed_api_keys

    log "Rendered AIOMetadata env to $OUTPUT_FILE"
}

main "$@"
