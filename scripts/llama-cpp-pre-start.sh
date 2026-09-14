#!/bin/sh
# Seeds the llama_models volume before the stack starts.
#
# llama-cpp sits on the "ai" network, which is internal: it has no route out, so
# it cannot pull its own weights the way `llama-server -hf ...` normally would.
# Fetching them here keeps the inference container air-gapped and keeps the
# download on the host's NVMe (a Docker volume) rather than the rotational USB
# drive DATA_LOCATION points at - the weights are mmap'd on every load.
set -eu

. "$(dirname "$0")/lib.sh"

# Keep in sync with the llama-cpp image tag in compose/compose-ai.yaml.
LLAMA_IMAGE="${LLAMA_IMAGE:-ghcr.io/ggml-org/llama.cpp:server-b10481}"
FETCH_SCRIPT="$PROJECT_DIR/config/llama-cpp/fetch-models.sh"

# compose prefixes volume names with the project name (the project directory
# unless COMPOSE_PROJECT_NAME says otherwise); mirror that so both sides mean
# the same volume.
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(basename "$PROJECT_DIR")}"
VOLUME_NAME="${PROJECT_NAME}_llama_models"

# Create the volume the way compose would, labels included, so `docker compose
# up` adopts it silently instead of warning that it did not create it.
ensure_volume() {
    if docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
        return 0
    fi

    docker volume create \
        --label "com.docker.compose.project=$PROJECT_NAME" \
        --label "com.docker.compose.volume=llama_models" \
        --label "com.docker.compose.version=$(docker compose version --short)" \
        "$VOLUME_NAME" >/dev/null
}

main() {
    if ! docker image inspect "$LLAMA_IMAGE" >/dev/null 2>&1; then
        log "Pulling $LLAMA_IMAGE"
        docker pull -q "$LLAMA_IMAGE" >/dev/null
    fi

    ensure_volume

    log "Checking Gemma 4 weights in $VOLUME_NAME"
    if docker run --rm \
        -v "$VOLUME_NAME:/models" \
        -v "$FETCH_SCRIPT:/fetch-models.sh:ro" \
        --entrypoint sh \
        "$LLAMA_IMAGE" /fetch-models.sh; then
        return 0
    fi

    die "Failed to prepare Gemma 4 weights; llama-cpp will not start"
}

main "$@"
