#!/bin/sh
# Post-start: claim the Trilium instance, point its AI assistant at
# agentgateway, turn its MCP server on, and hand agentgateway the ETAPI token
# it needs to reach that server.
#
# None of this is configurable by environment variable: config.ts has no AI
# section at all, so `aiEnabled`, `mcpEnabled` and `llmProviders` are database
# options and `PUT /api/options` is the only way in. That endpoint is
# `[checkApiAuth, csrfMiddleware]` - a session cookie and a CSRF token, with no
# ETAPI equivalent - and `POST /login` hands the browser to Authelia the moment
# SSO is enrolled (open_id.ts / login.ts). So the whole window in which any of
# this can be automated is *before* the owner enrols SSO, which is exactly
# where a post-start hook on a fresh install sits.
#
# That is also why this claims the instance itself rather than waiting for the
# owner: a session needs a password, and the only password known here is
# ${PASSWORD}. It closes the first-run window as a side effect - the instance
# is claimed by the stack that created it rather than by whoever reaches it
# first. See docs/SECURITY.md.
#
# A post-start hook (scripts/run-hooks.sh), tolerant. Idempotent: every step
# checks the state it would create and does nothing when it is already there.

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

# Claim the instance: create the document if there is none, then set the owner
# password if none is set.
#
# Neither step is gated on `hasExistingData`. That flag does not mean "has
# notes" - it is the wizard's "a database was already here when I booted", and
# it reads false on a perfectly populated instance (measured: false against 391
# notes). Gating on it would have been a guard that fires on the wrong thing.
# What actually protects each step is the condition upstream enforces:
# checkAppNotInitialized for the document, checkPasswordNotSet for the password.
claim_instance() {
    local status="" password="" code=""

    status="$(setup_status)" || {
        log "WARNING: Trilium did not answer /api/setup/status; skipping"
        return 1
    }

    # The only destructive call in this script: new-document runs
    # discardExistingData() first. Reached solely when Trilium reports no schema
    # at all, and refused upstream with a 401 in every other state.
    if [ "$(printf '%s' "$status" | jq -r '.isInitialized | tostring')" != "true" ]; then
        log "Creating Trilium's initial document"
        printf '{}' | api_send_json_stdin POST "$TRILIUM_URL" "/api/setup/new-document" >/dev/null 2>&1 || {
            log "WARNING: Trilium refused to create the initial document"
            return 1
        }
    fi

    password="$(get_env_value PASSWORD)"
    [ -n "$password" ] || {
        log "WARNING: PASSWORD is empty; cannot claim Trilium"
        return 1
    }

    # The status, not curl's exit code: checkPasswordNotSet answers a *redirect*
    # when a password is already set, and `curl -f` calls a 302 a success - so
    # exit-code-only reporting announced it had claimed an instance it had not
    # touched.
    code="$(jq -cn --arg p "$password" '{password1: $p, password2: $p}' \
        | docker_curl_stdin -X POST -o /dev/null -w '%{http_code}' \
            -H 'Content-Type: application/json' \
            "$TRILIUM_URL/set-password" 2>/dev/null || true)"
    case "$code" in
        200 | 201 | 204) log "Claimed Trilium: owner password set to PASSWORD" ;;
        *) : ;;
    esac
}

# --- Authenticating as the owner ---

# Echo the session cookie, or nothing. `POST /login` carries only the rate
# limiter, no CSRF - but its handler redirects to Authelia instead of checking
# the password once SSO is enrolled, which is what makes this a fresh-install
# path and not a repair tool.
open_session() {
    local password="" headers=""

    password="$(get_env_value PASSWORD)"
    [ -n "$password" ] || return 1

    headers="$(jq -cn --arg p "$password" '{password: $p}' \
        | docker_curl_stdin -X POST -D - -o /dev/null \
            -H 'Content-Type: application/json' \
            "$TRILIUM_URL/login" 2>/dev/null)" || return 1

    printf '%s' "$headers" \
        | tr -d '\r' \
        | sed -n 's/^[Ss]et-[Cc]ookie: *\(trilium\.sid=[^;]*\).*/\1/p' \
        | head -1
}

# Echo "<csrf cookie>|<csrf token>". csrf-csrf binds the token to the session
# id and hands out the cookie half in the same response, so both come from one
# call to /bootstrap and have to travel together on the write below.
csrf_material() {
    local session="$1" headers="" body="" cookie="" token=""

    headers="$(docker_curl -D - -o /dev/null -H "Cookie: $session" \
        "$TRILIUM_URL/bootstrap" 2>/dev/null)" || return 1
    cookie="$(printf '%s' "$headers" | tr -d '\r' \
        | sed -n 's/^[Ss]et-[Cc]ookie: *\(trilium-csrf=[^;]*\).*/\1/p' | head -1)"

    # overwrite: false upstream, so this second call returns the same token the
    # cookie above was minted with rather than rotating it.
    body="$(api_get_with_cookie "$TRILIUM_URL" "/bootstrap" "$session" 2>/dev/null)" || return 1
    token="$(printf '%s' "$body" | jq -r '.csrfToken // empty')"

    [ -n "$token" ] || return 1
    printf '%s|%s' "$cookie" "$token"
}

# --- The options themselves ---

# Echo the models agentgateway is serving, as the LlmModelInfo array Trilium
# stores in `selectedModels`. Denormalised on purpose: Trilium's model picker
# renders straight from the option and never re-fetches, so a provider saved
# with an empty list shows up with no models at all.
gateway_models() {
    local key="$1"

    docker_curl -H "Authorization: Bearer $key" "$AGENTGATEWAY_URL/v1/models" 2>/dev/null \
        | jq -c '[.data[]? | {id: .id, name: .id}]' 2>/dev/null
}

