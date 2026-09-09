#!/bin/sh
# Bring Audiobookshelf up to a usable state without anyone touching its setup
# wizard: create the root account, point it at Authelia over OIDC, and add the
# audiobook library.
#
# A post-start hook (scripts/stack-up.sh). Idempotent and best-effort: every step
# checks the current state first, and a failure warns rather than failing the
# stack start.
#
# Audiobookshelf keeps all of this in its own SQLite database and exposes no way
# to seed it from the environment or a config file, so the API is the only door -
# and the API needs an account, which is why /init comes first.
#
# That account's password is also what OIDC replaces: once SSO works, local
# logins are switched off, and from then on the only credential this script
# holds is the API key it minted for itself while they were still on. So the
# order below is not cosmetic - ensure_api_key must succeed before
# configure_oidc drops `local`, or the next run has no way back in.

set -eu

. "$(dirname "$0")/lib.sh"

MAX_RETRIES=60
RETRY_INTERVAL=2
ABS_CONTAINER="${ABS_CONTAINER:-pi-audiobookshelf}"
ABS_URL="${ABS_URL:-http://pi-audiobookshelf}"
AUTHELIA_CONTAINER="${AUTHELIA_CONTAINER:-pi-authelia}"
LIBRARY_NAME="Audiobooks"
LIBRARY_PATH="/audiobooks"
# The name the automation key is filed under in Settings > API Keys, so the one
# key nobody should revoke is recognisable there.
API_KEY_NAME="pi-web-bootstrap"
# Set once a key in audiobookshelf_api_key_file() is known to authenticate. The
# gate on turning local logins off.
HAVE_API_KEY=0

abs_get() {
    docker_curl -H "Authorization: Bearer $TOKEN" "$ABS_URL$1"
}

# abs_send <method> <path> ; JSON body on stdin.
abs_send() {
    docker_curl_stdin -X "$1" \
        -H "Authorization: Bearer $TOKEN" \
        -H 'Content-Type: application/json' \
        "$ABS_URL$2"
}

# --- Root account -----------------------------------------------------------

# /init is the only unauthenticated write in the whole API, and it refuses to run
# once a root user exists - so this is safe to call blind, but /status says so
# without a write attempt.
ensure_root_user() {
    local status="" user="" password=""

    status="$(docker_curl "$ABS_URL/status" 2>/dev/null)" || {
        log "WARNING: could not read Audiobookshelf /status; skipping"
        return 1
    }

    if [ "$(printf '%s' "$status" | jq -r '.isInit // false')" = "true" ]; then
        return 0
    fi

    user="$(get_env_value ADMIN_USER)"
    password="$(get_env_value PASSWORD)"
    [ -n "$user" ] && [ -n "$password" ] || {
        log "WARNING: ADMIN_USER/PASSWORD not set; cannot create the Audiobookshelf root account"
        return 1
    }

    jq -cn --arg u "$user" --arg p "$password" '{newRoot: {username: $u, password: $p}}' \
        | docker_curl_stdin -X POST -H 'Content-Type: application/json' "$ABS_URL/init" >/dev/null 2>&1 || {
        log "WARNING: Audiobookshelf /init failed"
        return 1
    }

    log "Created the Audiobookshelf root account '$user'"
}

# The root account is created with a username and a password and nothing else, so
# it carries no email - and email is what OIDC logins are matched against below.
# Without this the admin would sign in through Authelia and land on a *second*,
# plain-user account instead of the one that can reach the settings pages.
ensure_root_email() {
    local email="" me="" id="" current=""

    email="$(get_env_value EMAIL)"
    [ -n "$email" ] || return 0

    me="$(abs_get "/api/me" 2>/dev/null)" || return 0
    id="$(printf '%s' "$me" | jq -r '.id // empty')"
    current="$(printf '%s' "$me" | jq -r '.email // empty')"
    [ -n "$id" ] || return 0

    [ "$current" = "$email" ] && return 0

    jq -cn --arg e "$email" '{email: $e}' | abs_send PATCH "/api/users/$id" >/dev/null 2>&1 \
        || { log "WARNING: could not set the root account's email"; return 0; }
    log "Set the Audiobookshelf root account's email to $email"
}

# --- Automation key ---------------------------------------------------------

