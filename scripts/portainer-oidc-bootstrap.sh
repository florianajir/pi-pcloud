#!/bin/bash
# Configure Portainer OAuth against Authelia OIDC.
# Safe to run multiple times.

set -euo pipefail

. "$(dirname "$0")/lib.sh"

MAX_RETRIES=120
RETRY_INTERVAL=2
PORTAINER_CONTAINER="${PORTAINER_CONTAINER:-pi-portainer}"
PORTAINER_URL_DOCKER="${PORTAINER_URL_DOCKER:-http://pi-portainer:9000}"
PORTAINER_OIDC_DEFAULT_TEAM_NAME="oidc-users"
PORTAINER_ENDPOINT_ROLE_ID=1
PORTAINER_TEAM_MEMBER_ROLE=2

wait_for_authelia_health() {
    local status

    for i in $(seq 1 $MAX_RETRIES); do
        status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' pi-authelia 2>/dev/null || true)
        if [ "$status" = "healthy" ]; then
            log "Authelia container is healthy"
            return 0
        fi
        sleep "$RETRY_INTERVAL"
    done

    log "WARNING: Timed out waiting for Authelia health"
    return 1
}

restart_authelia_if_running() {
    if ! docker ps --format '{{.Names}}' | grep -q '^pi-authelia$'; then
        return 0
    fi

    log "Restarting Authelia to apply OIDC client updates"
    if (cd "$PROJECT_DIR" && docker compose restart authelia >/dev/null); then
        wait_for_authelia_health || true
        return 0
    fi

    log "WARNING: Failed to restart Authelia automatically"
    return 1
}

authelia_container_has_portainer_materials() {
    if ! docker ps --format '{{.Names}}' | grep -q '^pi-authelia$'; then
        return 1
    fi

    (cd "$PROJECT_DIR" && docker compose exec -T authelia sh -ec '[ -r /config/secrets/oidc_portainer_secret.txt ] && grep -q "client_id: portainer" /config/configuration.yml' >/dev/null 2>&1)
}

ensure_authelia_portainer_materials() {
    local data_root config_file secret_file pre_start_script

    data_root="$(resolve_data_location_path)"
    config_file="$data_root/authelia-config/configuration.yml"
    secret_file="$data_root/authelia-config/secrets/oidc_portainer_secret.txt"
    pre_start_script="$PROJECT_DIR/scripts/authelia-pre-start.sh"

    if [ -r "$secret_file" ] && [ -f "$config_file" ] && grep -q 'client_id: portainer' "$config_file" 2>/dev/null; then
        return 0
    fi

    if authelia_container_has_portainer_materials; then
        return 0
    fi

    log "Detected missing Portainer OIDC materials in Authelia config data"

    if [ ! -f "$pre_start_script" ]; then
        log "WARNING: Missing $pre_start_script; cannot auto-heal Authelia OIDC materials"
        return 1
    fi

    if ! sh "$pre_start_script"; then
        log "WARNING: authelia-pre-start.sh failed while preparing Portainer OIDC materials"
        return 1
    fi

    restart_authelia_if_running || true

    if [ ! -r "$secret_file" ] || [ ! -f "$config_file" ] || ! grep -q 'client_id: portainer' "$config_file" 2>/dev/null; then
        if authelia_container_has_portainer_materials; then
            return 0
        fi
        log "WARNING: Portainer OIDC materials are still missing after regeneration attempt"
        return 1
    fi

    return 0
}

wait_for_portainer_http() {
    log "Waiting for Portainer HTTP API..."
    for i in $(seq 1 $MAX_RETRIES); do
        if docker_curl "$PORTAINER_URL_DOCKER/" >/dev/null 2>&1; then
            log "Portainer HTTP endpoint is reachable"
            return 0
        fi
        sleep "$RETRY_INTERVAL"
    done

    log "ERROR: Portainer HTTP endpoint did not become reachable"
    return 1
}

