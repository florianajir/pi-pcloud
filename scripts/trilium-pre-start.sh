#!/bin/sh
# Pre-start: make sure Trilium's OIDC client secret exists as a *file* before
# the container binds it, and create the data directory.
#
# Without this, enabling Trilium on an already-installed host starts it before
# any hook has written the secret, and the Docker daemon materialises the
# missing bind source as an empty **directory**. The container still comes up
# healthy - Trilium only reads the secret when someone tries to sign in - so the
# failure is invisible until authelia-pre-start.sh later refuses to overwrite a
# directory with a file. `make enable` runs only `<service>-pre-start.sh`, and
# Trilium is the first OIDC client whose secret is written by nothing else:
# every other one has a hook of its own that happens to run first.
#
# A pre-start hook (scripts/run-hooks.sh). Idempotent.

set -eu

. "$(dirname "$0")/lib.sh"

main() {
    local data_location=""

    data_location="$(resolve_data_location_path)"

    if [ ! -d "$data_location/trilium" ]; then
        mkdir -p "$data_location/trilium"
        # The container chowns its data directory to uid 1000 on every start, so
        # this is only about keeping it inspectable from the host in between.
        fix_ownership "$data_location/trilium"
    fi

    # Idempotent: returns immediately once the secret file and the client stanza
    # both exist, and otherwise runs authelia-pre-start.sh to mint them.
    ensure_authelia_oidc_materials trilium "Trilium" || {
        log "WARNING: could not prepare Trilium OIDC materials; SSO will not be offered"
        return 0
    }

    log "Ensured Trilium data directory and OIDC materials"
}

main "$@"
