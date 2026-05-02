#!/bin/bash
# Configure Dockhand OIDC, app timezone, and ntfy notifications.
# Safe to run multiple times.

set -euo pipefail

. "$(dirname "$0")/lib.sh"

MAX_RETRIES=120
RETRY_INTERVAL=2
DOCKHAND_CONTAINER="${DOCKHAND_CONTAINER:-pi-dockhand}"
DOCKHAND_URL_DOCKER="${DOCKHAND_URL_DOCKER:-http://pi-dockhand:3000}"
NTFY_ENV_FILE="${PROJECT_DIR}/config/ntfy/ntfy.env"
DOCKHAND_NOTIFICATION_NAME="Dockhand ntfy"
DOCKHAND_NTFY_DEFAULT_TOPIC="pi"
DOCKHAND_NTFY_EVENT_TYPES_JSON='["container_started","container_stopped","container_restarted","container_exited","container_oom","container_unhealthy","container_healthy","image_pulled"]'

ensure_authelia_dockhand_materials() {
    ensure_authelia_oidc_materials "dockhand" "Dockhand" "$MAX_RETRIES" "$RETRY_INTERVAL"
}

wait_for_dockhand_http() {
    wait_for_http_endpoint "$DOCKHAND_URL_DOCKER/api/auth/session" "Dockhand HTTP API" "$MAX_RETRIES" "$RETRY_INTERVAL"
}

dockhand_api_get() {
    local path="$1"
    local cookie="$2"

    api_get_with_cookie "$DOCKHAND_URL_DOCKER" "$path" "$cookie"
}

dockhand_api_post_json() {
    local path="$1"
    local payload="$2"
    local cookie="$3"

    api_post_json_with_cookie "$DOCKHAND_URL_DOCKER" "$path" "$payload" "$cookie"
}

dockhand_api_put_json() {
    local path="$1"
    local payload="$2"
    local cookie="$3"

    api_put_json_with_cookie "$DOCKHAND_URL_DOCKER" "$path" "$payload" "$cookie"
}

dockhand_login_with_user() {
    local username="$1"
    local password="$2"
    local curl_image payload response status cookie

    curl_image="${CURL_IMAGE:-curlimages/curl:8.12.1}"
    payload="$(jq -nc --arg u "$username" --arg p "$password" '{username:$u,password:$p,provider:"local"}')"

    response="$(docker run --rm --network frontend "$curl_image" \
        -sS -i -X POST \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "$DOCKHAND_URL_DOCKER/api/auth/login" 2>/dev/null || true)"

    status="$(printf '%s' "$response" | awk 'NR==1 {print $2}')"
    cookie="$(printf '%s' "$response" | awk 'tolower($0) ~ /^set-cookie:/ {sub(/^[^:]*:[[:space:]]*/, "", $0); split($0, a, ";"); print a[1]; exit}' | tr -d '\r\n')"

    if [ "$status" = "200" ] && [ -n "$cookie" ]; then
        printf '%s' "$cookie"
        return 0
    fi

    return 1
}

authenticate_dockhand() {
    local password usernames candidate first_candidate cookie attempted

    password="$(get_env_value PASSWORD)"
    if [ -z "$password" ]; then
        log "ERROR: Missing Dockhand local password. Set PASSWORD in .env"
        return 1
    fi

    usernames="$(get_env_value USER)"
    candidate="$(get_env_value EMAIL)"
    if [ -n "$candidate" ] && [ "$candidate" != "$usernames" ]; then
        usernames="${usernames:+$usernames }$candidate"
    fi

    if [ -z "$usernames" ]; then
        usernames="admin"
    else
        case " $usernames " in
            *" admin "*) ;;
            *) usernames="$usernames admin" ;;
        esac
    fi

    first_candidate="${usernames%% *}"
    attempted=""

    for candidate in $usernames; do
        cookie="$(dockhand_login_with_user "$candidate" "$password" || true)"
        if [ -n "$cookie" ]; then
            if [ "$candidate" != "$first_candidate" ]; then
                log "Authenticated to Dockhand API using fallback local user '$candidate'"
            fi
            printf '%s' "$cookie"
            return 0
        fi
        attempted="${attempted:+$attempted, }$candidate"
    done

    log "WARNING: Dockhand local API login is unavailable (attempted users: $attempted)"
    return 1
}

