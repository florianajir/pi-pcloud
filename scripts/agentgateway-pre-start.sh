#!/bin/sh
# Prepares the two things agentgateway cannot get for itself: a writable data
# directory, and the two secrets its configuration file reads from the
# environment.
#
# config/agentgateway/config.yaml refers to ${UI_CLIENT_SECRET}, and the OIDC
# client secret is a file that scripts/authelia-pre-start.sh generates - so
# something has to carry it into the container's environment. agentgateway is a
# distroless image with no shell, so the `export $(cat ...)` entrypoint trick the
# other services use is not available here; an env_file is.
#
# A pre-start hook (scripts/stack-up.sh), after authelia-pre-start.sh so the
# client secret exists. Idempotent.

set -eu

. "$(dirname "$0")/lib.sh"

# Not ENV_FILE: that name is lib.sh's path to .env, and resolve_data_location_path
# below reads DATA_LOCATION out of it. Overwriting it made this script chown
# ./data/agentgateway while compose mounted $DATA_LOCATION/agentgateway - and the
# chown reported success, so nothing pointed at the directory agentgateway could
# not write.
AGW_ENV_DIR="$PROJECT_DIR/config/agentgateway"
AGW_ENV_FILE="$AGW_ENV_DIR/agentgateway.env"

# The uid compose pins the container to, which is the one that has to be able to
# write the SQLite overlay. Deliberately not fix_ownership's project owner: on a
# host where those differ, chowning to the project owner reports success and
# agentgateway still cannot open its database.
WRITER_UID="${WRITER_UID:-1000}"
WRITER_GID="${WRITER_GID:-1000}"

main() {
    local data_dir="" secrets_dir="" cookie_file="" client_secret="" cookie_secret=""

    data_dir="$(resolve_data_location_path)/agentgateway"
    secrets_dir="$data_dir/secrets"
    cookie_file="$secrets_dir/cookie_secret"

    mkdir -p "$secrets_dir"
    safe_chmod 700 "$secrets_dir"

    # AES-256-GCM key for the session cookie: agentgateway refuses to start
    # unless it is exactly 64 hex characters, which generate_secret produces.
    # Persisted rather than regenerated, or every start would log everyone out.
    if [ ! -s "$cookie_file" ]; then
        write_file_atomic "$cookie_file" generate_secret \
            || die "Failed to generate the agentgateway cookie secret"
        safe_chmod 600 "$cookie_file"
        log "Generated the agentgateway session cookie secret"
    fi
    cookie_secret="$(cat "$cookie_file")"

    client_secret="$(get_oidc_secret agentgateway)" || client_secret=""
    if [ -z "$client_secret" ]; then
        log "WARNING: no Authelia OIDC secret for agentgateway yet; it will not start until there is one"
        return 0
    fi

    mkdir -p "$AGW_ENV_DIR"
    printf 'OIDC_COOKIE_SECRET=%s\nUI_CLIENT_SECRET=%s\n' \
        "$cookie_secret" "$client_secret" | write_secret_file "$AGW_ENV_FILE" \
        || die "Failed to write $AGW_ENV_FILE"
    safe_chmod 600 "$AGW_ENV_FILE"

    # chown the directory only, never -R: its contents are a database
    # agentgateway owns and a secret this script wrote 0600.
    if [ "$(stat -c '%u:%g' "$data_dir" 2>/dev/null || echo unknown)" != "${WRITER_UID}:${WRITER_GID}" ]; then
        chown "${WRITER_UID}:${WRITER_GID}" "$data_dir" 2>/dev/null \
            || log "WARNING: could not chown $data_dir to ${WRITER_UID}:${WRITER_GID}; agentgateway cannot write its database"
    fi

    log "Ensured agentgateway secrets and data directory"
}

main "$@"