apply_options() {
    local session="$1" csrf_cookie="$2" csrf_token="$3"
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

    # `openai-compatible` rather than `openai`: the openai provider talks to
    # api.openai.com and ignores baseURL for model listing. Same reasoning as
    # the `custom` provider agentgateway itself uses for llama-cpp.
    providers="$(jq -cn --arg id "$PROVIDER_ID" --arg key "$key" \
        --arg url "$AGENTGATEWAY_URL/v1" --argjson models "$models" \
        '[{id: $id, name: "Agentgateway", provider: "openai-compatible",
           apiKey: $key, baseURL: $url, selectedModels: $models}]')"

    desired="$(jq -cn --argjson p "$providers" \
        '{aiEnabled: "true", mcpEnabled: "true", llmProviders: ($p | tostring)}')"

    # Only write when something actually differs: every PUT is an entity change
    # Trilium syncs and shows in its options history.
    current="$(api_get_with_cookie "$TRILIUM_URL" "/api/options" "$session" 2>/dev/null)" || current='{}'
    if printf '%s' "$current" | jq -e --argjson d "$desired" \
        'to_entries | map(select(.key as $k | $d | has($k))) | from_entries == $d' >/dev/null 2>&1; then
        log "Trilium AI and MCP options already match"
        return 0
    fi

    printf '%s' "$desired" | docker_curl_stdin -X PUT \
        -H "Cookie: $session; $csrf_cookie" \
        -H "x-csrf-token: $csrf_token" \
        -H 'Content-Type: application/json' \
        "$TRILIUM_URL/api/options" >/dev/null 2>&1 \
        || { log "WARNING: Trilium refused the options update"; return 1; }

    log "Enabled Trilium's AI assistant against agentgateway, and its MCP server"
}

# --- The token agentgateway needs ---

# `POST /api/login/token` verifies the password directly and is *not* gated on
# SSO the way /login is, so this keeps working after enrolment - the same shape
# as Kavita's API key. Written where agentgateway-pre-start.sh looks for it.
mint_etapi_token() {
    local token_file="" password="" token=""

    token_file="$(trilium_etapi_token_file)"
    # Not `[ -s "$token_file" ] && return 1`: under `set -e` an and-list whose
    # first command fails takes the whole script down with it.
    #
    # A token pasted here by hand counts: on an instance whose password this
    # stack did not set, that file is the only way the MCP target ever gets a
    # credential, and re-running this hook must not overwrite it.
    if [ -s "$token_file" ]; then
        return 1
    fi

    password="$(get_env_value PASSWORD)"
    [ -n "$password" ] || return 1

    # Unlike /login, this route verifies the password itself and is not handed
    # to Authelia when SSO is enrolled - so it is the one automated path that
    # still works on an enrolled instance. It 401s when the owner chose their
    # own password in the setup wizard, which is not an error worth shouting
    # about: it is the normal state of an instance this stack did not claim.
    token="$(jq -cn --arg p "$password" '{password: $p, tokenName: "agentgateway-mcp"}' \
        | api_send_json_stdin POST "$TRILIUM_URL" "/api/login/token" 2>/dev/null \
        | jq -r '.authToken // empty')"
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

# Re-render agentgateway's env_file and restart it, so the target picks the
# token up in this run rather than at the next boot. Only ever called when the
# token was just created: agentgateway is on an optional profile and restarting
# it disconnects every open chat.
refresh_agentgateway() {
    container_is_running "pi-agentgateway" || return 0

    sh "$SCRIPT_DIR/agentgateway-pre-start.sh" >/dev/null 2>&1 \
        || { log "WARNING: could not re-render agentgateway's environment"; return 0; }
    # up -d, not restart: env_file values are frozen at container creation, so a
    # restart would keep the empty token this run just replaced.
    compose up -d agentgateway >/dev/null 2>&1 \
        || log "WARNING: could not recreate agentgateway with the new token"
}

main() {
    local session="" material="" csrf_cookie="" csrf_token=""

    wait_for_http_endpoint "$TRILIUM_URL/api/setup/status" "Trilium" 60 2 || return 0

    claim_instance || return 0

    # Two independent halves, because they fail independently. The options need
    # a session, which only exists before SSO is enrolled; the ETAPI token needs
    # only the password, which /api/login/token still checks afterwards. An
    # enrolled instance can therefore still get its MCP target wired.
    session="$(open_session)"
    if [ -n "$session" ]; then
        material="$(csrf_material "$session")" || material=""
        if [ -n "$material" ]; then
            csrf_cookie="${material%%|*}"
            csrf_token="${material#*|}"
            apply_options "$session" "$csrf_cookie" "$csrf_token" || true
        else
            log "WARNING: could not obtain a CSRF token from Trilium"
        fi
    else
        # The normal state once the owner has enrolled SSO: /login stops
        # checking passwords and hands the browser to Authelia. Nothing is
        # broken - there is simply no longer a way in from a script, so
        # aiEnabled/mcpEnabled/llmProviders have to be set in the UI. See
        # docs/AI.md.
        log "No password session (SSO enrolled, or an owner password this stack did not set)"
        log "  Leaving Trilium's AI and MCP options alone; set them in Options -> AI."
    fi

    if mint_etapi_token; then
        refresh_agentgateway
    fi
}

main "$@"
