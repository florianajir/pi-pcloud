#!/bin/sh
# Copy the live .env into the backed-up tree, as a Backrest
# CONDITION_SNAPSHOT_START hook.
#
# Why a copy and not a bind mount of ./.env: a single-FILE bind mount pins the
# inode. Every writer in this repo replaces .env rather than rewriting it -
# services.sh's write_profiles and rotate-password.sh both use `sed -i`, which
# writes a temp file and renames, and most editors do the same. Neither
# recreates backrest, so the container would keep the pre-edit inode and every
# later snapshot would silently ship a stale .env. Reading it by name out of a
# read-only mount of the project directory picks up whatever is there now.
#
# It also removes a sharp edge: with ./.env bind-mounted as a file, a
# `docker compose up` run when .env is missing makes Docker create ./.env as a
# DIRECTORY, which then breaks every get_env_value in scripts/lib.sh.
#
# Two plans consume this copy: s3-backup, whose repository cannot be opened
# without BACKREST_S3_REPO_PASSWORD (a value inside the very file it stores),
# and usb-env, a local repository on the data disk that keeps its own password
# beside it precisely so this file can be recovered without the other one. See
# docs/BACKUP.md.

set -eu

# .env holds every secret in the stack.
umask 077

SRC="${ENV_SNAPSHOT_SRC:-/pi-web-src/.env}"
DEST_DIR="${ENV_SNAPSHOT_DIR:-/userdata/pi-web-env}"
DEST="$DEST_DIR/.env"

if [ ! -f "$SRC" ]; then
    echo "WARNING: $SRC not found; leaving the previous .env copy in place" >&2
    exit 1
fi

mkdir -p "$DEST_DIR"

# Write via a temp file in the same directory so a snapshot that starts
# mid-copy never sees a truncated .env.
tmp="$DEST_DIR/.env.tmp"
if cat "$SRC" > "$tmp"; then
    chmod 600 "$tmp"
    mv "$tmp" "$DEST"
    echo "Copied .env into the backup set ($DEST)"
else
    rm -f "$tmp"
    echo "ERROR: failed to copy $SRC to $DEST" >&2
    exit 1
fi
