#!/bin/sh
# Prepares what agentgateway cannot get for itself: a writable data directory,
# and an env_file carrying the four secrets its config reads from the
# environment.
#
# An env_file rather than the `export $(cat ...)` entrypoint the other services
# use, because the image is distroless and has no shell to run it in.
#
# A pre-start hook, after authelia-pre-start.sh so the client secret exists.
# Runs for open-webui too, not just agentgateway: open-webui's entrypoint reads
# the LLM API key this writes. Idempotent.

set -eu

. "$(dirname "$0")/lib.sh"

# Not ENV_FILE: lib.sh uses that name for .env, and resolve_data_location_path
# reads DATA_LOCATION out of it. Shadowing it made this chown ./data/agentgateway
# while compose mounted $DATA_LOCATION/agentgateway, and report success.
AGW_ENV_DIR="$PROJECT_DIR/config/agentgateway"
AGW_ENV_FILE="$AGW_ENV_DIR/agentgateway.env"

# The uid compose pins the container to. Deliberately not fix_ownership's
# project owner: where the two differ, that chown succeeds and the container
# still cannot open its database.
WRITER_UID="${WRITER_UID:-1000}"
WRITER_GID="${WRITER_GID:-1000}"

main() {
    local data_dir="" secrets_dir="" cookie_file="" key_file="" agent_key_file=""
    local client_secret="" cookie_secret="" llm_api_key="" agent_api_key=""
    local trilium_key_file="" mcp_key_file="" trilium_llm_key="" mcp_api_key=""
    local trilium_etapi_token=""

    data_dir="$(resolve_data_location_path)/agentgateway"
    secrets_dir="$data_dir/secrets"
    cookie_file="$secrets_dir/cookie_secret"
    key_file="$secrets_dir/llm_api_key"
    agent_key_file="$secrets_dir/agent_api_key"
    trilium_key_file="$secrets_dir/trilium_llm_key"
    mcp_key_file="$secrets_dir/mcp_api_key"

    mkdir -p "$secrets_dir"
    safe_chmod 700 "$secrets_dir"

    # AES-256-GCM: agentgateway refuses to start unless this is exactly 64 hex
    # characters, which generate_secret produces. Persisted, or every start
    # would log everyone out.
    if [ ! -s "$cookie_file" ]; then
        write_file_atomic "$cookie_file" generate_secret \
            || die "Failed to generate the agentgateway cookie secret"
        safe_chmod 600 "$cookie_file"
        log "Generated the agentgateway session cookie secret"
    fi
    # The credential every /v1 caller presents, open-webui included. Not derived
    # from PASSWORD: llm.<HOST_NAME> carries no forward-auth on /v1, so a
    # PASSWORD leak would otherwise be a free pass to the models. It also has to
    # outlive a rotation - OPENAI_API_KEY is PersistentConfig in Open WebUI, so
    # whatever that container starts with is copied into its database.
    if [ ! -s "$key_file" ]; then
        write_file_atomic "$key_file" generate_secret \
            || die "Failed to generate the agentgateway LLM API key"
        safe_chmod 600 "$key_file"
        log "Generated the agentgateway LLM API key"
    fi
    # What tools on other machines present to the path routes. Separate from the
    # key above so revoking one does not lock the other out. Generated, not taken
    # from .env: empty exits at startup and a placeholder would be a password
    # readable off a tracked file, so Compose can supply no safe default.
    if [ ! -s "$agent_key_file" ]; then
        write_file_atomic "$agent_key_file" generate_secret \
            || die "Failed to generate the agentgateway agent API key"
        safe_chmod 600 "$agent_key_file"
        log "Generated the agentgateway agent API key"
    fi
    # Trilium's own /v1 credential, separate from open-webui's for the same
    # reason agent_api_key is: revoking the notes' access to the models must not
    # log the chat out, and the two are written by different hooks.
    if [ ! -s "$trilium_key_file" ]; then
        write_file_atomic "$trilium_key_file" generate_secret \
            || die "Failed to generate the Trilium LLM API key"
        safe_chmod 600 "$trilium_key_file"
        log "Generated the Trilium LLM API key"
    fi
    # The inbound credential for /mcp. That surface is a different one from /v1
    # and has no gate of its own by default (docs/AI.md), and everything behind
    # it reads and writes every note - so it is nobody else's key.
    if [ ! -s "$mcp_key_file" ]; then
        write_file_atomic "$mcp_key_file" generate_secret \
            || die "Failed to generate the agentgateway MCP API key"
        safe_chmod 600 "$mcp_key_file"
        log "Generated the agentgateway MCP API key"
    fi
    # -R, and after the writes: a root-run systemd boot leaves both a 0700
    # directory the next non-root run cannot mktemp in and 0600 files it cannot
    # read, and this is a blocking pre-start hook.
    fix_ownership "$secrets_dir"

    cookie_secret="$(cat "$cookie_file")"
    llm_api_key="sk-$(cat "$key_file")"
    agent_api_key="sk-$(cat "$agent_key_file")"
    trilium_llm_key="sk-$(cat "$trilium_key_file")"
    mcp_api_key="sk-$(cat "$mcp_key_file")"

    # Minted by scripts/trilium-bootstrap.sh, which runs post-start - so on a
    # fresh boot there is nothing here yet and the MCP target presents a token
    # Trilium answers 401 to. That bootstrap re-runs this hook and recreates
    # agentgateway once it holds the real one, so the gap closes inside the same
    # `make update`.
    #
    # The placeholder is not cosmetic: config.yaml expands this reference, and
    # an empty expansion leaves a null where agentgateway wants a string, which
    # makes it refuse the entire mcp: section at startup. A wrong token degrades
    # to 401 on one target; an empty one takes the gateway down.
    trilium_etapi_token="$(read_trilium_etapi_token)"
    [ -n "$trilium_etapi_token" ] || trilium_etapi_token="pending-trilium-bootstrap"

    client_secret="$(get_oidc_secret agentgateway)" || client_secret=""
    if [ -z "$client_secret" ]; then
        log "WARNING: no Authelia OIDC secret for agentgateway yet; it will not start until there is one"
        return 0
    fi

    mkdir -p "$AGW_ENV_DIR"
    printf 'OIDC_COOKIE_SECRET=%s\nUI_CLIENT_SECRET=%s\nLLM_API_KEY=%s\nAGENT_API_KEY=%s\nTRILIUM_LLM_KEY=%s\nMCP_API_KEY=%s\nTRILIUM_ETAPI_TOKEN=%s\n' \
        "$cookie_secret" "$client_secret" "$llm_api_key" "$agent_api_key" \
        "$trilium_llm_key" "$mcp_api_key" "$trilium_etapi_token" \
        | write_secret_file "$AGW_ENV_FILE" \
        || die "Failed to write $AGW_ENV_FILE"
    safe_chmod 600 "$AGW_ENV_FILE"
    # The systemd unit runs this as root; without this the file lands root:root
    # 0600, and then a non-root `docker compose up` cannot read the env_file
    # (`required: false` covers a missing one, not an unreadable one).
    fix_ownership "$AGW_ENV_FILE"

    # The directory only, never -R: its contents are a database agentgateway
    # owns and a secret this script wrote 0600.
    if [ "$(stat -c '%u:%g' "$data_dir" 2>/dev/null || echo unknown)" != "${WRITER_UID}:${WRITER_GID}" ]; then
        chown "${WRITER_UID}:${WRITER_GID}" "$data_dir" 2>/dev/null \
            || log "WARNING: could not chown $data_dir to ${WRITER_UID}:${WRITER_GID}; agentgateway cannot write its database"
    fi

    log "Ensured agentgateway secrets and data directory"
}

main "$@"
