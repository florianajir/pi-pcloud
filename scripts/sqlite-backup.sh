#!/bin/sh
# Consistent point-in-time copies of the stack's live SQLite databases.
#
# Runs as a Backrest CONDITION_SNAPSHOT_START hook, the SQLite counterpart of
# db-backup.sh. Without it, restic copies kavita.db and its -wal at different
# instants while the service is mid-write, so the restored pair can disagree.
# `sqlite3 .backup` takes a proper read transaction instead: the copy it writes
# is a single consistent state with the WAL already applied.
#
# The sources stay mounted read-only. That works because the owning service
# holds the database open, so the -shm index already exists and SQLite can map
# it read-only. A WAL-mode database with no -shm (checkpointed and closed, like
# beszel's auxiliary.db) cannot be opened read-only at all, because SQLite would
# have to create the -shm; see the immutable=1 fallback below. Anything that
# still fails is logged and skipped, and restic ships the raw files as before.
#
# Everything here is small (~35 MB total) and dedupes well between snapshots.
# Deliberately NOT listed:
#   - lldap, open-webui, nextcloud, immich, vaultwarden, authelia - on Postgres
#     in this stack; db-backup.sh already dumps them. Their leftover .db files
#     are stale stubs and restoring one would be actively misleading.
#   - kavita/cache.db, prowlarr/logs.db, pihole-FTL.db - caches and logs the
#     service rebuilds by itself.
#   - pihole/gravity.db - 99.99% regenerable (670k downloaded block domains
#     against ~67 rows of actual configuration), so it gets a config-only SQL
#     dump instead; see GRAVITY_TABLES below.

set -eu

# The copies carry account tables and API keys; keep them out of group/other
# reach, like db-backup.sh's dumps.
umask 077

DEST="${SQLITE_BACKUP_DIR:-/userdata/sqlite-backups}"

# <name>:<source path>. The name is the output basename, so it must be unique.
DATABASES='
kavita:/userdata/kavita/kavita.db
n8n:/userdata/n8n/database.sqlite
ntfy-user:/userdata/ntfy/user.db
headscale:/userdata/headscale/db.sqlite
headplane:/userdata/headplane/hp_persist.db
beszel-data:/userdata/beszel/data.db
beszel-auxiliary:/userdata/beszel/auxiliary.db
uptime-kuma:/userdata/uptime-kuma/kuma.db
prowlarr:/userdata/prowlarr/prowlarr.db
kapowarr:/userdata/kapowarr-db/Kapowarr.db
shelfmark:/userdata/shelfmark/users.db
audiobookshelf:/userdata/audiobookshelf/absdatabase.sqlite
agentgateway:/userdata/agentgateway/agentgateway.db
trilium:/userdata/trilium/document.db
'

mkdir -p "$DEST"

failed=""
copied=0

# Word splitting on the list is the parse; no entry contains whitespace.
# shellcheck disable=SC2086
for entry in $DATABASES; do
    name="${entry%%:*}"
    src="${entry#*:}"

    # A service that is not in COMPOSE_PROFILES has no database. Not an error.
    if [ ! -f "$src" ]; then
        continue
    fi

    tmp="$DEST/.$name.db.tmp"
    rm -f "$tmp"

    # mode=ro so a bug here can never write to the service's live database,
    # and so the open succeeds against the read-only bind mount.
    if sqlite3 "file:$src?mode=ro" ".backup '$tmp'" 2>/dev/null; then
        :
    elif [ ! -e "$src-wal" ] && sqlite3 "file:$src?immutable=1" ".backup '$tmp'" 2>/dev/null; then
        # A WAL-mode database whose -wal is gone has been fully checkpointed,
        # so the main file alone IS the whole database and reading it without
        # locking is consistent. Only ever taken when -wal is absent: with one
        # present, immutable=1 would silently skip every uncommitted frame.
        :
    else
        rm -f "$tmp"
        failed="$failed $name"
        continue
    fi

    # Rename only after a clean copy: a snapshot that catches the partial write
    # would otherwise replace a good backup with a truncated one.
    mv "$tmp" "$DEST/$name.db"
    copied=$((copied + 1))
done

# --- Pi-hole gravity: configuration only ---
#
# gravity.db is 39 MB, but 670k of its rows are the block-list domains `pihole
# -g` re-downloads, and only ~67 are configuration: which lists are subscribed,
# the allow/deny entries, and the group/client assignments. Excluding the file
# and dumping those tables turns 39 MB of daily churn into 8 KB of SQL that
# also happens to be readable when you need to know what was configured.
#
# Restore with:  sqlite3 gravity.db < pihole-gravity-config.sql  (then pihole -g)
GRAVITY_DB="${GRAVITY_DB:-/userdata/pihole/gravity.db}"
GRAVITY_TABLES="adlist domainlist group client adlist_by_group domainlist_by_group client_by_group"

if [ -f "$GRAVITY_DB" ]; then
    tmp="$DEST/.pihole-gravity-config.sql.tmp"
    rm -f "$tmp"
    # shellcheck disable=SC2086
    if sqlite3 "file:$GRAVITY_DB?mode=ro" ".dump $GRAVITY_TABLES" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mv "$tmp" "$DEST/pihole-gravity-config.sql"
        copied=$((copied + 1))
    else
        rm -f "$tmp"
        failed="$failed pihole-gravity-config"
    fi
fi

echo "SQLite backups written to ${DEST}: ${copied} database(s)"

if [ -n "$failed" ]; then
    echo "WARNING: could not back up:${failed} (raw files are still in the snapshot)" >&2
    exit 1
fi