# Mint the key this script (and scripts/homepage-widgets-bootstrap.sh, and
# scripts/rotate-password.sh) authenticates with from here on, and put it on
# disk. Called only when audiobookshelf_api_key() found nothing usable, so
# $TOKEN is a password-login token and local logins are necessarily still on.
#
# Sets HAVE_API_KEY on success, which is what lets configure_oidc turn them off.
# A failure is therefore self-limiting: the stack keeps a working password login
# and the next run tries again.
ensure_api_key() {
    local file="" keys="" existing_id="" user_id="" key=""

    file="$(audiobookshelf_api_key_file)"

    keys="$(abs_get "/api/api-keys" 2>/dev/null)" || {
        log "WARNING: could not list Audiobookshelf API keys; leaving local logins enabled"
        return 1
    }
    existing_id="$(printf '%s' "$keys" | jq -r --arg n "$API_KEY_NAME" \
        'first(.apiKeys[]? | select(.name == $n) | .id) // empty')"

    # The value is shown once, at creation, and stored hashed after that - so a
    # record whose file is gone (or whose file the server just rejected, which is
    # the only way to reach this function) can never be recovered. Drop it and
    # mint a matching pair; without the delete, every run would leave another
    # dead key behind in the settings page.
    if [ -n "$existing_id" ]; then
        docker_curl -X DELETE -H "Authorization: Bearer $TOKEN" \
            "$ABS_URL/api/api-keys/$existing_id" >/dev/null 2>&1 \
            || log "WARNING: could not remove the orphaned '$API_KEY_NAME' API key"
    fi

    user_id="$(abs_get "/api/me" 2>/dev/null | jq -r '.id // empty')"
    [ -n "$user_id" ] || {
        log "WARNING: could not read the Audiobookshelf user id; leaving local logins enabled"
        return 1
    }

    # isActive has to be sent: the API stores !!req.body.isActive, so an omitted
    # field creates a key that authenticates nothing. No expiresIn either - an
    # expiring key would silently take the OIDC reconcile, the Homepage widget
    # and password rotation down with it on some date nobody wrote down.
    key="$(jq -cn --arg n "$API_KEY_NAME" --arg u "$user_id" \
            '{name: $n, userId: $u, isActive: true}' \
        | abs_send POST "/api/api-keys" 2>/dev/null | jq -r '.apiKey.apiKey // empty')"
    [ -n "$key" ] || {
        log "WARNING: could not create an Audiobookshelf API key; leaving local logins enabled"
        return 1
    }

    # umask, not a chmod afterwards: the window between the two is enough for the
    # key to be world-readable on the data disk.
    (umask 077 && printf '%s' "$key" > "$file") || {
        log "WARNING: could not write $file; leaving local logins enabled"
        return 1
    }
    fix_ownership "$file"

    HAVE_API_KEY=1
    log "Stored an Audiobookshelf API key ('$API_KEY_NAME') at $file"
}

# --- OIDC -------------------------------------------------------------------

# Authelia's own discovery document, so a path it moves is followed rather than
# guessed. Read from inside the container over loopback: the URLs it returns are
# built from the forwarded host, and a plain call to :9091 would answer with none
# at all. Falls back to the documented paths, which have not moved in years.
authelia_endpoints() {
    local host_name="$1" discovery=""

    discovery="$(docker exec "$AUTHELIA_CONTAINER" sh -c \
        "wget -qO- --header='X-Forwarded-Proto: https' --header='X-Forwarded-Host: auth.${host_name}' http://127.0.0.1:9091/.well-known/openid-configuration" 2>/dev/null)" || discovery=""

    if printf '%s' "$discovery" | jq -e '.issuer and .authorization_endpoint and .token_endpoint and .userinfo_endpoint and .jwks_uri' >/dev/null 2>&1; then
        printf '%s' "$discovery"
        return 0
    fi

    log "WARNING: could not read Authelia's discovery document; using the default endpoint paths"
    jq -cn --arg base "https://auth.${host_name}" '{
        issuer: $base,
        authorization_endpoint: ($base + "/api/oidc/authorization"),
        token_endpoint: ($base + "/api/oidc/token"),
        userinfo_endpoint: ($base + "/api/oidc/userinfo"),
        jwks_uri: ($base + "/jwks.json")
    }'
}

