#!/bin/bash
# Auto-initialization script for Beszel Hub + beszel-agent token bootstrap.
# Ensures a permanent universal token exists, persists it to
# config/beszel-agent/agent.env, then
# (re)starts beszel-agent so first boot works out-of-the-box.

set -euo pipefail

. "$(dirname "$0")/lib.sh"

NTFY_ENV_FILE="$PROJECT_DIR/config/ntfy/ntfy.env"
AGENT_ENV_DIR="$PROJECT_DIR/config/beszel-agent"
AGENT_ENV_FILE="$AGENT_ENV_DIR/agent.env"
MAX_RETRIES=90
RETRY_INTERVAL=2
HUB_URL_DOCKER="http://pi-beszel:8090"
DEFAULT_BESZEL_NTFY_TOPIC="pi"
DEFAULT_BESZEL_TEMP_ALERT_VALUE="70"
DEFAULT_BESZEL_TEMP_ALERT_MIN="5"
DEFAULT_BESZEL_NTFY_SCHEME="http"
DEFAULT_BESZEL_OIDC_PROVIDER_NAME="oidc"
DEFAULT_BESZEL_OIDC_PROVIDER_DISPLAY_NAME="Authelia"
DEFAULT_BESZEL_OIDC_SCOPE="openid profile email"
CONFIG_UPDATED=0

get_agent_env_value() {
    read_env_value_from_file "$AGENT_ENV_FILE" "$1"
}

get_ntfy_env_value() {
    read_env_value_from_file "$NTFY_ENV_FILE" "$1"
}

upsert_env_value() {
    local file="$1"
    local key="$2"
    local value="$3"
    local tmp_file

    tmp_file=$(mktemp)
    awk -v k="$key" -v v="$value" '
        BEGIN { done = 0 }
        $0 ~ ("^" k "=") {
            if (!done) {
                print k "=" v
                done = 1
            }
            next
        }
        { print }
        END {
            if (!done) {
                print k "=" v
            }
        }
    ' "$file" > "$tmp_file"

    mv "$tmp_file" "$file"
}

set_agent_env_value() {
    upsert_env_value "$AGENT_ENV_FILE" "$1" "$2"
    chmod 600 "$AGENT_ENV_FILE" 2>/dev/null || true
}

resolve_key_from_env() {
    local value

    value=$(get_env_value BESZEL_AGENT_KEY)
    if [ -n "$value" ]; then
        printf '%s' "$value"
        return 0
    fi

    value=$(get_env_value BESZEL_KEY)
    if [ -n "$value" ]; then
        printf '%s' "$value"
        return 0
    fi

    value=$(get_env_value KEY)
    if [ -n "$value" ]; then
        printf '%s' "$value"
        return 0
    fi
}

get_beszel_runtime_env_value() {
    local key="$1"
    docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' pi-beszel 2>/dev/null | grep "^${key}=" | tail -n1 | cut -d'=' -f2- || true
}

beszel_password_auth_disabled() {
    local value
    value=$(get_beszel_runtime_env_value DISABLE_PASSWORD_AUTH)
    is_truthy "$value"
}

prepare_agent_env_for_passwordless_mode() {
    local existing_token existing_key sourced_key

    existing_token=$(get_agent_env_value TOKEN)
    existing_key=$(get_agent_env_value KEY)

    if [ -z "$existing_key" ]; then
        sourced_key=$(resolve_key_from_env)
        if [ -n "$sourced_key" ]; then
            set_agent_env_value KEY "$sourced_key"
            CONFIG_UPDATED=1
            existing_key="$sourced_key"
            log "Seeded KEY in $AGENT_ENV_FILE from environment"
        fi
    fi

    if [ -n "$existing_token" ] && [ -n "$existing_key" ]; then
        return 0
    fi

    return 1
}

extract_json_field() {
    printf '%s' "$1" | tr -d '\n' | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

extract_json_bool() {
    printf '%s' "$1" | tr -d '\n' | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p"
}

escape_json() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

url_encode() {
    _value="$1"

    if ! command -v python3 >/dev/null 2>&1; then
        printf '%s' "$_value"
        return 0
    fi

    python3 - "$_value" <<'PY'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe=""))
PY
}

extract_settings_record_id() {
    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi

    python3 -c 'import json,sys
s = sys.stdin.read() or "{}"
try:
    data = json.loads(s)
except json.JSONDecodeError:
    sys.exit(1)
items = data.get("items") or []
print(items[0].get("id", "") if items else "")'
}

