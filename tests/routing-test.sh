#!/bin/sh
# Tests for the two checkers behind tests/routing-smoke.sh: the projection that
# reads the routing table out of the compose files, and the comparison against
# the one Traefik loaded.
#
# routing-smoke.sh itself needs a running stack, so `make test` cannot run it —
# which would leave the checkers it depends on covered by nothing. A checker
# that looks at the wrong key, or a rule that stops matching after a compose
# schema change, reports the same silence as a clean stack. So everything here
# is fed a routing table that is broken on purpose, one class at a time, and
# nothing touches docker.
# Run with `make test`.
set -eu

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

pass=0
fail=0

ok() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  got  [%s]\n  want [%s]\n' "$1" "$2" "$3"
    fi
}

# project <outside-ip> <render-json> : the records, or nothing on refusal.
project() {
    printf '%s' "$2" | python3 "$TESTS_DIR/traefik-routers.py" "$1" 2>/dev/null || true
}

# refuses <label> <needle> <outside-ip> <render-json>
refuses() {
    _got="$(printf '%s' "$4" | python3 "$TESTS_DIR/traefik-routers.py" "$3" 2>&1 >/dev/null || true)"
    case "$_got" in
        *"$2"*) pass=$((pass + 1)) ;;
        *)
            fail=$((fail + 1))
            printf 'FAIL %s\n  got  [%s]\n  want [*%s*]\n' "$1" "$_got" "$2"
            ;;
    esac
}

# The parts of a render that are not about any one router: the two ip
# allowlists, the port the runtime API answers on, and the pair of pinned
# addresses that say who may ask it.
FIXED='"traefik": {"image": "x:1",
    "networks": {"frontend": {"ipv4_address": "172.30.11.250"}},
    "labels": {
      "traefik.http.middlewares.lan.ipallowlist.sourcerange": "192.168.1.0/24,172.30.0.0/16",
      "traefik.http.middlewares.internalapi-allow.ipallowlist.sourcerange": "172.30.11.240/32",
      "traefik.http.routers.internalapi.rule": "PathPrefix(`/api`)",
      "traefik.http.routers.internalapi.entrypoints": "traefik",
      "traefik.http.routers.internalapi.middlewares": "internalapi-allow@docker",
      "traefik.http.services.traefik.loadbalancer.server.port": "8080"}},
  "reader": {"image": "x:1", "networks": {"frontend": {"ipv4_address": "172.30.11.240"}}}'

# render [extra-services-json] : a table broad enough to clear the floors in
# traefik-routers.py, so a case below fails on what it changed rather than on
# the size of what it handed over.
render() {
    printf '{"services": {%s' "$FIXED"
    _i=1
    while [ "$_i" -le 20 ]; do
        printf ',"svc%s": {"image": "x:1", "labels": {' "$_i"
        printf '"traefik.http.routers.r%s.rule": "Host(`h%s.test`)",' "$_i" "$_i"
        printf '"traefik.http.routers.r%s.entrypoints": "websecure",' "$_i"
        printf '"traefik.http.routers.r%s.middlewares": "frame-deny@docker,lan@docker"}}' "$_i"
        _i=$((_i + 1))
    done
    [ "$#" -eq 0 ] || printf ',%s' "$1"
    printf '}}'
}

# --- the projection reads what Traefik reads ---------------------------------

records="$(project 10.199.0.250 "$(render)")"

ok "every declared router is reported" \
    "$(printf '%s\n' "$records" | grep -c '^ROUTER ')" 21

# A router on an entrypoint the LAN cannot reach has nothing a probe could be,
# and needs no middleware for the same reason.
ok "a router on an internal entrypoint is not probed" \
    "$(printf '%s\n' "$records" | grep -c '^PROBE internalapi ')" 0
ok "but it is still declared, so the API check covers it" \
    "$(printf '%s\n' "$records" | grep -c '^ROUTER internalapi$')" 1

ok "a router behind an ip allowlist is marked lan" \
    "$(printf '%s\n' "$records" | grep -c '^PROBE r1 h1.test / lan$')" 1