configure_oidc() {
    local host_name="" secret="" endpoints="" current="" desired="" methods=""

    host_name="$(get_env_value HOST_NAME)"
    host_name="${host_name:-pi.lan}"

    ensure_authelia_oidc_materials "audiobookshelf" "Audiobookshelf" "$MAX_RETRIES" "$RETRY_INTERVAL" || {
        log "WARNING: Audiobookshelf OIDC prerequisites are missing in Authelia; skipping"
        return 0
    }

    secret="$(get_oidc_secret "audiobookshelf")" || {
        log "WARNING: could not read the Audiobookshelf OIDC client secret; skipping"
        return 0
    }
    [ -n "$secret" ] || { log "WARNING: the Audiobookshelf OIDC client secret is empty; skipping"; return 0; }

    endpoints="$(authelia_endpoints "$host_name")"

    current="$(abs_get "/api/auth-settings" 2>/dev/null)" || {
        log "WARNING: could not read Audiobookshelf auth settings; skipping"
        return 0
    }

    # OIDC only, so the shared PASSWORD is not a second way past Authelia into
    # a service holding everyone's listening history. Every client can do it:
    # the web app redirects, and the mobile apps get their own registered
    # redirect URI (see the Authelia client) - which is why this is safe here
    # and would not be for Kavita's OPDS readers.
    #
    # Gated on the API key, not on OIDC looking configured. Audiobookshelf has
    # no root-password escape hatch and no way to re-enable a method from
    # outside the API, so switching `local` off without a credential that
    # survives it is a one-way door: an OIDC config that turns out to be broken
    # would leave nobody, script or human, able to log in and fix it. The
    # server's own guard only reaches as far as a restart, where it drops
    # `openid` if the settings are incomplete and falls back to `local`.
    methods='["local", "openid"]'
    if [ "$HAVE_API_KEY" = "1" ]; then
        methods='["openid"]'
    else
        log "WARNING: no Audiobookshelf API key is available; keeping local logins enabled"
    fi

    # authOpenIDSubfolderForRedirectURLs is the empty string on purpose, not
    # merely absent: Audiobookshelf interpolates it into the redirect_uri
    # unguarded, so leaving it undefined builds "undefined/auth/openid/callback"
    # and every login fails on a redirect_uri mismatch.
    #
    # Empty rather than the router base path (/audiobookshelf), which is what
    # upstream's own settings page would default it to. The callback then lands
    # on the prefix-less path and the server's rewrite carries it onto the
    # prefixed route, so this is the URI Authelia has registered - keep the two
    # in step if you ever change it.
    #
    # authOpenIDGroupClaim stays empty for the reason spelled out beside the
    # Authelia client: the claim is read as a role, and a user in none of
    # admin/user/guest is denied outright. Only `admin` exists in this stack.
    # Authelia implements no OIDC logout mechanism, so its discovery document
    # carries no end_session_endpoint and reading one from $e left this null -
    # signing out of Audiobookshelf never touched the portal session. Its
    # *portal* logout route is not OIDC, but the browser is redirected there
    # with its session cookie, so the session actually ends; `rd` sends it on to
    # the Audiobookshelf login page, which is under the session cookie domain
    # and so passes Authelia's safe-redirection check.
    #
    # No placeholder parameter is needed to protect `rd` here, unlike the same
    # URL in nextcloud-oidc-bootstrap.sh: Audiobookshelf hands this to
    # openid-client, which parses the URL and merges its own query parameters
    # instead of appending a second `?`. Its post_logout_redirect_uri and
    # id_token_hint ride along and Authelia ignores both.
    local logout_url="https://auth.${host_name}/logout?rd=https%3A%2F%2Faudiobooks.${host_name}%2Flogin%2F"

    desired="$(printf '%s' "$current" | jq -c \
        --argjson e "$endpoints" \
        --argjson methods "$methods" \
        --arg secret "$secret" \
        --arg logout_url "$logout_url" \
        '. + {
            authActiveAuthMethods: $methods,
            authOpenIDIssuerURL: $e.issuer,
            authOpenIDAuthorizationURL: $e.authorization_endpoint,
            authOpenIDTokenURL: $e.token_endpoint,
            authOpenIDUserInfoURL: $e.userinfo_endpoint,
            authOpenIDJwksURL: $e.jwks_uri,
            authOpenIDLogoutURL: $logout_url,
            authOpenIDClientID: "audiobookshelf",
            authOpenIDClientSecret: $secret,
            authOpenIDTokenSigningAlgorithm: "RS256",
            authOpenIDButtonText: "Sign in with SSO",
            authOpenIDAutoRegister: true,
            authOpenIDMatchExistingBy: "email",
            authOpenIDSubfolderForRedirectURLs: "",
            authOpenIDGroupClaim: "",
            authOpenIDAdvancedPermsClaim: ""
         }')"

    if [ "$(printf '%s' "$current" | jq -S .)" = "$(printf '%s' "$desired" | jq -S .)" ]; then
        log "Audiobookshelf OIDC already configured"
        return 0
    fi

    printf '%s' "$desired" | abs_send PATCH "/api/auth-settings" >/dev/null 2>&1 || {
        log "WARNING: updating Audiobookshelf auth settings failed"
        return 0
    }
    log "Configured Audiobookshelf OIDC against https://auth.${host_name}"

    # The PATCH lands in the database, but OidcAuthStrategy.getClient() memoises
    # its client for the life of the process (`if (!this.client)`) and captures
    # the issuer metadata - end_session_endpoint among it - when it first builds
    # one. So a running instance keeps serving the values it started with: that
    # is why the logout URL set above did nothing until the container was
    # restarted by hand. Only reached when the settings actually changed, since
    # the comparison above returns early otherwise.
    log "Restarting Audiobookshelf so it rebuilds its memoised OIDC client"
    docker restart "$ABS_CONTAINER" >/dev/null 2>&1 || {
        log "WARNING: could not restart Audiobookshelf; its OIDC client keeps the previous settings"
        return 0
    }
    wait_for_http_endpoint "$ABS_URL/healthcheck" "Audiobookshelf HTTP API" "$MAX_RETRIES" "$RETRY_INTERVAL" \
        || log "WARNING: Audiobookshelf did not come back in time; the library step may be skipped this run"
}

