#!/bin/bash
# Bootstrap Pi-hole: adds recommended block lists and updates gravity.
# Uses the Pi-hole v6 REST API via docker exec curl.
# Firebog "ticked" lists (low false-positive rate) — https://firebog.net
# Safe to run multiple times — skips lists already present.

set -euo pipefail

. "$(dirname "$0")/lib.sh"

MAX_RETRIES=60
RETRY_INTERVAL=5
PIHOLE_CONTAINER="${PIHOLE_CONTAINER:-pi-pihole}"
PIHOLE_API="http://localhost:8082/api"

# Firebog "ticked" lists — https://firebog.net
# Groups: Base | Suspicious | Advertising | Tracking & Telemetry | Malicious
BLOCK_LISTS="
https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts
https://raw.githubusercontent.com/PolishFiltersTeam/KADhosts/master/KADhosts.txt
https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.Spam/hosts
https://v.firebog.net/hosts/static/w3kbl.txt
https://adaway.org/hosts.txt
https://v.firebog.net/hosts/AdguardDNS.txt
https://v.firebog.net/hosts/Admiral.txt
https://raw.githubusercontent.com/anudeepND/blacklist/master/adservers.txt
https://v.firebog.net/hosts/Easylist.txt
https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext
https://raw.githubusercontent.com/FadeMind/hosts.extras/master/UncheckyAds/hosts
https://raw.githubusercontent.com/bigdargon/hostsVN/master/hosts
https://v.firebog.net/hosts/Easyprivacy.txt
https://v.firebog.net/hosts/Prigent-Ads.txt
https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.2o7Net/hosts
https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt
https://hostfiles.frogeye.fr/firstparty-trackers-hosts.txt
https://raw.githubusercontent.com/DandelionSprout/adfilt/master/Alternate%20versions%20Anti-Malware%20List/AntiMalwareHosts.txt
https://v.firebog.net/hosts/Prigent-Crypto.txt
https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.Risk/hosts
https://phishing.army/download/phishing_army_blocklist_extended.txt
https://raw.githubusercontent.com/Spam404/lists/master/main-blacklist.txt
https://urlhaus.abuse.ch/downloads/hostfile/
"

# Run curl inside the Pi-hole container (has curl; avoids extra network hop).
pihole_curl() {
    docker exec "$PIHOLE_CONTAINER" curl -sS "$@"
}

# Authenticate and return the session ID (sid).
# Password is written to a temp file to avoid it appearing in process args or logs.
get_session() {
    local password="$1"
    local body_file response
    body_file=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f $body_file" EXIT
    printf '{"password":"%s"}' "$password" > "$body_file"
    response=$(docker exec -i "$PIHOLE_CONTAINER" curl -sS \
        -X POST \
        -H "Content-Type: application/json" \
        -d @- \
        "$PIHOLE_API/auth" < "$body_file")
    rm -f "$body_file"
    # Extract sid from {"session":{"sid":"VALUE",...}}
    printf '%s' "$response" | grep -o '"sid":"[^"]*"' | head -1 | cut -d'"' -f4
}

# Add a block list via the API.
# Returns 0 if newly added, 1 if already present or on error.
add_list() {
    local sid="$1"
    local url="$2"
    local response http_code
    # type=block must be a query param, not in the JSON body
    response=$(pihole_curl \
        -w "\n%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -H "sid: $sid" \
        -d "{\"address\":\"$url\",\"comment\":\"firebog\",\"enabled\":true}" \
        "$PIHOLE_API/lists?type=block" 2>&1)
    http_code=$(printf '%s' "$response" | tail -1)

    case "$http_code" in
        2*) log "Added: $url"; return 0 ;;
        *)  log "Already present or error (HTTP $http_code): $url"; return 1 ;;
    esac
}

update_gravity() {
    local sid="$1"
    log "Updating gravity (downloading block lists, this may take a while)..."
    # Pi-hole v6: trigger gravity update via API
    local http_code
    http_code=$(pihole_curl \
        -o /dev/null \
        -w "%{http_code}" \
        -X POST \
        -H "sid: $sid" \
        "$PIHOLE_API/action/gravity")
    if [ "${http_code#2}" != "$http_code" ]; then
        log "Gravity update triggered via API (runs in background)"
        return 0
    fi
    # Fallback: reload lists via CLI (v6 known-working command)
    if docker exec "$PIHOLE_CONTAINER" pihole reloadlists >/dev/null 2>&1; then
        log "Lists reloaded via CLI"
        return 0
    fi
    log "WARNING: gravity update failed — run manually: docker exec $PIHOLE_CONTAINER pihole reloadlists"
}

main() {
    log "=== Pi-hole Bootstrap ==="

    wait_for_container "$PIHOLE_CONTAINER" "$MAX_RETRIES" "$RETRY_INTERVAL"
    wait_for_health "$PIHOLE_CONTAINER" "$MAX_RETRIES" "$RETRY_INTERVAL"

    local password
    password="$(get_env_value PASSWORD)"
    password="${password:-admin}"

    local sid
    sid=$(get_session "$password")
    if [ -z "$sid" ]; then
        die "Could not authenticate with Pi-hole API (check PASSWORD in .env)"
    fi
    log "Authenticated with Pi-hole API"

    local newly_added=0
    for url in $BLOCK_LISTS; do
        [ -z "$url" ] && continue
        if add_list "$sid" "$url"; then
            newly_added=$((newly_added + 1))
        fi
    done

    if [ "$newly_added" -gt 0 ]; then
        log "$newly_added new list(s) added"
        update_gravity "$sid"
    else
        log "All block lists already present, skipping gravity update"
    fi

    log "Pi-hole block lists configured"
}

main "$@"
