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
# A step timeout in CI, or a Ctrl-C on a local run, arrives as a signal. Without
# these the EXIT trap never runs, and the throwaway network stays attached to
# Traefik at an address the allowlist does not admit until somebody notices.
# Each handler exits, which is what runs cleanup — it is idempotent either way.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

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

# api@internal is reachable only from the addresses the allowlist on its own
# router admits, so the request has to come from a container pinned to one of
# them. wget rather than curl: today that container is Homepage's, whose image
# ships busybox. A widened allowlist admits more than one, and not all of them
# ship an HTTP client, so each candidate is tried in turn.
grep '^APIPROBE ' "$RECORDS" >/dev/null \
    || die "no APIPROBE record; traefik-routers.py should have refused rather than emitted none"

API_READ=""
API_TRIED=""
while read -r kind service url; do
    [ "$kind" = APIPROBE ] || continue
    API_TRIED="$API_TRIED $service"
    if compose exec -T "$service" wget -q -O - "$url/api/http/routers" \
        </dev/null >"$WORK/routers.json" 2>>"$WORK/api-errors"; then
        API_READ="$service"
        break
    fi
done <"$RECORDS"

if [ -z "$API_READ" ]; then
    printf '%s: could not read Traefik'"'"'s runtime API from any of:%s\n' "$(basename "$0")" "$API_TRIED" >&2
    sed 's/^/  /' "$WORK/api-errors" >&2
    exit 1
fi

if python3 "$TESTS_DIR/traefik-api-check.py" "$RECORDS" <"$WORK/routers.json"; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
fi

# --- half two: the ip allowlist, from both sides -----------------------------

# A run killed between the connect and the disconnect leaves the network behind,
# and every run after it would then die here. Clear it rather than telling the
# reader to: nothing else uses this name.
if docker network inspect "$OUTSIDE_NET" >/dev/null 2>&1; then
    printf '  clearing a %s left behind by an earlier run\n' "$OUTSIDE_NET"
    for _cid in $(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$OUTSIDE_NET" 2>/dev/null); do
        docker network disconnect -f "$OUTSIDE_NET" "$_cid" >/dev/null 2>&1 || true
    done
    docker network rm "$OUTSIDE_NET" >/dev/null 2>&1 || true
fi

docker network create --subnet "$OUTSIDE_SUBNET" "$OUTSIDE_NET" >/dev/null \
    || die "could not create $OUTSIDE_NET on $OUTSIDE_SUBNET (ROUTING_SMOKE_SUBNET overrides)"
NET_CREATED=1

TRAEFIK_CID="$(compose ps -q traefik)"
PROBER_CID="$(compose ps -q "$PROBER")"
docker network connect --ip "$OUTSIDE_IP" "$OUTSIDE_NET" "$TRAEFIK_CID" >/dev/null
ATTACHED="$TRAEFIK_CID"
docker network connect "$OUTSIDE_NET" "$PROBER_CID" >/dev/null
ATTACHED="$ATTACHED $PROBER_CID"

# `docker compose exec` attaches stdin even under -T, and the loop below is
# reading the record file on stdin — so an exec without this eats the rest of
# it, and the whole file probes one router and reports a pass. </dev/null on
# every exec is half the fix; the count after the loop is the other half.
#
# probe <target> <host> <path> : the HTTP status, or 000 when nothing answered.
probe() {
    _code="$(compose exec -T "$PROBER" curl -sS -k -o /dev/null \
        --max-time "$TIMEOUT" --connect-to "$2:443:$1:443" \
        -w '%{http_code}' "https://$2$3" </dev/null 2>/dev/null | tr -d '\r\n')" || _code=""
    case "$_code" in
        [0-9][0-9][0-9]) printf '%s' "$_code" ;;
        *) printf '000' ;;
    esac
}

# Traefik's answer when no router matched is a 404 with this exact body. A
# backend's own 404 is a different thing entirely and not this test's business.
traefik_own_404() {
    compose exec -T "$PROBER" curl -sS -k --max-time "$TIMEOUT" \
        --connect-to "$2:443:$1:443" "https://$2$3" </dev/null 2>/dev/null \
        | head -c 64 | grep -q '404 page not found'
}

probed=0
while read -r kind router host path gate; do
    [ "$kind" = PROBE ] || continue
    probed=$((probed + 1))

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

# Every record has to have been reached. A loop that stops early still reports
# only passes, which is the one failure this file could not otherwise see.
declared_probes="$(grep -c '^PROBE ' "$RECORDS" || true)"
if [ "$probed" = "$declared_probes" ]; then
    ok "all $probed routers named in the records were probed"
else
    no "only $probed of $declared_probes routers were probed; the loop stopped early"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
