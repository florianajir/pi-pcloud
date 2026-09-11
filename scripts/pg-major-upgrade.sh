#!/bin/sh
# Migrate the shared Postgres cluster to a new major version, by dump/restore.
#
# One step of the procedure in docs/POSTGRES-UPGRADE.md, which covers the
# pre-flight checks, the Backrest client bump this needs alongside it, and the
# post-cutover verification. Read that first.
#
# Usage: pg-major-upgrade.sh --to <image> [--apply] [--keep-dumps] [--rehearse]
#   --to <image>   target image, e.g.
#                  ghcr.io/immich-app/postgres:18-vectorchord1.1.1@sha256:...
#   --apply        rewrite compose.yaml's postgres image and data mount on
#                  success (otherwise the two edits are printed for review)
#   --keep-dumps   do not delete the dump directory afterwards
#   --rehearse     dry-run against the live cluster: dump and restore for real
#                  (dumps into DATA_LOCATION and the scratch cluster into
#                  POSTGRES_DATA_LOCATION, so point both at scratch space via a
#                  scratch ENV_FILE), but stop NOTHING — no service, not
#                  Postgres itself — and refuse --apply. The verification is
#                  identical; only the outage is missing.
#
# Why dump/restore rather than pg_upgrade: the immich-app/postgres image ships
# exactly one major's binaries, so pg_upgrade (which needs both) would require
# a custom image carrying two Postgres builds plus VectorChord. A dump/restore
# also rebuilds the vchord indexes at the new extension version, which is what
# Immich's docs otherwise ask you to do by hand after any vchord change.
#
# Only the Postgres-backed services are stopped for the migration window; the
# DNS/VPN path (pihole, unbound, headscale, tailscale) keeps running, so
# tailnet devices never lose name resolution or connectivity.
#
# The old data directory is never touched: the new major initialises a fresh
# one, so rollback is reverting the two compose lines. From Postgres 18 the
# upstream image stores data under /var/lib/postgresql/<major>/docker instead
# of /var/lib/postgresql/data and refuses to start with anything mounted at
# the latter, so the mount point moves with the version.

set -eu

. "$(dirname "$0")/lib.sh"

PG_CONTAINER="${PG_CONTAINER:-pi-postgres}"
TARGET_IMAGE=""
APPLY=0
KEEP_DUMPS=0
REHEARSE=0

# Every database in the cluster, and the role that owns it (same name here).
DATABASES="immich nextcloud authelia lldap open-webui vaultwarden freshrss"

# The containers that hold connections into those databases, plus backrest
# (whose scheduled db-backup.sh hooks would fire pg_dump against a stopped
# server mid-migration). ONLY these are stopped: the DNS/VPN path — pihole,
# unbound, headscale, tailscale, gluetun, traefik — uses no Postgres at all
# (headscale is SQLite), so devices on the tailnet keep resolving and routing
# through the whole cutover. The one visible effect of authelia being down is
# that SSO logins fail for the duration; established sessions and the network
# itself are untouched.
WRITER_CONTAINERS="pi-immich pi-immich-machine-learning pi-nextcloud pi-authelia pi-lldap pi-open-webui pi-vaultwarden pi-freshrss pi-backrest"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --to) TARGET_IMAGE="${2:-}"; shift 2 ;;
        --apply) APPLY=1; shift ;;
        --keep-dumps) KEEP_DUMPS=1; shift ;;
        --rehearse) REHEARSE=1; shift ;;
        *) die "unknown argument: $1 (see the header for usage)" ;;
    esac
done

[ -n "$TARGET_IMAGE" ] || die "--to <image> is required"
if [ "$REHEARSE" = "1" ]; then
    [ "$APPLY" = "0" ] || die "--rehearse and --apply are contradictory: a rehearsal must not edit compose.yaml"
    log "REHEARSAL: nothing will be stopped; the live cluster is only read"
fi
command -v jq >/dev/null 2>&1 || die "jq is required"