ensure_dockhand_local_admin_user() {
    local cookie="$1"
    local users_json admin_username admin_email admin_password existing_count payload

    users_json="$(dockhand_api_get "/api/users" "$cookie")" || {
        log "ERROR: Failed to fetch Dockhand users"
        return 1
    }

    admin_username="$(get_env_value USER)"
    [ -n "$admin_username" ] || admin_username="$(get_env_value EMAIL)"
    [ -n "$admin_username" ] || admin_username="admin"

    existing_count="$(printf '%s' "$users_json" | jq -r --arg u "$admin_username" '[.[] | select(.username == $u)] | length')"
    if [ "$existing_count" -gt 0 ] 2>/dev/null; then
        log "Dockhand local user '$admin_username' already exists"
        return 0
    fi

    admin_password="$(get_env_value PASSWORD)"
    if [ -z "$admin_password" ]; then
        log "ERROR: Missing Dockhand local password. Set PASSWORD in .env"
        return 1
    fi

    admin_email="$(get_env_value EMAIL)"
    payload="$(jq -nc \
        --arg username "$admin_username" \
        --arg password "$admin_password" \
        --arg email "$admin_email" \
        --arg display_name "$admin_username" \
        '{username:$username,password:$password,displayName:$display_name}
         + (if $email != "" then {email:$email} else {} end)')"

    if ! dockhand_api_post_json "/api/users" "$payload" "$cookie" >/dev/null 2>&1; then
        users_json="$(dockhand_api_get "/api/users" "$cookie" || true)"
        existing_count="$(printf '%s' "$users_json" | jq -r --arg u "$admin_username" '[.[] | select(.username == $u)] | length' 2>/dev/null || printf '0')"
        if [ "$existing_count" -gt 0 ] 2>/dev/null; then
            log "Dockhand local user '$admin_username' already exists"
            return 0
        fi

        log "ERROR: Failed to create Dockhand local user '$admin_username'"
        return 1
    fi

    log "Created Dockhand local user '$admin_username'"
    return 0
}

dockhand_db_query() {
    local sql="$1"

    printf '%s\n' "$sql" | docker exec -i "$DOCKHAND_CONTAINER" sh -lc 'sqlite3 -batch -separator "\t" /app/data/db/dockhand.db'
}

dockhand_db_exec() {
    local sql="$1"

    dockhand_db_query "$sql" >/dev/null
}

dockhand_db_scalar() {
    local sql="$1"

    dockhand_db_query "$sql" | head -n1 | tr -d '\r\n'
}

dockhand_environment_ids() {
    dockhand_db_query 'SELECT id FROM environments ORDER BY id;' | tr -d '\r'
}

oidc_defaults() {
    local host="$1"
    local auth_base="https://auth.${host}"
    local dockhand_base="https://dockhand.${host}"
    local raw_scopes

    OIDC_PROVIDER_NAME="$(get_env_value DOCKHAND_OIDC_PROVIDER_NAME)"
    OIDC_PROVIDER_NAME="${OIDC_PROVIDER_NAME:-Authelia}"

    OIDC_CLIENT_ID_VAL="$(get_env_value DOCKHAND_OIDC_CLIENT_ID)"
    OIDC_CLIENT_ID_VAL="${OIDC_CLIENT_ID_VAL:-dockhand}"

    OIDC_ISSUER_URL="$(get_env_value DOCKHAND_OIDC_ISSUER_URL)"
    OIDC_ISSUER_URL="${OIDC_ISSUER_URL:-$auth_base}"

    OIDC_REDIRECT_URI="$(get_env_value DOCKHAND_OIDC_REDIRECT_URI)"
    OIDC_REDIRECT_URI="${OIDC_REDIRECT_URI:-$dockhand_base/api/auth/oidc/callback}"

    raw_scopes="$(get_env_value DOCKHAND_OIDC_SCOPES)"
    raw_scopes="${raw_scopes:-openid profile email groups}"
    OIDC_SCOPES="$(printf '%s' "$raw_scopes" | tr ',' ' ' | tr -s ' ')"

    OIDC_USERNAME_CLAIM="$(get_env_value DOCKHAND_OIDC_USERNAME_CLAIM)"
    OIDC_USERNAME_CLAIM="${OIDC_USERNAME_CLAIM:-preferred_username}"

    OIDC_EMAIL_CLAIM="$(get_env_value DOCKHAND_OIDC_EMAIL_CLAIM)"
    OIDC_EMAIL_CLAIM="${OIDC_EMAIL_CLAIM:-email}"

    OIDC_DISPLAY_NAME_CLAIM="$(get_env_value DOCKHAND_OIDC_DISPLAY_NAME_CLAIM)"
    OIDC_DISPLAY_NAME_CLAIM="${OIDC_DISPLAY_NAME_CLAIM:-name}"

    OIDC_ADMIN_CLAIM="$(get_env_value DOCKHAND_OIDC_ADMIN_CLAIM)"
    OIDC_ADMIN_CLAIM="${OIDC_ADMIN_CLAIM:-groups}"

    OIDC_ADMIN_VALUE="$(get_env_value DOCKHAND_OIDC_ADMIN_VALUE)"
    OIDC_ADMIN_VALUE="${OIDC_ADMIN_VALUE:-admin}"

    DOCKHAND_DEFAULT_PROVIDER="$(get_env_value DOCKHAND_AUTH_DEFAULT_PROVIDER)"
    DOCKHAND_DEFAULT_PROVIDER="${DOCKHAND_DEFAULT_PROVIDER:-oidc}"
}

