#!/bin/sh
# Pre-start: let Nextcloud organise the media libraries it mounts, not just
# share them.
#
# Making those bind mounts read-write in compose/compose-cloud.yaml is necessary but not
# sufficient. Nextcloud's PHP runs as uid 33 (www-data) while everything under
# DATA_LOCATION belongs to uid/gid 1000 in mode 0755, so uid 33 would still get
# r-x and could not create, move or delete anything - the Files app would show
# a permission error on every attempt. compose/compose-cloud.yaml puts the container in gid
# 1000 via `group_add`; this hook is the other half, granting that gid write
# access to the tree.
#
# POSIX ACLs rather than `chmod -R g+w`, because a chmod does not survive. The
# services that fill these folders - qBittorrent, Kapowarr, Shelfmark - all run
# with umask 022, so every directory they create afterwards would come back
# 0755 and Nextcloud would silently lose access to exactly the new downloads it
# is most likely to be asked to tidy up. A *default* ACL is inherited by
# whatever is created later, umask notwithstanding, which is why it is set here
# instead of chasing a UMASK setting through four different images.
#
# `rwX`, not `rwx`, for the access entry: capital X grants execute on
# directories only, so files do not come out spuriously executable.
#
# A pre-start hook (scripts/stack-up.sh). Idempotent, and cheap enough to run
# every boot - the whole tree is a few hundred entries.

set -eu

. "$(dirname "$0")/lib.sh"

# The uid Nextcloud's PHP runs as: www-data in the official image, which is
# Debian's 33. If a future image moves it, Nextcloud keeps read access and the
# Files app starts refusing writes - visible, not silent.
NEXTCLOUD_UID="${NEXTCLOUD_UID:-33}"

# The roots behind the files_external mounts. download/ covers the books/ and
# audiobooks/ mounts, which are subdirectories of it.
MEDIA_DIRS="download comics manga"

main() {
    local data_location="" dir="" applied=0

    if ! command -v setfacl >/dev/null 2>&1; then
        log "WARNING: setfacl not found (install the 'acl' package); Nextcloud will be able to read the libraries but not reorganise them"
        return 0
    fi

    data_location="$(resolve_data_location_path)"

    for dir in $MEDIA_DIRS; do
        [ -d "$data_location/$dir" ] || continue
        if setfacl -R -m "d:u:${NEXTCLOUD_UID}:rwx" -m "u:${NEXTCLOUD_UID}:rwX" "$data_location/$dir" 2>/dev/null; then
            applied=$((applied + 1))
        else
            # Not fatal: a filesystem without ACL support, or a non-root run
            # over files this user does not own, leaves the tree readable.
            log "WARNING: could not set ACLs on $data_location/$dir; Nextcloud will not be able to reorganise it"
        fi
    done

    log "Granted uid $NEXTCLOUD_UID write access to $applied media director$([ "$applied" = "1" ] && echo y || echo ies) for Nextcloud"
}

main "$@"