major_of() {
    # 18 out of ".../postgres:18-vectorchord1.1.1@sha256:..."
    printf '%s' "$1" | sed -n 's|.*:\([0-9][0-9]*\)[-@].*|\1|p;s|.*:\([0-9][0-9]*\)$|\1|p' | head -n1
}

TARGET_MAJOR="$(major_of "$TARGET_IMAGE")"
[ -n "$TARGET_MAJOR" ] || die "could not read a major version out of '$TARGET_IMAGE'"

container_is_running "$PG_CONTAINER" \
    || die "$PG_CONTAINER is not running; the dump has to come from the live cluster"

CURRENT_MAJOR="$(docker exec "$PG_CONTAINER" psql -U postgres -Atc 'SHOW server_version;' | cut -d. -f1)"
log "cluster is on Postgres $CURRENT_MAJOR, target is $TARGET_MAJOR"
[ "$CURRENT_MAJOR" != "$TARGET_MAJOR" ] || { log "already on $TARGET_MAJOR, nothing to do"; exit 0; }
[ "$TARGET_MAJOR" -gt "$CURRENT_MAJOR" ] || die "refusing to move backwards ($CURRENT_MAJOR -> $TARGET_MAJOR)"

DATA_LOCATION="$(resolve_data_location_path)"
# Where the clusters themselves live, which is POSTGRES_DATA_LOCATION when set
# and DATA_LOCATION otherwise. The dumps stay on DATA_LOCATION: they are
# transient, roughly cluster-sized, and that root is the one sized for bulk.
PG_DATA_ROOT="$(resolve_postgres_data_location_path)"
# The pre-18 layout had no major in the path; from 18 it does. Naming the
# wrong directory here would send a rollback at the next major (18 -> 19) to a
# stale cluster, or to one that does not exist.
if [ -d "$PG_DATA_ROOT/postgres$CURRENT_MAJOR" ]; then
    OLD_DIR="$PG_DATA_ROOT/postgres$CURRENT_MAJOR"
else
    OLD_DIR="$PG_DATA_ROOT/postgres"
fi
NEW_DIR="$PG_DATA_ROOT/postgres$TARGET_MAJOR"
DUMP_DIR="$DATA_LOCATION/postgres-upgrade-$CURRENT_MAJOR-to-$TARGET_MAJOR"

[ ! -d "$NEW_DIR" ] || die "$NEW_DIR already exists; move it aside or finish the previous attempt"

PASSWORD="$(get_env_value PASSWORD)"
[ -n "$PASSWORD" ] || die "PASSWORD is not set in .env"

# Space: the dumps are roughly the cluster size, and the new cluster another
# copy. Those are two different filesystems as soon as POSTGRES_DATA_LOCATION
# points off DATA_LOCATION, so only the same-filesystem case has to hold all 3x.
# Split, each root still asks 2x for the one copy that lands on it: plain-SQL
# dumps are not reliably smaller than the cluster (no indexes, but every value
# is text), and the restored cluster is not reliably the size of the source.
# df needs an existing path, and PG_DATA_ROOT may not have been created yet.
existing_ancestor() {
    local dir="$1"
    while [ -n "$dir" ] && [ "$dir" != "/" ] && [ ! -d "$dir" ]; do
        dir="$(dirname "$dir")"
    done
    printf '%s' "${dir:-/}"
}
free_kb_at() {
    df -Pk "$(existing_ancestor "$1")" | awk 'NR==2 {print $4}'
}
same_filesystem() {
    [ "$(df -Pk "$(existing_ancestor "$1")" | awk 'NR==2 {print $1}')" \
      = "$(df -Pk "$(existing_ancestor "$2")" | awk 'NR==2 {print $1}')" ]
}

cluster_kb="$(docker exec "$PG_CONTAINER" psql -U postgres -Atc \
    "SELECT ceil(sum(pg_database_size(datname))/1024) FROM pg_database WHERE NOT datistemplate;")"
log "cluster is $((cluster_kb / 1024))MB"

