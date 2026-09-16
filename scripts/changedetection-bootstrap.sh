#!/bin/sh
# Post-start: point changedetection.io's default notifications at ntfy, so a
# page that changes reaches a phone instead of only the web UI.
#
# The notification URL list is a datastore setting with no environment
# equivalent, and the one API that writes it wants the datastore's own API
# token - minted on the first start, which is why this cannot be a pre-start
# render like scripts/shelfmark-pre-start.sh's ADMIN_NOTIFICATION_ROUTES.
#
# It seeds the *system default* only, the one a new watch inherits with
# "Notifications > use system defaults"; a per-watch URL still wins. Additive
# and never destructive: POST /api/v1/notifications appends and de-duplicates,
# so a list an operator has edited by hand keeps every entry it had.
#
# A post-start hook (scripts/run-hooks.sh). Idempotent.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

CHANGEDETECTION_URL="${CHANGEDETECTION_URL:-http://changedetection:5000}"
NTFY_ENV_FILE="${NTFY_ENV_FILE:-$PROJECT_DIR/config/ntfy/ntfy.env}"

# Apprise's ntfy plugin reads the token out of the userinfo field; mode and auth
# are spelled out rather than left to its hostname/`tk_` heuristics, as in
# scripts/shelfmark-pre-start.sh. The host is the container, not
# ntfy.$HOST_NAME: both sit on `frontend`, so nothing hairpins out through
# Traefik and back.
ntfy_notification_url() {
    local token="" topic=""

    token="$(read_env_value_from_file "$NTFY_ENV_FILE" NTFY_CHANGEDETECTION_TOKEN)"
    [ -n "$token" ] || return 1
    # Read rather than hardcoded: scripts/ntfy-pre-start.sh owns the topic names
    # and the ACL that grants this user write access to exactly one of them.
    topic="$(read_env_value_from_file "$NTFY_ENV_FILE" NTFY_WATCHES_TOPIC)"
    [ -n "$topic" ] || return 1

    printf 'ntfy://%s@ntfy/%s?mode=private&auth=token' "$token" "$topic"
}

seed_notification_url() {
    local key="" url="" existing=""

    url="$(ntfy_notification_url)" || {
        log "WARNING: no changedetection ntfy token/topic in $NTFY_ENV_FILE; leaving notifications unset"
        return 0
    }

    key="$(changedetection_api_key)"
    if [ -z "$key" ]; then
        log "WARNING: could not read changedetection.io's API token; retrying next start"
        return 0
    fi

    existing="$(docker_curl -H "x-api-key: $key" "$CHANGEDETECTION_URL/api/v1/notifications" 2>/dev/null)" || {
        log "WARNING: changedetection.io did not answer /api/v1/notifications; retrying next start"
        return 0
    }

    if printf '%s' "$existing" | jq -e --arg u "$url" 'any(.notification_urls[]?; . == $u)' >/dev/null 2>&1; then
        log "ntfy is already changedetection.io's default notification target"
        return 0
    fi

    # The one failure that is reported rather than swallowed: everything above is
    # a prerequisite that can legitimately not be there yet, but a POST refused
    # by a service that just answered the GET is a bug. The hook phase decides
    # what happens next - tolerant on boot (logged, retried next start), blocking
    # in CI, where an unfinishable bootstrap is the thing under test.
    jq -cn --arg u "$url" '{notification_urls: [$u]}' \
        | docker_curl_stdin -X POST -H "x-api-key: $key" -H 'Content-Type: application/json' \
            "$CHANGEDETECTION_URL/api/v1/notifications" >/dev/null 2>&1 || {
        log "ERROR: /api/v1/notifications refused the ntfy notification URL"
        return 1
    }

    log "Added ntfy as changedetection.io's default notification target"
}

main() {
    log "=== changedetection.io Bootstrap ==="

    wait_for_container "pi-changedetection" 60 2 || {
        log "WARNING: pi-changedetection did not appear in time; skipping"
        return 0
    }

    # Flask answers well before the first healthcheck probe says so, and the API
    # token only exists once the datastore has been written - which on a fresh
    # install is part of that same first start.
    wait_for_http_endpoint "$CHANGEDETECTION_URL/" "changedetection.io" 30 2 || {
        log "WARNING: changedetection.io did not answer in time; retrying next start"
        return 0
    }

    seed_notification_url

    log "changedetection.io bootstrap completed"
}

main "$@"
