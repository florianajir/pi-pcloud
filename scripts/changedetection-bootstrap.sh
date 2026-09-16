#!/bin/sh
# Post-start: point changedetection.io's default notifications at ntfy.
#
# Post-start and not a pre-start render, because the notification URL list is a
# datastore setting with no environment equivalent and the only API that writes
# it wants the token the datastore mints on its first start.
#
# The *system default* only, the one a new watch inherits; a per-watch URL still
# wins. POST appends and de-duplicates, so a hand-edited list keeps its entries.
#
# A post-start hook (scripts/run-hooks.sh). Idempotent.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

CHANGEDETECTION_URL="${CHANGEDETECTION_URL:-http://changedetection:5000}"
NTFY_ENV_FILE="${NTFY_ENV_FILE:-$PROJECT_DIR/config/ntfy/ntfy.env}"

# Apprise's ntfy plugin reads the token out of the userinfo field; mode and auth
# are spelled out rather than left to its heuristics, as in
# scripts/shelfmark-pre-start.sh. Both containers are on `frontend`, so the host
# is `ntfy` and nothing hairpins out through Traefik and back.
ntfy_notification_url() {
    local token="" topic=""

    token="$(read_env_value_from_file "$NTFY_ENV_FILE" NTFY_CHANGEDETECTION_TOKEN)"
    [ -n "$token" ] || return 1
    # scripts/ntfy-pre-start.sh owns the topic names and the matching ACL.
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

    # The one failure reported rather than swallowed: everything above can
    # legitimately not be there yet, but a POST refused by a service that just
    # answered the GET is a bug. Tolerated on boot, fatal in CI.
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

    # Flask answers well before the first healthcheck probe says so.
    wait_for_http_endpoint "$CHANGEDETECTION_URL/" "changedetection.io" 30 2 || {
        log "WARNING: changedetection.io did not answer in time; retrying next start"
        return 0
    }

    seed_notification_url

    log "changedetection.io bootstrap completed"
}

main "$@"
