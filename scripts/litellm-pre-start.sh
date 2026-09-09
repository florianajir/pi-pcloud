#!/bin/sh
# Generates the two LiteLLM secrets that are not PASSWORD, and the directories
# compose bind-mounts into the container.
#
#   salt_key    encrypts the provider credentials in the database. There is no
#               re-encrypt path: a new key does not invalidate the old rows, it
#               makes them undecryptable. So it is never rotated.
#   master_key  the management API's admin credential and the break-glass UI
#               password. Not PASSWORD, for the same reason as Vaultwarden's
#               admin token - llm.$HOST_NAME carries no forward-auth - and it
#               has to outlive a rotation, because OPENAI_API_KEY is
#               PersistentConfig in open-webui.
#
# Both hex, which is what lets open-webui-bootstrap.sh splice one into SQL. Both
# under DATA_LOCATION, the LiteLLM state that is not in Postgres, which backrest
# snapshots.
#
# A pre-start hook. Idempotent.

set -eu

. "$(dirname "$0")/lib.sh"

SECRETS_DIR="$(resolve_data_location_path)/litellm/secrets"
BACKUP_DIR="$(resolve_data_location_path)/litellm/backups"

# -s, not -f: a zero-byte leftover would be accepted forever.
ensure_secret() {
    local file="$SECRETS_DIR/$1"
    local label="$2"

    [ ! -s "$file" ] || return 0
    write_file_atomic "$file" generate_secret || die "Failed to generate the LiteLLM $label"
    safe_chmod 600 "$file"
    log "Generated the LiteLLM $label"
}

mkdir -p "$SECRETS_DIR" "$BACKUP_DIR"
safe_chmod 700 "$SECRETS_DIR"

ensure_secret salt_key "salt key"
ensure_secret master_key "master key"

# The secrets too: after a root-run systemd start, a non-root re-run of
# open-webui-bootstrap.sh has to be able to read the master key.
fix_ownership "$SECRETS_DIR"
fix_ownership "$BACKUP_DIR"
