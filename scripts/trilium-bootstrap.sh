#!/bin/sh
# Post-start: claim the Trilium instance, point its AI assistant at
# agentgateway, turn its MCP server on, and mint the ETAPI token agentgateway
# needs to reach it.
#
# `aiEnabled`, `mcpEnabled` and `llmProviders` are database options with no
# environment equivalent, and `PUT /api/options` wants a session cookie plus a
# CSRF token. `POST /login` redirects to Authelia once SSO is enrolled, so the
# only window in which this can be automated is before that - hence claiming
# the instance with ${PASSWORD} rather than waiting for the owner, which also
# closes the first-run land-grab. See docs/AI.md and docs/SECURITY.md.
#
# A post-start hook (scripts/run-hooks.sh). Idempotent.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

TRILIUM_URL="${TRILIUM_URL:-http://trilium:8080}"
AGENTGATEWAY_URL="${AGENTGATEWAY_URL:-http://agentgateway:4000}"

# The provider config id written into `llmProviders`. Stable, because it is the
# key the option is matched on: changing it would add a second provider card
# rather than update this one.
PROVIDER_ID="agentgateway"

# --- Reading Trilium's state ---

setup_status() {
    docker_curl "$TRILIUM_URL/api/setup/status" 2>/dev/null
}

# Create the document if there is none, then set the owner password if none is
# set. Deliberately not gated on `hasExistingData`: that flag means "a database
# was already here at boot", not "has notes", and reads false against a
# populated instance. The real guards are upstream - checkAppNotInitialized and
# checkPasswordNotSet.
claim_instance() {
    local status="" password=""

    status="$(setup_status)" || {
        log "WARNING: Trilium did not answer /api/setup/status; skipping"
        return 1
    }

    # The only destructive call here - new-document runs discardExistingData()
    # first - so it is reached only when Trilium reports no schema at all.
    #
    # ?skipDemoDb drops the 177-note "Trilium Demo" tree; the built-in help
    # subtree is separate and stays. Its *value* is never read (upstream tests
    # `!== undefined`), so `=false` would skip the demo too - not a boolean.
    if [ "$(printf '%s' "$status" | jq -r '.isInitialized | tostring')" != "true" ]; then
        log "Creating Trilium's initial document (without the demo notes)"
        printf '{}' \
            | api_send_json_stdin POST "$TRILIUM_URL" "/api/setup/new-document?skipDemoDb=true" >/dev/null 2>&1 || {
            log "WARNING: Trilium refused to create the initial document"
            return 1
        }
    fi

    password="$(get_env_value PASSWORD)"
    [ -n "$password" ] || {
        log "WARNING: PASSWORD is empty; cannot claim Trilium"
        return 1
    }

    # Attempted, never judged: success and checkPasswordNotSet's refusal are both
    # `res.redirect("login")`, so no status distinguishes them. Whether the stack
    # owns the password is answered by the sign-in below instead.
    jq -cn --arg p "$password" '{password1: $p, password2: $p}' \
        | docker_curl_stdin -X POST -o /dev/null \
            -H 'Content-Type: application/json' \
            "$TRILIUM_URL/set-password" >/dev/null 2>&1 || true
}

# --- Authenticating as the owner ---

# Echo the session cookie, or nothing. `POST /login` needs no CSRF, but its
# handler redirects to Authelia rather than checking the password once SSO is
# enrolled - which is what makes this a fresh-install path, not a repair tool.
open_session() {
    local password="" headers="" session=""

    password="$(get_env_value PASSWORD)"
    [ -n "$password" ] || return 1

    headers="$(jq -cn --arg p "$password" '{password: $p}' \
        | docker_curl_stdin -X POST -D - -o /dev/null \
            -H 'Content-Type: application/json' \
            "$TRILIUM_URL/login" 2>/dev/null)" || return 1

    session="$(printf '%s' "$headers" | tr -d '\r' \
        | sed -n 's/^[Ss]et-[Cc]ookie: *\(trilium\.sid=[^;]*\).*/\1/p' | head -1)"
    [ -n "$session" ] || return 1

    # A cookie is not a login: a *failed* attempt gets a session too, so trusting
    # Set-Cookie alone reads a wrong password as success.
    api_get_with_cookie "$TRILIUM_URL" "/bootstrap" "$session" 2>/dev/null \
        | jq -e '.loggedIn == true' >/dev/null 2>&1 || return 1

    printf '%s' "$session"
}

