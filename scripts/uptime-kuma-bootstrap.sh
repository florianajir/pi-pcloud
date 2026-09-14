#!/bin/sh
# Bootstrap Uptime Kuma: auto-configures admin account, ntfy notifications,
# Docker host, and container monitors for all services in compose/*.yaml.
# Runs the Python bootstrap script inside a temporary container on the
# same Docker network as Uptime Kuma (no local venv required).

set -eu

. "$(dirname "$0")/lib.sh"

PYTHON_SCRIPT="$SCRIPT_DIR/uptime-kuma-bootstrap.py"
PYTHON_IMAGE="python:3.12-slim"
# Pinned, not floating: this runs on every start, as root, on the frontend
# network, and a compromised release of any of these would run with whatever the
# container can reach. Bump deliberately, like any other dependency here.
PIP_PACKAGES="python-socketio==5.16.4 python-engineio==4.14.0 websocket-client==1.9.2 bidict==0.24.1 simple-websocket==1.1.0 h11==0.16.0 wsproto==1.3.2"
MAX_RETRIES=90
RETRY_INTERVAL=2

# Enabled compose services, comma-separated. `docker compose config --services`
# applies the COMPOSE_PROFILES line from .env on its own; a .env without the
# line is the legacy everything-enabled layout, which maps to the "all"
# profile. Empty output (compose failure) makes the python side keep every
# monitor active rather than pausing anything.
enabled_services_csv() {
    if grep -q '^COMPOSE_PROFILES=' "$ENV_FILE"; then
        compose config --services 2>/dev/null | tr '\n' ',' | sed 's/,$//'
    else
        (cd "$PROJECT_DIR" && COMPOSE_PROFILES=all docker compose config --services) 2>/dev/null | tr '\n' ',' | sed 's/,$//'
    fi
}

main() {
    log "=== Uptime Kuma Bootstrap ==="

    if [ ! -f "$ENV_FILE" ]; then
        die ".env missing at $ENV_FILE"
    fi

    wait_for_container "pi-uptime-kuma" "$MAX_RETRIES" "$RETRY_INTERVAL"
    wait_for_health "pi-uptime-kuma" "$MAX_RETRIES" "$RETRY_INTERVAL"

    # The healthcheck passes a little before the Socket.IO endpoint answers.
    sleep 5

    docker image inspect "$PYTHON_IMAGE" >/dev/null 2>&1 || docker pull "$PYTHON_IMAGE"

    # Passed explicitly: the script's fallback shells out to `docker inspect`, which
    # cannot work inside this container (no docker CLI, no socket mounted), so
    # without this the TLS certificate monitor is silently skipped.
    HOST_NAME="${HOST_NAME:-$(get_env_value HOST_NAME)}"
    [ -n "$HOST_NAME" ] || log "WARNING: HOST_NAME not resolved; TLS certificate monitor will be skipped"

    # The bootstrap container used to get the whole .env bind-mounted for this
    # one value, putting every secret in the stack inside a container that
    # installs packages from PyPI at runtime.
    ADMIN_USER="${ADMIN_USER:-$(get_env_value_clean ADMIN_USER)}"
    [ -n "$ADMIN_USER" ] || die "ADMIN_USER is not set in .env"
    export ADMIN_USER

    # Computed here because the bootstrap container has no docker CLI: monitors
    # of profile-disabled services get paused (not deleted) by the python side.
    ENABLED_SERVICES="$(enabled_services_csv)"
    if [ -n "$ENABLED_SERVICES" ]; then
        log "Enabled services: $ENABLED_SERVICES"
    else
        log "WARNING: could not determine enabled services; no monitors will be paused or resumed"
    fi

    # Run bootstrap Python script inside a temporary container on the frontend
    # network so it can reach pi-uptime-kuma:3001 and pi-ntfy by container name.
    docker run --rm \
        --name pi-uptime-kuma-bootstrap \
        --network frontend \
        -v "$PYTHON_SCRIPT:/bootstrap.py:ro" \
        -v "$PROJECT_DIR/compose:/project/compose:ro" \
        -v "$PROJECT_DIR/config/ntfy/ntfy.env:/project/config/ntfy/ntfy.env:ro" \
        -e PROJECT_DIR=/project \
        -e UPTIME_KUMA_URL=http://pi-uptime-kuma:3001 \
        -e HOST_NAME="$HOST_NAME" \
        -e ADMIN_USER \
        -e ENABLED_SERVICES="$ENABLED_SERVICES" \
        "$PYTHON_IMAGE" \
        sh -c "pip install --quiet --disable-pip-version-check $PIP_PACKAGES && python /bootstrap.py"
}

main "$@"
