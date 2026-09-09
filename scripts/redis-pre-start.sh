#!/bin/sh
# Generates the shared Redis password and renders the `requirepass` directive
# config/redis/valkey.conf includes. See docs/SECURITY.md for what this closes.
#
# Generated rather than derived from PASSWORD: every consumer reads it from a
# file, so nothing has to type it, and rotate-password.sh then has no
# four-service restart to sequence. `rotate-secret.sh redis-auth` rotates it.
#
# A blocking pre-start hook, because valkey refuses to start when an included
# file is missing: a failure here stops the boot with a diagnosis instead.
# Idempotent.

set -eu

. "$(dirname "$0")/lib.sh"

# Beside the Authelia secrets, because that is the only directory Authelia
# mounts and it reads this through `{{ secret "/config/secrets/..." }}`.
SECRETS_DIR="$(resolve_data_location_path)/authelia-config/secrets"
PASSWORD_FILE="$SECRETS_DIR/redis_password"
AUTH_CONF_DIR="$(resolve_data_location_path)/redis"
AUTH_CONF="$AUTH_CONF_DIR/redis-auth.conf"
# The bare password, in the same 0700 directory, for the one consumer whose
# non-root processes have to read it themselves. See below.
WWW_COPY="$AUTH_CONF_DIR/redis-password"

mkdir -p "$SECRETS_DIR" "$AUTH_CONF_DIR"
safe_chmod 700 "$SECRETS_DIR"

# -s, not -f: a zero-byte leftover would be accepted forever, and every client
# would then authenticate with an empty string.
if [ ! -s "$PASSWORD_FILE" ]; then
    write_file_atomic "$PASSWORD_FILE" generate_secret \
        || die "Failed to generate the Redis password"
    safe_chmod 600 "$PASSWORD_FILE"
    log "Generated the Redis password"
fi

REDIS_PASSWORD="$(cat "$PASSWORD_FILE")"
[ -n "$REDIS_PASSWORD" ] || die "$PASSWORD_FILE is empty"

# Re-rendered every run, so a hand-edited or half-written file is repaired
# before valkey reads it. generate_secret is hex, so it needs no quoting; and no
# trailing newline, which `$(cat ...)` strips - keeping one here would make every
# run see a difference.
RENDERED="requirepass $REDIS_PASSWORD"
CHANGED=0
if [ "$(cat "$AUTH_CONF" 2>/dev/null || true)" != "$RENDERED" ]; then
    printf '%s\n' "$RENDERED" | write_secret_file "$AUTH_CONF" \
        || die "Failed to render $AUTH_CONF"
    log "Rendered the Redis auth directive to $AUTH_CONF"
    CHANGED=1
fi

# The same secret again, bare, for Nextcloud. Its entrypoint resolves
# REDIS_HOST_PASSWORD_FILE as root, but config/redis.config.php keeps the `_FILE`
# branch and re-evaluates it on every request - and `docker exec -u www-data`
# (the cron unit, the external-storage hook) gets the container's configured
# environment, not the entrypoint's exports, so uid 33 has to be able to read the
# file itself or every such run fails with NOAUTH.
if [ "$(cat "$WWW_COPY" 2>/dev/null || true)" != "$REDIS_PASSWORD" ]; then
    printf '%s\n' "$REDIS_PASSWORD" | write_secret_file "$WWW_COPY" \
        || die "Failed to render $WWW_COPY"
    log "Rendered the Nextcloud-readable copy of the Redis password"
    CHANGED=1
fi

# 0644, the two secrets here that are not 0600: the valkey entrypoint re-execs
# the server under `setpriv --reuid=valkey --clear-groups` (uid 999) and
# Nextcloud's cron runs as www-data (uid 33), while this hook runs as root under
# systemd or as the project owner under `make update` - neither can hand a file
# to 999 or 33 without the other losing it. The 0700 directory is what protects
# them on the host; a bind-mounted file is reached by its own mode inside the
# container. The 0600 copy in $SECRETS_DIR stays authoritative.
#
# Before the recreate below, not after: write_secret_file leaves the mktemp at
# 0600, and a valkey recreated against a 0600 include dies with `can't open
# config file` and crash-loops - with the definition then matching, so nothing
# recreates it again.
safe_chmod 644 "$AUTH_CONF"
safe_chmod 644 "$WWW_COPY"
safe_chmod 700 "$AUTH_CONF_DIR"

# Here rather than leaving it to the `up -d` that starts the stack, because
# authelia-pre-start.sh runs next and restarts Authelia with the new password: a
# server that has not read the directive yet answers it `ERR Client sent AUTH,
# but no password is set`. --force-recreate, because the password lives in a
# bind-mounted file: the service definition is byte-identical afterwards, so a
# plain `up -d` finds a matching config hash and does nothing at all.
if [ "$CHANGED" -eq 1 ] && container_is_running "pi-redis"; then
    log "Applying the new Redis password before the consumers are restarted"
    compose up -d --force-recreate --no-deps redis >/dev/null 2>&1 \
        || log "WARNING: could not recreate redis"
fi

# Both, or a root-run start leaves a directory the project owner cannot traverse
# and a password file it cannot re-render from.
fix_ownership "$AUTH_CONF_DIR"
fix_ownership "$PASSWORD_FILE"
