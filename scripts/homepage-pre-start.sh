#!/bin/sh
# Pre-start: the one path compose binds into pi-homepage that nothing else
# creates - HOMEPAGE_AUTH_SECRET, the key NextAuth signs its session cookie
# with. It has to exist before `docker compose up`: a bind source the daemon
# does not find becomes a *directory*, and the entrypoint's `cat` would hand
# homepage an empty secret, which it rejects at start.
#
# Not derived from PASSWORD and left alone by rotate-password.sh, like the OIDC
# client secrets and FreshRSS's OIDCCryptoPassphrase: a regenerated one only
# costs everyone a fresh sign-in. The OIDC client secret homepage also mounts
# comes from authelia-pre-start.sh, which runs first.
#
# A pre-start hook (scripts/run-hooks.sh). Idempotent.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

main() {
    data_dir="$(resolve_data_location_path)"
    secrets_dir="$data_dir/authelia-config/secrets"
    auth_secret="$secrets_dir/homepage_auth_secret"

    # authelia-pre-start.sh owns this directory and runs first, but this hook
    # can stand on its own - including the 0700, or a standalone run would leave
    # the Authelia secrets directory at the caller's umask.
    mkdir -p "$secrets_dir"
    safe_chmod 700 "$secrets_dir"

    # Before the -s test, not after: a directory has a non-zero size, so
    # `[ ! -s ]` is FALSE for one and the generate block would be skipped - the
    # hook logging success forever while homepage read an empty secret and 500'd
    # its auth stack. write_file_atomic refuses a directory, but never gets
    # called. Same removal headscale-pre-start.sh does for its own mounts.
    if [ -d "$auth_secret" ]; then
        log "WARNING: $auth_secret is a directory (Docker bind-mount artifact). Removing..."
        rm -rf "$auth_secret"
    fi

    # -s, not -f, like the hooks this is copied from: write_file_atomic stops
    # NEW empty files, but a zero-byte leftover from an interrupted run must be
    # regenerated, not accepted forever.
    if [ ! -s "$auth_secret" ]; then
        # `openssl rand -hex 32` - 64 chars, over NextAuth's 32 minimum.
        write_file_atomic "$auth_secret" generate_secret \
            || die "Failed to generate the Homepage auth secret"
        safe_chmod 600 "$auth_secret"
        log "Generated the Homepage auth secret"
    fi

    # Unconditional: the unit runs this as root, and a root-owned 0600 file is
    # one the next non-root `make update` cannot read (tests/stack-up-test.sh
    # enforces this).
    fix_ownership "$auth_secret"

    log "Ensured the Homepage auth secret"
}

main "$@"
