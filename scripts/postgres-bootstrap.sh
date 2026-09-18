#!/bin/sh
# Keep the shared cluster in the shape config/postgres/init-databases.sh creates
# it: one role and database per Postgres-backed service, the immich role without
# SUPERUSER, and the immich database's extensions at the versions the running
# postgres image ships. A post-start hook (scripts/stack-up.sh), and a pre-start
# one on `make enable` (scripts/services.sh). Idempotent, cheap, and safe on
# every boot.
#
# It repairs three things nothing else can:
#
#   * a service whose role init-databases.sh never created, because that script
#     only runs on a fresh PGDATA and the service joined the stack (or
#     COMPOSE_PROFILES) afterwards. Without this it cannot authenticate at all.
#
#   * init-databases.sh only ever runs on a *fresh* PGDATA, from
#     docker-entrypoint-initdb.d. A cluster restored from a dump, or migrated by
#     scripts/pg-major-upgrade.sh (whose pg_dumpall --roles-only faithfully
#     reproduces the source's role attributes), carries whatever the source had
#     — including the SUPERUSER the immich role was created with before the
#     current init script dropped it. Re-asserting it here means the cutover
#     runbook cannot forget the step, and a restore cannot silently regress it.
#
#   * immich-server's bootstrap aborts when a newer vchord is available but its
#     own role cannot install it: vchord.control sets `superuser = true`, and
#     the immich role deliberately is not one — it shares this instance with the
#     vaultwarden, authelia and lldap databases. Running ALTER EXTENSION here as
#     postgres is what upstream asks a non-superuser deployment to do, and keeps
#     image bumps hands-off.
#
# Being a post-start hook, this races immich-server's own boot rather than
# preceding it: `compose up -d` returns once immich-server has *started*, not
# once it is healthy. The hook is one psql round-trip against a database Immich
# spends far longer migrating, so it normally wins — and when it does not,
# `restart: unless-stopped` costs one immich-server restart, not an outage.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

PG_CONTAINER="${PG_CONTAINER:-pi-postgres}"

# pg_available_extensions comes back in no particular order, and an extension's
# upgrade script may need its dependency updated first (vchord requires vector).
# Rather than hardcode that graph, retry the whole pass while it makes progress.
MAX_PASSES=4

if ! container_is_running "$PG_CONTAINER"; then
    log "$PG_CONTAINER is not running, skipping"
    exit 0
fi

# -q drops the command tags, so a query's own output is all that comes back.
psql_postgres() {
    docker exec -i "$PG_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -Atq "$@"
}

psql_immich() {
    docker exec -i "$PG_CONTAINER" psql -U postgres -d immich -v ON_ERROR_STOP=1 -Atq "$@"
}

# --- A service enabled after the cluster was created has no role ---
#
# config/postgres/init-databases.sh runs once, from docker-entrypoint-initdb.d
# on a *fresh* PGDATA. A Postgres-backed service added to the stack later, or
# left out of COMPOSE_PROFILES until now, therefore finds neither role nor
# database and cannot authenticate at all - `make enable freshrss` on an
# existing install started a container that could only crash-loop.
#
# CREATE, never ALTER: the password of an existing role belongs to
# scripts/rotate-password.sh, and re-asserting PASSWORD here would undo a
# rotation on the next boot. A new role gets PASSWORD because that is what the
# service is handed in its environment - the same value both sides read.

# The one list, read from the script that owns it rather than restated here.
postgres_backed_services() {
    sed -n 's/^SERVICES="\([^"]*\)".*/\1/p' \
        "$PROJECT_DIR/config/postgres/init-databases.sh"
}

# The SQL init-databases.sh runs for one service, minus its ELSE ALTER branch.
# Heredoc on stdin, never argv: the host's process table is world-readable.
create_role_and_database() {
    service="$1"
    password_sql="$2"

    docker exec -i "$PG_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -Atq <<EOF
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$service') THEN
        CREATE USER "$service" WITH ENCRYPTED PASSWORD '$password_sql';
    END IF;
END
\$\$;
SELECT 'CREATE DATABASE "$service"'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '$service')
\gexec
GRANT ALL PRIVILEGES ON DATABASE "$service" TO "$service";
ALTER DATABASE "$service" OWNER TO "$service";

\connect "$service"
GRANT ALL ON SCHEMA public TO "$service";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "$service";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "$service";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO "$service";
EOF
}

# Separate connection: the database this installs into has just been created,
# so the heredoc above could not have reached it.
create_immich_extensions() {
    docker exec -i "$PG_CONTAINER" psql -U postgres -d immich -v ON_ERROR_STOP=1 -Atq <<'EOF'
CREATE EXTENSION IF NOT EXISTS vchord CASCADE;
CREATE EXTENSION IF NOT EXISTS earthdistance CASCADE;
EOF
}