# Outputs one "record_id<TAB>payload" line per user_settings record that needs
# the webhook applied, so callers can PATCH each record individually.
build_all_user_settings_patches() {
    _webhook_url="$1"

    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi

    python3 -c 'import json,sys
from urllib.parse import urlparse

new_webhook = sys.argv[1]
s = sys.stdin.read() or "{}"
try:
    data = json.loads(s)
except json.JSONDecodeError:
    sys.exit(1)
items = data.get("items") or []
target = urlparse(new_webhook)

for item in items:
    record_id = item.get("id", "")
    if not record_id:
        continue
    settings = item.get("settings") or {}
    webhooks = settings.get("webhooks") or []

    # remove legacy/duplicate ntfy beszel webhooks targeting the same host/topic
    normalized = []
    for webhook in webhooks:
        parsed = urlparse(webhook)
        is_same_beszel_ntfy_target = (
            parsed.scheme == "ntfy"
            and (parsed.hostname or "") == (target.hostname or "")
            and (parsed.username or "") == "beszel"
            and (parsed.path or "") == (target.path or "")
        )
        if not is_same_beszel_ntfy_target:
            normalized.append(webhook)

    webhooks = normalized
    if new_webhook not in webhooks:
        webhooks.append(new_webhook)
    settings["webhooks"] = webhooks
    payload = json.dumps({"settings": settings}, separators=(",", ":"))
    print(f"{record_id}\t{payload}")' "$_webhook_url"
}

count_system_records() {
    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi

    python3 -c 'import json,sys
s = sys.stdin.read() or "{}"
try:
    data = json.loads(s)
except json.JSONDecodeError:
    sys.exit(1)
items = data.get("items") or []
print(len(items))'
}

count_json_array_items() {
    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi

    python3 -c 'import json,sys
s = sys.stdin.read() or "[]"
try:
    data = json.loads(s)
except json.JSONDecodeError:
    sys.exit(1)
if isinstance(data, list):
    print(len(data))
else:
    print(0)'
}

build_system_user_sync_updates() {
    # argv[1]: JSON array of all known user IDs that every system should expose
    local _all_user_ids_json="${1:-[]}"

    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi

    python3 -c 'import json,sys
from collections import defaultdict

# All known Beszel users — every system should be visible to all of them.
try:
    all_user_ids = set(json.loads(sys.argv[1]))
except Exception:
    all_user_ids = set()

s = sys.stdin.read() or "{}"
try:
    data = json.loads(s)
except json.JSONDecodeError:
    sys.exit(1)

items = data.get("items") or []
groups = defaultdict(list)

for item in items:
    name = (item.get("name") or "").strip()
    if not name:
        continue
    groups[name].append(item)

updates = []
for _, group in groups.items():
    # Pick the authoritative record: prefer "up" systems, then most recently updated.
    up_candidates = [item for item in group if (item.get("status") or "").lower() == "up"]
    target_candidates = up_candidates if up_candidates else group
    target = sorted(target_candidates, key=lambda item: item.get("updated") or "", reverse=True)[0]

    # Union: users from every same-named record + all known users.
    merged_users = set(all_user_ids)
    for item in group:
        for user_id in (item.get("users") or []):
            if user_id:
                merged_users.add(user_id)

    if not merged_users:
        continue

    current_users = set(user_id for user_id in (target.get("users") or []) if user_id)
    if current_users == merged_users:
        continue

    updates.append({"id": target.get("id"), "users": list(merged_users)})

print(json.dumps(updates, separators=(",", ":")))' "$_all_user_ids_json"
}

extract_system_user_sync_lines() {
    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi

    python3 -c 'import json,sys
s = sys.stdin.read() or "[]"
try:
    updates = json.loads(s)
except json.JSONDecodeError:
    sys.exit(1)

for update in updates:
    system_id = update.get("id")
    users = [user_id for user_id in (update.get("users") or []) if user_id]
    if not system_id or not users:
        continue
    payload = json.dumps({"users": users}, separators=(",", ":"))
    print(f"{system_id}\t{payload}")'
}

