#!/bin/sh
# Pre-start: make sure Tuwunel's OIDC client secret exists as a *file* before
# the container binds it.
#
# Tuwunel reads the secret at the first sign-in, not at start, so a bind source
# Docker had to invent - an empty directory - would leave the server healthy
# and fail the family's first login instead. Its data lives in named volumes
# Docker creates itself, so there is no directory to prepare.
#
# A pre-start hook (scripts/run-hooks.sh). Idempotent.

set -eu

. "$(dirname "$0")/lib.sh"

main() {
    # Fatal on purpose, as for Trilium: the alternative is the silent failure
    # described above.
    ensure_authelia_oidc_materials tuwunel "Tuwunel" \
        || die "Could not prepare Tuwunel's OIDC client secret"

    log "Ensured Tuwunel OIDC materials"
}

main "$@"
