#!/bin/sh
# Pre-start: create the data directory, and make sure Trilium's OIDC client
# secret exists as a *file* before the container binds it.
#
# `make enable` runs only `<service>-pre-start.sh`, and Trilium is the first
# OIDC client whose secret is written by no hook of its own - so without this
# the container starts first and Docker materialises the missing bind source as
# an empty directory. It still comes up healthy, because the secret is read
# only at sign-in.
#
# A pre-start hook (scripts/run-hooks.sh). Idempotent.

set -eu

. "$(dirname "$0")/lib.sh"

main() {
    local data_location=""

    data_location="$(resolve_data_location_path)"

    if [ ! -d "$data_location/trilium" ]; then
        mkdir -p "$data_location/trilium"
        # The container chowns this to uid 1000 at every start; this only keeps
        # it inspectable from the host in between.
        fix_ownership "$data_location/trilium"
    fi

    # Idempotent: a no-op once the secret and the client stanza both exist.
    #
    # Fatal on purpose. The alternative is the failure this script exists to
    # prevent: `export VAR="$(cat <missing>)"` exits 0, so the container starts
    # healthy and only reveals the empty secret at the next sign-in.
    ensure_authelia_oidc_materials trilium "Trilium" \
        || die "Could not prepare Trilium's OIDC client secret"

    log "Ensured Trilium data directory and OIDC materials"
}

main "$@"
