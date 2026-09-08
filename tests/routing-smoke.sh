#!/bin/sh
# The reverse proxy, probed the way a client reaches it, against a live stack.
#
# `docker compose up --wait` proves every container answers its own healthcheck
# on its own port. None of that goes through Traefik, and Traefik is where this
# stack's access control lives: forty-odd routers, an ip allowlist and a forward
# auth, all declared as container labels and all resolved by name at runtime. A
# middleware whose name does not exist takes its router out of the routing table
# and every request for that host gets a 404 instead — which is also what a
# stopped backend gives, so the first half below asks Traefik itself rather than
# guessing from a status code.
#
# Two halves:
#   * every router Traefik loaded is enabled and carries no error, and every
#     router compose.yaml declares is one Traefik loaded
#   * each router answers a request from a LAN address, and refuses the same
#     request from outside the ip allowlist — so the gate is known to be doing
#     something rather than merely configured
#
# Needs a running stack, so `make test` does not run it: CI runs it after
# `up --wait`, and `make smoke` runs it against whatever is up. For the outside
# half it creates a throwaway network outside the allowlist, attaches Traefik
# and the probe container to it for the duration, and removes it again. Nothing
# is restarted and no configuration is written.
set -eu

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"

# Where the LAN-side probes come from: a container sharing a network with
# Traefik, so its source address is one the allowlist admits, and one of the few
# images in the stack shipping curl — whose --connect-to keeps the Host header
# and the TLS SNI intact while aiming the connection at an address of our
# choosing. pihole is core, so it is there whatever COMPOSE_PROFILES says.
PROBER="${ROUTING_SMOKE_PROBER:-pihole}"
TIMEOUT="${ROUTING_SMOKE_TIMEOUT:-15}"

# Stands in for the internet. Not in any range compose.yaml's ALLOW_IP_RANGES
# default lists — and not taken on trust: traefik-routers.py refuses to emit its
# records if this address turns out to be inside the rendered allowlist, because
# then every "must be refused" below would pass for the wrong reason.
OUTSIDE_NET="${ROUTING_SMOKE_NET:-pi-pcloud-routing-smoke}"
OUTSIDE_SUBNET="${ROUTING_SMOKE_SUBNET:-10.199.0.0/24}"
OUTSIDE_IP="${ROUTING_SMOKE_IP:-10.199.0.250}"

WORK="$(mktemp -d)"
ATTACHED=""
NET_CREATED=""