# --- Library ----------------------------------------------------------------

# Audible is the only metadata source here that actually carries audio editions
# (narrator, runtime, chapters), and it is regional - a French catalogue is
# invisible from audible.com. Derived from DEFAULT_LANGUAGE so moving the stack
# to another language needs no Audiobookshelf knowledge; anything with no Audible
# storefront falls back to the .com one.
audible_provider() {
    local tag="" lang="" region=""

    tag="$(get_env_value DEFAULT_LANGUAGE)"
    lang="$(printf '%s' "${tag%%-*}" | tr '[:upper:]' '[:lower:]')"
    region="$(printf '%s' "${tag#*-}" | tr '[:lower:]' '[:upper:]')"

    case "$lang" in
        fr) printf 'audible.fr' ;;
        de) printf 'audible.de' ;;
        it) printf 'audible.it' ;;
        es) printf 'audible.es' ;;
        ja) printf 'audible.jp' ;;
        en)
            case "$region" in
                GB|UK) printf 'audible.uk' ;;
                CA)    printf 'audible.ca' ;;
                AU)    printf 'audible.au' ;;
                IN)    printf 'audible.in' ;;
                *)     printf 'audible' ;;
            esac
            ;;
        *) printf 'audible' ;;
    esac
}

# Seeded, not reconciled: the folder list, the scanner settings and the metadata
# provider are all things the owner is expected to tune in the UI afterwards, and
# rewriting them on every boot would undo that.
ensure_library() {
    local libraries="" existing=""

    libraries="$(abs_get "/api/libraries" 2>/dev/null)" || {
        log "WARNING: could not list Audiobookshelf libraries; skipping"
        return 0
    }

    existing="$(printf '%s' "$libraries" | jq -r --arg p "$LIBRARY_PATH" \
        '.libraries[]? | select([.folders[]?.fullPath] | index($p)) | .name' 2>/dev/null || true)"
    if [ -n "$existing" ]; then
        log "Audiobookshelf library '$existing' already covers $LIBRARY_PATH"
        return 0
    fi

    jq -cn --arg name "$LIBRARY_NAME" --arg path "$LIBRARY_PATH" --arg provider "$(audible_provider)" \
        '{name: $name, folders: [{fullPath: $path}], mediaType: "book", provider: $provider, icon: "audiobookshelf"}' \
        | abs_send POST "/api/libraries" >/dev/null 2>&1 || {
        log "WARNING: creating the Audiobookshelf library failed"
        return 0
    }
    log "Created the Audiobookshelf library '$LIBRARY_NAME' on $LIBRARY_PATH ($(audible_provider))"
}

main() {
    log "=== Audiobookshelf Bootstrap ==="

    [ -f "$ENV_FILE" ] || die ".env missing at $ENV_FILE"

    container_is_running "$ABS_CONTAINER" || { log "Audiobookshelf is not running; skipping"; return 0; }
    wait_for_http_endpoint "$ABS_URL/healthcheck" "Audiobookshelf HTTP API" "$MAX_RETRIES" "$RETRY_INTERVAL" || return 0

    ensure_root_user || return 0

    # The stored key first: on every run after the first it is the only thing
    # that works, because configure_oidc has since turned local logins off.
    TOKEN="$(audiobookshelf_api_key "$ABS_URL" || true)"
    if [ -n "${TOKEN:-}" ]; then
        HAVE_API_KEY=1
    else
        TOKEN="$(audiobookshelf_password_token "$ABS_URL" || true)"
        [ -n "${TOKEN:-}" ] || {
            log "WARNING: could not authenticate to Audiobookshelf; skipping the rest"
            log "         (no usable $(audiobookshelf_api_key_file), and the password login was refused)"
            return 0
        }
        ensure_api_key || true
    fi

    ensure_root_email
    configure_oidc
    ensure_library

    log "Audiobookshelf bootstrap complete"
}

main "$@"