build_dockhand_oidc_payload() {
    local oidc_secret="$1"

    oidc_defaults "$HOST_NAME"

    jq -nc \
        --arg name "$OIDC_PROVIDER_NAME" \
        --arg issuer_url "$OIDC_ISSUER_URL" \
        --arg client_id "$OIDC_CLIENT_ID_VAL" \
        --arg client_secret "$oidc_secret" \
        --arg redirect_uri "$OIDC_REDIRECT_URI" \
        --arg scopes "$OIDC_SCOPES" \
        --arg username_claim "$OIDC_USERNAME_CLAIM" \
        --arg email_claim "$OIDC_EMAIL_CLAIM" \
        --arg display_name_claim "$OIDC_DISPLAY_NAME_CLAIM" \
        --arg admin_claim "$OIDC_ADMIN_CLAIM" \
        --arg admin_value "$OIDC_ADMIN_VALUE" '
        {
            name: $name,
            enabled: true,
            issuerUrl: $issuer_url,
            clientId: $client_id,
            clientSecret: $client_secret,
            redirectUri: $redirect_uri,
            scopes: $scopes,
            usernameClaim: $username_claim,
            emailClaim: $email_claim,
            displayNameClaim: $display_name_claim
        }
        + (if $admin_claim != "" and $admin_value != "" then {adminClaim: $admin_claim, adminValue: $admin_value} else {} end)
    '
}

find_dockhand_oidc_id_db() {
    local client_id_sql name_sql

    client_id_sql="$(sql_escape "$OIDC_CLIENT_ID_VAL")"
    name_sql="$(sql_escape "$OIDC_PROVIDER_NAME")"

    dockhand_db_scalar "SELECT id FROM oidc_config WHERE client_id = '${client_id_sql}' OR name = '${name_sql}' ORDER BY id LIMIT 1;"
}

upsert_dockhand_oidc_provider() {
    local cookie="$1"
    local payload="$2"
    local configs_json oidc_id

    configs_json="$(dockhand_api_get "/api/auth/oidc" "$cookie")" || {
        log "ERROR: Failed to fetch Dockhand OIDC providers"
        return 1
    }

    oidc_id="$(printf '%s' "$configs_json" | jq -r --arg cid "$OIDC_CLIENT_ID_VAL" --arg name "$OIDC_PROVIDER_NAME" '[.[] | select(.clientId == $cid or .name == $name)] | first | .id // empty')"

    if [ -n "$oidc_id" ]; then
        dockhand_api_put_json "/api/auth/oidc/$oidc_id" "$payload" "$cookie" >/dev/null || {
            log "ERROR: Failed to update Dockhand OIDC provider (id=$oidc_id)"
            return 1
        }
        log "Updated Dockhand OIDC provider '$OIDC_PROVIDER_NAME'"
    else
        dockhand_api_post_json "/api/auth/oidc" "$payload" "$cookie" >/dev/null || {
            log "ERROR: Failed to create Dockhand OIDC provider '$OIDC_PROVIDER_NAME'"
            return 1
        }
        log "Created Dockhand OIDC provider '$OIDC_PROVIDER_NAME'"
    fi
}

upsert_dockhand_oidc_provider_db() {
    local oidc_secret="$1"
    local oidc_id provider_name issuer_url client_id redirect_uri scopes username_claim email_claim display_name_claim admin_claim admin_value client_secret

    oidc_defaults "$HOST_NAME"

    provider_name="$(sql_escape "$OIDC_PROVIDER_NAME")"
    issuer_url="$(sql_escape "$OIDC_ISSUER_URL")"
    client_id="$(sql_escape "$OIDC_CLIENT_ID_VAL")"
    client_secret="$(sql_escape "$oidc_secret")"
    redirect_uri="$(sql_escape "$OIDC_REDIRECT_URI")"
    scopes="$(sql_escape "$OIDC_SCOPES")"
    username_claim="$(sql_escape "$OIDC_USERNAME_CLAIM")"
    email_claim="$(sql_escape "$OIDC_EMAIL_CLAIM")"
    display_name_claim="$(sql_escape "$OIDC_DISPLAY_NAME_CLAIM")"
    admin_claim="$(sql_escape "$OIDC_ADMIN_CLAIM")"
    admin_value="$(sql_escape "$OIDC_ADMIN_VALUE")"
    oidc_id="$(find_dockhand_oidc_id_db || true)"

    if [ -n "$oidc_id" ]; then
        dockhand_db_exec "
            UPDATE oidc_config
               SET name='${provider_name}',
                   enabled=1,
                   issuer_url='${issuer_url}',
                   client_id='${client_id}',
                   client_secret='${client_secret}',
                   redirect_uri='${redirect_uri}',
                   scopes='${scopes}',
                   username_claim='${username_claim}',
                   email_claim='${email_claim}',
                   display_name_claim='${display_name_claim}',
                   admin_claim='${admin_claim}',
                   admin_value='${admin_value}',
                   updated_at=CURRENT_TIMESTAMP
             WHERE id=${oidc_id};
        "
        log "Updated Dockhand OIDC provider '$OIDC_PROVIDER_NAME' via database fallback"
    else
        dockhand_db_exec "
            INSERT INTO oidc_config (
                name,
                enabled,
                issuer_url,
                client_id,
                client_secret,
                redirect_uri,
                scopes,
                username_claim,
                email_claim,
                display_name_claim,
                admin_claim,
                admin_value,
                created_at,
                updated_at
            ) VALUES (
                '${provider_name}',
                1,
                '${issuer_url}',
                '${client_id}',
                '${client_secret}',
                '${redirect_uri}',
                '${scopes}',
                '${username_claim}',
                '${email_claim}',
                '${display_name_claim}',
                '${admin_claim}',
                '${admin_value}',
                CURRENT_TIMESTAMP,
                CURRENT_TIMESTAMP
            );
        "
        log "Created Dockhand OIDC provider '$OIDC_PROVIDER_NAME' via database fallback"
    fi
}

