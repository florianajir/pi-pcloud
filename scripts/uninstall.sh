#!/bin/sh
# `make uninstall`: remove the stack, its state and everything it installed on
# the host, after an explicit "yes". The media libraries and .env are kept.
#
#   uninstall.sh           keep the media libraries
#   uninstall.sh --purge   delete them too, after a second confirmation
#
# Both answers are asked before anything is removed.
#
# Host-only, never mounted into a container, so sourcing lib.sh is fine here.

set -eu

# Derived from this file's location, never inherited: an exported PROJECT_DIR
# or ENV_FILE would point every removal below at another tree.
unset PROJECT_DIR ENV_FILE

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

PURGE=0
case "$*" in
    "") ;;
    --purge) PURGE=1 ;;
    *) die "usage: $(basename "$0") [--purge]" ;;
esac

# What the services keep under DATA_LOCATION, split by who filled it: the stack
# wrote the state and goes with it, a person filled the media libraries.
STATE_DIRS='nextcloud-config nextcloud-themes n8n lldap authelia-config'
MEDIA_DIRS='nextcloud immich comics manga download'
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

if [ "$PURGE" -eq 1 ] && [ -z "$DATA_ROOT" ]; then
    die "could not resolve the data root, so --purge cannot say what it would delete; nothing was removed"
fi

# Usage: ask <prompt> <expected answer>
ask() {
    local answer=""
    printf '%s' "$1"
    read -r answer || answer=""
    if [ "$answer" != "$2" ]; then
        echo "Aborted"
        exit 1
    fi
}

confirm() {
    local dir="" file="" root="${DATA_ROOT:-<DATA_LOCATION>}"
    echo "🗑️  Uninstalling pi-pcloud..."
    echo
    echo "⚠️  WARNING: This will remove:"
    echo "   - Docker volumes (pi-hole, headscale, etc.)"
    for dir in $STATE_DIRS; do
        echo "   - State dir: $root/$dir"
    done
    echo "   - State dirs: $root/postgres*"
    echo "   - The Postgres cluster, wherever POSTGRES_DATA_LOCATION puts it"
    for file in $GENERATED_CONFIGS; do
        echo "   - Generated config: ./config/$file"
    done
    echo "   - The systemd units, sysctl drop-in, /etc/hosts record and pi-pcloud command"
    echo
    if [ "$PURGE" -eq 0 ]; then
        echo "   Kept: .env and the media libraries ($MEDIA_DIRS under $root)."
        echo
    fi
    ask "Are you sure? Type 'yes' to confirm: " yes
    [ "$PURGE" -eq 1 ] || return 0
    echo
    echo "🔥 --purge also deletes the media libraries:"
    for dir in $MEDIA_DIRS; do
        echo "   - $DATA_ROOT/$dir"
    done
    echo
    ask "Type 'purge' to delete them as well: " purge
    echo
}

# POSTGRES_DATA_LOCATION can put the cluster on another disk entirely, which
# the data root glob misses - and a surviving PGDATA is exactly the failure
# remove_state describes. Resolved through lib.sh so this cannot drift from
# what compose/compose-core.yaml mounts.
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
remove_state() {
    local dir="" file=""
    echo "🐳 Removing containers and volumes..."
    docker compose down -v --remove-orphans 2>/dev/null ||
        echo "  ⚠ docker compose down failed; check \`docker volume ls\` for what is left"
    echo "🧹 Removing state directories..."
    if [ -n "$DATA_ROOT" ]; then
        for dir in $STATE_DIRS; do
            $SUDO rm -rf "$DATA_ROOT/$dir"
        done
        $SUDO rm -rf "$DATA_ROOT"/postgres*
    else
        echo "  ⚠ could not resolve the data root; remove the state directories by hand"
    fi
    remove_postgres_cluster
    echo "🧹 Removing generated config files..."
    for file in $GENERATED_CONFIGS; do
        rm -f "$PROJECT_DIR/config/$file"
    done
}

remove_media() {
    local dir=""
    echo "🔥 Removing the media libraries..."
    for dir in $MEDIA_DIRS; do
        $SUDO rm -rf "$DATA_ROOT/$dir"
    done
}

confirm
cd "$PROJECT_DIR"
# Best-effort past the confirmation: a step that fails must not leave the rest
# behind. The host integration goes first, so the stack and its timers are
# stopped before their data disappears.
set +e
run_script install-system.sh --remove
remove_state
[ "$PURGE" -eq 0 ] || remove_media
echo "✅ Uninstall complete"
echo
if [ "$PURGE" -eq 0 ]; then
    echo "ℹ️  Media libraries kept under ${DATA_ROOT:-<DATA_LOCATION>}: $MEDIA_DIRS"
    echo "   \`make -C $PROJECT_DIR uninstall -- --purge\` deletes them too."
fi
echo "ℹ️  Note: .env file preserved. Remove manually if needed."
