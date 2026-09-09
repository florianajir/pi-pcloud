#!/bin/sh
set -eu

# Generates the Vaultwarden /admin credential: a random token plus the Argon2id
# PHC digest that is all the container ever sees.
#
# Vaultwarden accepts a plaintext ADMIN_TOKEN but logs a NOTICE about it on every
# start, and wants a PHC string instead. Hashing has to happen out here because
# neither tool that can produce one takes the secret on stdin: `vaultwarden hash`
# reads from /dev/tty, and Authelia's CLI requires --password on argv.
#
# The token is deliberately NOT derived from PASSWORD. /admin sits behind the LAN
# allowlist with no Authelia forward-auth in front of it, so reusing the SSO
# password would turn a PASSWORD leak into an admin-panel compromise. Like the
# OIDC client secrets and the ntfy passwords, rotate-password.sh leaves it alone.

. "$(dirname "$0")/lib.sh"

# Only used to borrow its `crypto hash` CLI; keep in step with compose.yaml.
AUTHELIA_IMAGE="${AUTHELIA_IMAGE:-authelia/authelia:4.39.20}"

DATA_DIR="$(resolve_data_location_path)"
SECRETS_DIR="$DATA_DIR/authelia-config/secrets"
TOKEN_FILE="$SECRETS_DIR/vaultwarden_admin_token"
HASH_FILE="$SECRETS_DIR/vaultwarden_admin_token_hash"

# The token lands in the container's argv for as long as the hash takes (~1s).
# That is unavoidable with this CLI, and acceptable only because the value is a
# freshly generated per-service token rather than PASSWORD.
hash_argon2() {
    docker run --rm --entrypoint authelia "$AUTHELIA_IMAGE" \
        crypto hash generate argon2 --no-confirm --password "$1" 2>/dev/null |
        sed -n 's/^Digest: //p'
}

mkdir -p "$SECRETS_DIR"

# A regenerated token invalidates any existing digest, so the two are kept in
# step here rather than each being tested for existence independently.
_token_is_new=0
if [ ! -s "$TOKEN_FILE" ]; then
    generate_secret >"$TOKEN_FILE"
    safe_chmod 600 "$TOKEN_FILE"
    _token_is_new=1
    log "Generated Vaultwarden admin token"
fi

if [ ! -s "$HASH_FILE" ] || [ "$_token_is_new" = "1" ]; then
    _token="$(cat "$TOKEN_FILE")"
    [ -n "$_token" ] || die "Vaultwarden admin token file is empty: $TOKEN_FILE"

    _digest="$(hash_argon2 "$_token")"
    case "$_digest" in
        '$argon2id$'*) ;;
        *) die "Could not generate an Argon2id digest for the Vaultwarden admin token (is $AUTHELIA_IMAGE pullable?)" ;;
    esac

    printf '%s\n' "$_digest" >"$HASH_FILE"
    safe_chmod 600 "$HASH_FILE"
    log "Generated Vaultwarden admin token hash"
fi

# Both files, every run: authelia-pre-start.sh sweeps this directory with the
# same call, but it runs *before* this hook - so a token written here by a root
# boot stayed root-owned until the next one, and `rotate-secret.sh vaultwarden`
# could only read it with sudo in between.
fix_ownership "$TOKEN_FILE"
fix_ownership "$HASH_FILE"
