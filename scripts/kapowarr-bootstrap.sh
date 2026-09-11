#!/bin/sh
# Feed kapowarr-bootstrap.py to the Kapowarr container's own python3.
#
# The logic lives in the .py; this is the part that cannot. Kapowarr shares
# gluetun's network namespace, so its API answers on localhost:5656 only from
# inside that container, and the image ships no curl and no jq - a bootstrap
# running on the host would have nothing to connect to.
#
# Credentials go in through `docker exec -e`, never as arguments: argv is
# world-readable in the host's process table for the length of the call.
#
# A post-start hook (scripts/run-hooks.sh), so it runs after docker compose up.
# Best-effort: warns, never fails the start.

set -eu

. "$(dirname "$0")/lib.sh"

KAPOWARR_CONTAINER="${KAPOWARR_CONTAINER:-pi-kapowarr}"

main() {
    container_is_running "$KAPOWARR_CONTAINER" || { log "Kapowarr not running, skipping"; return 0; }

    local user password
    user="$(get_env_value ADMIN_USER)"
    password="$(get_env_value PASSWORD)"

    KAP_USER="$user" KAP_PASS="$password" docker exec -i \
        -e KAP_USER -e KAP_PASS "$KAPOWARR_CONTAINER" \
        python3 - < "$SCRIPT_DIR/kapowarr-bootstrap.py"

    log "Kapowarr bootstrap complete"
}

main "$@"