init_portainer_admin() {
    local curl_image="${CURL_IMAGE:-curlimages/curl:8.12.1}"
    local check_headers check_status redirect_reason

    check_headers="$(docker run --rm --network frontend "$curl_image" \
        -si -o /dev/null -D - \
        "$PORTAINER_URL_DOCKER/api/users/admin/check" 2>/dev/null)" || check_headers=""

    check_status="$(printf '%s' "$check_headers" | head -1 | grep -oE '[0-9]{3}')"
    redirect_reason="$(printf '%s' "$check_headers" | grep -i '^Redirect-Reason:' | tr -d '\r' | cut -d: -f2- | tr -d ' ')"

    case "$check_status" in
        204)
            # Admin already exists — nothing to do
            return 0
            ;;
        404)
            # Fresh install: admin not yet created — fall through to init
            ;;
        303)
            if [ "$redirect_reason" = "AdminInitTimeout" ]; then
                log "Portainer initialization timed out. Restarting Portainer to get a fresh init window..."
                (cd "$PROJECT_DIR" && docker compose restart portainer >/dev/null 2>&1) || {
                    log "ERROR: Failed to restart Portainer container"
                    return 1
                }
                # Wait for the container to come back up and be reachable
                if ! wait_for_container "$PORTAINER_CONTAINER" "$MAX_RETRIES" "$RETRY_INTERVAL"; then
                    return 1
                fi
                if ! wait_for_portainer_http; then
                    return 1
                fi
                # Re-check: after restart and before browser opens, should be 404
                check_status="$(docker run --rm --network frontend "$curl_image" \
                    -s -o /dev/null -w '%{http_code}' \
                    "$PORTAINER_URL_DOCKER/api/users/admin/check" 2>/dev/null)" || check_status="000"
                if [ "$check_status" = "204" ]; then
                    return 0
                elif [ "$check_status" != "404" ]; then
                    log "WARNING: Unexpected status $check_status after Portainer restart; skipping admin init"
                    return 1
                fi
            else
                log "WARNING: Unexpected 303 (Redirect-Reason: ${redirect_reason:-unknown}) from /api/users/admin/check; skipping admin init"
                return 1
            fi
            ;;
        *)
            log "WARNING: Unexpected status ${check_status:-000} from /api/users/admin/check; skipping admin init"
            return 1
            ;;
    esac

    local password admin_username init_response

    password="$(get_env_value PASSWORD)"
    if [ -z "$password" ]; then
        log "ERROR: Missing Portainer admin password. Set PASSWORD in .env"
        return 1
    fi

    admin_username="$(get_env_value EMAIL)"
    [ -n "$admin_username" ] || admin_username="$(get_env_value USER)"
    [ -n "$admin_username" ] || admin_username="admin"

    log "Initializing Portainer admin user '$admin_username'..."

    init_response="$(docker run --rm --network frontend "$curl_image" \
        -fsS -X POST \
        -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg u "$admin_username" --arg p "$password" '{Username:$u,Password:$p}')" \
        "$PORTAINER_URL_DOCKER/api/users/admin/init" 2>/dev/null)" || {
        log "ERROR: Failed to call Portainer /api/users/admin/init"
        return 1
    }

    if ! printf '%s' "$init_response" | jq -e '.Id // empty' >/dev/null 2>&1; then
        log "ERROR: Portainer admin init returned unexpected response: $init_response"
        return 1
    fi

    log "Portainer admin user initialized successfully"
}

authenticate_portainer() {
    local password usernames attempted auth_response jwt_token candidate

    password="$(get_env_value PASSWORD)"
    if [ -z "$password" ]; then
        log "ERROR: Missing Portainer admin password. Set PASSWORD in .env"
        return 1
    fi

    # Build candidate username list: EMAIL, USER (if different), admin (if not already listed)
    usernames="$(get_env_value EMAIL)"
    candidate="$(get_env_value USER)"
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

    attempted=""
    for candidate in $usernames; do
        auth_response="$(docker_curl -X POST -H 'Content-Type: application/json' \
            -d "$(jq -nc --arg u "$candidate" --arg p "$password" '{Username:$u,Password:$p}')" \
            "$PORTAINER_URL_DOCKER/api/auth" 2>/dev/null)" || continue

        jwt_token="$(printf '%s' "$auth_response" | jq -re '.jwt // empty')" || continue

        if [ -n "$jwt_token" ]; then
            if [ "$candidate" != "${usernames%% *}" ]; then
                log "Authenticated to Portainer API using fallback local user '$candidate'"
            fi
            printf '%s' "$jwt_token"
            return 0
        fi

        attempted="${attempted:+$attempted, }$candidate"
    done

    log "ERROR: Failed to authenticate to Portainer API (attempted users: $attempted)"
    return 1
}

portainer_api_get() {
    local jwt="$1"
    local path="$2"

    docker_curl -H "Authorization: Bearer $jwt" "$PORTAINER_URL_DOCKER$path"
}