enable_dockhand_auth_with_oidc_default() {
    local cookie="$1"
    local settings_json payload

    settings_json="$(dockhand_api_get "/api/auth/settings" "$cookie")" || {
        log "ERROR: Failed to fetch Dockhand auth settings"
        return 1
    }

    payload="$(printf '%s' "$settings_json" | jq -c --arg default_provider "$DOCKHAND_DEFAULT_PROVIDER" '{authEnabled: true, defaultProvider: $default_provider, sessionTimeout: (.sessionTimeout // 86400)}')"

    dockhand_api_put_json "/api/auth/settings" "$payload" "$cookie" >/dev/null || {
        log "ERROR: Failed to update Dockhand auth settings"
        return 1
    }
}

enable_dockhand_auth_with_oidc_default_db() {
    local session_timeout auth_settings_id default_provider_sql

    default_provider_sql="$(sql_escape "$DOCKHAND_DEFAULT_PROVIDER")"
    session_timeout="$(dockhand_db_scalar 'SELECT COALESCE(session_timeout, 86400) FROM auth_settings ORDER BY id LIMIT 1;')"
    [ -n "$session_timeout" ] || session_timeout="86400"
    auth_settings_id="$(dockhand_db_scalar 'SELECT id FROM auth_settings ORDER BY id LIMIT 1;')"

    if [ -n "$auth_settings_id" ]; then
        dockhand_db_exec "
            UPDATE auth_settings
               SET auth_enabled=1,
                   default_provider='${default_provider_sql}',
                   session_timeout=${session_timeout},
                   updated_at=CURRENT_TIMESTAMP
             WHERE id=${auth_settings_id};
        "
    else
        dockhand_db_exec "
            INSERT INTO auth_settings (
                auth_enabled,
                default_provider,
                session_timeout,
                created_at,
                updated_at
            ) VALUES (
                1,
                '${default_provider_sql}',
                ${session_timeout},
                CURRENT_TIMESTAMP,
                CURRENT_TIMESTAMP
            );
        "
    fi
}

dockhand_timezone_defaults() {
    DOCKHAND_TIMEZONE="$(get_env_value TIMEZONE)"
    DOCKHAND_TIMEZONE="${DOCKHAND_TIMEZONE:-Europe/Paris}"
}

upsert_dockhand_setting_json_string_db() {
    local key="$1"
    local value="$2"
    local key_sql json_value_sql

    key_sql="$(sql_escape "$key")"
    json_value_sql="$(jq -nc --arg value "$value" '$value' | sed "s/'/''/g")"

    dockhand_db_exec "
        INSERT INTO settings (key, value, updated_at)
        VALUES ('${key_sql}', '${json_value_sql}', CURRENT_TIMESTAMP)
        ON CONFLICT(key) DO UPDATE SET
            value=excluded.value,
            updated_at=CURRENT_TIMESTAMP;
    "
}

configure_dockhand_timezone_api() {
    local cookie="$1"
    local payload env_payload env_id

    dockhand_timezone_defaults

    payload="$(jq -nc --arg timezone "$DOCKHAND_TIMEZONE" '{defaultTimezone:$timezone}')"
    dockhand_api_post_json "/api/settings/general" "$payload" "$cookie" >/dev/null || {
        log "ERROR: Failed to update Dockhand general timezone"
        return 1
    }

    env_payload="$(jq -nc --arg timezone "$DOCKHAND_TIMEZONE" '{timezone:$timezone}')"
    for env_id in $(dockhand_environment_ids); do
        dockhand_api_post_json "/api/environments/$env_id/timezone" "$env_payload" "$cookie" >/dev/null || {
            log "ERROR: Failed to update Dockhand environment timezone for environment $env_id"
            return 1
        }
    done

    log "Configured Dockhand timezone to '$DOCKHAND_TIMEZONE'"
}