sync_system_user_access() {
    local auth_token="$1"
    local users_response all_user_ids_json systems_response updates_json update_count system_id payload

    if ! command -v python3 >/dev/null 2>&1; then
        log "WARNING: python3 not found; skipping system access sync"
        return 0
    fi

    # Collect all known user IDs so every system is visible to every user.
    users_response=$(beszel_api_get "$auth_token" "/api/collections/users/records" \
        --data-urlencode "page=1" \
        --data-urlencode "perPage=500" \
        --data-urlencode "fields=id" \
    )
    all_user_ids_json=$(printf '%s' "$users_response" | python3 -c '
import json,sys
try:
    data=json.load(sys.stdin)
except Exception:
    print("[]"); sys.exit(0)
print(json.dumps([item["id"] for item in (data.get("items") or []) if item.get("id")], separators=(",",":")))') || all_user_ids_json="[]"

    systems_response=$(beszel_api_get "$auth_token" "/api/collections/systems/records" \
        --data-urlencode "page=1" \
        --data-urlencode "perPage=500" \
    )

    updates_json=$(printf '%s' "$systems_response" | build_system_user_sync_updates "$all_user_ids_json") || {
        log "WARNING: Failed to compute system access sync updates"
        return 1
    }

    update_count=$(printf '%s' "$updates_json" | count_json_array_items)
    if [ -z "$update_count" ] || [ "$update_count" -eq 0 ]; then
        log "System access is already in sync"
        return 0
    fi

    log "Synchronizing users on active system records ($update_count update(s))"
    while IFS=$(printf '\t') read -r system_id payload; do
        [ -n "$system_id" ] || continue
        [ -n "$payload" ] || continue

        if ! beszel_api_patch_json "$auth_token" "/api/collections/systems/records/$system_id" "$payload" >/dev/null; then
            log "WARNING: Failed to sync users for system id=$system_id"
            continue
        fi

        log "Synchronized users for system id=$system_id"
    done <<EOF
$(printf '%s' "$updates_json" | extract_system_user_sync_lines)
EOF
}

build_temperature_alert_payload() {
    _value="$1"
    _min="$2"
    _overwrite="$3"

    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi

    python3 -c 'import json,sys
value_arg = sys.argv[1]
min_arg = sys.argv[2]
overwrite_arg = sys.argv[3].strip().lower()
try:
    value = float(value_arg)
except ValueError:
    value = 70.0
try:
    min_minutes = int(float(min_arg))
except ValueError:
    min_minutes = 5
overwrite = overwrite_arg in ("1", "true", "yes", "on")
s = sys.stdin.read() or "{}"
try:
    data = json.loads(s)
except json.JSONDecodeError:
    sys.exit(1)
systems = [item.get("id") for item in (data.get("items") or []) if item.get("id")]
payload = {"name": "Temperature", "value": value, "min": min_minutes, "systems": systems, "overwrite": overwrite}
print(json.dumps(payload, separators=(",", ":")))' "$_value" "$_min" "$_overwrite"
}

# --- Beszel API thin wrappers ---

beszel_api_get() {
    local auth_token="$1"
    local path="$2"
    shift 2

    docker_curl -G -H "Authorization: $auth_token" "$@" "$HUB_URL_DOCKER$path"
}

beszel_api_post_json() {
    local auth_token="$1"
    local path="$2"
    local payload="$3"

    docker_curl -X POST \
        -H "Authorization: $auth_token" \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "$HUB_URL_DOCKER$path"
}

beszel_api_patch_json() {
    local auth_token="$1"
    local path="$2"
    local payload="$3"

    docker_curl -X PATCH \
        -H "Authorization: $auth_token" \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "$HUB_URL_DOCKER$path"
}

get_hub_public_key() {
    local auth_token response hub_key
    auth_token="$1"

    response=$(docker_curl \
        -H "Authorization: $auth_token" \
        "$HUB_URL_DOCKER/api/beszel/getkey")

    hub_key=$(extract_json_field "$response" key)
    if [ -z "$hub_key" ]; then
        log "ERROR: Failed to retrieve Beszel hub public key"
        return 1
    fi

    printf '%s' "$hub_key"
}

ensure_agent_env_file() {
    mkdir -p "$AGENT_ENV_DIR"

    if [ ! -f "$AGENT_ENV_FILE" ]; then
        {
            printf '# Managed by scripts/beszel-agent-bootstrap.sh\n'
            printf 'TOKEN=\n'
            printf 'KEY=\n'
        } > "$AGENT_ENV_FILE"
        chmod 600 "$AGENT_ENV_FILE" 2>/dev/null || true
        log "Created $AGENT_ENV_FILE"
    fi
}

login_and_get_auth_token() {
    local email_escaped pass_escaped payload response token
    email_escaped=$(escape_json "$EMAIL")
    pass_escaped=$(escape_json "$PASSWORD")
    payload=$(printf '{"identity":"%s","password":"%s"}' "$email_escaped" "$pass_escaped")

    response=$(docker_curl \
        -X POST \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "$HUB_URL_DOCKER/api/collections/users/auth-with-password")

    token=$(extract_json_field "$response" token)
    if [ -z "$token" ]; then
        log "ERROR: Failed to authenticate to Beszel (no token returned)"
        return 1
    fi
    printf '%s' "$token"
}

login_and_get_superuser_token() {
    local email_escaped pass_escaped payload response token
    email_escaped=$(escape_json "$EMAIL")
    pass_escaped=$(escape_json "$PASSWORD")
    payload=$(printf '{"identity":"%s","password":"%s"}' "$email_escaped" "$pass_escaped")

    response=$(docker_curl \
        -X POST \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "$HUB_URL_DOCKER/api/collections/_superusers/auth-with-password")

    token=$(extract_json_field "$response" token)
    if [ -z "$token" ]; then
        log "ERROR: Failed to authenticate to Beszel superuser API (no token returned)"
        return 1
    fi

    printf '%s' "$token"
}

build_beszel_oidc_payload() {
    local host_name="$1"
    local client_secret="$2"

    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi

    python3 -c 'import json,sys
host = sys.argv[1]
secret = sys.argv[2]
provider_name = sys.argv[3]
display_name = sys.argv[4]
scope = sys.argv[5]
issuer = f"https://auth.{host}"
payload = {
    "oauth2": {
        "enabled": True,
        "mappedFields": {
            "id": "",
            "name": "name",
            "username": "",
            "avatarURL": "avatar",
        },
        "providers": [
            {
                "name": provider_name,
                "displayName": display_name,
                "clientId": "beszel",
                "clientSecret": secret,
                "authURL": f"{issuer}/api/oidc/authorization",
                "tokenURL": f"{issuer}/api/oidc/token",
                "userInfoURL": f"{issuer}/api/oidc/userinfo",
                "pkce": True,
                "extra": {
                    "scope": scope,
                },
            }
        ],
    }
}
print(json.dumps(payload, separators=(",", ":")))' \
        "$host_name" \
        "$client_secret" \
        "$DEFAULT_BESZEL_OIDC_PROVIDER_NAME" \
        "$DEFAULT_BESZEL_OIDC_PROVIDER_DISPLAY_NAME" \
        "$DEFAULT_BESZEL_OIDC_SCOPE"
}

auth_methods_has_expected_oidc_provider() {
    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi

    python3 -c 'import json,sys
provider_name = sys.argv[1]
display_name = sys.argv[2]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
oauth2 = data.get("oauth2") or {}
providers = oauth2.get("providers") or []
is_enabled = bool(oauth2.get("enabled"))
has_match = any((p.get("name") == provider_name and (p.get("displayName") or "") == display_name) for p in providers)
sys.exit(0 if is_enabled and has_match else 1)' \
        "$DEFAULT_BESZEL_OIDC_PROVIDER_NAME" \
        "$DEFAULT_BESZEL_OIDC_PROVIDER_DISPLAY_NAME"
}

configure_beszel_oidc_provider() {
    local auth_token host_name client_secret payload auth_methods

    if ! command -v python3 >/dev/null 2>&1; then
        log "WARNING: python3 not found; skipping Beszel OIDC bootstrap"
        return 1
    fi

    auth_token=$(login_and_get_superuser_token) || {
        log "WARNING: Could not authenticate as Beszel superuser; skipping OIDC bootstrap"
        return 1
    }

    host_name=$(get_env_value HOST_NAME)
    [ -n "$host_name" ] || host_name="pi.lan"

    client_secret=$(get_oidc_secret "beszel" "BESZEL_OIDC_CLIENT_SECRET") || {
        log "WARNING: Could not read Beszel OIDC client secret; skipping OIDC bootstrap"
        return 1
    }

    payload=$(build_beszel_oidc_payload "$host_name" "$client_secret") || {
        log "WARNING: Could not build Beszel OIDC payload"
        return 1
    }

    if ! beszel_api_patch_json "$auth_token" "/api/collections/users" "$payload" >/dev/null; then
        log "WARNING: Failed to apply Beszel OIDC provider configuration"
        return 1
    fi

    auth_methods=$(beszel_api_get "$auth_token" "/api/collections/users/auth-methods" || true)
    if [ -n "$auth_methods" ] && printf '%s' "$auth_methods" | auth_methods_has_expected_oidc_provider; then
        log "Beszel OIDC provider is configured (${DEFAULT_BESZEL_OIDC_PROVIDER_DISPLAY_NAME})"
        return 0
    fi

    log "WARNING: OIDC bootstrap ran but verification did not detect the expected provider"
    return 1
}

get_or_create_permanent_universal_token() {
    local auth_token current_json token active permanent created_json
    local user_id="$2"
    auth_token="$1"

    current_json=$(beszel_api_get "$auth_token" "/api/beszel/universal-token")

    token=$(extract_json_field "$current_json" token)
    active=$(extract_json_bool "$current_json" active)
    permanent=$(extract_json_bool "$current_json" permanent)

    if [ -n "$token" ] && [ "$active" = "true" ]; then
        printf '%s' "$token"
        return 0
    fi

    # Beszel API compatibility: some versions reject permanent=1 with HTTP 400.
    # Try permanent token first, then gracefully fall back to non-permanent.
    if [ -n "$user_id" ]; then
        created_json=$(beszel_api_get "$auth_token" "/api/beszel/universal-token" \
            --data-urlencode "enable=1" \
            --data-urlencode "permanent=1" \
            --data-urlencode "token=$token" \
            --data-urlencode "user=$user_id" \
        ) || true
    else
        created_json=$(beszel_api_get "$auth_token" "/api/beszel/universal-token" \
            --data-urlencode "enable=1" \
            --data-urlencode "permanent=1" \
            --data-urlencode "token=$token" \
        ) || true
    fi

    if [ -z "$created_json" ]; then
        if [ -n "$user_id" ]; then
            created_json=$(beszel_api_get "$auth_token" "/api/beszel/universal-token" \
                --data-urlencode "enable=1" \
                --data-urlencode "token=$token" \
                --data-urlencode "user=$user_id" \
            ) || true
        else
            created_json=$(beszel_api_get "$auth_token" "/api/beszel/universal-token" \
                --data-urlencode "enable=1" \
                --data-urlencode "token=$token" \
            ) || true
        fi
    fi

    token=$(extract_json_field "$created_json" token)
    active=$(extract_json_bool "$created_json" active)
    permanent=$(extract_json_bool "$created_json" permanent)

    if [ -z "$token" ] || [ "$active" != "true" ]; then
        log "ERROR: Failed to create universal token"
        return 1
    fi

    if [ "$permanent" = "true" ]; then
        log "Created permanent universal token"
    else
        log "Created non-permanent universal token (API does not support permanent mode)"
    fi

    printf '%s' "$token"
}

lookup_user_id_by_email() {
    local auth_token="$1"
    local email="$2"
    local users_response

    [ -n "$email" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1

    users_response=$(beszel_api_get "$auth_token" "/api/collections/users/records" \
        --data-urlencode "page=1" \
        --data-urlencode "perPage=500" \
        --data-urlencode "fields=id,email" \
    ) || return 1

    printf '%s' "$users_response" | python3 -c 'import json,sys
target = sys.argv[1].strip().lower()
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for item in data.get("items") or []:
    email = (item.get("email") or "").strip().lower()
    if email == target:
        print(item.get("id") or "")
        sys.exit(0)
sys.exit(1)' "$email"
}

get_or_create_db_universal_token_for_user() {
    local auth_token="$1"
    local user_id="$2"
    local records_json record_id token payload

    [ -n "$auth_token" ] || return 1
    [ -n "$user_id" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1

    records_json=$(beszel_api_get "$auth_token" "/api/collections/universal_tokens/records" \
        --data-urlencode "page=1" \
        --data-urlencode "perPage=1" \
        --data-urlencode "fields=id,token,user" \
        --data-urlencode "filter=user='$user_id'" \
    ) || return 1

    record_id=$(printf '%s' "$records_json" | python3 -c 'import json,sys
try:
    data=json.load(sys.stdin)
except Exception:
    sys.exit(1)
items=data.get("items") or []
print(items[0].get("id","") if items else "")') || return 1

    token=$(printf '%s' "$records_json" | python3 -c 'import json,sys
try:
    data=json.load(sys.stdin)
except Exception:
    sys.exit(1)
items=data.get("items") or []
print(items[0].get("token","") if items else "")') || return 1

    if [ -n "$token" ]; then
        printf '%s' "$token"
        return 0
    fi

    token=$(python3 -c 'import uuid; print(uuid.uuid4())') || return 1
    payload=$(printf '{"user":"%s","token":"%s"}' "$user_id" "$token")

    if [ -n "$record_id" ]; then
        beszel_api_patch_json "$auth_token" "/api/collections/universal_tokens/records/$record_id" "$payload" >/dev/null || return 1
    else
        beszel_api_post_json "$auth_token" "/api/collections/universal_tokens/records" "$payload" >/dev/null || return 1
    fi

    printf '%s' "$token"
}

persist_agent_config() {
    local token="$1"
    local hub_key="$2"
    local current_token=""
    local current_key=""
    local sourced_key=""
    local target_key=""
    local updated=0

    if [ ! -f "$AGENT_ENV_FILE" ]; then
        log "ERROR: agent env file not found at $AGENT_ENV_FILE"
        return 1
    fi

    current_token=$(get_agent_env_value TOKEN)

    if [ "$current_token" != "$token" ]; then
        set_agent_env_value TOKEN "$token"
        updated=1
        log "Updated TOKEN in $AGENT_ENV_FILE"
    else
        log "TOKEN already up to date in $AGENT_ENV_FILE"
    fi

    current_key=$(get_agent_env_value KEY)
    if [ -n "$hub_key" ]; then
        target_key="$hub_key"
    else
        sourced_key=$(resolve_key_from_env)
        target_key="$sourced_key"
    fi

    if [ -z "$target_key" ]; then
        log "ERROR: KEY is required but no hub key (or override key) is available"
        return 1
    fi

    if [ "$current_key" != "$target_key" ]; then
        set_agent_env_value KEY "$target_key"
        updated=1
        log "Updated KEY in $AGENT_ENV_FILE"
    else
        log "KEY already up to date in $AGENT_ENV_FILE"
    fi

    CONFIG_UPDATED=$updated
}

agent_is_running() {
    docker ps --format '{{.Names}}' | grep -q '^beszel-agent$'
}

agent_has_active_system() {
    local auth_token="$1"
    local response count
    response=$(beszel_api_get "$auth_token" "/api/collections/systems/records" \
        --data-urlencode "page=1" \
        --data-urlencode "perPage=1" \
        --data-urlencode "filter=(status='up')")
    count=$(printf '%s' "$response" | count_system_records)
    [ -n "$count" ] && [ "$count" -gt 0 ]
}

restart_agent_if_needed() {
    if [ "$CONFIG_UPDATED" = "0" ] && agent_is_running; then
        log "Agent config unchanged and beszel-agent already running, skipping restart"
        return 0
    fi

    log "Applying beszel-agent configuration..."
    if agent_is_running; then
        # Recreate container so updated env_file values (TOKEN/KEY) are reloaded.
        (
            cd "$PROJECT_DIR"
            docker compose up -d --force-recreate --no-deps beszel-agent </dev/null >/dev/null 2>&1
        ) || {
            log "WARNING: beszel-agent recreate failed"
            return 0
        }
        log "beszel-agent recreated"
    else
        (
            cd "$PROJECT_DIR"
            docker compose up -d --no-deps beszel-agent </dev/null >/dev/null 2>&1
        ) || {
            log "WARNING: beszel-agent start failed; it will start via the main stack"
            return 0
        }
        log "beszel-agent is up"
    fi
}

build_pocketbase_settings_payload() {
    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi

    python3 -c '
import json, sys, os

def env(k):
    return os.environ.get(k, "").strip()

def truthy(v):
    return v.lower() in ("1", "true", "yes", "on")

payload = {}

# ── SMTP ──────────────────────────────────────────────────────────────
smtp_host = env("SMTP_HOST")
if smtp_host:
    smtp_port = env("SMTP_PORT") or "587"
    smtp = {
        "enabled": True,
        "host": smtp_host,
        "port": int(smtp_port),
    }
    smtp_user = env("SMTP_USERNAME")
    smtp_pass = env("SMTP_PASSWORD")
    if smtp_user:
        smtp["username"] = smtp_user
    if smtp_pass:
        smtp["password"] = smtp_pass
    # STARTTLS on port 587, implicit TLS on 465
    smtp["tls"] = smtp_port == "465"
    payload["smtp"] = smtp

    # sender info in meta
    email = env("EMAIL")
    host_name = env("HOST_NAME") or "pi.lan"
    if email:
        payload["meta"] = {
            "senderName": "Beszel",
            "senderAddress": email,
        }

# ── S3 file storage ──────────────────────────────────────────────────
s3_endpoint = env("S3_ENDPOINT")
s3_bucket   = env("S3_BUCKET")
if s3_endpoint and s3_bucket:
    s3 = {
        "enabled": True,
        "endpoint": s3_endpoint,
        "bucket": s3_bucket,
        "region": env("S3_REGION"),
        "accessKey": env("S3_ACCESS_KEY_ID"),
        "secret": env("S3_SECRET_ACCESS_KEY"),
        "forcePathStyle": truthy(env("BESZEL_S3_FORCE_PATH_STYLE") or "true"),
    }
    payload["s3"] = s3

# ── Backups (PocketBase built-in) ────────────────────────────────────
backup_cron = env("BESZEL_BACKUP_CRON")
if backup_cron:
    backups = {
        "cron": backup_cron,
        "cronMaxKeep": int(env("BESZEL_BACKUP_MAX_KEEP") or "7"),
    }
    # Use the same S3 config for backup storage if available
    if s3_endpoint and s3_bucket:
        backups["s3"] = {
            "enabled": True,
            "endpoint": s3_endpoint,
            "bucket": s3_bucket,
            "region": env("S3_REGION"),
            "accessKey": env("S3_ACCESS_KEY_ID"),
            "secret": env("S3_SECRET_ACCESS_KEY"),
            "forcePathStyle": truthy(env("BESZEL_S3_FORCE_PATH_STYLE") or "true"),
        }
    payload["backups"] = backups

# ── Trusted proxy (Traefik → Beszel) ────────────────────────────────
payload["trustedProxy"] = {
    "headers": ["X-Forwarded-For"],
    "useLeftmostIP": True,
}

# ── Logs: persist client IP now that proxy header is trusted ────────
payload["logs"] = {
    "logIP": True,
}

if not payload:
    sys.exit(1)

print(json.dumps(payload, separators=(",", ":")))
'
}

configure_pocketbase_settings() {
    local auth_token payload current_settings

    if ! command -v python3 >/dev/null 2>&1; then
        log "WARNING: python3 not found; skipping PocketBase settings bootstrap"
        return 0
    fi

    auth_token=$(login_and_get_superuser_token) || {
        log "WARNING: Could not authenticate as superuser; skipping PocketBase settings bootstrap"
        return 1
    }

    # Export env vars so the python helper can read them
    export SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD EMAIL HOST_NAME
    export S3_ENDPOINT S3_BUCKET S3_REGION S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY BESZEL_S3_FORCE_PATH_STYLE
    export BESZEL_BACKUP_CRON BESZEL_BACKUP_MAX_KEEP

    payload=$(build_pocketbase_settings_payload) || {
        log "No PocketBase settings to configure (SMTP/S3 vars not set)"
        return 0
    }

    if ! beszel_api_patch_json "$auth_token" "/api/settings" "$payload" >/dev/null; then
        log "WARNING: Failed to apply PocketBase settings (SMTP/S3/backups/proxy)"
        return 1
    fi

    log "PocketBase settings configured (SMTP, S3, backups, trusted proxy)"
    return 0
}

configure_ntfy_webhook_and_temperature_alerts() {
    local auth_token="$1"
    local beszel_password beszel_topic
    local password_encoded topic_encoded webhook_url
    local settings_response settings_record_id settings_payload
    local systems_response systems_count alert_value alert_min alert_overwrite alerts_payload

    if ! command -v python3 >/dev/null 2>&1; then
        log "WARNING: python3 not found; skipping Beszel notifications bootstrap"
        return 0
    fi

    if [ ! -f "$NTFY_ENV_FILE" ]; then
        log "WARNING: $NTFY_ENV_FILE not found; skipping Beszel notifications bootstrap"
        return 0
    fi

    beszel_password=$(get_ntfy_env_value NTFY_BESZEL_PASSWORD)
    beszel_topic=$(get_ntfy_env_value NTFY_BESZEL_TOPIC)

    if [ -z "$beszel_password" ]; then
        log "WARNING: NTFY_BESZEL_PASSWORD missing; skipping Beszel notifications bootstrap"
        return 0
    fi

    [ -n "$beszel_topic" ] || beszel_topic="$DEFAULT_BESZEL_NTFY_TOPIC"

    password_encoded=$(url_encode "$beszel_password")
    topic_encoded=$(url_encode "$beszel_topic")
    webhook_url="ntfy://beszel:${password_encoded}@ntfy/${topic_encoded}?scheme=${DEFAULT_BESZEL_NTFY_SCHEME}"

    log "Ensuring Beszel notification webhook is configured for all users"
    settings_response=$(beszel_api_get "$auth_token" "/api/collections/user_settings/records" \
        --data-urlencode "page=1" \
        --data-urlencode "perPage=500" \
    )

    settings_patches=$(printf '%s' "$settings_response" | build_all_user_settings_patches "$webhook_url")
    if [ -z "$settings_patches" ]; then
        log "WARNING: No user_settings records found; skipping notifications webhook bootstrap"
    else
        printf '%s\n' "$settings_patches" | while IFS=$(printf '\t') read -r record_id patch_payload; do
            [ -n "$record_id" ] || continue
            beszel_api_patch_json \
                "$auth_token" \
                "/api/collections/user_settings/records/$record_id" \
                "$patch_payload" >/dev/null
            log "Configured ntfy webhook for user_settings id=$record_id"
        done
    fi

    log "Ensuring default temperature alerts are configured"
    systems_response=$(beszel_api_get "$auth_token" "/api/collections/systems/records" \
        --data-urlencode "page=1" \
        --data-urlencode "perPage=500" \
        --data-urlencode "fields=id" \
    )

    systems_count=$(printf '%s' "$systems_response" | count_system_records)
    if [ -z "$systems_count" ] || [ "$systems_count" -eq 0 ]; then
        log "No systems found yet; skipping temperature alert bootstrap"
        return 0
    fi

    alert_value=$(get_env_value BESZEL_TEMP_ALERT_VALUE)
    alert_min=$(get_env_value BESZEL_TEMP_ALERT_MIN)
    alert_overwrite=$(get_env_value BESZEL_TEMP_ALERT_OVERWRITE)

    [ -n "$alert_value" ] || alert_value="$DEFAULT_BESZEL_TEMP_ALERT_VALUE"
    [ -n "$alert_min" ] || alert_min="$DEFAULT_BESZEL_TEMP_ALERT_MIN"
    [ -n "$alert_overwrite" ] || alert_overwrite="false"

    alerts_payload=$(printf '%s' "$systems_response" | build_temperature_alert_payload "$alert_value" "$alert_min" "$alert_overwrite")
    beszel_api_post_json "$auth_token" "/api/beszel/user-alerts" "$alerts_payload" >/dev/null
}

main() {
    log "=== Beszel Agent Bootstrap ==="

    if [ ! -f "$ENV_FILE" ]; then
        die ".env missing at $ENV_FILE"
    fi

    ensure_agent_env_file

    EMAIL=$(get_env_value EMAIL)
    PASSWORD=$(get_env_value PASSWORD)

    if [ -z "$EMAIL" ] || [ -z "$PASSWORD" ]; then
        die "EMAIL and PASSWORD must be set in .env"
    fi

    # Load env vars used by configure_pocketbase_settings
    HOST_NAME=$(get_env_value HOST_NAME)
    SMTP_HOST=$(get_env_value SMTP_HOST)
    SMTP_PORT=$(get_env_value SMTP_PORT)
    SMTP_USERNAME=$(get_env_value SMTP_USERNAME)
    SMTP_PASSWORD=$(get_env_value SMTP_PASSWORD)
    S3_ENDPOINT=$(get_env_value S3_ENDPOINT)
    S3_BUCKET=$(get_env_value S3_BUCKET)
    S3_REGION=$(get_env_value S3_REGION)
    S3_ACCESS_KEY_ID=$(get_env_value S3_ACCESS_KEY_ID)
    S3_SECRET_ACCESS_KEY=$(get_env_value S3_SECRET_ACCESS_KEY)
    BESZEL_S3_FORCE_PATH_STYLE=$(get_env_value BESZEL_S3_FORCE_PATH_STYLE)
    BESZEL_BACKUP_CRON=$(get_env_value BESZEL_BACKUP_CRON)
    BESZEL_BACKUP_MAX_KEEP=$(get_env_value BESZEL_BACKUP_MAX_KEEP)

    wait_for_container "pi-beszel" "$MAX_RETRIES" "$RETRY_INTERVAL"
    wait_for_health "pi-beszel" "$MAX_RETRIES" "$RETRY_INTERVAL"

    if ! configure_beszel_oidc_provider; then
        log "Continuing without enforced OIDC bootstrap verification"
    fi

    if beszel_password_auth_disabled; then
        log "Detected DISABLE_PASSWORD_AUTH=true on Beszel; skipping password-based API bootstrap"

        if prepare_agent_env_for_passwordless_mode; then
            if AUTH_TOKEN=$(login_and_get_superuser_token); then
                sync_system_user_access "$AUTH_TOKEN" || true
                configure_ntfy_webhook_and_temperature_alerts "$AUTH_TOKEN" || true
            else
                log "WARNING: Could not authenticate as superuser; skipping system access sync"
            fi
            restart_agent_if_needed
            log "Using existing agent TOKEN/KEY from $AGENT_ENV_FILE"
            log "Bootstrap completed successfully"
            return 0
        fi

        log "TOKEN/KEY are incomplete in passwordless mode; trying superuser fallback bootstrap"

        if ! AUTH_TOKEN=$(login_and_get_superuser_token); then
            log "ERROR: Beszel password auth is disabled and superuser auth fallback failed"
            log "Set BESZEL_DISABLE_PASSWORD_AUTH=false temporarily, run bootstrap once, then re-enable OIDC-only mode."
            exit 1
        fi

        TARGET_USER_ID=$(lookup_user_id_by_email "$AUTH_TOKEN" "$EMAIL" || true)
        if [ -z "$TARGET_USER_ID" ]; then
            die "Could not resolve users.id for EMAIL=$EMAIL"
        fi

        # In passwordless mode we authenticate with _superusers; using /api/beszel/universal-token
        # would bind token ownership to e.Auth.Id (superuser id), which is invalid for systems.users.
        UNIVERSAL_TOKEN=$(get_or_create_db_universal_token_for_user "$AUTH_TOKEN" "$TARGET_USER_ID")
        HUB_PUBLIC_KEY=$(get_hub_public_key "$AUTH_TOKEN")

        if [ -z "$UNIVERSAL_TOKEN" ] || [ -z "$HUB_PUBLIC_KEY" ]; then
            die "Failed to bootstrap TOKEN/KEY using superuser fallback"
        fi

        # Preserve the existing agent token when an active system already exists to
        # prevent the agent from reconnecting with a new identity and creating a
        # duplicate system record.
        EXISTING_AGENT_TOKEN=$(get_agent_env_value TOKEN)
        if [ -n "$EXISTING_AGENT_TOKEN" ] && [ "$EXISTING_AGENT_TOKEN" != "$UNIVERSAL_TOKEN" ]; then
            if agent_has_active_system "$AUTH_TOKEN"; then
                log "Active system exists; keeping current agent token to prevent duplicate system registration"
                UNIVERSAL_TOKEN="$EXISTING_AGENT_TOKEN"
            fi
        fi

        persist_agent_config "$UNIVERSAL_TOKEN" "$HUB_PUBLIC_KEY"
        restart_agent_if_needed
        configure_pocketbase_settings || true
        sync_system_user_access "$AUTH_TOKEN" || true
        configure_ntfy_webhook_and_temperature_alerts "$AUTH_TOKEN"
        log "Bootstrap completed successfully (superuser fallback in passwordless mode)"
        return 0
    fi

    AUTH_TOKEN=$(login_and_get_auth_token)
    TARGET_USER_ID=$(lookup_user_id_by_email "$AUTH_TOKEN" "$EMAIL" || true)
    UNIVERSAL_TOKEN=$(get_or_create_permanent_universal_token "$AUTH_TOKEN" "$TARGET_USER_ID")
    HUB_PUBLIC_KEY=$(get_hub_public_key "$AUTH_TOKEN")

    if [ -z "$UNIVERSAL_TOKEN" ]; then
        die "Could not obtain universal token"
    fi

    if [ -z "$HUB_PUBLIC_KEY" ]; then
        die "Could not obtain Beszel hub public key"
    fi

    # Preserve the existing agent token when an active system already exists to
    # prevent the agent from reconnecting with a new identity and creating a
    # duplicate system record.
    EXISTING_AGENT_TOKEN=$(get_agent_env_value TOKEN)
    if [ -n "$EXISTING_AGENT_TOKEN" ] && [ "$EXISTING_AGENT_TOKEN" != "$UNIVERSAL_TOKEN" ]; then
        if agent_has_active_system "$AUTH_TOKEN"; then
            log "Active system exists; keeping current agent token to prevent duplicate system registration"
            UNIVERSAL_TOKEN="$EXISTING_AGENT_TOKEN"
        fi
    fi

    persist_agent_config "$UNIVERSAL_TOKEN" "$HUB_PUBLIC_KEY"
    restart_agent_if_needed
    configure_pocketbase_settings || true
    sync_system_user_access "$AUTH_TOKEN" || true
    configure_ntfy_webhook_and_temperature_alerts "$AUTH_TOKEN"

    log "Bootstrap completed successfully"
}

main "$@"