ok "who reads the runtime API, and where, is derived from the allowlist" \
    "$(printf '%s\n' "$records" | grep '^APIPROBE ')" \
    "APIPROBE reader http://172.30.11.250:8080"

# --- middlewares that are not an allowlist are not a gate --------------------

records="$(project 10.199.0.250 "$(render '"open": {"image": "x:1", "labels": {
  "traefik.http.routers.pub.rule": "Host(`pub.test`)",
  "traefik.http.routers.pub.entrypoints": "websecure",
  "traefik.http.routers.pub.middlewares": "frame-deny@docker,security-headers@docker"}}')")"
ok "a router with no ip allowlist is marked open" \
    "$(printf '%s\n' "$records" | grep -c '^PROBE pub pub.test / open$')" 1

# --- the path a probe asks for -----------------------------------------------

records="$(project 10.199.0.250 "$(render '"sub": {"image": "x:1", "labels": {
  "traefik.http.routers.sub.rule": "Host(`sub.test`) && PathPrefix(`/s/`) && !PathRegexp(`/configure$`)",
  "traefik.http.routers.sub.entrypoints": "websecure",
  "traefik.http.routers.sub.middlewares": "lan@docker"}}')")"
ok "a PathPrefix becomes the path probed" \
    "$(printf '%s\n' "$records" | grep -c '^PROBE sub sub.test /s/ lan$')" 1

# A negated matcher names a path the router deliberately does *not* serve, and
# aiming a probe at it would test whichever router is next in priority.
records="$(project 10.199.0.250 "$(render '"neg": {"image": "x:1", "labels": {
  "traefik.http.routers.neg.rule": "Host(`neg.test`) && !PathPrefix(`/nope`)",
  "traefik.http.routers.neg.entrypoints": "websecure",
  "traefik.http.routers.neg.middlewares": "lan@docker"}}')")"
ok "a negated matcher is not taken for the path" \
    "$(printf '%s\n' "$records" | grep -c '^PROBE neg neg.test / lan$')" 1

# --- a host two routers share is decided by priority, not by this file -------

records="$(project 10.199.0.250 "$(render '"second": {"image": "x:1", "labels": {
  "traefik.http.routers.alt.rule": "Host(`h1.test`) && PathPrefix(`/alt`)",
  "traefik.http.routers.alt.entrypoints": "websecure",
  "traefik.http.routers.alt.middlewares": "lan@docker"}}')")"
ok "neither router on a shared host is probed" \
    "$(printf '%s\n' "$records" | grep -cE '^PROBE (r1|alt) ')" 0
ok "and both are still declared" \
    "$(printf '%s\n' "$records" | grep -cE '^ROUTER (r1|alt)$')" 2

# --- what it must refuse -----------------------------------------------------
#
# Each of these would otherwise leave the outside half of routing-smoke.sh
# passing for a reason that has nothing to do with the allowlist working.

refuses "an outside address that is inside the allowlist" \
    "is inside the ip allowlist" 192.168.1.50 "$(render)"

refuses "an outside address inside the container range" \
    "is inside the ip allowlist" 172.30.99.9 "$(render)"

refuses "an allowlist range that is not CIDR" \
    "not valid CIDR" 10.199.0.250 \
    '{"services": {"traefik": {"image": "x:1", "labels": {
      "traefik.http.middlewares.lan.ipallowlist.sourcerange": "not-an-address",
      "traefik.http.routers.only.rule": "Host(`only.test`)",
      "traefik.http.routers.only.entrypoints": "websecure",
      "traefik.http.routers.only.middlewares": "lan@docker"}}}}'

refuses "a render that came back nearly empty" \
    "expected at least" 10.199.0.250 \
    '{"services": {"lonely": {"image": "x:1", "labels": {
      "traefik.http.routers.lonely.rule": "Host(`lonely.test`)",
      "traefik.http.routers.lonely.entrypoints": "websecure",
      "traefik.http.routers.lonely.middlewares": "lan@docker"}}}}'

