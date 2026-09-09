#!/bin/bash
set -eu

# Runs once from docker-entrypoint-initdb.d, on a fresh PGDATA: one role plus
# one database per Postgres-backed service, all sharing $POSTGRES_PASSWORD.
# Rotating that password afterwards is scripts/rotate-password.sh's job.

TEMP_SQL=$(mktemp)
trap 'rm -f "$TEMP_SQL"' EXIT

# Escape a value for a single-quoted SQL literal. Mirrors lib.sh's sql_escape,
# which this script cannot source: it runs inside the postgres container, where
# only this one file is mounted. Without it an apostrophe in PASSWORD is a
# syntax error, and ON_ERROR_STOP aborts the entire init.
sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

PASSWORD_SQL=$(sql_escape "$POSTGRES_PASSWORD")

# Role name and database name are identical for every service.
SERVICES="immich nextcloud authelia lldap open-webui vaultwarden"

for service in $SERVICES; do
    cat >> "$TEMP_SQL" << EOF
-- $service
DO \$\$
BEGIN
	IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$service') THEN
		CREATE USER "$service" WITH ENCRYPTED PASSWORD '$PASSWORD_SQL';
	ELSE
		ALTER USER "$service" WITH ENCRYPTED PASSWORD '$PASSWORD_SQL';
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
\connect postgres

EOF
done

# Immich needs vchord and earthdistance. Both are pre-created here by the
# postgres superuser so the immich role does not need SUPERUSER itself — it
# shares this instance with the vaultwarden, authelia and lldap databases, and
# Immich is the only service here reachable without Authelia forward-auth.
# See https://docs.immich.app/administration/postgres-standalone/ ("without
# superuser"). Trade-off: a vchord version bump in a future immich-app/postgres
# image needs a manual `ALTER EXTENSION vchord UPDATE;` as postgres.
cat >> "$TEMP_SQL" << 'EOF'
\connect immich
CREATE EXTENSION IF NOT EXISTS vchord CASCADE;
CREATE EXTENSION IF NOT EXISTS earthdistance CASCADE;
\connect postgres
EOF

psql -v ON_ERROR_STOP=1 --username postgres --dbname postgres < "$TEMP_SQL"
