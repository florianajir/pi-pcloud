#!/bin/sh
# Pre-start: make sure Tuwunel's OIDC client secret exists as a *file* before
# the container binds it.
#
# Tuwunel checks the secret file at start and refuses to run without it
# (config/check.rs at v1.9.3), so a bind source Docker had to invent - an empty
# directory - would crash-loop the server. Its data lives in named volumes
# Docker creates itself, so there is no directory to prepare.
#
# A pre-start hook (scripts/run-hooks.sh). Idempotent.

set -eu

. "$(dirname "$0")/lib.sh"

main() {
    # Fatal on purpose, as for Trilium: better stopped here, with the reason,
    # than crash-looping after the start.
    ensure_authelia_oidc_materials tuwunel "Tuwunel" \
        || die "Could not prepare Tuwunel's OIDC client secret"

    log "Ensured Tuwunel OIDC materials"
}

main "$@"
