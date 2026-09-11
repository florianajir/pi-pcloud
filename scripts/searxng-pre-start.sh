#!/bin/sh
# Pre-start: the one thing SearXNG cannot get for itself - the secret_key it
# refuses to start without.
#
# An env_file rather than a value in settings.yml: the container runs as uid
# 977 and the project owner is 1000, so a 0600 secret in the mounted config
# would be one SearXNG could not read, and a readable one would be a secret at
# 0644. SEARXNG_SECRET is an override the image already supports, so the config
# file stays non-sensitive and the secret stays 0600.
#
# Frozen at container creation like every env_file here: a rotated secret needs
# `up -d`, not `restart`. Nothing rotates this one - regenerating it only
# invalidates saved /preferences cookies and image-proxy links.
#
# A pre-start hook (scripts/run-hooks.sh). Idempotent.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

# Not ENV_FILE: lib.sh uses that name for .env, and resolve_data_location_path
# reads DATA_LOCATION out of it. agentgateway-pre-start.sh has the same note.
SEARXNG_ENV_DIR="$PROJECT_DIR/config/searxng"
SEARXNG_ENV_FILE="$SEARXNG_ENV_DIR/searxng.env"

main() {
    local secret=""

    # Docker materialises a missing bind-mount source as a directory, and a
    # directory has a non-zero size - so the -s test below would pass and
    # compose would fail to load the env_file forever. Same removal
    # homepage-pre-start.sh does for its own mount.
    if [ -d "$SEARXNG_ENV_FILE" ]; then
        log "WARNING: $SEARXNG_ENV_FILE is a directory (Docker bind-mount artifact). Removing..."
        rm -rf "$SEARXNG_ENV_FILE"
    fi

    if [ -s "$SEARXNG_ENV_FILE" ]; then
        log "SearXNG secret already present"
        return 0
    fi

    mkdir -p "$SEARXNG_ENV_DIR"

    secret="$(generate_secret)" || die "Failed to generate the SearXNG secret"
    [ -n "$secret" ] || die "Failed to generate the SearXNG secret"

    printf 'SEARXNG_SECRET=%s\n' "$secret" \
        | write_secret_file "$SEARXNG_ENV_FILE" \
        || die "Failed to write $SEARXNG_ENV_FILE"
    safe_chmod 600 "$SEARXNG_ENV_FILE"
    # The systemd unit runs this as root; without this the file lands root:root
    # 0600, and then a non-root `docker compose up` cannot read the env_file
    # (`required: false` covers a missing one, not an unreadable one).
    # tests/stack-up-test.sh enforces this pairing.
    fix_ownership "$SEARXNG_ENV_FILE"

    log "Generated the SearXNG secret"
}

main "$@"
