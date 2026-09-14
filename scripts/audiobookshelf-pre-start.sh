#!/bin/sh
# Pre-start: create the directories Audiobookshelf binds, and make sure the
# audiobook library is writable by the service that fills it.
#
# Audiobookshelf itself runs as root and would be happy with whatever the Docker
# daemon creates. The reason this hook exists is the folder it shares with
# Shelfmark - see repair_handoff_ownership below.
#
# A pre-start hook (scripts/stack-up.sh). Idempotent.

set -eu

. "$(dirname "$0")/lib.sh"

# Create $1 if missing and hand it to the project owner, so the data directory
# stays inspectable without sudo. Only what this run created is chowned:
# fix_ownership is chown -R, and a directory we just made is empty, so walking it
# is free.
ensure_dir() {
    [ -d "$1" ] && return 0
    mkdir -p "$1"
    fix_ownership "$1"
}

# The uid/gid the services writing here actually run as: every PUID/PGID in
# compose/compose-media.yaml is 1000. Deliberately not fix_ownership's "whoever owns the
# project directory" - that exists so generated files stay readable to the
# person running the stack, which is a different question from who must be able
# to *write* into a handoff folder. On the usual install both are 1000; where
# they are not, chowning to the project owner logs success while Shelfmark
# still cannot write.
WRITER_UID="${WRITER_UID:-1000}"
WRITER_GID="${WRITER_GID:-1000}"

# download/audiobooks is a handoff, not a private directory: Shelfmark writes
# into it (DESTINATION_AUDIOBOOK) and Audiobookshelf reads it. Where the other
# download folders are created by qBittorrent from inside its own container,
# this one has no writer until a download completes - so on a stack that ran
# Shelfmark before this hook existed, the Docker daemon created it as root:root
# and Shelfmark has silently been unable to file anything there. Repair that,
# but only the directory itself: its contents are audio files whose ownership
# is not ours to rewrite.
repair_handoff_ownership() {
    local dir="$1" current=""

    [ -d "$dir" ] || return 0

    current="$(stat -c '%u:%g' "$dir" 2>/dev/null || echo unknown)"
    [ "$current" = "${WRITER_UID}:${WRITER_GID}" ] && return 0
    # Only ever take a directory away from root. One deliberately handed to
    # another account is not ours to reassign.
    [ "$current" = "0:0" ] || return 0

    if chown "${WRITER_UID}:${WRITER_GID}" "$dir" 2>/dev/null; then
        log "Handed $dir to ${WRITER_UID}:${WRITER_GID} (it was root-owned, so Shelfmark could not write into it)"
    else
        log "WARNING: $dir is root-owned and could not be chowned (needs root); Shelfmark cannot file audiobooks there"
    fi
}

main() {
    local data_location=""

    data_location="$(resolve_data_location_path)"

    ensure_dir "$data_location/audiobookshelf"
    ensure_dir "$data_location/audiobookshelf/config"
    ensure_dir "$data_location/audiobookshelf/metadata"
    # Both levels: mkdir -p would create download/ as root too under systemd.
    ensure_dir "$data_location/download"
    ensure_dir "$data_location/download/audiobooks"
    repair_handoff_ownership "$data_location/download/audiobooks"

    log "Ensured Audiobookshelf directories"
}

main "$@"
