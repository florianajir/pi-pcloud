#!/bin/sh
# Generates the shared Redis password and renders the one config directive that
# carries it.
#
# The instance holds Authelia's session store (database 1) alongside Immich's and
# Nextcloud's caches, and until this hook existed it ran with no authentication
# at all - `user default on nopass ~* &* +@all` - so every container that could
# open redis:6379 could read or forge an SSO session. That was seven of them, all
# core services, which is why it was a latent hole rather than a live one; it is
# also what made the cache impossible to extend to anything less trusted.
#
# The password is generated, not PASSWORD: nothing here has to type it, every
# consumer reads it from a file, and rotate-password.sh then has no four-service
# restart to sequence. `sh scripts/rotate-secret.sh redis-auth` owns rotating it.
#
# requirepass cannot live in config/redis/valkey.conf, which is a versioned file
# mounted read-only, so that file ends with `include` and this hook renders the
# included half. Valkey refuses to start when an included file is missing - so
# this is a blocking pre-start hook (scripts/run-hooks.sh), and a failure here
# stops the boot with a diagnosis instead of a redis that never comes up.
#
# A pre-start hook. Idempotent.

set -eu

. "$(dirname "$0")/lib.sh"

# Beside the Authelia secrets rather than under a redis/ of its own: Authelia
# reads it through `{{ secret "/config/secrets/redis_password" }}`, and that is
# the only directory it mounts. vaultwarden_admin_token lives here for the same
# reason - the directory is the stack's secret store, not Authelia's alone.
SECRETS_DIR="$(resolve_data_location_path)/authelia-config/secrets"
PASSWORD_FILE="$SECRETS_DIR/redis_password"
AUTH_CONF_DIR="$(resolve_data_location_path)/redis"
AUTH_CONF="$AUTH_CONF_DIR/redis-auth.conf"

mkdir -p "$SECRETS_DIR" "$AUTH_CONF_DIR"
safe_chmod 700 "$SECRETS_DIR"

# -s, not -f: a zero-byte leftover would be accepted forever, and every client
# would then authenticate with an empty string against a server expecting one.
if [ ! -s "$PASSWORD_FILE" ]; then
    write_file_atomic "$PASSWORD_FILE" generate_secret \
        || die "Failed to generate the Redis password"
    safe_chmod 600 "$PASSWORD_FILE"
    log "Generated the Redis password"
fi

# Rendered every run rather than only when missing, so a hand-edited or
# half-written file is repaired before valkey reads it. generate_secret produces
# hex, so the value needs no quoting to be a valid directive argument.
REDIS_PASSWORD="$(cat "$PASSWORD_FILE")"
[ -n "$REDIS_PASSWORD" ] || die "$PASSWORD_FILE is empty"

# No trailing newline in the comparison value: `$(cat ...)` strips one, so
# building it with the newline would make every run see a difference.
RENDERED="requirepass $REDIS_PASSWORD"
if [ "$(cat "$AUTH_CONF" 2>/dev/null || true)" != "$RENDERED" ]; then
    printf '%s\n' "$RENDERED" | write_secret_file "$AUTH_CONF" \
        || die "Failed to render $AUTH_CONF"
    log "Rendered the Redis auth directive to $AUTH_CONF"
    # Same reason authelia-pre-start.sh restarts Authelia when it re-renders
    # configuration.yml, and it has to happen here rather than in the `up -d`
    # that follows: the Authelia hook runs next, and it restarts Authelia with
    # the new password. A server that has not read the directive yet answers
    # that client `ERR Client sent AUTH, but no password is set`, so every
    # session lookup fails until the stack-wide `up -d` gets to redis.
    #
    # `up -d`, not `restart`: on the release that introduces this, the service
    # definition gains the two mounts below, and a restart would not apply them.
    if container_is_running "pi-redis"; then
        log "Applying the new Redis password before the consumers are restarted"
        compose up -d redis >/dev/null 2>&1 || log "WARNING: could not recreate redis"
    fi
fi

# 0644 on the file, 0700 on the directory around it - the one place in this
# stack where a secret is not 0600, and the reason is the image. The valkey
# entrypoint re-execs the server under `setpriv --reuid=valkey --clear-groups`
# (uid 999), so the server reads its own config as an unprivileged user that
# this hook cannot chown to: the hook has to work both as root under systemd and
# as the project owner under `make update`, and neither can hand a file to 999
# without the other losing it. A bind-mounted file is reached by its own mode
# inside the container, while the host still has to traverse the directory - so
# the directory is what carries the protection here, as it already does for the
# Authelia secrets under a 0777 DATA_LOCATION.
#
# The authoritative copy in $SECRETS_DIR stays 0600: only root and the project
# owner ever read that one, and it is what backrest snapshots.
safe_chmod 644 "$AUTH_CONF"
safe_chmod 700 "$AUTH_CONF_DIR"

# Both, or a root-run systemd start leaves a directory the project owner cannot
# traverse on the next non-root `make update`, and a password file immich and
# nextcloud read through a bind mount cannot be re-rendered from.
fix_ownership "$AUTH_CONF_DIR"
fix_ownership "$PASSWORD_FILE"