configure_dockhand_timezone_db() {
    local env_id

    dockhand_timezone_defaults

    upsert_dockhand_setting_json_string_db "default_timezone" "$DOCKHAND_TIMEZONE"
    for env_id in $(dockhand_environment_ids); do
        upsert_dockhand_setting_json_string_db "env_${env_id}_timezone" "$DOCKHAND_TIMEZONE"
    done

    log "Configured Dockhand timezone to '$DOCKHAND_TIMEZONE' via database fallback"
}

dockhand_notification_defaults() {
    DOCKHAND_NTFY_PASSWORD="$(read_env_value_from_file "$NTFY_ENV_FILE" NTFY_DOCKHAND_PASSWORD)"
    DOCKHAND_NTFY_TOPIC="$(read_env_value_from_file "$NTFY_ENV_FILE" NTFY_DOCKHAND_TOPIC)"
    [ -n "$DOCKHAND_NTFY_TOPIC" ] || DOCKHAND_NTFY_TOPIC="$DOCKHAND_NTFY_DEFAULT_TOPIC"
    DOCKHAND_NTFY_URL=""

    if [ -n "$DOCKHAND_NTFY_PASSWORD" ]; then
        DOCKHAND_NTFY_URL="ntfy://dockhand:${DOCKHAND_NTFY_PASSWORD}@ntfy/${DOCKHAND_NTFY_TOPIC}"
    fi
}

build_dockhand_notification_payload() {
    jq -nc \
        --arg name "$DOCKHAND_NOTIFICATION_NAME" \
        --arg url "$DOCKHAND_NTFY_URL" '
        {
            type: "apprise",
            name: $name,
            enabled: true,
            config: {
                urls: [$url]
            }
        }
    '
}

build_dockhand_environment_notification_create_payload() {
    local notification_id="$1"

    jq -nc \
        --argjson notificationId "$notification_id" \
        --argjson eventTypes "$DOCKHAND_NTFY_EVENT_TYPES_JSON" '
        {
            notificationId: $notificationId,
            enabled: true,
            eventTypes: $eventTypes
        }
    '
}

build_dockhand_environment_notification_update_payload() {
    jq -nc \
        --argjson eventTypes "$DOCKHAND_NTFY_EVENT_TYPES_JSON" '
        {
            enabled: true,
            eventTypes: $eventTypes
        }
    '
}

find_dockhand_notification_id_db() {
    local name_sql url_sql

    dockhand_notification_defaults
    if [ -z "$DOCKHAND_NTFY_URL" ]; then
        return 1
    fi

    name_sql="$(sql_escape "$DOCKHAND_NOTIFICATION_NAME")"
    url_sql="$(sql_escape "$DOCKHAND_NTFY_URL")"

    dockhand_db_scalar "
        SELECT id
          FROM notification_settings
         WHERE type = 'apprise'
           AND (
                name = '${name_sql}'
                OR json_extract(config, '$.urls[0]') = '${url_sql}'
           )
         ORDER BY id
         LIMIT 1;
    "
}

environment_notification_exists_db() {
    local environment_id="$1"
    local notification_id="$2"
    local existing_count

    existing_count="$(dockhand_db_scalar "SELECT COUNT(*) FROM environment_notifications WHERE environment_id = ${environment_id} AND notification_id = ${notification_id};")"
    [ "$existing_count" -gt 0 ] 2>/dev/null
}

upsert_dockhand_notifications_api() {
    local cookie="$1"
    local notification_id payload env_id env_payload

    dockhand_notification_defaults
    if [ ! -f "$NTFY_ENV_FILE" ]; then
        log "WARNING: $NTFY_ENV_FILE not found; skipping Dockhand ntfy notification bootstrap"
        return 0
    fi

    if [ -z "$DOCKHAND_NTFY_PASSWORD" ] || [ -z "$DOCKHAND_NTFY_URL" ]; then
        log "WARNING: NTFY_DOCKHAND_PASSWORD missing; skipping Dockhand ntfy notification bootstrap"
        return 0
    fi

    payload="$(build_dockhand_notification_payload)"
    notification_id="$(find_dockhand_notification_id_db || true)"

    if [ -n "$notification_id" ]; then
        dockhand_api_put_json "/api/notifications/$notification_id" "$payload" "$cookie" >/dev/null || {
            log "ERROR: Failed to update Dockhand ntfy notification channel"
            return 1
        }
    else
        notification_id="$(dockhand_api_post_json "/api/notifications" "$payload" "$cookie" | jq -r '.id // empty')"
        if [ -z "$notification_id" ]; then
            log "ERROR: Failed to create Dockhand ntfy notification channel"
            return 1
        fi
    fi

    for env_id in $(dockhand_environment_ids); do
        if environment_notification_exists_db "$env_id" "$notification_id"; then
            env_payload="$(build_dockhand_environment_notification_update_payload)"
            dockhand_api_put_json "/api/environments/$env_id/notifications/$notification_id" "$env_payload" "$cookie" >/dev/null || {
                log "ERROR: Failed to update Dockhand notification binding for environment $env_id"
                return 1
            }
        else
            env_payload="$(build_dockhand_environment_notification_create_payload "$notification_id")"
            dockhand_api_post_json "/api/environments/$env_id/notifications" "$env_payload" "$cookie" >/dev/null || {
                log "ERROR: Failed to create Dockhand notification binding for environment $env_id"
                return 1
            }
        fi
    done

    log "Configured Dockhand ntfy notifications"
}

