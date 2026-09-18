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

# Compose interpolates env_file values, so a literal '$' has to be doubled or it
# would be eaten as the start of a variable reference. Every hook that renders a
# generated env_file puts its values through this.
escape_compose_env_value() {
    printf '%s' "$1" | sed 's/[$]/$$/g'
}

# --- Data location ---

# Normalise one data root: strip trailing slashes, then make it absolute
# against PROJECT_DIR the way Compose resolves a relative bind source.
#
# Every caller appends "/something", so a trailing slash here doubled it -
# harmless to open(2), but it reaches anything printing or comparing these
# paths. Guarded so a bare "/" does not become the empty string.
absolute_data_root() {
    local path="$1"

    while :; do
        case "$path" in
            /) break ;;
            */) path="${path%/}" ;;
            *) break ;;
        esac
    done

    case "$path" in
        /*) printf '%s' "$path" ;;
        *) printf '%s/%s' "$PROJECT_DIR" "$path" ;;
    esac
}

resolve_data_location_path() {
    local data_location

    data_location="$(get_env_value DATA_LOCATION)"
    [ -n "$data_location" ] || data_location="./data"

    absolute_data_root "$data_location"
}

# Root the shared Postgres cluster lives under, made absolute the same way.
# Mirrors compose/compose-core.yaml's ${POSTGRES_DATA_LOCATION:-${DATA_LOCATION:-./data}}:
# unset and empty must both fall back, because .env.dist ships the key empty and
# an operator clearing the value means "put it back with the rest of the data",
# not "use the project directory".
resolve_postgres_data_location_path() {
    local postgres_data_location

    postgres_data_location="$(get_env_value POSTGRES_DATA_LOCATION)"
    [ -n "$postgres_data_location" ] || { resolve_data_location_path; return; }

    absolute_data_root "$postgres_data_location"
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

# Docker materialises a *missing* bind-mount source as an empty directory, so a
# path that must be a file can come back as one - and then every `-r`/`-s` guard
# on it reads as success while the file is never written. Restore the file path:
# rmdir when it is only the empty directory compose made, move aside when it is
# not, because a non-empty one is somebody else's data.
# Usage: ensure_config_target_is_file <path>
ensure_config_target_is_file() {
    local target="$1"
    local backup_dir=""

    [ -d "$target" ] || return 0

    if [ -z "$(ls -A "$target" 2>/dev/null)" ]; then
        rmdir "$target" || {
            log "ERROR: could not remove the empty directory at $target"
            return 1
        }
        log "Removed empty directory at $target to restore file path"
        return 0
    fi

    backup_dir="${target}.dir.bak.$(date +%Y%m%d-%H%M%S)"
    mv "$target" "$backup_dir" || {
        log "ERROR: could not move the directory at $target aside"
        return 1
    }
    log "Moved directory $target to $backup_dir to restore file path"
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

# The whole of what a pre-start hook does when its service just needs one or
# more generated secrets in an env file: keep the values already there, mint the
# missing ones, write the file 0600 and hand it back to the project owner.
#
# Usage: ensure_env_secrets <file> <KEY> [KEY...]
#
# It owns the whole file - anything in it that is not a listed key is dropped -
# which is what makes it safe to rewrite on every start. A service whose env
# file also carries settings a human edits must keep its own hook.
#
# Dropping is not the same as losing: a file holding a key nobody asked for is
# copied aside first, the way ensure_config_target_is_file moves a stray
# directory. A secret cannot be regenerated from nothing, and "deterministic"
# is not worth being destructive over the one case that says the caller's key
# list is wrong.
#
# Per key, not all-or-nothing: an env file that lost one of its two keys gets
# that one regenerated and keeps the other, rather than rotating both.
#
# Written once here because the sequence has an invisible failure in it.
# fix_ownership is the last line for a reason - the systemd unit runs the hooks
# as root, so without it the file lands root:root 0600, the next non-root
# `make update` dies reading its own secret, and `docker compose up` cannot load
# an env_file it just wrote. Three hooks shipped without it before
# tests/stack-up-test.sh started checking for it; a hook that calls this cannot
# get it wrong at all.
ensure_env_secrets() {
    local _file="$1"
    local _generated=""
    local _body=""
    local _key=""
    local _value=""

    shift
    [ "$#" -gt 0 ] || {
        log "ERROR: ensure_env_secrets needs at least one key name"
        return 1
    }

    # A bind mount whose source did not exist leaves a *directory* where the
    # file belongs, and docker recreates it on every start until something moves
    # it aside. write_secret_file would refuse; this repairs.
    ensure_config_target_is_file "$_file" || return 1
    mkdir -p "$(dirname "$_file")" || return 1

    # An existing file we cannot read reads back as "no value at all", and the
    # loop below would then mint a fresh secret over a perfectly good one -
    # silently, because the running container froze the old value at creation
    # and only fails auth somewhere else. This is exactly the state a root-run
    # hook leaves behind when fix_ownership had nothing to hand back to (a
    # root-owned PROJECT_DIR), so refuse instead of rotating blind.
    if [ -e "$_file" ] && [ ! -r "$_file" ]; then
        log "ERROR: $_file exists but is not readable - refusing to overwrite it with new secrets"
        return 1
    fi

    for _key in "$@"; do
        _value="$(read_env_value_from_file "$_file" "$_key")"
        if [ -z "$_value" ]; then
            _value="$(generate_secret)" || return 1
            [ -n "$_value" ] || {
                log "ERROR: could not generate a value for $_key"
                return 1
            }
            _generated="$_generated $_key"
        fi
        # A literal newline rather than $(printf): command substitution strips
        # trailing newlines, so the last key would run into the one after it.
        _body="$_body$_key=$_value
"
    done

    # Anything present that no caller claims. The rewrite below would drop it, so
    # it is kept where a human can find it and the log says where.
    if [ -f "$_file" ]; then
        local _unclaimed=""
        local _present=""
        for _present in $(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$_file" 2>/dev/null | tr -d '='); do
            for _key in "$@"; do
                [ "$_present" = "$_key" ] && continue 2
            done
            _unclaimed="$_unclaimed $_present"
        done
        if [ -n "$_unclaimed" ]; then
            local _aside=""
            _aside="${_file}.bak.$(date +%Y%m%d-%H%M%S)"
            cp -p "$_file" "$_aside" || return 1
            safe_chmod 600 "$_aside"
            fix_ownership "$_aside"
            log "WARNING:${_unclaimed} in $_file is claimed by no caller; kept a copy at $_aside"
        fi
    fi

    # `scripts/<name>`, the same string the hooks wrote before this existed, so
    # `grep -rl "Managed by scripts/n8n-pre-start.sh"` still finds its file.
    # %s for the body, so a value holding a % is not read as a format.
    printf '# Managed by scripts/%s - do not edit, values here are generated\n%s' \
        "$(basename "$0")" "$_body" | write_secret_file "$_file" || {
        log "ERROR: could not write $_file"
        return 1
    }
    safe_chmod 600 "$_file"
    fix_ownership "$_file"

    if [ -n "$_generated" ]; then
        log "Generated${_generated} in $_file"
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

# --- Running a sibling script ---

# Run another script from scripts/ by file name, picking the interpreter from
# its extension. The bootstraps are a mix of sh and python3 (AGENTS.md has the
# rule for which is which), and every caller used to hardcode `sh`: pointed at a
# .py, that is a syntax error on line 1, reported as the bootstrap "failing"
# with no hint that the interpreter was the problem.
#
# Usage: script_interpreter <file-name>
script_interpreter() {
    case "$1" in
        *.py) printf 'python3' ;;
        *) printf '/bin/sh' ;;
    esac
}

# An absolute path is used as given, so a caller that located the script itself
# (services.sh globs $PROJECT_DIR/scripts) runs the same file it just tested for,
# rather than a same-named one under $SCRIPT_DIR.
#
# Usage: run_script <file-name|path> [args...]
run_script() {
    local _script="$1"
    shift
    case "$_script" in
        /*) ;;
        *) _script="$SCRIPT_DIR/$_script" ;;
    esac
    "$(script_interpreter "$_script")" "$_script" "$@"
}

# --- Container helpers ---

compose() {
    (cd "$PROJECT_DIR" && docker compose "$@")
}

# Is <service> in COMPOSE_PROFILES? run-if-enabled.sh's test mode is the single
# answer to that question - it is what the systemd units and run-hooks.sh ask -
# so hooks that render a block only when another service exists call it through
# here rather than re-deriving the selection.
# Usage: service_enabled <service>[,<service>...]
service_enabled() {
    /bin/sh "$SCRIPT_DIR/run-if-enabled.sh" "$1"
}

# Export COMPOSE_PROFILES the way the boot path resolves it, unless the caller
# already set one. systemd supplies it (EnvironmentFile=.env, falling back to
# its own Environment=all for installs predating per-service profiles); under
# make there is no such wrapper, so the same two rules are reproduced here.
#
# Empty stays empty: that means core-only, not everything.
#
# Lives here rather than in stack-up.sh because changed-services.sh has to
# resolve the *same* selection to decide which services are running at all - and
# two copies of this is two answers to "is kavita enabled".
resolve_compose_profiles() {
    [ -z "${COMPOSE_PROFILES+x}" ] || return 0

    if grep -qE '^COMPOSE_PROFILES=' "$ENV_FILE" 2>/dev/null; then
        # Compose, systemd and run-if-enabled.sh all strip quotes and CR;
        # get_env_value reads verbatim. Left in, `"stremio"` would match no
        # profile while --remove-orphans deleted the optional containers.
        COMPOSE_PROFILES="$(get_env_value_clean COMPOSE_PROFILES)"
    else
        COMPOSE_PROFILES=all
    fi
    export COMPOSE_PROFILES
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

# Prowlarr's API key, from the host copy of its config.xml rather than through
# `docker exec`: the callers are pre-start hooks, so on a cold boot no container
# is up yet and a container read would come back empty - and a hook would then
# rewrite its env file *without* the Prowlarr block, dropping a source that was
# working. prowlarr-pre-start.sh runs earlier in the same sequence and is what
# puts the key in that file. Empty when it cannot be read; every caller checks.
prowlarr_api_key() {
    local config_file=""
    config_file="$(resolve_data_location_path)/prowlarr/config.xml"
    [ -r "$config_file" ] || return 0
    grep -oE '<ApiKey>[^<]+</ApiKey>' "$config_file" 2>/dev/null \
        | sed -e 's|<ApiKey>||' -e 's|</ApiKey>||' | tr -d '\r\n'
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

# Echo changedetection.io's API access token, or nothing. Minted into the
# datastore on its first start with no environment equivalent, so reading it back
# is the only way to get it. From inside the container: on the host that file is
# a root-owned 0600 a non-root `make update` could not open.
#
# Empty output, never a failing status - same contract as kavita_admin_api_key:
# callers assign it, and `set -e` does not exempt an assignment, so a failing
# status here would kill the hook before it could log its own warning.
# Usage: changedetection_api_key [container]
changedetection_api_key() {
    local container="${1:-pi-changedetection}"

    container_is_running "$container" || return 0

    docker exec "$container" python3 -c \
        'import json; print(json.load(open("/datastore/changedetection.json"))["settings"]["application"].get("api_access_token", ""), end="")' \
        2>/dev/null || true
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
    # service comes up healthy with an empty one.
    ensure_config_target_is_file "$secret_file" || return 1

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
    printf '%s/agentgateway/secrets/trilium_etapi_token' "$(resolve_data_location_path)"
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

# Echo a logged-in Trilium session cookie, or nothing.
#
# Shared by trilium-bootstrap.sh and rotate-password.sh, which both need one and
# would otherwise keep two copies of the same handshake. `POST /login` needs no
# CSRF, but its handler redirects to Authelia rather than checking the password
# once SSO is enrolled - so an empty answer here means "no scriptable way in",
# not "wrong password".
#
# A cookie alone is not a login: a *failed* attempt gets a session too, so the
# result is confirmed against /bootstrap before it is handed back.
# Usage: trilium_open_session <base_url> <password>
trilium_open_session() {
    local base_url="$1" password="$2" headers="" session=""

    [ -n "$password" ] || return 1

    headers="$(jq -cn --arg p "$password" '{password: $p}' \
        | docker_curl_stdin -X POST -D - -o /dev/null \
            -H 'Content-Type: application/json' \
            "$base_url/login" 2>/dev/null)" || return 1

    session="$(printf '%s' "$headers" | tr -d '\r' \
        | sed -n 's/^[Ss]et-[Cc]ookie: *\(trilium\.sid=[^;]*\).*/\1/p' | head -1)"
    [ -n "$session" ] || return 1

    api_get_with_cookie "$base_url" "/bootstrap" "$session" 2>/dev/null \
        | jq -e '.loggedIn == true' >/dev/null 2>&1 || return 1

    printf '%s' "$session"
}

