#!/bin/sh
# Shared library for pi-pcloud scripts.
# Source with: . "$(dirname "$0")/lib.sh"

# --- Project paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$SCRIPT_DIR")}"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0" .sh)}"

# --- Logging ---

log() {
    echo "[$SCRIPT_NAME] $(date '+%H:%M:%S') $*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

# --- Privilege prefix ---

# Empty when already root, `sudo` otherwise — the same rule install.sh and the
# Makefile apply to their own root-only commands, and for the same reason: a
# root-only image often ships no sudo binary at all, so a bare `sudo cp` there
# fails with "not found" and any `|| true` around it reports success. Use as
# `$SUDO cp ...`, unquoted, so the empty case expands to nothing.
# shellcheck disable=SC2034 # used as $SUDO by the scripts that source this
if [ "$(id -u)" = "0" ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# --- Environment helpers ---

# Docker Compose's .env parser mangles more than `$VAR` interpolation: a
# trailing backslash escapes the newline, an unquoted value is truncated at
# whitespace-then-`#` (inline comment), surrounding quotes are stripped and
# leading/trailing whitespace is trimmed — while these scripts read .env
# verbatim (read_env_value_from_file below), so any of those would hand the
# services and the scripts two different values. install.sh refuses them at
# the prompt and the Makefile's check-env re-checks the file; both call this
# function so the two cannot drift. A mid-value backslash is fine (Compose
# passes it through verbatim), only a trailing one escapes the newline.
# Newlines can only arrive from a pre-exported value; ENV_LF is a literal
# newline because $(...) strips trailing ones.
ENV_LF='
'
# shellcheck disable=SC2034 # read by install.sh and the Makefile's check-env
ENV_VALUE_RULES="must not contain '\$', a newline or ' #', must not end with '\\', and must not start or end with a quote or whitespace (Docker Compose's .env parser mangles these)"

# shellcheck disable=SC1003 # '\' is a literal backslash pattern, not an escaped quote
env_value_is_safe() {
    case "$1" in
        *'$'* | *[[:space:]]'#'* | *'\' | \"* | *\" | \'* | *\' | *"$ENV_LF"*) return 1 ;;
        [[:space:]]* | *[[:space:]]) return 1 ;;
        *) return 0 ;;
    esac
}

read_env_value_from_file() {
    local file="$1"
    local key="$2"

    if [ ! -f "$file" ]; then
        return 0
    fi

    grep "^$key=" "$file" 2>/dev/null | tail -n1 | cut -d'=' -f2-
}

get_env_value() {
    read_env_value_from_file "$ENV_FILE" "$1"
}

# Strip a trailing CR (a .env edited from Windows over Samba) and one layer of
# surrounding quotes — what Compose, systemd and run-if-enabled.sh all do to a
# value, and what get_env_value deliberately does not. Reading a list verbatim
# and writing it back is how a CR or a quote ends up *mid*-value, where it
# matches no profile at all while --remove-orphans deletes the containers.
unquote_env_value() {
    local value=""
    value="$(printf '%s' "$1" | tr -d '\r')"
    case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    printf '%s' "$value"
}

get_env_value_clean() {
    unquote_env_value "$(get_env_value "$1")"
}

# --- Data location ---

