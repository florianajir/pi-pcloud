#!/bin/bash
# Unified PostgreSQL backup script.
# Usage: db-backup.sh <service>
#   e.g.: db-backup.sh authelia
#         db-backup.sh lldap
#         db-backup.sh nextcloud
#
# Per-service env vars (all optional with sensible defaults):
#   ${SERVICE}_SQL_BACKUP_DIR   — backup directory
#   ${SERVICE}_SQL_BACKUP_KEEP  — number of backups to retain
#   ${SERVICE}_DB_NAME          — database name  (falls back to DB_NAME, then service name)
#   ${SERVICE}_DB_USER          — database user   (falls back to DB_USER, then service name)
#   ${SERVICE}_DB_PASSWORD      — database password (falls back to DB_PASSWORD)
#   DB_HOST                     — PostgreSQL host  (default: postgres)
#
# Nextcloud-specific:
#   NEXTCLOUD_CONFIG_FILE       — path to config.php (default: /nextcloud-config/config.php)
#   Enables maintenance mode before dump and restores original state after.

set -euo pipefail

SERVICE="${1:-}"
if [ -z "$SERVICE" ]; then
    echo "Usage: $0 <service> (e.g., authelia, lldap, nextcloud)" >&2
    exit 1
fi

SERVICE_UPPER="$(printf '%s' "$SERVICE" | tr '[:lower:]' '[:upper:]')"

# --- Per-service defaults ---
eval "BACKUP_DIR=\"\${${SERVICE_UPPER}_SQL_BACKUP_DIR:-/userdata/${SERVICE}/backups}\""
eval "KEEP_COUNT=\"\${${SERVICE_UPPER}_SQL_BACKUP_KEEP:-7}\""
DB_HOST="${DB_HOST:-postgres}"
eval "DB_NAME=\"\${${SERVICE_UPPER}_DB_NAME:-\${DB_NAME:-$SERVICE}}\""
eval "DB_USER=\"\${${SERVICE_UPPER}_DB_USER:-\${DB_USER:-$SERVICE}}\""
eval "DB_PASSWORD=\"\${${SERVICE_UPPER}_DB_PASSWORD:-\${DB_PASSWORD:-}}\""

if [ -z "$DB_PASSWORD" ]; then
    echo "${SERVICE_UPPER}_DB_PASSWORD (or DB_PASSWORD) is required" >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"

# --- Nextcloud maintenance mode ---
if [ "$SERVICE" = "nextcloud" ]; then
    CONFIG_FILE="${NEXTCLOUD_CONFIG_FILE:-/nextcloud-config/config.php}"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Nextcloud config file not found: $CONFIG_FILE" >&2
        exit 1
    fi

    current_maintenance_state() {
        state="$(sed -n "s/.*'maintenance' => \(true\|false\).*/\1/p" "$CONFIG_FILE" | head -n1 || true)"
        [ -n "$state" ] || state="false"
        printf '%s' "$state"
    }

    set_maintenance_state() {
        target_state="$1"
        if grep -Eq "'maintenance' => (true|false)" "$CONFIG_FILE"; then
            sed -E -i "s/'maintenance' => (true|false)/'maintenance' => ${target_state}/" "$CONFIG_FILE"
        else
            awk -v state="${target_state}" '
                /^\);[[:space:]]*$/ {
                    print "  '\''maintenance'\'' => " state ","
                }
                { print }
            ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
            mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        fi
        echo "Nextcloud maintenance mode set to ${target_state}"
    }

    original_state="$(current_maintenance_state)"
    restore_original_state() {
        set_maintenance_state "$original_state" || true
    }
    trap restore_original_state EXIT INT TERM
    set_maintenance_state true
fi

# --- Dump ---
timestamp="$(date +%Y%m%d_%H%M%S)"
tmp_file="$BACKUP_DIR/${SERVICE}-sqlbkp_${timestamp}.bak.tmp"
out_file="$BACKUP_DIR/${SERVICE}-sqlbkp_${timestamp}.bak"

export PGPASSWORD="$DB_PASSWORD"
pg_dump -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -f "$tmp_file"
mv "$tmp_file" "$out_file"
unset PGPASSWORD

echo "${SERVICE} PostgreSQL backup created: ${out_file}"

# --- Restore nextcloud maintenance state ---
if [ "$SERVICE" = "nextcloud" ]; then
    set_maintenance_state "$original_state"
    trap - EXIT INT TERM
fi

# --- Prune ---
case "$KEEP_COUNT" in
    ''|*[!0-9]*) KEEP_COUNT=7 ;;
esac

if [ "$KEEP_COUNT" -gt 0 ]; then
    old_backups="$(ls -1t "$BACKUP_DIR"/${SERVICE}-sqlbkp_*.bak 2>/dev/null | tail -n +$((KEEP_COUNT + 1)) || true)"
    if [ -n "$old_backups" ]; then
        echo "Pruning old ${SERVICE} backups (keeping ${KEEP_COUNT})"
        echo "$old_backups" | xargs -r rm -f
    fi
fi