portainer_api_put_json() {
    local jwt="$1"
    local path="$2"
    local payload="$3"

    docker_curl -X PUT \
        -H "Authorization: Bearer $jwt" \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "$PORTAINER_URL_DOCKER$path"
}

portainer_api_post_json() {
    local jwt="$1"
    local path="$2"
    local payload="$3"

    docker_curl -X POST \
        -H "Authorization: Bearer $jwt" \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "$PORTAINER_URL_DOCKER$path"
}

ensure_portainer_default_team() {
    local jwt="$1"
    local settings_json="$2"
    local teams_json current_default_team_id team_id

    teams_json="$(portainer_api_get "$jwt" "/api/teams")" || {
        log "ERROR: Failed to fetch Portainer teams"
        return 1
    }

    # Check if existing default team is still valid
    current_default_team_id="$(printf '%s' "$settings_json" | jq -r '.OAuthSettings.DefaultTeamID // 0')"
    if [ "$current_default_team_id" -gt 0 ] 2>/dev/null; then
        if printf '%s' "$teams_json" | jq -e --argjson id "$current_default_team_id" 'map(select(.Id == $id)) | length > 0' >/dev/null 2>&1; then
            printf '%s' "$current_default_team_id"
            return 0
        fi
    fi

    # Look up team by name
    team_id="$(printf '%s' "$teams_json" | jq -r --arg name "$PORTAINER_OIDC_DEFAULT_TEAM_NAME" \
        '[.[] | select(.Name == $name)] | first | .Id // empty')"
    if [ -n "$team_id" ] && [ "$team_id" -gt 0 ] 2>/dev/null; then
        printf '%s' "$team_id"
        return 0
    fi

    # Create team
    log "Creating Portainer team '$PORTAINER_OIDC_DEFAULT_TEAM_NAME' for OAuth users"
    portainer_api_post_json "$jwt" "/api/teams" \
        "$(jq -nc --arg n "$PORTAINER_OIDC_DEFAULT_TEAM_NAME" '{Name:$n,TeamLeaders:[]}')" >/dev/null 2>&1 || true

    # Re-fetch and verify
    teams_json="$(portainer_api_get "$jwt" "/api/teams")" || {
        log "ERROR: Failed to refresh Portainer teams after create attempt"
        return 1
    }

    team_id="$(printf '%s' "$teams_json" | jq -r --arg name "$PORTAINER_OIDC_DEFAULT_TEAM_NAME" \
        '[.[] | select(.Name == $name)] | first | .Id // empty')"
    if [ -z "$team_id" ] || [ "$team_id" -le 0 ] 2>/dev/null; then
        log "ERROR: Failed to ensure Portainer team '$PORTAINER_OIDC_DEFAULT_TEAM_NAME' exists"
        return 1
    fi

    printf '%s' "$team_id"
}