resolve_data_location_path() {
    local data_location

    data_location="$(get_env_value DATA_LOCATION)"
    [ -n "$data_location" ] || data_location="./data"

    # Every caller appends "/something", so a trailing slash here doubled it -
    # harmless to open(2), but it reaches anything printing or comparing these
    # paths. Guarded so a bare "/" does not become the empty string.
    while :; do
        case "$data_location" in
            /) break ;;
            */) data_location="${data_location%/}" ;;
            *) break ;;
        esac
    done

    case "$data_location" in
        /*) printf '%s' "$data_location" ;;
        *) printf '%s/%s' "$PROJECT_DIR" "$data_location" ;;
    esac
}

# --- Permissions ---

safe_chmod() {
    local mode="$1"
    local path="$2"
    if ! chmod "$mode" "$path" 2>/dev/null; then
        log "WARNING: could not chmod $mode $path (insufficient permissions?)"
    fi
}

# Fix ownership of a path to match the project directory owner so non-root
# users can still read generated files after a root-run systemd start.
fix_ownership() {
    local _owner
    _owner=$(stat -c '%u:%g' "$PROJECT_DIR" 2>/dev/null || true)
    if [ -n "$_owner" ] && [ "$_owner" != "0:0" ]; then
        chown -R "$_owner" "$1" 2>/dev/null || true
    fi
}

# --- Secret generation ---

# Run a generator and put its output at $1 only if it succeeded and produced
# something. `cmd > "$file"` truncates the target *before* cmd runs, so a
# generator that fails (missing python3, missing openssl, full disk) leaves an
# empty file behind — and every `[ ! -f "$file" ]` guard in this repo then
# treats that empty file as already generated, forever. The temp file is made
# next to the destination so the mv is atomic and inherits its directory mode.
# Usage: write_file_atomic <dest> <cmd> [args...]
write_file_atomic() {
    local dest="$1"
    shift
    local tmp=""
    # Docker creates a *directory* at a missing bind-mount source; mv into it
    # would succeed while the caller believes it wrote a file (the same trap
    # ensure_config_target_is_file exists for). Refuse it explicitly.
    if [ -d "$dest" ]; then
        log "ERROR: $dest is a directory (created by a bind mount?) - refusing to write a file there"
        return 1
    fi
    tmp="$(mktemp "${dest}.XXXXXX")" || return 1
    if "$@" > "$tmp" && [ -s "$tmp" ] && mv "$tmp" "$dest"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Same idea for a *rendered* file that carries a secret. `cmd > "$file"` creates
# it under the caller's umask, world-readable until a chmod that may never come;
# mktemp is 0600 from creation and mv preserves that.
# Usage: <producer> | write_secret_file <dest>
write_secret_file() {
    local dest="$1"
    local tmp=""
    if [ -d "$dest" ]; then
        log "ERROR: $dest is a directory (created by a bind mount?) - refusing to write a file there"
        return 1
    fi
    tmp="$(mktemp "${dest}.XXXXXX")" || return 1
    if cat > "$tmp" && [ -s "$tmp" ] && mv "$tmp" "$dest"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

generate_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        log "WARNING: openssl not found; falling back to /dev/urandom"
        head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n'
    fi
}

# Hash a plaintext secret using PBKDF2-SHA512 (Authelia's default format).
# Requires python3 with hashlib (stdlib).
# Passed through the environment rather than argv: argv is world-readable in
# the host's process table for the lifetime of the python3 call.
hash_pbkdf2() {
    PBKDF2_PLAINTEXT="$1" python3 -c "
import hashlib, os, base64
pw = os.environ['PBKDF2_PLAINTEXT'].encode()
salt = os.urandom(16)
dk = hashlib.pbkdf2_hmac('sha512', pw, salt, 310000)
s = base64.b64encode(salt).rstrip(b'=').decode().replace('+','.')
d = base64.b64encode(dk).rstrip(b'=').decode().replace('+','.')
print(f'\$pbkdf2-sha512\$310000\${s}\${d}')
"
}

# --- Container helpers ---

compose() {
    (cd "$PROJECT_DIR" && docker compose "$@")
}

# Silent generic retry loop; the caller logs around it.
# Usage: wait_for_cmd <max_retries> <interval_seconds> <command...>
wait_for_cmd() {
    local max_retries="$1"
    local interval="$2"
    shift 2

    for i in $(seq 1 "$max_retries"); do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$interval"
    done
    return 1
}

# Usage: wait_for_container <name> [max_retries] [interval_seconds]
wait_for_container() {
    local name="$1"
    local max_retries="${2:-120}"
    local interval="${3:-2}"

    log "Waiting for $name container to appear..."
    for i in $(seq 1 "$max_retries"); do
        if docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
            log "$name container is running"
            return 0
        fi
        sleep "$interval"
    done
    log "ERROR: $name container did not start in time"
    return 1
}

# Usage: wait_for_health <name> [max_retries] [interval_seconds]
wait_for_health() {
    local name="$1"
    local max_retries="${2:-120}"
    local interval="${3:-2}"
    local status

    log "Waiting for $name health status..."
    for i in $(seq 1 "$max_retries"); do
        status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || true)
        if [ "$status" = "healthy" ]; then
            log "$name container is healthy"
            return 0
        fi
        sleep "$interval"
    done
    log "ERROR: $name container did not become healthy in time"
    return 1
}

container_is_running() {
    local name="$1"
    docker ps --format '{{.Names}}' | grep -q "^${name}$"
}

# Mint a 1-year Headscale API key. Headscale's json output moved the key
# between a bare string and an object across versions, hence the two parses.
create_headscale_api_key() {
    local raw_output api_key
    raw_output=$(docker exec pi-headscale "${HEADSCALE_BIN:-headscale}" apikeys create --expiration 8760h --output json 2>/dev/null | tr -d '\r\n')
    api_key=$(printf '%s' "$raw_output" | sed -n -E 's/^"([^"]+)"$/\1/p')
    if [ -z "$api_key" ]; then
        api_key=$(printf '%s' "$raw_output" | grep -oE '"(api_key|apiKey|key)"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/^"[^"]+"[[:space:]]*:[[:space:]]*"([^"]+)"$/\1/')
    fi
    printf '%s' "$api_key"
}

# Like wait_for_health, but a timeout is a warning rather than an error.
# Usage: wait_for_health_warning <name> [max_retries] [interval_seconds]
# Echo a Kavita admin's API key, or nothing. Read from kavita.db rather than the API
# because our own OIDC config sets DisablePasswordAuthentication, so there is no
# credential a script could log in with - and the one endpoint that works without a
# password (/api/Plugin/authenticate) needs this very key. Copied out with docker cp
# because the volume is not host-readable without root; the -wal file comes too, or a
# key created since the last checkpoint would be missed.
kavita_admin_api_key() {
    _kak_container="${1:-pi-kavita}"
    container_is_running "$_kak_container" || return 0

    _kak_tmp="$(mktemp -d)" || return 0
    docker cp "$_kak_container:/config/kavita.db" "$_kak_tmp/kavita.db" >/dev/null 2>&1 || {
        rm -rf "$_kak_tmp"
        return 0
    }
    docker cp "$_kak_container:/config/kavita.db-wal" "$_kak_tmp/kavita.db-wal" >/dev/null 2>&1 || true

    KAVITA_DB="$_kak_tmp/kavita.db" python3 - <<'PY' 2>/dev/null || true
import os, sqlite3, sys

# Kavita 0.9.x keeps API keys in AppUserAuthKey, not AspNetUsers.ApiKey (always NULL).
# Guard the whole thing: the schema is not stable across Kavita majors, and a widget
# key is never worth failing a boot over.
try:
    db = sqlite3.connect(f"file:{os.environ['KAVITA_DB']}?mode=ro", uri=True)
    row = db.execute("""
        select k.Key from AppUserAuthKey k
        join AspNetUserRoles ur on ur.UserId = k.AppUserId
        join AspNetRoles r on r.Id = ur.RoleId
        where r.Name = 'Admin' and k.Name = 'opds'
        order by k.AppUserId limit 1
    """).fetchone()
except Exception:
    sys.exit(0)

if row and row[0]:
    print(row[0], end="")
PY
    rm -rf "$_kak_tmp"
}

# A short-lived admin JWT for Kavita's API. /api/Plugin/authenticate is the only
# credential path left once our OIDC config sets DisablePasswordAuthentication, so
# every script that has to talk to Kavita goes through here. Empty output means no
# admin exists yet (fresh install) - callers warn and skip rather than fail a boot.
# Usage: kavita_token [container]
kavita_token() {
    _kt_container="${1:-pi-kavita}"
    _kt_key="$(kavita_admin_api_key "$_kt_container")"
    [ -n "$_kt_key" ] || return 0

    KAVITA_KEY="$_kt_key" docker exec -i -e KAVITA_KEY "$_kt_container" sh -c \
        'curl -sS -X POST "http://localhost:5000/api/Plugin/authenticate?apiKey=$KAVITA_KEY&pluginName=pi-web-bootstrap"' \
        2>/dev/null | jq -r '.token // empty'
}

# Where scripts/audiobookshelf-bootstrap.sh persists the API key every later
# script authenticates with. Inside /config rather than beside it so Backrest's
# read-only mount of that directory carries it off-site: local logins are
# switched off once the key exists, which makes it the only credential left, and
# a lost one can then only be replaced by hand from a browser SSO session.
# Usage: audiobookshelf_api_key_file
audiobookshelf_api_key_file() {
    printf '%s/audiobookshelf/config/pi-web-api-key' "$(resolve_data_location_path)"
}

# Echo the stored Audiobookshelf API key, or nothing. Probed rather than
# trusted: the value is a JWT the server can have forgotten (a key deleted in
# the UI, a /config restored from a snapshot older than the file), and a dead
# key must fall through to the password login below rather than fail the caller.
# Usage: audiobookshelf_api_key [base_url]
audiobookshelf_api_key() {
    local base_url="${1:-http://pi-audiobookshelf}"
    local file="" key=""

    file="$(audiobookshelf_api_key_file)"
    [ -r "$file" ] || return 1
    key="$(tr -d '\r\n' < "$file")"
    [ -n "$key" ] || return 1

    docker_curl -o /dev/null -H "Authorization: Bearer $key" "$base_url/api/me" >/dev/null 2>&1 || return 1
    printf '%s' "$key"
}

# Audiobookshelf hands out an access token only in exchange for a login, and the
# root account it created in scripts/audiobookshelf-bootstrap.sh is the one
# account whose credentials are known: ADMIN_USER / PASSWORD from .env. Returns
# nothing before that bootstrap has run, which is the expected state on a fresh
# install. The body goes over stdin so the password never reaches `ps`.
#
# Only works while `local` is still an active auth method: the /login route is
# wired to passport's local strategy, and disabling the method unuses that
# strategy, so the request errors rather than 401s. That is why this is the
# fallback and the API key is the primary - see audiobookshelf_token.
# Usage: audiobookshelf_password_token [base_url]
audiobookshelf_password_token() {
    local base_url="${1:-http://pi-audiobookshelf}"
    local user="" password=""

    user="$(get_env_value ADMIN_USER)"
    password="$(get_env_value PASSWORD)"
    [ -n "$user" ] && [ -n "$password" ] || return 1

    jq -cn --arg u "$user" --arg p "$password" '{username: $u, password: $p}' \
        | api_send_json_stdin POST "$base_url" "/login" 2>/dev/null \
        | jq -r '.user.accessToken // empty'
}

# Echo something that authenticates as the Audiobookshelf root account, or
# nothing. The stored API key first, because it is what still works once local
# logins are off; the password login second, because a fresh install has no key
# yet and minting one needs an authenticated call.
# Usage: audiobookshelf_token [base_url]
audiobookshelf_token() {
    local base_url="${1:-http://pi-audiobookshelf}"

    audiobookshelf_api_key "$base_url" && return 0
    audiobookshelf_password_token "$base_url"
}

wait_for_health_warning() {
    local name="$1"
    local max_retries="${2:-120}"
    local interval="${3:-2}"
    local status

    for i in $(seq 1 "$max_retries"); do
        status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || true)
        if [ "$status" = "healthy" ]; then
            log "$name container is healthy"
            return 0
        fi
        sleep "$interval"
    done

    log "WARNING: Timed out waiting for $name health"
    return 1
}

authelia_container_has_oidc_materials() {
    local client_id="$1"

    if ! container_is_running "pi-authelia"; then
        return 1
    fi

    compose exec -T authelia sh -ec "[ -r /config/secrets/oidc_${client_id}_secret.txt ] && grep -q \"client_id: ${client_id}\" /config/configuration.yml" >/dev/null 2>&1
}

# Usage: ensure_authelia_oidc_materials <client_id> <display_name> [max_retries] [interval_seconds]
ensure_authelia_oidc_materials() {
    local client_id="$1"
    local display_name="$2"
    local max_retries="${3:-120}"
    local interval="${4:-2}"
    local data_root config_file secret_file pre_start_script

    [ -n "$client_id" ] || {
        log "ERROR: Missing client_id for ensure_authelia_oidc_materials"
        return 1
    }

    [ -n "$display_name" ] || display_name="$client_id"

    data_root="$(resolve_data_location_path)"
    config_file="$data_root/authelia-config/configuration.yml"
    secret_file="$data_root/authelia-config/secrets/oidc_${client_id}_secret.txt"
    pre_start_script="$PROJECT_DIR/scripts/authelia-pre-start.sh"

    # A container that started before this secret existed leaves a *directory*
    # here, and every guard below then reads as success: `-r` is true for a
    # directory, and generate_oidc_secret's `[ ! -s ]` is false because a
    # directory has a size. The client is silently never given a secret and the
    # service comes up healthy with an empty one. rmdir, not rm -rf: only the
    # empty directory compose made; a non-empty one is somebody else's data.
    if [ -d "$secret_file" ]; then
        if rmdir "$secret_file" 2>/dev/null; then
            log "Removed the empty directory compose left at $secret_file (it started before the secret existed)"
        else
            log "ERROR: $secret_file is a non-empty directory; refusing to touch it"
            return 1
        fi
    fi

    if [ -r "$secret_file" ] && [ -f "$config_file" ] && grep -q "client_id: ${client_id}" "$config_file" 2>/dev/null; then
        return 0
    fi

    if authelia_container_has_oidc_materials "$client_id"; then
        return 0
    fi

    log "Detected missing ${display_name} OIDC materials in Authelia config data"

    if [ ! -f "$pre_start_script" ]; then
        log "WARNING: Missing $pre_start_script; cannot auto-heal Authelia OIDC materials"
        return 1
    fi

    if ! sh "$pre_start_script"; then
        log "WARNING: authelia-pre-start.sh failed while preparing ${display_name} OIDC materials"
        return 1
    fi

    if container_is_running "pi-authelia"; then
        log "Restarting Authelia to apply OIDC client updates"
        if compose restart authelia >/dev/null; then
            wait_for_health_warning "pi-authelia" "$max_retries" "$interval" || true
        else
            log "WARNING: Failed to restart Authelia automatically"
        fi
    fi

    if [ ! -r "$secret_file" ] || [ ! -f "$config_file" ] || ! grep -q "client_id: ${client_id}" "$config_file" 2>/dev/null; then
        if authelia_container_has_oidc_materials "$client_id"; then
            return 0
        fi
        log "WARNING: ${display_name} OIDC materials are still missing after regeneration attempt"
        return 1
    fi

    return 0
}

# --- Trilium ---

# Where scripts/trilium-bootstrap.sh leaves the ETAPI token and where
# scripts/agentgateway-pre-start.sh reads it. One definition: the two run in
# different phases, and a drifting path fails silently - agentgateway would
# just send no credential.
#
# Under agentgateway's secrets directory, not Trilium's data directory, even
# though Trilium mints it: that data directory is `chown -R`'d to uid 1000 by
# the container on every start, so a hook running as anyone else cannot manage
# a file inside it. agentgateway-pre-start.sh already owns this directory, and
# agentgateway is the only consumer.
# Usage: trilium_etapi_token_file
trilium_etapi_token_file() {
    printf '%s/agentgateway/secrets/%s' "$(resolve_data_location_path)" "trilium_etapi_token"
}

# Echo the stored ETAPI token, or nothing before it has been minted. Never
# fails: callers treat empty as "not ready yet".
# Usage: read_trilium_etapi_token
read_trilium_etapi_token() {
    local token_file=""

    token_file="$(trilium_etapi_token_file)"
    [ -r "$token_file" ] || return 0
    cat "$token_file" 2>/dev/null || return 0
}

# --- OIDC secret retrieval ---

# Falls back from the env var to the secret file on disk to a docker exec, so it
# works before the file exists on a fresh install and after the stack is up.
# Usage: get_oidc_secret <client_name> [env_var_name]
get_oidc_secret() {
    local client_name="$1"
    local env_var_name="${2:-}"
    local secret_value data_root secret_file

    if [ -n "$env_var_name" ]; then
        secret_value="$(eval "printf '%s' \"\${$env_var_name:-}\"")"
        [ -z "$secret_value" ] && secret_value="$(get_env_value "$env_var_name")"
        if [ -n "$secret_value" ]; then
            printf '%s' "$secret_value"
            return 0
        fi
    fi

    data_root="$(resolve_data_location_path)"
    secret_file="$data_root/authelia-config/secrets/oidc_${client_name}_secret.txt"
    if [ -r "$secret_file" ]; then
        tr -d '\r\n' < "$secret_file"
        return 0
    fi

    secret_value="$(compose exec -T authelia sh -ec "cat /config/secrets/oidc_${client_name}_secret.txt" 2>/dev/null | tr -d '\r\n')"
    if [ -n "$secret_value" ]; then
        printf '%s' "$secret_value"
        return 0
    fi

    return 1
}

# --- Docker API helpers ---

# A throwaway container, so no service needs curl installed to be probed.
#
# The timeouts matter: these run from hooks under a Type=oneshot unit with no
# TimeoutStartSec, so a service that accepts the connection and never answers
# hangs the whole start sequence forever.
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.12.1}"
CURL_TIMEOUTS="--connect-timeout 5 --max-time 30"

# Which network the throwaway container joins. Almost every service is on
# frontend; a caller whose target sits on a dedicated segment overrides it.
# Getting it wrong is not subtle: the service name does not resolve at all.
DOCKER_CURL_NETWORK="${DOCKER_CURL_NETWORK:-frontend}"

docker_curl() {
    # shellcheck disable=SC2086  # CURL_TIMEOUTS is two flag pairs, split on purpose
    docker run --rm --network "$DOCKER_CURL_NETWORK" "$CURL_IMAGE" -fsS $CURL_TIMEOUTS "$@"
}

# Same, but the request body is read from stdin (`--data @-`) instead of being
# passed as an argument. `docker run` puts its whole argv in the host's process
# table, so a `-d '{"password":"..."}'` is readable by any local `ps` for the
# length of the call. Use this whenever the payload carries a credential.
docker_curl_stdin() {
    # shellcheck disable=SC2086  # CURL_TIMEOUTS is two flag pairs, split on purpose
    docker run --rm -i --network "$DOCKER_CURL_NETWORK" "$CURL_IMAGE" -fsS $CURL_TIMEOUTS --data @- "$@"
}

# Usage: api_send_json_stdin <method> <base_url> <path> [cookie]  (body on stdin)
api_send_json_stdin() {
    local method="$1"
    local base_url="$2"
    local path="$3"
    local cookie="${4:-}"

    if [ -n "$cookie" ]; then
        docker_curl_stdin -X "$method" \
            -H "Cookie: $cookie" \
            -H 'Content-Type: application/json' \
            "$base_url$path"
    else
        docker_curl_stdin -X "$method" \
            -H 'Content-Type: application/json' \
            "$base_url$path"
    fi
}

# Usage: wait_for_http_endpoint <url> <name> [max_retries] [interval_seconds]
wait_for_http_endpoint() {
    local url="$1"
    local name="$2"
    local max_retries="${3:-120}"
    local interval="${4:-2}"

    [ -n "$name" ] || name="$url"

    log "Waiting for $name..."
    # shellcheck disable=SC2034 # a countdown, the body does not need the index
    for i in $(seq 1 "$max_retries"); do
        if docker_curl "$url" >/dev/null 2>&1; then
            log "$name is reachable"
            return 0
        fi
        sleep "$interval"
    done

    log "ERROR: $name did not become reachable"
    return 1
}

# Usage: api_get_with_cookie <base_url> <path> [cookie]
api_get_with_cookie() {
    local base_url="$1"
    local path="$2"
    local cookie="${3:-}"

    if [ -n "$cookie" ]; then
        docker_curl -H "Cookie: $cookie" "$base_url$path"
    else
        docker_curl "$base_url$path"
    fi
}


# --- qBittorrent ---

# Set the WebUI login through setPreferences, unauthenticated: the config
# qbittorrent-pre-start.sh renders enables auth bypass for 127.0.0.1. Prints the
# HTTP status on stdout so each caller reports it in its own voice.
# Usage: qbittorrent_set_credentials <container> <username> <password>
#
# Shared by qbittorrent-bootstrap.sh (first install) and rotate-password.sh
# (after a leak), which kept two copies that had already drifted: the rotation
# one passed the new password to jq as a command-line argument, putting it on
# the host's process table for the length of the call. One copy, the safe way.
qbittorrent_set_credentials() {
    local container="$1"
    local username="$2"
    local password="$3"
    local prefs=""

    # The password goes through the environment, not argv, to keep it off the
    # host's process table.
    prefs="$(QB_WEB_UI_PASSWORD="$password" jq -nc --arg u "$username" \
        '{web_ui_username: $u, web_ui_password: $ENV.QB_WEB_UI_PASSWORD}')" || return 1

    # --data-urlencode rather than a raw body: qBittorrent's form parser decodes
    # a '+' in either value back to a space (silently storing a login nobody can
    # use), and a '&' truncates the field. Both values can contain either —
    # ADMIN_USER is arbitrary user input.
    printf '%s' "$prefs" | docker exec -i "$container" curl -sS \
        -H "Referer: http://127.0.0.1:8080" \
        -w '%{http_code}' \
        -o /dev/null \
        --data-urlencode "json@-" \
        "http://127.0.0.1:8080/api/v2/app/setPreferences"
}

# --- Utilities ---

# Escape a value for use as the replacement in a `sed "s|…|…|g"` render: a
# literal \, & or | would otherwise be interpreted (or terminate the
# expression) and corrupt the rendered config. Values read via get_env_value
# cannot contain newlines (it is line-based), so those need no handling.
sed_escape() {
    printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

is_truthy() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

# Deduped, in the given priority order, always ending with "admin".
# Usage: build_candidate_usernames "$EMAIL" "$ADMIN_USER"
build_candidate_usernames() {
    local result="" candidate
    for candidate in "$@"; do
        [ -n "$candidate" ] || continue
        case " $result " in
            *" $candidate "*) ;;
            *) result="${result:+$result }$candidate" ;;
        esac
    done
    [ -n "$result" ] || result="admin"
    case " $result " in
        *" admin "*) ;;
        *) result="$result admin" ;;
    esac
    printf '%s' "$result"
}

normalize_json() {
    if [ -z "${1:-}" ]; then
        printf '[]'
        return 0
    fi

    printf '%s' "$1" | jq -c 'if type == "array" then sort else . end'
}
