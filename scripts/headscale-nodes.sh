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
    require_env_file
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

# Fails when the listing does: piped straight into jq, a headscale that is down
# reads as one with nothing to delete, and the reset reports success.
# Usage: headscale_ids nodes|preauthkeys
headscale_ids() {
    local json=""
    json="$(compose exec -T headscale headscale "$1" list -o json)" || return 1
    printf '%s' "$json" | jq -r '.[]?.id'
}

# Best-effort past the confirmation: one node that will not delete must not
# keep every preauth key alive.
reset() {
    local id="" ids="" complete=1
    echo "⚠️  This will WIPE ALL Headscale nodes, preauth keys, and IP allocations!"
    confirm_or_abort "Are you sure?"
    echo "🧹 Deleting all Headscale nodes..."
    ids="$(headscale_ids nodes)" || { echo "  ⚠ could not list the nodes"; complete=0; }
    for id in $ids; do
        compose exec -T headscale headscale nodes delete --identifier "$id" --force ||
            { echo "  ⚠ node $id was not deleted"; complete=0; }
    done
    echo "🧹 Deleting all Headscale preauth keys..."
    ids="$(headscale_ids preauthkeys)" || { echo "  ⚠ could not list the preauth keys"; complete=0; }
    for id in $ids; do
        compose exec -T headscale headscale preauthkeys expire --id "$id" --force ||
            { echo "  ⚠ preauth key $id was not expired"; complete=0; }
    done
    echo "🧹 Resetting Headscale IP allocations (restarting service)..."
    compose restart headscale || { echo "  ⚠ headscale did not restart"; complete=0; }
    if [ "$complete" -eq 0 ]; then
        echo "❌ Headscale reset incomplete - see the warnings above"
        exit 1
    fi
    echo "✅ Headscale reset complete"
}

case "${1:-}" in
    register) register "${2:-}" ;;
    reset) reset ;;
    *) die "usage: $(basename "$0") register <key> | reset" ;;
esac