ensure_portainer_default_team_endpoint_access() {
    local jwt="$1"
    local team_id="$2"
    local endpoints_json endpoint_ids endpoint_id endpoint_json group_id group_json update_result update_status update_payload

    endpoints_json="$(portainer_api_get "$jwt" "/api/endpoints")" || {
        log "ERROR: Failed to fetch Portainer endpoints"
        return 1
    }

    endpoint_ids="$(printf '%s' "$endpoints_json" | jq -r '[.[] | select(.Id > 0) | .Id] | join(" ")')"
    if [ -z "$endpoint_ids" ]; then
        return 0
    fi

    for endpoint_id in $endpoint_ids; do
        endpoint_json="$(portainer_api_get "$jwt" "/api/endpoints/$endpoint_id")" || {
            log "ERROR: Failed to inspect Portainer endpoint $endpoint_id"
            return 1
        }

        group_id="$(printf '%s' "$endpoint_json" | jq -r '.GroupId // 0')"
        group_json='{}'
        if [ "$group_id" -gt 0 ] 2>/dev/null; then
            group_json="$(portainer_api_get "$jwt" "/api/endpoint_groups/$group_id")" || {
                log "ERROR: Failed to inspect Portainer endpoint group $group_id"
                return 1
            }
        fi

        update_result="$(jq -rnc \
            --argjson endpoint "$endpoint_json" \
            --argjson group "$group_json" \
            --arg team_id "$team_id" \
            --argjson role_id "$PORTAINER_ENDPOINT_ROLE_ID" '
            ($endpoint.UserAccessPolicies // {}) as $eu |
            ($endpoint.TeamAccessPolicies // {}) as $et |
            ($group.UserAccessPolicies // {}) as $gu |
            ($group.TeamAccessPolicies // {}) as $gt |
            ($et * {($team_id):{RoleId:$role_id}}) as $updated_et |
            if $et[$team_id] then
                if ($et[$team_id].RoleId // 0) == $role_id then "noop"
                else "update\n" + ({UserAccessPolicies:$eu,TeamAccessPolicies:$updated_et} | tojson)
                end
            elif $gt[$team_id] then "noop"
            elif ($eu | length > 0) or ($et | length > 0) or ($gu | length > 0) or ($gt | length > 0) then "skip"
            else "update\n" + ({UserAccessPolicies:$eu,TeamAccessPolicies:$updated_et} | tojson)
            end')" || {
            log "ERROR: Failed to compute access update for Portainer endpoint $endpoint_id"
            return 1
        }

        update_status="$(printf '%s\n' "$update_result" | head -n1)"
        case "$update_status" in
            noop)
                ;;
            skip)
                log "Leaving Portainer endpoint $endpoint_id access unchanged because explicit access policies already exist"
                ;;
            update*)
                update_payload="$(printf '%s\n' "$update_result" | tail -n +2)"
                if [ -z "$update_payload" ]; then
                    log "ERROR: Missing Portainer endpoint access payload for endpoint $endpoint_id"
                    return 1
                fi

                portainer_api_put_json "$jwt" "/api/endpoints/$endpoint_id" "$update_payload" >/dev/null || {
                    log "ERROR: Failed to grant team access to Portainer endpoint $endpoint_id"
                    return 1
                }
                ;;
            *)
                log "ERROR: Unexpected Portainer endpoint access action '$update_status' for endpoint $endpoint_id"
                return 1
                ;;
        esac
    done
}

ensure_portainer_default_team_memberships() {
    local jwt="$1"
    local team_id="$2"
    local users_json memberships_json user_ids user_id

    users_json="$(portainer_api_get "$jwt" "/api/users")" || {
        log "ERROR: Failed to fetch Portainer users"
        return 1
    }

    memberships_json="$(portainer_api_get "$jwt" "/api/team_memberships")" || {
        log "ERROR: Failed to fetch Portainer team memberships"
        return 1
    }

    # Find standard users (Role==2) with no team memberships
    user_ids="$(jq -nr --argjson users "$users_json" --argjson memberships "$memberships_json" '
        [$memberships | .[] | .UserID] | unique as $has_team |
        [$users | .[] | select(.Id > 0 and .Role == 2 and (.Id | IN($has_team[]) | not)) | .Id] |
        join(" ")')"

    if [ -z "$user_ids" ]; then
        return 0
    fi

    for user_id in $user_ids; do
        portainer_api_post_json "$jwt" "/api/team_memberships" \
            "$(jq -nc --argjson uid "$user_id" --argjson tid "$team_id" --argjson role "$PORTAINER_TEAM_MEMBER_ROLE" \
                '{UserID:$uid,TeamID:$tid,Role:$role}')" >/dev/null || {
            log "ERROR: Failed to add Portainer user $user_id to default OAuth team $team_id"
            return 1
        }
    done
}

ensure_portainer_users_are_admin() {
    local jwt="$1"
    local users_json user_ids user_id

    users_json="$(portainer_api_get "$jwt" "/api/users")" || {
        log "ERROR: Failed to fetch Portainer users"
        return 1
    }

    user_ids="$(printf '%s' "$users_json" | jq -r '[.[] | select(.Id > 0 and .Role != 1) | .Id] | join(" ")')"

    if [ -z "$user_ids" ]; then
        log "All Portainer users are already admin"
        return 0
    fi

    for user_id in $user_ids; do
        portainer_api_put_json "$jwt" "/api/users/$user_id" '{"Role":1}' >/dev/null || {
            log "ERROR: Failed to promote Portainer user $user_id to admin"
            return 1
        }
        log "Promoted Portainer user $user_id to admin"
    done
}

