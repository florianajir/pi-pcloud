#!/bin/sh
# `make headscale-register <key>` and `make headscale-reset`.
#
#   headscale-nodes.sh register <key>   register a device under EMAIL's user
#   headscale-nodes.sh reset            delete every node and preauth key,
#                                       after a typed "yes"
#
# Host-only, never mounted into a container, so sourcing lib.sh is fine here.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

register() {
    local key="$1" user=""
    echo "🔐 Registering headscale node..."
    if [ ! -f "$ENV_FILE" ]; then
        echo "❌ .env missing (copy .env.dist)"
        exit 1
    fi
    if [ -z "$key" ]; then
        echo "❌ Key missing (use: make headscale-register <key>)"
        exit 1
    fi
    user="${EMAIL:-$(get_env_value EMAIL)}"
    if [ -z "$user" ]; then
        echo "❌ EMAIL not set in .env"
        exit 1
    fi
    compose run --rm headscale nodes register --key "$key" --user "$user"
}

# Usage: headscale_ids nodes|preauthkeys
headscale_ids() {
    compose exec -T headscale headscale "$1" list -o json | jq -r '.[].id' 2>/dev/null
}

# Best-effort past the confirmation: one node that will not delete must not
# keep every preauth key alive.
reset() {
    local answer="" id=""
    echo "⚠️  This will WIPE ALL Headscale nodes, preauth keys, and IP allocations!"
    printf "Are you sure? Type 'yes' to confirm: "
    read -r answer || answer=""
    if [ "$answer" != "yes" ]; then
        echo "Aborted"
        exit 1
    fi
    echo "🧹 Deleting all Headscale nodes..."
    for id in $(headscale_ids nodes); do
        compose exec -T headscale headscale nodes delete --identifier "$id" --force ||
            echo "  ⚠ node $id was not deleted"
    done
    echo "🧹 Deleting all Headscale preauth keys..."
    for id in $(headscale_ids preauthkeys); do
        compose exec -T headscale headscale preauthkeys expire --id "$id" --force ||
            echo "  ⚠ preauth key $id was not expired"
    done
    echo "🧹 Resetting Headscale IP allocations (restarting service)..."
    compose restart headscale || echo "  ⚠ headscale did not restart"
    echo "✅ Headscale reset complete"
}

case "${1:-}" in
    register) register "${2:-}" ;;
    reset) reset ;;
    *) die "usage: $(basename "$0") register <key> | reset" ;;
esac