upsert_dockhand_notifications_db() {
    local notification_id config_json config_sql name_sql url_sql event_types_sql env_id

    dockhand_notification_defaults
    if [ ! -f "$NTFY_ENV_FILE" ]; then
        log "WARNING: $NTFY_ENV_FILE not found; skipping Dockhand ntfy notification bootstrap"
        return 0
    fi

    if [ -z "$DOCKHAND_NTFY_PASSWORD" ] || [ -z "$DOCKHAND_NTFY_URL" ]; then
        log "WARNING: NTFY_DOCKHAND_PASSWORD missing; skipping Dockhand ntfy notification bootstrap"
        return 0
    fi

    notification_id="$(find_dockhand_notification_id_db || true)"
    config_json="$(jq -nc --arg url "$DOCKHAND_NTFY_URL" '{urls:[$url]}')"
    config_sql="$(sql_escape "$config_json")"
    name_sql="$(sql_escape "$DOCKHAND_NOTIFICATION_NAME")"
    url_sql="$(sql_escape "$DOCKHAND_NTFY_URL")"
    event_types_sql="$(sql_escape "$DOCKHAND_NTFY_EVENT_TYPES_JSON")"

    if [ -n "$notification_id" ]; then
        dockhand_db_exec "
            UPDATE notification_settings
               SET type='apprise',
                   name='${name_sql}',
                   enabled=1,
                   config='${config_sql}',
                   event_types=NULL,
                   updated_at=CURRENT_TIMESTAMP
             WHERE id=${notification_id};
        "
    else
        dockhand_db_exec "
            INSERT INTO notification_settings (
                type,
                name,
                enabled,
                config,
                event_types,
                created_at,
                updated_at
            ) VALUES (
                'apprise',
                '${name_sql}',
                1,
                '${config_sql}',
                NULL,
                CURRENT_TIMESTAMP,
                CURRENT_TIMESTAMP
            );
        "
        notification_id="$(find_dockhand_notification_id_db || true)"
    fi

    if [ -z "$notification_id" ]; then
        log "ERROR: Failed to upsert Dockhand ntfy notification channel via database fallback"
        return 1
    fi

    for env_id in $(dockhand_environment_ids); do
        dockhand_db_exec "
            INSERT INTO environment_notifications (
                environment_id,
                notification_id,
                enabled,
                event_types,
                created_at,
                updated_at
            ) VALUES (
                ${env_id},
                ${notification_id},
                1,
                '${event_types_sql}',
                CURRENT_TIMESTAMP,
                CURRENT_TIMESTAMP
            )
            ON CONFLICT(environment_id, notification_id) DO UPDATE SET
                enabled=excluded.enabled,
                event_types=excluded.event_types,
                updated_at=CURRENT_TIMESTAMP;
        "
    done

    log "Configured Dockhand ntfy notifications via database fallback"
}