# Echo "<cookie header>|<csrf token>".
#
# One request, not two: csrf-csrf binds the token to the session id and
# /bootstrap re-issues `trilium.sid` alongside `trilium-csrf`, so headers and
# body fetched separately pair a token with the wrong session. The failure is
# a 403 visible only in Trilium's log.
csrf_material() {
    local session="$1" response="" headers="" body="" cookies="" token=""

    response="$(docker_curl -i -H "Cookie: $session" "$TRILIUM_URL/bootstrap" 2>/dev/null)" || return 1

    headers="$(printf '%s' "$response" | tr -d '\r' | sed -n '1,/^$/p')"
    body="$(printf '%s' "$response" | tr -d '\r' | sed -n '/^$/,$p' | tail -n +2)"

    token="$(printf '%s' "$body" | jq -r '.csrfToken // empty' 2>/dev/null)"
    [ -n "$token" ] || return 1

    # Every cookie this response set, refreshed session id included.
    cookies="$(printf '%s' "$headers" \
        | sed -n 's/^[Ss]et-[Cc]ookie: *\([^;]*\).*/\1/p' | paste -sd'; ' -)"
    [ -n "$cookies" ] || cookies="$session"

    printf '%s|%s' "$cookies" "$token"
}

# --- The options themselves ---

# The models agentgateway serves, as the LlmModelInfo array Trilium stores in
# `selectedModels`. Denormalised because its picker renders straight from the
# option and never re-fetches: an empty list means no models at all.
gateway_models() {
    local key="$1"

    docker_curl -H "Authorization: Bearer $key" "$AGENTGATEWAY_URL/v1/models" 2>/dev/null \
        | jq -c '[.data[]? | {id: .id, name: .id}]' 2>/dev/null
}

apply_options() {
    local cookies="$1" csrf_token="$2"
    local key_file="" key="" models="" providers="" current="" desired=""

    key_file="$(resolve_data_location_path)/agentgateway/secrets/trilium_llm_key"
    [ -r "$key_file" ] || {
        log "WARNING: no Trilium LLM key yet (agentgateway-pre-start.sh has not run); skipping the AI wiring"
        return 1
    }
    key="sk-$(cat "$key_file")"

    models="$(gateway_models "$key")"
    [ -n "$models" ] || models='[]'
    if [ "$models" = '[]' ]; then
        log "NOTE: agentgateway listed no models; the provider is saved without a preselection"
    fi

    # `openai-compatible`, not `openai`: the latter talks to api.openai.com and
    # ignores baseURL when listing models.
    providers="$(jq -cn --arg id "$PROVIDER_ID" --arg key "$key" \
        --arg url "$AGENTGATEWAY_URL/v1" --argjson models "$models" \
        '[{id: $id, name: "Agentgateway", provider: "openai-compatible",
           apiKey: $key, baseURL: $url, selectedModels: $models}]')"

    desired="$(jq -cn --argjson p "$providers" \
        '{aiEnabled: "true", mcpEnabled: "true", llmProviders: ($p | tostring)}')"

    # Only write when something actually differs: every PUT is an entity change
    # Trilium syncs and shows in its options history.
    current="$(api_get_with_cookie "$TRILIUM_URL" "/api/options" "$cookies" 2>/dev/null)" || current='{}'
    if printf '%s' "$current" | jq -e --argjson d "$desired" \
        'to_entries | map(select(.key as $k | $d | has($k))) | from_entries == $d' >/dev/null 2>&1; then
        log "Trilium AI and MCP options already match"
        return 0
    fi

    printf '%s' "$desired" | docker_curl_stdin -X PUT \
        -H "Cookie: $cookies" \
        -H "x-csrf-token: $csrf_token" \
        -H 'Content-Type: application/json' \
        "$TRILIUM_URL/api/options" >/dev/null 2>&1 \
        || { log "WARNING: Trilium refused the options update"; return 1; }

    log "Enabled Trilium's AI assistant against agentgateway, and its MCP server"
}

# --- The token agentgateway needs ---