# Compute OIDC defaults once, reused by build and verify
oidc_defaults() {
    local host="$1"
    local auth_base="https://auth.${host}"
    local portainer_base="https://portainer.${host}"

    OIDC_CLIENT_ID_VAL="$(get_env_value PORTAINER_OIDC_CLIENT_ID)"
    OIDC_CLIENT_ID_VAL="${OIDC_CLIENT_ID_VAL:-portainer}"
    OIDC_AUTH_URI="$(get_env_value PORTAINER_OIDC_AUTHORIZATION_URI)"
    OIDC_AUTH_URI="${OIDC_AUTH_URI:-${auth_base}/api/oidc/authorization}"
    OIDC_TOKEN_URI="$(get_env_value PORTAINER_OIDC_TOKEN_URI)"
    OIDC_TOKEN_URI="${OIDC_TOKEN_URI:-${auth_base}/api/oidc/token}"
    OIDC_RESOURCE_URI="$(get_env_value PORTAINER_OIDC_RESOURCE_URI)"
    OIDC_RESOURCE_URI="${OIDC_RESOURCE_URI:-${auth_base}/api/oidc/userinfo}"
    OIDC_REDIRECT_URI="$(get_env_value PORTAINER_OIDC_REDIRECT_URI)"
    OIDC_REDIRECT_URI="${OIDC_REDIRECT_URI:-${portainer_base}}"
    OIDC_LOGOUT_URI="$(get_env_value PORTAINER_OIDC_LOGOUT_URI)"
    OIDC_LOGOUT_URI="${OIDC_LOGOUT_URI:-${auth_base}/logout}"
    OIDC_USER_ID="$(get_env_value PORTAINER_OIDC_USER_IDENTIFIER)"
    OIDC_USER_ID="${OIDC_USER_ID:-preferred_username}"

    local raw_scopes
    raw_scopes="$(get_env_value PORTAINER_OIDC_SCOPES)"
    raw_scopes="${raw_scopes:-openid profile email groups}"
    OIDC_SCOPES="$(printf '%s' "$raw_scopes" | tr ',' ' ' | tr -s ' ')"
}