verify_dockhand_oidc_db() {
    local oidc_id enabled client_id issuer_url redirect_uri scopes username_claim email_claim display_name_claim admin_claim admin_value

    oidc_id="$(find_dockhand_oidc_id_db || true)"
    if [ -z "$oidc_id" ]; then
        return 1
    fi

    enabled="$(dockhand_db_scalar "SELECT enabled FROM oidc_config WHERE id = ${oidc_id};")"
    client_id="$(dockhand_db_scalar "SELECT client_id FROM oidc_config WHERE id = ${oidc_id};")"
    issuer_url="$(dockhand_db_scalar "SELECT issuer_url FROM oidc_config WHERE id = ${oidc_id};")"
    redirect_uri="$(dockhand_db_scalar "SELECT redirect_uri FROM oidc_config WHERE id = ${oidc_id};")"
    scopes="$(dockhand_db_scalar "SELECT scopes FROM oidc_config WHERE id = ${oidc_id};")"
    username_claim="$(dockhand_db_scalar "SELECT username_claim FROM oidc_config WHERE id = ${oidc_id};")"
    email_claim="$(dockhand_db_scalar "SELECT email_claim FROM oidc_config WHERE id = ${oidc_id};")"
    display_name_claim="$(dockhand_db_scalar "SELECT display_name_claim FROM oidc_config WHERE id = ${oidc_id};")"
    admin_claim="$(dockhand_db_scalar "SELECT COALESCE(admin_claim, '') FROM oidc_config WHERE id = ${oidc_id};")"
    admin_value="$(dockhand_db_scalar "SELECT COALESCE(admin_value, '') FROM oidc_config WHERE id = ${oidc_id};")"

    [ "$enabled" = "1" ] || return 1
    [ "$client_id" = "$OIDC_CLIENT_ID_VAL" ] || return 1
    [ "$issuer_url" = "$OIDC_ISSUER_URL" ] || return 1
    [ "$redirect_uri" = "$OIDC_REDIRECT_URI" ] || return 1
    [ "$(printf '%s' "$scopes" | tr -s ' ')" = "$(printf '%s' "$OIDC_SCOPES" | tr -s ' ')" ] || return 1
    [ "$username_claim" = "$OIDC_USERNAME_CLAIM" ] || return 1
    [ "$email_claim" = "$OIDC_EMAIL_CLAIM" ] || return 1
    [ "$display_name_claim" = "$OIDC_DISPLAY_NAME_CLAIM" ] || return 1
    [ "$admin_claim" = "$OIDC_ADMIN_CLAIM" ] || return 1
    [ "$admin_value" = "$OIDC_ADMIN_VALUE" ] || return 1

    return 0
}

verify_dockhand_auth_settings_db() {
    local auth_enabled default_provider

    auth_enabled="$(dockhand_db_scalar 'SELECT auth_enabled FROM auth_settings ORDER BY id LIMIT 1;')"
    default_provider="$(dockhand_db_scalar 'SELECT default_provider FROM auth_settings ORDER BY id LIMIT 1;')"

    [ "$auth_enabled" = "1" ] && [ "$default_provider" = "$DOCKHAND_DEFAULT_PROVIDER" ]
}

verify_dockhand_timezones_db() {
    local current_default env_id current_env

    dockhand_timezone_defaults

    current_default="$(dockhand_db_scalar "SELECT json_extract(value, '$') FROM settings WHERE key = 'default_timezone' LIMIT 1;")"
    [ "$current_default" = "$DOCKHAND_TIMEZONE" ] || return 1

    for env_id in $(dockhand_environment_ids); do
        current_env="$(dockhand_db_scalar "SELECT json_extract(value, '$') FROM settings WHERE key = 'env_${env_id}_timezone' LIMIT 1;")"
        [ "$current_env" = "$DOCKHAND_TIMEZONE" ] || return 1
    done

    return 0
}

verify_dockhand_notifications_db() {
    local notification_id enabled url desired_event_types current_event_types env_enabled env_id

    dockhand_notification_defaults
    if [ ! -f "$NTFY_ENV_FILE" ] || [ -z "$DOCKHAND_NTFY_PASSWORD" ] || [ -z "$DOCKHAND_NTFY_URL" ]; then
        return 0
    fi

    notification_id="$(find_dockhand_notification_id_db || true)"
    if [ -z "$notification_id" ]; then
        return 1
    fi

    enabled="$(dockhand_db_scalar "SELECT enabled FROM notification_settings WHERE id = ${notification_id};")"
    url="$(dockhand_db_scalar "SELECT json_extract(config, '$.urls[0]') FROM notification_settings WHERE id = ${notification_id};")"

    [ "$enabled" = "1" ] || return 1
    [ "$url" = "$DOCKHAND_NTFY_URL" ] || return 1

    desired_event_types="$(normalize_json "$DOCKHAND_NTFY_EVENT_TYPES_JSON")"
    for env_id in $(dockhand_environment_ids); do
        env_enabled="$(dockhand_db_scalar "SELECT enabled FROM environment_notifications WHERE environment_id = ${env_id} AND notification_id = ${notification_id} LIMIT 1;")"
        current_event_types="$(dockhand_db_scalar "SELECT COALESCE(event_types, '[]') FROM environment_notifications WHERE environment_id = ${env_id} AND notification_id = ${notification_id} LIMIT 1;")"

        [ "$env_enabled" = "1" ] || return 1
        [ "$(normalize_json "$current_event_types")" = "$desired_event_types" ] || return 1
    done

    return 0
}

verify_dockhand_provider_visibility() {
    local providers_json

    providers_json="$(dockhand_api_get "/api/auth/providers" "" || true)"
    [ -n "$providers_json" ] || return 1

    printf '%s' "$providers_json" | jq -e --arg default_provider "$DOCKHAND_DEFAULT_PROVIDER" '
        .defaultProvider == $default_provider
        and any(.providers[]; .type == "oidc")
        and (any(.providers[]; .type == "local") | not)
    ' >/dev/null
}