# `POST /api/login/token` verifies the password itself and is not gated on SSO
# the way /login is, so this still works after enrolment - the same shape as
# Kavita's API key. Written where agentgateway-pre-start.sh looks for it.
mint_etapi_token() {
    local token_file="" password="" token=""

    token_file="$(trilium_etapi_token_file)"
    # Three outcomes: 0 minted, 2 already there, 1 could not - main() must tell
    # "nothing to do" from "the contract moved". A token pasted here by hand
    # counts as already there and is never overwritten.
    if [ -s "$token_file" ]; then
        return 2
    fi

    password="$(get_env_value PASSWORD)"
    [ -n "$password" ] || return 1

    # `.token`, not the `.authToken` the internal OpenAPI document advertises -
    # that spelling belongs to /etapi/auth/login. Both accepted. A 401 here just
    # means the owner chose their own password, which is not an error.
    token="$(jq -cn --arg p "$password" '{password: $p, tokenName: "agentgateway-mcp"}' \
        | api_send_json_stdin POST "$TRILIUM_URL" "/api/login/token" 2>/dev/null \
        | jq -r '.token // .authToken // empty')"
    if [ -z "$token" ]; then
        log "No ETAPI token minted: Trilium's owner password is not PASSWORD."
        log "  Create one in Trilium (Options -> ETAPI) and write it to $token_file,"
        log "  then re-run this hook - agentgateway's MCP target reads it from there."
        return 1
    fi

    mkdir -p "$(dirname "$token_file")"
    safe_chmod 700 "$(dirname "$token_file")"
    printf '%s' "$token" | write_secret_file "$token_file" || return 1
    safe_chmod 600 "$token_file"
    fix_ownership "$(dirname "$token_file")"

    log "Minted the Trilium ETAPI token for agentgateway's MCP target"
    return 0
}

# Re-render agentgateway's env_file and recreate it, so the MCP target picks the
# token up now rather than at the next boot. Only called when the token was just
# minted: recreating it disconnects every open chat.
refresh_agentgateway() {
    container_is_running "pi-agentgateway" || return 0

    sh "$SCRIPT_DIR/agentgateway-pre-start.sh" >/dev/null 2>&1 \
        || { log "WARNING: could not re-render agentgateway's environment"; return 0; }
    # up -d, not restart: env_file values are frozen at container creation.
    compose up -d agentgateway >/dev/null 2>&1 \
        || log "WARNING: could not recreate agentgateway with the new token"
}

main() {
    local session="" material="" csrf_cookie="" csrf_token="" owned=0 failed=0

    wait_for_http_endpoint "$TRILIUM_URL/api/setup/status" "Trilium" 60 2 || return 0

    claim_instance || return 0

    # Two independent halves: the options need a session, which exists only
    # before SSO is enrolled, while the token needs only the password. So an
    # enrolled instance can still get its MCP target wired.
    session="$(open_session)"
    if [ -n "$session" ]; then
        owned=1
        log "Signed in to Trilium as the owner (its password is PASSWORD)"
        material="$(csrf_material "$session")" || material=""
        if [ -n "$material" ]; then
            csrf_cookie="${material%%|*}"
            csrf_token="${material#*|}"
            # csrf_cookie already carries the session id, so it replaces it
            apply_options "$csrf_cookie" "$csrf_token" || failed=1
        else
            log "WARNING: could not obtain a CSRF token from Trilium"
            failed=1
        fi
    else
        # Normal once SSO is enrolled: nothing is broken, there is simply no way
        # in from a script any more. See docs/AI.md.
        log "No password session (SSO enrolled, or an owner password this stack did not set)"
        log "  Leaving Trilium's AI and MCP options alone; set them in Options -> AI."
    fi

    # Not `mint && refresh || case`: that also runs the handler when *refresh*
    # fails, on the wrong $?.
    if mint_etapi_token; then
        refresh_agentgateway
    else
        case "$?" in
            2) : ;;          # already there, nothing to do
            *) [ "$owned" -eq 0 ] || failed=1 ;;
        esac
    fi

    # Non-zero only when the instance was ours and configuring it still failed,
    # which means the endpoints moved. CI runs post-start hooks blocking, so
    # that is a red boot. An instance we do not own must stay 0 - otherwise
    # every later `make update` fails on a working setup.
    if [ "$failed" -eq 1 ]; then
        log "ERROR: Trilium is owned by this stack but could not be configured;"
        log "  run tests/trilium-api-contract.sh - the API this hook drives may have moved."
        return 1
    fi
}

main "$@"
