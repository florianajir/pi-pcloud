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
if [ "$(cat "$AUTH_CONF" 2>/dev/null || true)" != "$RENDERED" ]; then
    printf '%s\n' "$RENDERED" | write_secret_file "$AUTH_CONF" \
        || die "Failed to render $AUTH_CONF"
    log "Rendered the Redis auth directive to $AUTH_CONF"
    # Here rather than in the `up -d` that follows, because authelia-pre-start.sh
    # runs next and restarts Authelia with the new password: a server that has
    # not read the directive yet answers it `ERR Client sent AUTH, but no
    # password is set`. `up -d`, not `restart`, or the new mounts are not applied.
    if container_is_running "pi-redis"; then
        log "Applying the new Redis password before the consumers are restarted"
        compose up -d --no-deps redis >/dev/null 2>&1 || log "WARNING: could not recreate redis"
    fi
fi

# 0644, the one secret here that is not 0600: the valkey entrypoint re-execs the
# server under `setpriv --reuid=valkey --clear-groups` (uid 999), and this hook
# runs as root under systemd or as the project owner under `make update` -
# neither can hand a file to 999 without the other losing it. The 0700 directory
# is what protects it on the host; a bind-mounted file is reached by its own mode
# inside the container. The 0600 copy in $SECRETS_DIR stays authoritative.
safe_chmod 644 "$AUTH_CONF"
safe_chmod 700 "$AUTH_CONF_DIR"

# Both, or a root-run start leaves a directory the project owner cannot traverse
# and a password file it cannot re-render from.
fix_ownership "$AUTH_CONF_DIR"
fix_ownership "$PASSWORD_FILE"
