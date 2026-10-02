#!/bin/sh
# Pre-start: make sure Tuwunel's two secret files exist as *files* before the
# container binds them.
#
# Tuwunel checks the OIDC secret file at start and refuses to run without it
# (config/check.rs at v1.9.3), so a bind source Docker had to invent - an empty
# directory - would crash-loop the server. Its data lives in named volumes
# Docker creates itself, so there is no directory to prepare.
#
# The registration shared secret enables /_synapse/admin/v1/register, the
# HMAC-signed endpoint scripts/openclaw-bootstrap.py creates the assistant's
# account through. Password registration stays off: that endpoint bypasses it,
# and Traefik routes no /_synapse path, so only a container on one of
# Tuwunel's networks can reach it at all. Generated here rather than by the
# OpenClaw hook because it is Tuwunel's secret - it exists whether or not the
# assistant is enabled, and holding it is equivalent to holding an admin token.
#
# A pre-start hook (scripts/run-hooks.sh). Idempotent.

set -eu

. "$(dirname "$0")/lib.sh"

ensure_registration_shared_secret() {
    local secret_dir="" secret_file=""

    secret_dir="$(resolve_data_location_path)/tuwunel-secrets"
    secret_file="$secret_dir/registration_shared_secret"

    mkdir -p "$secret_dir"
    safe_chmod 700 "$secret_dir"
    ensure_config_target_is_file "$secret_file" \
        || die "Could not restore $secret_file as a file"
    if [ ! -s "$secret_file" ]; then
        generate_secret | write_secret_file "$secret_file" \
            || die "Failed to generate Tuwunel's registration shared secret"
        log "Generated Tuwunel's registration shared secret"
    fi
    safe_chmod 600 "$secret_file"
    fix_ownership "$secret_dir"
}

main() {
    # Fatal on purpose, as for Trilium: better stopped here, with the reason,
    # than crash-looping after the start.
    ensure_authelia_oidc_materials tuwunel "Tuwunel" \
        || die "Could not prepare Tuwunel's OIDC client secret"
    ensure_registration_shared_secret

    log "Ensured Tuwunel OIDC materials and registration shared secret"
}

main "$@"