build_portainer_oidc_payload() {
    local current_settings_json="$1"
    local oidc_secret="$2"
    local default_team_id="$3"

    oidc_defaults "$HOST_NAME"

    local auto_create sso auth_style
    auto_create="$(get_env_value PORTAINER_OIDC_AUTO_CREATE_USERS)"
    sso="$(get_env_value PORTAINER_OIDC_SSO)"
    auth_style="$(get_env_value PORTAINER_OIDC_AUTH_STYLE)"

    jq -nc \
        --argjson current "$current_settings_json" \
        --arg client_id "$OIDC_CLIENT_ID_VAL" \
        --arg client_secret "$oidc_secret" \
        --arg auth_uri "$OIDC_AUTH_URI" \
        --arg token_uri "$OIDC_TOKEN_URI" \
        --arg resource_uri "$OIDC_RESOURCE_URI" \
        --arg redirect_uri "$OIDC_REDIRECT_URI" \
        --arg logout_uri "$OIDC_LOGOUT_URI" \
        --arg user_id "$OIDC_USER_ID" \
        --arg scopes "$OIDC_SCOPES" \
        --argjson default_team_id "${default_team_id:-0}" \
        --arg auto_create "$auto_create" \
        --arg sso "$sso" \
        --arg auth_style "$auth_style" '
        def parse_bool(val; default):
            if val == "" then default
            elif val | test("^(1|true|yes|on)$"; "i") then true
            else false end;
        def parse_int(val; default):
            if val == "" then default
            else (val | tonumber? // default) end;

        ($current.OAuthSettings // {}) as $oc |
        {
            AuthenticationMethod: 3,
            OAuthSettings: {
                ClientID: $client_id,
                ClientSecret: $client_secret,
                AccessTokenURI: $token_uri,
                AuthorizationURI: $auth_uri,
                ResourceURI: $resource_uri,
                RedirectURI: $redirect_uri,
                UserIdentifier: $user_id,
                Scopes: $scopes,
                OAuthAutoCreateUsers: parse_bool($auto_create; true),
                DefaultTeamID: $default_team_id,
                SSO: parse_bool($sso; (if $oc.SSO != null then $oc.SSO else true end)),
                LogoutURI: $logout_uri,
                AuthStyle: parse_int($auth_style; ($oc.AuthStyle // 2))
            }
        }'
}

verify_portainer_oidc() {
    local jwt="$1"
    local expected_default_team_id="$2"
    local settings_json

    settings_json="$(portainer_api_get "$jwt" "/api/settings")"

    oidc_defaults "$HOST_NAME"

    printf '%s' "$settings_json" | jq -e \
        --arg client_id "$OIDC_CLIENT_ID_VAL" \
        --arg auth_uri "$OIDC_AUTH_URI" \
        --arg token_uri "$OIDC_TOKEN_URI" \
        --arg resource_uri "$OIDC_RESOURCE_URI" \
        --arg redirect_uri "$OIDC_REDIRECT_URI" \
        --arg user_id "$OIDC_USER_ID" \
        --arg scopes "$OIDC_SCOPES" \
        --argjson expected_team "${expected_default_team_id:-0}" '
        .AuthenticationMethod == 3 and
        .OAuthSettings.ClientID == $client_id and
        .OAuthSettings.AuthorizationURI == $auth_uri and
        .OAuthSettings.AccessTokenURI == $token_uri and
        .OAuthSettings.ResourceURI == $resource_uri and
        .OAuthSettings.RedirectURI == $redirect_uri and
        .OAuthSettings.UserIdentifier == $user_id and
        .OAuthSettings.Scopes == $scopes and
        (if $expected_team > 0 then .OAuthSettings.DefaultTeamID == $expected_team else true end)
    ' >/dev/null
}

main() {
    log "=== Portainer OIDC Bootstrap ==="

    if [ ! -f "$ENV_FILE" ]; then
        die ".env missing at $ENV_FILE"
    fi

    enabled="$(get_env_value PORTAINER_OIDC_ENABLED)"
    [ -n "$enabled" ] || enabled="true"
    if ! is_truthy "$enabled"; then
        log "PORTAINER_OIDC_ENABLED is disabled, skipping bootstrap"
        exit 0
    fi

    HOST_NAME="$(get_env_value HOST_NAME)"
    HOST_NAME="${HOST_NAME:-pi.lan}"

    ensure_authelia_portainer_materials || {
        die "Portainer OIDC prerequisites are missing in Authelia configuration"
    }

    if ! wait_for_container "$PORTAINER_CONTAINER" "$MAX_RETRIES" "$RETRY_INTERVAL"; then
        exit 1
    fi

    if ! wait_for_portainer_http; then
        exit 1
    fi

    init_portainer_admin || {
        log "WARNING: Could not auto-initialize Portainer admin; will attempt authentication anyway"
    }

    OIDC_CLIENT_SECRET="$(get_oidc_secret "portainer" "PORTAINER_OIDC_CLIENT_SECRET")" || {
        die "Could not read Portainer OIDC client secret"
    }

    if [ -z "$OIDC_CLIENT_SECRET" ]; then
        die "Portainer OIDC client secret is empty"
    fi

    JWT_TOKEN="$(authenticate_portainer)" || {
        log "WARNING: Unable to authenticate to Portainer; OIDC bootstrap skipped"
        log "         Ensure .env PASSWORD matches the Portainer local account password"
        log "         (user candidates tried: .env EMAIL, then .env USER, then 'admin')"
        exit 1
    }

    CURRENT_SETTINGS="$(portainer_api_get "$JWT_TOKEN" "/api/settings")" || {
        die "Failed to fetch current Portainer settings"
    }

    DEFAULT_TEAM_ID="$(ensure_portainer_default_team "$JWT_TOKEN" "$CURRENT_SETTINGS")" || {
        die "Failed to ensure Portainer default OAuth team"
    }

    SETTINGS_PAYLOAD="$(build_portainer_oidc_payload "$CURRENT_SETTINGS" "$OIDC_CLIENT_SECRET" "$DEFAULT_TEAM_ID")" || {
        die "Failed to build Portainer OIDC settings payload"
    }

    portainer_api_put_json "$JWT_TOKEN" "/api/settings" "$SETTINGS_PAYLOAD" >/dev/null || {
        die "Failed to update Portainer settings with OIDC configuration"
    }

    if ! verify_portainer_oidc "$JWT_TOKEN" "$DEFAULT_TEAM_ID"; then
        die "Portainer OIDC verification failed after settings update"
    fi

    ensure_portainer_default_team_endpoint_access "$JWT_TOKEN" "$DEFAULT_TEAM_ID" || {
        die "Failed to grant Portainer default OAuth team access to unassigned endpoints"
    }

    ensure_portainer_default_team_memberships "$JWT_TOKEN" "$DEFAULT_TEAM_ID" || {
        die "Failed to backfill Portainer default OAuth team memberships"
    }

    ensure_portainer_users_are_admin "$JWT_TOKEN" || {
        die "Failed to promote all users to admin in Portainer"
    }

    log "Portainer OIDC configured successfully"
}

main "$@"
