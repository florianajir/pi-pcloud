#!/bin/bash
# Bootstrap Uptime Kuma: auto-configures admin account, ntfy notifications,
# Docker host, and container monitors for all services in compose.yaml.
# Runs the Python bootstrap script inside a temporary container on the
# same Docker network as Uptime Kuma (no local venv required).

set -euo pipefail

. "$(dirname "$0")/lib.sh"

PYTHON_SCRIPT="$SCRIPT_DIR/uptime-kuma-bootstrap.py"
PYTHON_IMAGE="python:3.12-slim"
MAX_RETRIES=90
RETRY_INTERVAL=2

wait_for_kuma_health() {
    local status

    log "Waiting for Uptime Kuma health status..."
    for i in $(seq 1 $MAX_RETRIES); do
        status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' pi-uptime-kuma 2>/dev/null || true)
        if [ "$status" = "healthy" ]; then
            log "Uptime Kuma container is healthy"
            return 0
        fi
        sleep "$RETRY_INTERVAL"
    done
    log "ERROR: Uptime Kuma container did not become healthy in time"
    return 1
}

main() {
    log "=== Uptime Kuma Bootstrap ==="

    if [ ! -f "$ENV_FILE" ]; then
        die ".env missing at $ENV_FILE"
    fi

    wait_for_container "pi-uptime-kuma" "$MAX_RETRIES" "$RETRY_INTERVAL"
    wait_for_kuma_health

    # Give Uptime Kuma a moment to fully initialize after healthcheck passes
    sleep 5

    # Pull image if needed (will be cached after first run)
    docker image inspect "$PYTHON_IMAGE" >/dev/null 2>&1 || docker pull "$PYTHON_IMAGE"

    # Run bootstrap Python script inside a temporary container on the frontend
    # network so it can reach pi-uptime-kuma:3001 and pi-ntfy by container name.
    docker run --rm \
        --name pi-uptime-kuma-bootstrap \
        --network frontend \
        -v "$PYTHON_SCRIPT:/bootstrap.py:ro" \
        -v "$PROJECT_DIR/compose.yaml:/project/compose.yaml:ro" \
        -v "$PROJECT_DIR/.env:/project/.env:ro" \
        -v "$PROJECT_DIR/config/ntfy/ntfy.env:/project/config/ntfy/ntfy.env:ro" \
        -e PROJECT_DIR=/project \
        -e UPTIME_KUMA_URL=http://pi-uptime-kuma:3001 \
        "$PYTHON_IMAGE" \
        sh -c 'pip install --quiet --disable-pip-version-check "python-socketio[client]" && python /bootstrap.py'
}

main "$@"