check_space() {
    local label="$1" dir="$2" multiple="$3" free_kb need_kb
    free_kb="$(free_kb_at "$dir")"
    need_kb=$((cluster_kb * multiple))
    log "$label $dir: free $((free_kb / 1024))MB, want $((need_kb / 1024))MB"
    [ "$free_kb" -gt "$need_kb" ] || die "not enough free space at $dir"
}

if same_filesystem "$DATA_LOCATION" "$PG_DATA_ROOT"; then
    check_space "dumps + new cluster" "$DATA_LOCATION" 3
else
    check_space "dumps" "$DATA_LOCATION" 2
    check_space "new cluster" "$PG_DATA_ROOT" 2
fi

log "pulling $TARGET_IMAGE"
docker pull -q "$TARGET_IMAGE" >/dev/null || die "could not pull $TARGET_IMAGE"

mkdir -p "$DUMP_DIR"
safe_chmod 700 "$DUMP_DIR"

# --- Quiesce ---------------------------------------------------------------
# Writers stop BEFORE the dump, not after: everything a service wrote between
# the dump and the old `compose down` used to be silently absent from the new
# cluster. With the writers stopped first, the dump is the complete final
# state. `|| true` per container: a service the operator disabled is already
# absent, and that must not abort the migration.
if [ "$REHEARSE" = "1" ]; then
    log "REHEARSAL: leaving every service running (writes during the dump stay in the live cluster only)"
else
    log "stopping the services that write to Postgres (DNS/VPN keep running)"
    for c in $WRITER_CONTAINERS; do
        docker stop "$c" >/dev/null 2>&1 || true
    done
fi

# --- Dump, from the live cluster -----------------------------------------
log "dumping roles"
docker exec "$PG_CONTAINER" pg_dumpall -U postgres --roles-only > "$DUMP_DIR/roles.sql"
[ -s "$DUMP_DIR/roles.sql" ] || die "role dump is empty"

for db in $DATABASES; do
    log "dumping $db"
    docker exec -e PGPASSWORD="$PASSWORD" "$PG_CONTAINER" \
        pg_dump -U "$db" -d "$db" > "$DUMP_DIR/$db.sql" \
        || die "pg_dump of $db failed"
    [ -s "$DUMP_DIR/$db.sql" ] || die "dump of $db is empty"
done

# Row counts to compare after the restore.
#
# Exact count(*) for every table, not pg_stat_user_tables.n_live_tup: that
# column is an estimate the stats collector only refreshes on (auto)analyze,
# and a table too small to trip the autovacuum threshold can carry a figure
# that was never right. On this stack lldap.groups read 0 against 4 real rows
# and lldap.users read 2 against 5, with last_analyze and last_autoanalyze both
# NULL. A freshly restored cluster, by contrast, has accurate counts because
# the collector just watched every INSERT — so estimate-vs-exact compared as if
# they were the same thing, and reported a clean migration as data loss.
#
# Sampling the top N by that estimate compounded it: the two sides then chose
# *different sets of tables*, which surfaced as "table absent after" for a
# table that was present and correct. Counting everything also catches a table
# that failed to restore at all, which a top-N sample can miss entirely.
count_all_tables() {
    _container="$1"
    _db="$2"
    _sql="$(docker exec "$_container" psql -U postgres -d "$_db" -Atc "
        SELECT coalesce(string_agg(
            format('SELECT %L || ''|'' || %L || ''|'' || (SELECT count(*) FROM %I.%I)',
                   '$_db', relname, schemaname, relname),
            ' UNION ALL '), '')
        FROM pg_stat_user_tables;")" || return 1
    [ -n "$_sql" ] || return 0
    docker exec "$_container" psql -U postgres -d "$_db" -Atc "$_sql" || return 1
}

log "counting rows in every table (exact, not estimated)"
: > "$DUMP_DIR/counts.before"
for db in $DATABASES; do
    count_all_tables "$PG_CONTAINER" "$db" >> "$DUMP_DIR/counts.before" \
        || die "could not count the tables in $db"
