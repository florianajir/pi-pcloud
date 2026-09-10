#!/bin/sh
# Pre-start: the two paths compose binds into pi-freshrss that nothing else
# creates - the data directory, and the OIDCCryptoPassphrase.
#
# Both have to exist before `docker compose up`: a bind source the daemon does
# not find is created as an empty *directory*, and Apache would then read the
# passphrase file as one and refuse to start.
#
# The passphrase is deliberately not derived from PASSWORD and is left alone by
# rotate-password.sh, like the OIDC client secrets and the Vaultwarden admin
# token. mod_auth_openidc uses it to encrypt its session cookie and its cache,
# so all a regenerated one costs is that everyone signs in again - there is no
# reason to couple it to the SSO password.
#
# A pre-start hook (scripts/run-hooks.sh). Idempotent.

set -eu

. "$(dirname "$0")/lib.sh"

# Create $1 if missing and hand it to the project owner, so the data directory
# stays inspectable without sudo. Only what this run created is chowned, and
# that matters more here than in the hooks this is copied from: FreshRSS's own
# entrypoint runs cli/access-permissions.sh, which leaves the tree root:www-data
# with the cache and per-user directories at 0770. An unconditional
# fix_ownership (chown -R to uid/gid 1000) would take the *group* off those and
# lock Apache's uid 33 out of its own cache - and because `up -d` does not
# recreate an unchanged container, nothing would repair it until the next image
# bump. A directory we just made is empty, so walking it is free.
ensure_dir() {
    [ -d "$1" ] && return 0
    mkdir -p "$1"
    fix_ownership "$1"
}

main() {
    data_dir="$(resolve_data_location_path)"
    secrets_dir="$data_dir/authelia-config/secrets"
    crypto_key="$secrets_dir/freshrss_oidc_crypto_key"

    # authelia-pre-start.sh owns this directory and runs first, but this hook is
    # gated on the freshrss profile and that one is not, so it can also be run
    # on its own.
    mkdir -p "$secrets_dir"
    ensure_dir "$data_dir/freshrss"
    # Where the db-backup.sh hook drops its pg_dump; backrest binds it writable
    # and would otherwise have the daemon create it as root.
    ensure_dir "$data_dir/freshrss/backups"

    if [ ! -s "$crypto_key" ]; then
        write_file_atomic "$crypto_key" generate_secret \
            || die "Failed to generate the FreshRSS OIDC crypto passphrase"
        safe_chmod 600 "$crypto_key"
        log "Generated the FreshRSS OIDC crypto passphrase"
    fi

    # Unconditional on the passphrase, unlike the directories above: the unit
    # runs this as root, and a root-owned 0600 file is one the next non-root
    # `make update` cannot read (tests/stack-up-test.sh enforces this). It is a
    # single file this hook alone writes, so nothing in the container has an
    # opinion about who owns it.
    fix_ownership "$crypto_key"

    log "Ensured FreshRSS directories and OIDC crypto passphrase"
}

main "$@"