ensure_service_roles() {
    services="$(postgres_backed_services)"
    # An empty parse is a renamed variable, not a cluster with no services, and
    # would silently turn this whole pass into a no-op.
    if [ -z "$services" ]; then
        log "WARNING: no SERVICES list in config/postgres/init-databases.sh; skipping role check"
        return 0
    fi

    # One round-trip for the whole list: the `docker exec` around it costs far
    # more than the query, and this runs on every boot. Role *and* database, so
    # an interrupted first run that left one without the other is repaired too.
    existing="$(psql_postgres -c \
        "SELECT rolname FROM pg_roles INTERSECT SELECT datname FROM pg_database;")" \
        || { log "WARNING: could not list the roles in this cluster"; return 0; }

    missing=""
    for service in $services; do
        # Interpolated into SQL below, so it is checked rather than trusted.
        # Being [a-z0-9-] only, it is also a literal grep pattern.
        case "$service" in
            *[!a-z0-9-]*)
                log "WARNING: ignoring unexpected service name '$service' in the SERVICES list"
                continue
                ;;
        esac
        printf '%s\n' "$existing" | grep -qx -- "$service" || missing="$missing $service"
    done

    [ -n "$missing" ] || return 0

    password="$(get_env_value PASSWORD)"
    if [ -z "$password" ]; then
        log "WARNING: PASSWORD is empty, cannot create the missing role(s):$missing"
        return 0
    fi
    password_sql="$(sql_escape "$password")"

    for service in $missing; do
        if ! create_role_and_database "$service" "$password_sql" >/dev/null; then
            log "WARNING: could not create the $service role and database"
            continue
        fi
        log "$service: created the missing role/database (it joined this cluster after it was initialised)"
        # vchord.control sets `superuser = true` and the immich role
        # deliberately is not one, so init-databases.sh pre-creates its
        # extensions as postgres. Without them immich-server's first migration
        # fails on "permission denied to create extension".
        if [ "$service" = immich ] && ! create_immich_extensions >/dev/null; then
            log "WARNING: could not create the immich extensions (vchord, earthdistance)"
        fi
    done
}

# --- The immich role must not be a superuser ---

ensure_immich_not_superuser() {
    is_super="$(psql_postgres -c \
        "SELECT rolsuper FROM pg_roles WHERE rolname = 'immich';")" \
        || { log "WARNING: could not read the immich role's attributes"; return 0; }

    case "$is_super" in
        f)  : ;;
        t)
            if psql_postgres -c 'ALTER ROLE immich WITH NOSUPERUSER;' >/dev/null; then
                log "revoked SUPERUSER from the immich role (restored or pre-migration cluster)"
            else
                log "WARNING: could not revoke SUPERUSER from the immich role"
            fi
            ;;
        '') log "no immich role in this cluster, nothing to assert" ;;
        *)  log "WARNING: unexpected rolsuper value '$is_super' for the immich role" ;;
    esac
}

# --- The immich database's extensions must match the image ---

outdated_count() {
    psql_immich -c "
        SELECT count(*) FROM pg_available_extensions
        WHERE installed_version IS NOT NULL
          AND installed_version IS DISTINCT FROM default_version;"
}

# No ON_ERROR_STOP: one extension whose dependency has not been updated yet must
# not abort the others, or the retry below would replay the same failing order
# forever. psql still reports each failure on stderr, and the count is the
# authority on whether the pass actually worked.
update_pass() {
    docker exec -i "$PG_CONTAINER" psql -U postgres -d immich -Atq << 'EOF'
SELECT format('ALTER EXTENSION %I UPDATE', name)
FROM pg_available_extensions
WHERE installed_version IS NOT NULL
  AND installed_version IS DISTINCT FROM default_version
\gexec
EOF
}

update_immich_extensions() {
    # Separated from the "not there" case on purpose: a psql that fails (the
    # cluster still in crash recovery, say) also returns an empty string, and
    # reporting that as "no immich database" would send the reader looking in
    # entirely the wrong place for why the extension update was skipped.
    has_db="$(psql_postgres -c \
        "SELECT 1 FROM pg_database WHERE datname = 'immich';")" \
        || { log "WARNING: could not list the databases in this cluster"; return 0; }

    if [ "$has_db" != "1" ]; then
        log "no immich database in this cluster, skipping extension updates"
        return 0
    fi

    remaining="$(outdated_count)" \
        || { log "WARNING: could not read the immich extension versions"; return 0; }

    pass=0
    while [ "$remaining" != "0" ] && [ "$pass" -lt "$MAX_PASSES" ]; do
        pass=$((pass + 1))
        update_pass || true

        previous="$remaining"
        remaining="$(outdated_count)" \
            || { log "WARNING: could not re-read the immich extension versions"; return 0; }

        # A pass that changed nothing will not change anything next time either.
        [ "$remaining" != "$previous" ] || break
    done

    if [ "$remaining" = "0" ]; then
        if [ "$pass" -eq 0 ]; then
            log "immich extensions are current"
        else
            log "immich extensions updated in $pass pass(es)"
        fi
    else
        log "WARNING: $remaining immich extension(s) still outdated after $pass pass(es); see the psql errors above"
    fi
}

ensure_service_roles
ensure_immich_not_superuser
update_immich_extensions