done
sort -o "$DUMP_DIR/counts.before" "$DUMP_DIR/counts.before"
log "$(wc -l < "$DUMP_DIR/counts.before") tables counted"

# --- Swap ----------------------------------------------------------------
# Only Postgres itself; the writers are already stopped and everything else
# never touches it. Never in a rehearsal: stopping the live server is the one
# way a dry run can cause a real outage.
if [ "$REHEARSE" = "0" ]; then
    log "stopping $PG_CONTAINER"
    docker stop "$PG_CONTAINER" >/dev/null 2>&1 || true
fi

log "starting Postgres $TARGET_MAJOR on $NEW_DIR"
mkdir -p "$NEW_DIR"
docker rm -f pg-upgrade-target >/dev/null 2>&1 || true
docker run -d --name pg-upgrade-target \
    -e POSTGRES_PASSWORD="$PASSWORD" \
    -e POSTGRES_INITDB_ARGS=--data-checksums \
    -v "$NEW_DIR:/var/lib/postgresql" \
    --shm-size 256mb "$TARGET_IMAGE" >/dev/null

cleanup_target() { docker rm -f pg-upgrade-target >/dev/null 2>&1 || true; }
trap cleanup_target EXIT INT TERM

wait_for_cmd 60 2 docker exec pg-upgrade-target pg_isready -U postgres \
    || die "Postgres $TARGET_MAJOR did not come up; see: docker logs pg-upgrade-target"

target_psql() { docker exec -i pg-upgrade-target psql -U postgres -q -v ON_ERROR_STOP=1 "$@"; }

# --- Restore -------------------------------------------------------------
# The bootstrap superuser already exists in a fresh cluster, and its CREATE
# ROLE line would abort the script under ON_ERROR_STOP, silently skipping
# every role sorted after it.
log "restoring roles"
grep -vE '^(CREATE|ALTER) ROLE postgres[; ]' "$DUMP_DIR/roles.sql" | target_psql \
    || die "role restore failed"

for db in $DATABASES; do
    log "restoring $db"
    target_psql -c "CREATE DATABASE \"$db\" OWNER \"$db\";" || die "could not create $db"
    docker exec -i pg-upgrade-target psql -U postgres -d "$db" -q -v ON_ERROR_STOP=1 \
        < "$DUMP_DIR/$db.sql" || die "restore of $db failed"
done

# pgvecto.rs is gone from the 18+ images; the immich database carries it in a
# per-database search_path that would now point at a missing schema.
docker exec pg-upgrade-target psql -U postgres -q \
    -c "ALTER DATABASE immich RESET search_path;" >/dev/null 2>&1 || true

# --- Analyze -------------------------------------------------------------
# Per database: a bare `ANALYZE` analyzes only the database psql connected to,
# so the six restored ones were left with no planner statistics at all and the
# first queries after a cutover ran on default estimates until autovacuum
# caught up. On immich that is the difference between an index scan and a
# sequential scan over 227k rows.
for db in $DATABASES; do
    log "analyzing $db"
    docker exec pg-upgrade-target psql -U postgres -d "$db" -q -c 'ANALYZE;' \
        >/dev/null 2>&1 || log "warning: ANALYZE of $db failed (planner stats only, data is fine)"
done

# --- Verify --------------------------------------------------------------
log "verifying row counts"
: > "$DUMP_DIR/counts.after"
for db in $DATABASES; do
    count_all_tables pg-upgrade-target "$db" >> "$DUMP_DIR/counts.after" \
        || die "could not count the tables in the restored $db"
done
sort -o "$DUMP_DIR/counts.after" "$DUMP_DIR/counts.after"

# Whole-file compare, so a table that exists on one side only is a mismatch
# too, not something a per-row lookup can skip over.
if ! counts_diff="$(diff "$DUMP_DIR/counts.before" "$DUMP_DIR/counts.after")"; then
    log "row counts differ (< before, > after):"
    printf '%s\n' "$counts_diff" | head -n 40 >&2
    die "$NEW_DIR is suspect. The old cluster at $OLD_DIR is untouched: leave compose.yaml as it is and 'make start' to bring the stopped services back on it."