cleanup() {
    for _cid in $ATTACHED; do
        docker network disconnect "$OUTSIDE_NET" "$_cid" >/dev/null 2>&1 || true
    done
    [ -z "$NET_CREATED" ] || docker network rm "$OUTSIDE_NET" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

pass=0
fail=0

ok() {
    pass=$((pass + 1))
    printf '  \033[32m✔\033[0m %s\n' "$1"
}

no() {
    fail=$((fail + 1))
    printf '  \033[31m✘\033[0m %s\n' "$1"
}

die() {
    printf '%s: %s\n' "$(basename "$0")" "$1" >&2
    exit 1
}

compose() {
    (cd "$REPO_DIR" && docker compose "$@")
}

# A container that exists but is not running would make every probe read 000
# and the whole file report a routing fault instead of a stopped stack.
running() {
    _cid="$(compose ps -q "$1" 2>/dev/null)" || return 1
    [ -n "$_cid" ] || return 1
    [ "$(docker inspect -f '{{.State.Running}}' "$_cid" 2>/dev/null)" = true ]
}

command -v docker >/dev/null 2>&1 || die "docker is required"
running traefik || die "traefik is not running; start the stack first"
running "$PROBER" \
    || die "$PROBER is not running, and the probes come from it (ROUTING_SMOKE_PROBER overrides)"

# --- what the stack declares -------------------------------------------------
#
# Piped straight into the projection, never through a shell variable: the render
# inlines the contents of every env_file. Only compose's stderr is captured, so
# a failure can say why without the config being anywhere near it.
RECORDS="$WORK/records"
RENDER_ERRORS="$WORK/render-errors"
if ! (cd "$REPO_DIR" && docker compose config --format json) 2>"$RENDER_ERRORS" \
    | python3 "$TESTS_DIR/traefik-routers.py" "$OUTSIDE_IP" >"$RECORDS"; then
    printf '%s: could not read the routing table out of the compose files\n' "$(basename "$0")" >&2
    sed 's/^/  /' "$RENDER_ERRORS" >&2
    exit 1
fi

# --- half one: the routing table Traefik actually loaded ---------------------

API_SERVICE="$(awk '$1 == "APIPROBE" { print $2 }' "$RECORDS")"
API_URL="$(awk '$1 == "APIPROBE" { print $3 }' "$RECORDS")"
if [ -z "$API_SERVICE" ] || [ -z "$API_URL" ]; then
    die "no APIPROBE record; traefik-routers.py should have refused rather than emitted none"
fi

# api@internal is reachable from exactly one address (the allowlist on its own
# router says which), so the request has to come from that container. wget, not
# curl: that container is Homepage's, and its image ships busybox.
if ! compose exec -T "$API_SERVICE" wget -q -O - "$API_URL/api/http/routers" >"$WORK/routers.json" 2>"$WORK/api-errors"; then
    printf '%s: could not read %s from %s\n' "$(basename "$0")" "$API_URL/api/http/routers" "$API_SERVICE" >&2
    sed 's/^/  /' "$WORK/api-errors" >&2
    exit 1
fi

if python3 "$TESTS_DIR/traefik-api-check.py" "$RECORDS" <"$WORK/routers.json"; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
fi

# --- half two: the ip allowlist, from both sides -----------------------------

docker network create --subnet "$OUTSIDE_SUBNET" "$OUTSIDE_NET" >/dev/null \
    || die "could not create $OUTSIDE_NET on $OUTSIDE_SUBNET (ROUTING_SMOKE_SUBNET overrides)"
NET_CREATED=1

TRAEFIK_CID="$(compose ps -q traefik)"
PROBER_CID="$(compose ps -q "$PROBER")"
docker network connect --ip "$OUTSIDE_IP" "$OUTSIDE_NET" "$TRAEFIK_CID" >/dev/null
ATTACHED="$TRAEFIK_CID"
docker network connect "$OUTSIDE_NET" "$PROBER_CID" >/dev/null
ATTACHED="$ATTACHED $PROBER_CID"

# probe <target> <host> <path> : the HTTP status, or 000 when nothing answered.
probe() {
    _code="$(compose exec -T "$PROBER" curl -sS -k -o /dev/null \
        --max-time "$TIMEOUT" --connect-to "$2:443:$1:443" \
        -w '%{http_code}' "https://$2$3" 2>/dev/null | tr -d '\r\n')" || _code=""
    case "$_code" in
        [0-9][0-9][0-9]) printf '%s' "$_code" ;;
        *) printf '000' ;;
    esac
}

# Traefik's answer when no router matched is a 404 with this exact body. A
# backend's own 404 is a different thing entirely and not this test's business.
traefik_own_404() {
    compose exec -T "$PROBER" curl -sS -k --max-time "$TIMEOUT" \
        --connect-to "$2:443:$1:443" "https://$2$3" 2>/dev/null \
        | head -c 64 | grep -q '404 page not found'
}

while read -r kind router host path gate; do
    [ "$kind" = PROBE ] || continue

    inside="$(probe traefik "$host" "$path")"
    outside="$(probe "$OUTSIDE_IP" "$host" "$path")"

    if [ "$inside" = 000 ]; then
        no "$router: nothing answered on $host from the LAN"
    elif [ "$inside" = 404 ] && traefik_own_404 traefik "$host" "$path"; then
        no "$router: no router matched $host from the LAN (rule or middleware name gone)"
    elif [ "$inside" = 403 ]; then
        no "$router: $host refused a LAN address (the allowlist does not admit the probe)"
    else
        case "$inside" in
            5*) no "$router: $host answered $inside from the LAN" ;;
            *) ok "$router: $host answers $inside from the LAN" ;;
        esac
    fi

    if [ "$gate" = lan ]; then
        if [ "$outside" = 403 ]; then
            ok "$router: $host refuses an address outside the allowlist"
        else
            no "$router: $host answered $outside from outside the allowlist, expected 403"
        fi
    elif [ "$outside" = 403 ]; then
        no "$router: $host is meant to be public but refused an outside address"
    else
        ok "$router: $host answers $outside from outside, as a public route should"
    fi
done <"$RECORDS"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
