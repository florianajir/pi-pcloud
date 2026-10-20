#!/bin/sh
# `make uninstall`: remove the stack, its data and everything it installed on
# the host, after an explicit "yes". .env is kept.
#
# Host-only, never mounted into a container, so sourcing lib.sh is fine here.

set -eu

# Derived from this file's location, never inherited: an exported PROJECT_DIR
# or ENV_FILE would point every removal below at another tree.
unset PROJECT_DIR ENV_FILE

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

[ "$#" -eq 0 ] || die "takes no arguments (got: $*)"

DATA_DIRS='nextcloud n8n immich lldap authelia-config'
GENERATED_CONFIGS='headplane/config.yaml headscale/config.yaml
headscale/policy.hujson ntfy/ntfy.env beszel-agent/agent.env'

confirm() {
    local answer="" dir="" file=""
    echo "🗑️  Uninstalling pi-pcloud..."
    echo
    echo "⚠️  WARNING: This will remove ALL data including:"
    echo "   - Docker volumes (pi-hole, headscale, etc.)"
    for dir in $DATA_DIRS; do
        echo "   - Bind-mount data dir: ./data/$dir"
    done
    echo "   - Bind-mount data dirs: ./data/postgres*"
    echo "   - The Postgres cluster, wherever POSTGRES_DATA_LOCATION puts it"
    for file in $GENERATED_CONFIGS; do
        echo "   - Generated config: ./config/$file"
    done
    echo "   - The systemd units, sysctl drop-in, /etc/hosts record and pi-pcloud command"
    echo
    printf "Are you sure? Type 'yes' to confirm: "
    read -r answer || answer=""
    if [ "$answer" != "yes" ]; then
        echo "Aborted"
        exit 1
    fi
    echo
}

# POSTGRES_DATA_LOCATION can put the cluster on another disk entirely, which
# the data/ glob misses - and a surviving PGDATA is exactly the failure
# remove_data describes. Resolved through lib.sh so this cannot drift from what
# compose/compose-core.yaml mounts; skipped, loudly, if it resolves to nothing
# or to "/" rather than expanding into `rm -rf /postgres*`.
remove_postgres_cluster() {
    local root=""
    root="$(resolve_postgres_data_location_path)"
    case "$root" in
        "" | "/")
            echo "  ⚠ could not resolve the Postgres data root; remove the cluster by hand"
            ;;
        *)
            echo "  · Postgres cluster at $root"
            $SUDO rm -rf "$root"/postgres*
            ;;
    esac
}

# postgres* and not postgres: from 18 the cluster directory carries the major
# (data/postgres18), so the bare name leaves the whole cluster behind. A
# reinstall then finds a non-empty PGDATA, never runs init-databases.sh, and
# every service fails to authenticate against roles still holding the old
# PASSWORD. The glob also takes any leftover pg-major-upgrade.sh dump directory.
remove_data() {
    local dir="" file=""
    echo "🐳 Removing containers and volumes..."
    docker compose down -v --remove-orphans 2>/dev/null
    echo "🧹 Removing bind-mount data directories..."
    for dir in $DATA_DIRS; do
        $SUDO rm -rf "$PROJECT_DIR/data/$dir"
    done
    $SUDO rm -rf "$PROJECT_DIR"/data/postgres*
    remove_postgres_cluster
    echo "🧹 Removing generated config files..."
    for file in $GENERATED_CONFIGS; do
        rm -f "$PROJECT_DIR/config/$file"
    done
}

confirm
cd "$PROJECT_DIR"
# Best-effort past the confirmation: a step that fails must not leave the rest
# behind. The host integration goes first, so the stack and its timers are
# stopped before their data disappears.
set +e
run_script install-system.sh --remove
remove_data
echo "✅ Uninstall complete"
echo
echo "ℹ️  Note: .env file preserved. Remove manually if needed."
