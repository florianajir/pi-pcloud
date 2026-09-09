#!/bin/sh
# Generates the two LiteLLM secrets that are not PASSWORD, and the directories
# compose bind-mounts into the container.
#
#   salt_key    encrypts the provider credentials LiteLLM stores in its database
#               (STORE_MODEL_IN_DB). There is no re-encrypt path: a new key does
#               not invalidate the old rows, it makes them undecryptable.
#   master_key  the admin credential of the management API, and the break-glass
#               UI password. Generated rather than derived from PASSWORD for the
#               same reason as Vaultwarden's admin token: llm.$HOST_NAME carries
#               no Authelia forward-auth, so a PASSWORD leak would otherwise be
#               full control of the proxy. It also has to outlive a rotation -
#               open-webui calls /v1 with it, and PersistentConfig means the
#               value it was started with is copied into its database.
#
# Both are hex, which is what lets scripts/open-webui-bootstrap.sh splice the
# key into SQL. Both live under DATA_LOCATION rather than config/, because they
# are the LiteLLM state that is not in Postgres and backrest snapshots that path.
#
# A pre-start hook (scripts/stack-up.sh). Idempotent.

set -eu

. "$(dirname "$0")/lib.sh"

SECRETS_DIR="$(resolve_data_location_path)/litellm/secrets"
BACKUP_DIR="$(resolve_data_location_path)/litellm/backups"

# -s, not -f: a zero-byte leftover would otherwise be accepted forever, and
# LiteLLM would start with an empty key rather than regenerate one.
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

# The secrets too, not just the backups: they are 0600, and after a root-run
# systemd start a non-root re-run of open-webui-bootstrap.sh has to be able to
# read the master key - otherwise it logs a warning and leaves the Open WebUI
# connection unregistered. Same reason authelia-pre-start.sh chowns its own
# secrets directory.
fix_ownership "$SECRETS_DIR"
fix_ownership "$BACKUP_DIR"