refuses "a stack where no router carries an allowlist at all" \
    "nothing checks the LAN gate" 10.199.0.250 \
    "$(printf '{"services": {%s' "$FIXED" \
        | sed 's/,"traefik.http.middlewares.lan.ipallowlist.sourcerange": "192.168.1.0\/24,172.30.0.0\/16"//' \
        | sed 's/"traefik.http.middlewares.lan.ipallowlist.sourcerange": "192.168.1.0\/24,172.30.0.0\/16",//')}}"

# Without the container pinned to the address its own allowlist admits, nothing
# can read the runtime API, and half the file would quietly not run.
refuses "a runtime API nobody is pinned to reach" \
    "could not work out who reads" 10.199.0.250 \
    "$(render | sed 's/"reader": {"image": "x:1", "networks": {"frontend": {"ipv4_address": "172.30.11.240"}}}/"reader": {"image": "x:1"}/')"

refuses "an outside address that is not an address" \
    "is not an ip address" not-an-address "$(render)"

# --- and it must never echo a range it was handed ----------------------------
#
# ALLOW_IP_RANGES is a home LAN's subnet and its WAN address, and the render it
# arrives in carries every env_file besides. Hand it a canary in each place and
# fail if the canary comes back out.
canary="c4n4ry-must-not-appear-4d1e"
leaked="$(printf '%s' '{"services": {"traefik": {"image": "x:1",
  "environment": {"PASSWORD": "CANARY"},
  "env_file": ["CANARY"],
  "labels": {
    "homepage.widget.key": "CANARY",
    "traefik.http.middlewares.lan.ipallowlist.sourcerange": "CANARY",
    "traefik.http.routers.only.rule": "Host(`only.test`)",
    "traefik.http.routers.only.entrypoints": "websecure",
    "traefik.http.routers.only.middlewares": "lan@docker"}}}}' \
    | sed "s/CANARY/$canary/g" \
    | python3 "$TESTS_DIR/traefik-routers.py" 10.199.0.250 2>&1 | grep -c "$canary" || true)"
ok "no allowlist range reaches the output" "$leaked" 0

# --- the comparison against Traefik's own table ------------------------------

declared="$(printf 'ROUTER kavita\nROUTER ntfy\n')"
records_file="$(mktemp)"
trap 'rm -f "$records_file"' EXIT
printf '%s\n' "$declared" >"$records_file"

# api_says <api-json> : the checker's report, and its status in $rc.
api_says() {
    api_out="$(printf '%s' "$1" | python3 "$TESTS_DIR/traefik-api-check.py" "$records_file" 2>&1)" && rc=0 || rc=$?
}

api_says '[{"name": "kavita@docker", "status": "enabled"},
           {"name": "ntfy@docker", "status": "enabled"},
           {"name": "acme-http@internal", "status": "enabled"}]'
ok       "a table where everything loaded passes"  "$rc" 0
case "$api_out" in
    *"3 routers"*) ok "and says how many it saw" yes yes ;;
    *) ok "and says how many it saw" "$api_out" "should mention 3 routers" ;;
esac

# The failure this exists for: a middleware whose name does not exist takes its
# router out of the table, Traefik keeps serving, and every request for that
# host gets a 404 from then on.
api_says '[{"name": "kavita@docker", "status": "disabled",
            "error": ["middleware \"lan@docker\" does not exist"]},
           {"name": "ntfy@docker", "status": "enabled"}]'
ok       "a router that did not load fails"        "$rc" 1
case "$api_out" in
    *'lan@docker" does not exist'*) ok "and the reason Traefik gave is repeated" yes yes ;;
    *) ok "and the reason Traefik gave is repeated" "$api_out" "should carry Traefik's error" ;;
esac

api_says '[{"name": "kavita@docker", "status": "enabled"}]'
ok       "a declared router Traefik never loaded fails" "$rc" 1
case "$api_out" in
    *"ntfy is declared"*) ok "and it is named" yes yes ;;
    *) ok "and it is named" "$api_out" "should name ntfy" ;;
esac

api_says '[{"name": "kavita@docker"}, {"name": "ntfy@docker", "status": "enabled"}]'
ok "a router in no state at all fails" "$rc" 1

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