# Echo "<cookie header>|<csrf token>" for a write against Trilium's /api.
#
# One request, not two: csrf-csrf binds the token to the session id and
# /bootstrap re-issues `trilium.sid` alongside `trilium-csrf`, so headers and
# body fetched separately pair a token with the wrong session - a 403 visible
# only in Trilium's own log.
# Usage: trilium_csrf_material <base_url> <session>
trilium_csrf_material() {
    local base_url="$1" session="$2" response="" headers="" body="" cookies="" token=""

    response="$(docker_curl -i -H "Cookie: $session" "$base_url/bootstrap" 2>/dev/null)" || return 1

    headers="$(printf '%s' "$response" | tr -d '\r' | sed -n '1,/^$/p')"
    body="$(printf '%s' "$response" | tr -d '\r' | sed -n '/^$/,$p' | tail -n +2)"

    token="$(printf '%s' "$body" | jq -r '.csrfToken // empty' 2>/dev/null)"
    [ -n "$token" ] || return 1

    # `-d';'`, one character: paste treats -d as a *list* it cycles through, so
    # `-d'; '` joins the third cookie with a space instead of a semicolon and
    # mangles it. Two cookies hid that; /bootstrap sets exactly two today.
    cookies="$(printf '%s' "$headers" \
        | sed -n 's/^[Ss]et-[Cc]ookie: *\([^;]*\).*/\1/p' | paste -sd';' -)"
    [ -n "$cookies" ] || cookies="$session"

    printf '%s|%s' "$cookies" "$token"
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
