#!/bin/bash
set -euo pipefail

# Create a temporary SQL file with environment variables substituted
TEMP_SQL=$(mktemp)
trap "rm -f $TEMP_SQL" EXIT

cat > "$TEMP_SQL" << EOF
-- Create Immich database and user
DO \$\$
BEGIN
	IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'immich') THEN
		CREATE USER immich WITH ENCRYPTED PASSWORD '${POSTGRES_PASSWORD}';
	ELSE
		ALTER USER immich WITH ENCRYPTED PASSWORD '${POSTGRES_PASSWORD}';
	END IF;
END
\$\$;
SELECT 'CREATE DATABASE immich'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'immich')
\gexec
ALTER USER immich WITH SUPERUSER;
GRANT ALL PRIVILEGES ON DATABASE immich TO immich;
ALTER DATABASE immich OWNER TO immich;

-- Create Nextcloud database and user
DO \$\$
BEGIN
	IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nextcloud') THEN
		CREATE USER nextcloud WITH ENCRYPTED PASSWORD '${POSTGRES_PASSWORD}';
	ELSE
		ALTER USER nextcloud WITH ENCRYPTED PASSWORD '${POSTGRES_PASSWORD}';
	END IF;
END
\$\$;
SELECT 'CREATE DATABASE nextcloud'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'nextcloud')
\gexec
GRANT ALL PRIVILEGES ON DATABASE nextcloud TO nextcloud;
ALTER DATABASE nextcloud OWNER TO nextcloud;

-- Set proper permissions for Immich user on Immich DB
\connect immich
CREATE EXTENSION IF NOT EXISTS vchord CASCADE;
GRANT ALL ON SCHEMA public TO immich;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO immich;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO immich;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO immich;

-- Set proper permissions for Nextcloud user on Nextcloud DB
\connect nextcloud
GRANT ALL ON SCHEMA public TO nextcloud;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO nextcloud;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO nextcloud;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO nextcloud;

-- Create Authelia database and user
DO \$\$
BEGIN
	IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authelia') THEN
		CREATE USER authelia WITH ENCRYPTED PASSWORD '${POSTGRES_PASSWORD}';
	ELSE
		ALTER USER authelia WITH ENCRYPTED PASSWORD '${POSTGRES_PASSWORD}';
	END IF;
END
\$\$;
SELECT 'CREATE DATABASE authelia'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'authelia')
\gexec
GRANT ALL PRIVILEGES ON DATABASE authelia TO authelia;
ALTER DATABASE authelia OWNER TO authelia;

-- Set proper permissions for Authelia user on Authelia DB
\connect authelia
GRANT ALL ON SCHEMA public TO authelia;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO authelia;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO authelia;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO authelia;

-- Create LLDAP database and user
DO \$\$
BEGIN
	IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lldap') THEN
		CREATE USER lldap WITH ENCRYPTED PASSWORD '${POSTGRES_PASSWORD}';
	ELSE
		ALTER USER lldap WITH ENCRYPTED PASSWORD '${POSTGRES_PASSWORD}';
	END IF;
END
\$\$;
SELECT 'CREATE DATABASE lldap'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'lldap')
\gexec
GRANT ALL PRIVILEGES ON DATABASE lldap TO lldap;
ALTER DATABASE lldap OWNER TO lldap;

-- Set proper permissions for LLDAP user on LLDAP DB
\connect lldap
GRANT ALL ON SCHEMA public TO lldap;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO lldap;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO lldap;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO lldap;
-- Create Open-WebUI database and user
DO \$\$
BEGIN
	IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'open-webui') THEN
		CREATE USER "open-webui" WITH ENCRYPTED PASSWORD '${POSTGRES_PASSWORD}';
	ELSE
		ALTER USER "open-webui" WITH ENCRYPTED PASSWORD '${POSTGRES_PASSWORD}';
	END IF;
END
\$\$;
SELECT 'CREATE DATABASE "open-webui"'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'open-webui')
\gexec
GRANT ALL PRIVILEGES ON DATABASE "open-webui" TO "open-webui";
ALTER DATABASE "open-webui" OWNER TO "open-webui";

-- Set proper permissions for Open-WebUI user on Open-WebUI DB
\connect "open-webui"
GRANT ALL ON SCHEMA public TO "open-webui";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "open-webui";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "open-webui";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO "open-webui";
EOF

# Execute the SQL file
psql -v ON_ERROR_STOP=1 --username postgres --dbname postgres < "$TEMP_SQL"