verify_dockhand_auth_public_session() {
    local session_json

    session_json="$(dockhand_api_get "/api/auth/session" "" || true)"
    [ -n "$session_json" ] || return 1

    printf '%s' "$session_json" | jq -e '.authEnabled == true' >/dev/null
}

configure_dockhand_via_api() {
    local cookie="$1"
    local oidc_payload="$2"

    upsert_dockhand_oidc_provider "$cookie" "$oidc_payload" || return 1
    configure_dockhand_timezone_api "$cookie" || return 1
    upsert_dockhand_notifications_api "$cookie" || return 1
    enable_dockhand_auth_with_oidc_default "$cookie" || return 1

    return 0
}

configure_dockhand_via_db() {
    local oidc_client_secret="$1"

    upsert_dockhand_oidc_provider_db "$oidc_client_secret" || return 1
    configure_dockhand_timezone_db || return 1
    upsert_dockhand_notifications_db || return 1
    enable_dockhand_auth_with_oidc_default_db || return 1

    return 0
}

main() {
    local enabled session_json auth_enabled dockhand_cookie oidc_client_secret oidc_payload
    local used_db_fallback="false"

    log "=== Dockhand Bootstrap ==="

    if [ ! -f "$ENV_FILE" ]; then
        die ".env missing at $ENV_FILE"
    fi

    enabled="$(get_env_value DOCKHAND_OIDC_ENABLED)"
    [ -n "$enabled" ] || enabled="true"
    if ! is_truthy "$enabled"; then
        log "DOCKHAND_OIDC_ENABLED is disabled, skipping bootstrap"
        exit 0
    fi

    HOST_NAME="$(get_env_value HOST_NAME)"
    HOST_NAME="${HOST_NAME:-pi.lan}"

    oidc_defaults "$HOST_NAME"

    ensure_authelia_dockhand_materials || {
        die "Dockhand OIDC prerequisites are missing in Authelia configuration"
    }

    if ! wait_for_container "$DOCKHAND_CONTAINER" "$MAX_RETRIES" "$RETRY_INTERVAL"; then
        exit 1
    fi

    if ! wait_for_dockhand_http; then
        exit 1
    fi

    session_json="$(dockhand_api_get "/api/auth/session" "" || true)"
    auth_enabled="$(printf '%s' "$session_json" | jq -r '.authEnabled // false' 2>/dev/null || printf 'false')"

    dockhand_cookie=""
    if [ "$auth_enabled" = "true" ]; then
        dockhand_cookie="$(authenticate_dockhand || true)"
        if [ -z "$dockhand_cookie" ]; then
            used_db_fallback="true"
            log "Local Dockhand login is disabled or unavailable; using direct database bootstrap"
        fi
    else
        ensure_dockhand_local_admin_user "" || {
            die "Failed to ensure Dockhand local admin user before enabling authentication"
        }
    fi

    oidc_client_secret="$(get_oidc_secret "dockhand" "DOCKHAND_OIDC_CLIENT_SECRET")" || {
        die "Could not read Dockhand OIDC client secret"
    }

    if [ -z "$oidc_client_secret" ]; then
        die "Dockhand OIDC client secret is empty"
    fi

    oidc_payload="$(build_dockhand_oidc_payload "$oidc_client_secret")" || {
        die "Failed to build Dockhand OIDC payload"
    }

    if [ "$used_db_fallback" = "true" ]; then
        configure_dockhand_via_db "$oidc_client_secret" || {
            die "Failed to configure Dockhand via database fallback"
        }
    else
        configure_dockhand_via_api "$dockhand_cookie" "$oidc_payload" || {
            log "WARNING: API-based Dockhand bootstrap failed; retrying via database fallback"
            used_db_fallback="true"
            configure_dockhand_via_db "$oidc_client_secret" || {
                die "Failed to configure Dockhand via database fallback"
            }
        }
    fi

    oidc_defaults "$HOST_NAME"

    if ! verify_dockhand_oidc_db; then
        die "Dockhand OIDC verification failed after settings update"
    fi

    if ! verify_dockhand_auth_settings_db; then
        die "Dockhand auth settings verification failed after update"
    fi

    if ! verify_dockhand_timezones_db; then
        die "Dockhand timezone verification failed after update"
    fi

    if ! verify_dockhand_notifications_db; then
        die "Dockhand ntfy notification verification failed after update"
    fi

    if ! verify_dockhand_auth_public_session; then
        die "Dockhand auth public session verification failed after update"
    fi

    if ! verify_dockhand_provider_visibility; then
        die "Dockhand auth provider verification failed (expected OIDC-only login)"
    fi

    log "Dockhand bootstrap configured successfully"
}

main "$@"