fi
log "row counts match exactly: $(wc -l < "$DUMP_DIR/counts.after") tables across $(printf '%s' "$DATABASES" | wc -w) databases"

docker stop pg-upgrade-target >/dev/null
cleanup_target
trap - EXIT INT TERM

# --- Compose ------------------------------------------------------------
if [ "$REHEARSE" = "1" ]; then
    if [ "$KEEP_DUMPS" = "1" ]; then
        log "dumps kept at $DUMP_DIR"
    else
        log "removing $DUMP_DIR (pass --keep-dumps to retain it)"
        rm -rf "$DUMP_DIR"
    fi
    log "REHEARSAL complete: the migration verified end to end, nothing was stopped or edited."
    log "The migrated scratch cluster is at $NEW_DIR - remove it before the real run."
    exit 0
fi

old_image_line="$(grep -n 'image: ghcr.io/immich-app/postgres:' compose.yaml | head -n1)"
[ -n "$old_image_line" ] || die "could not find the postgres image line in compose.yaml"

# Only the tail is matched, so the substitution survives whatever interpolation
# prefixes the host path - today ${POSTGRES_DATA_LOCATION:-${DATA_LOCATION:-./data}},
# which the older ${DATA_LOCATION:-./data} pattern silently no longer matched.
# A silent miss here is the worst outcome available: compose would still point
# at the old major's directory, and `make start` would initialise an empty
# cluster over the top of a migration that had just succeeded.
PG_VOLUME_RE='/postgres[0-9]*:/var/lib/postgresql\(/data\)\{0,1\}$'

if [ "$APPLY" = "1" ]; then
    log "rewriting compose.yaml"
    grep -q "$PG_VOLUME_RE" compose.yaml \
        || die "could not find the postgres data mount in compose.yaml; apply both edits by hand"
    sed -i \
        -e "s|image: ghcr.io/immich-app/postgres:.*|image: $(sed_escape "$TARGET_IMAGE")|" \
        -e "s|$PG_VOLUME_RE|/postgres$TARGET_MAJOR:/var/lib/postgresql|" \
        compose.yaml
    grep -q "/postgres$TARGET_MAJOR:/var/lib/postgresql\$" compose.yaml \
        || die "compose.yaml rewrite did not take; check the postgres volume line before starting"
    git --no-pager diff --stat compose.yaml 2>/dev/null || true
    log "compose.yaml updated; run 'make start' to bring the stack up on Postgres $TARGET_MAJOR"
else
    cat <<EOF

Data is migrated. Two edits remain in compose.yaml (postgres service):

  image: $TARGET_IMAGE
  volumes:
    - \${POSTGRES_DATA_LOCATION:-\${DATA_LOCATION:-./data}}/postgres$TARGET_MAJOR:/var/lib/postgresql

Then: make start
Re-run with --apply to have this script make both edits.
EOF
fi

cat <<EOF

Also update, in the same change:
  config/backrest/Dockerfile   postgresql${CURRENT_MAJOR}-client -> postgresql${TARGET_MAJOR}-client
                               (a newer client emits SET parameters an older
                               server rejects, and vice versa: db-backup.sh's
                               dumps must restore into this server)
  compose.test.yaml            postgres_ci_data:/var/lib/postgresql

Rollback: revert those edits and 'make start'. The Postgres $CURRENT_MAJOR
cluster at $OLD_DIR was never modified.
EOF

if [ "$KEEP_DUMPS" = "1" ]; then
    log "dumps kept at $DUMP_DIR"
else
    log "removing $DUMP_DIR (pass --keep-dumps to retain it)"
    rm -rf "$DUMP_DIR"
fi

log "Postgres $CURRENT_MAJOR -> $TARGET_MAJOR migration complete"
