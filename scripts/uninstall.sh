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

DATA_DIRS='nextcloud nextcloud-config nextcloud-themes n8n immich lldap
authelia-config'
GENERATED_CONFIGS='headplane/config.yaml headscale/config.yaml
headscale/policy.hujson ntfy/ntfy.env beszel-agent/agent.env'

# Refuses a root that resolves to nothing or to "/", rather than letting
# `rm -rf "$root"/x` expand into `rm -rf /x`.
removable_root() {
    case "$1" in
        "" | "/") return 1 ;;
    esac
    printf '%s' "$1"
}

# The bind mounts follow DATA_LOCATION, as compose's ${DATA_LOCATION:-./data}
# does: a fixed ./data would leave every one of them behind on a moved data
# root while the Postgres cluster, which follows it too, is gone.
DATA_ROOT="$(removable_root "$(resolve_data_location_path)")" || DATA_ROOT=""

confirm() {
    local answer="" dir="" file=""
    echo "🗑️  Uninstalling pi-pcloud..."
    echo
    echo "⚠️  WARNING: This will remove ALL data including:"
    echo "   - Docker volumes (pi-hole, headscale, etc.)"
    for dir in $DATA_DIRS; do
        echo "   - Bind-mount data dir: ${DATA_ROOT:-<DATA_LOCATION>}/$dir"
    done
    echo "   - Bind-mount data dirs: ${DATA_ROOT:-<DATA_LOCATION>}/postgres*"
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
# the data root glob misses - and a surviving PGDATA is exactly the failure
# remove_data describes. Resolved through lib.sh so this cannot drift from what
# compose/compose-core.yaml mounts.
remove_postgres_cluster() {
    local root=""
    if ! root="$(removable_root "$(resolve_postgres_data_location_path)")"; then
        echo "  ⚠ could not resolve the Postgres data root; remove the cluster by hand"
        return 0
    fi
    echo "  · Postgres cluster at $root"
    $SUDO rm -rf "$root"/postgres*
}

# postgres* and not postgres: from 18 the cluster directory carries the major
# (data/postgres18), so the bare name leaves the whole cluster behind. A
# reinstall then finds a non-empty PGDATA, never runs init-databases.sh, and
# every service fails to authenticate against roles still holding the old
# PASSWORD. The glob also takes any leftover pg-major-upgrade.sh dump directory.
remove_data() {
    local dir="" file=""
    echo "🐳 Removing containers and volumes..."
    docker compose down -v --remove-orphans 2>/dev/null ||
        echo "  ⚠ docker compose down failed; check \`docker volume ls\` for what is left"
    echo "🧹 Removing bind-mount data directories..."
    if [ -n "$DATA_ROOT" ]; then
        for dir in $DATA_DIRS; do
            $SUDO rm -rf "$DATA_ROOT/$dir"
        done
        $SUDO rm -rf "$DATA_ROOT"/postgres*
    else
        echo "  ⚠ could not resolve the data root; remove the data directories by hand"
    fi
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
