#!/bin/sh
# Pre-start: ensure the download folders Kavita reads as libraries exist.
# Kavita mounts them read-only, and Docker creates a missing bind source as
# root:root - which Kavita could still read, but qBittorrent (PUID 1000) could no
# longer write the matching category into. Create them up front and hand them to the
# project owner. Idempotent. comics/ and manga/ - the top-level ones, not the
# download/ ones below - are Kapowarr root folders and belong to kapowarr-pre-start.sh.
# A pre-start hook (scripts/stack-up.sh), so it runs before docker compose up.

set -eu

. "$(dirname "$0")/lib.sh"

main() {
    local data_location dir

    data_location="$(resolve_data_location_path)"

    # Both levels, not just the leaf: mkdir -p creates download/ too, and under
    # systemd this runs as root. Leaving download/ root-owned would stop
    # qBittorrent (PUID 1000) creating any *other* category folder under it -
    # exactly the failure this hook exists to prevent, one level up.
    #
    # Only chown what this run created: fix_ownership is chown -R, and by the
    # time these exist they hold the whole download tree, which is far too much
    # to walk on every boot. A directory we just made is empty, so it is free.
    for dir in "$data_location/download" \
               "$data_location/download/manga" \
               "$data_location/download/comics" \
               "$data_location/download/books" \
               "$data_location/download/magazines"; do
        [ -d "$dir" ] && continue
        mkdir -p "$dir"
        fix_ownership "$dir"
    done

    log "Ensured Kavita download library directories"
}

main "$@"
