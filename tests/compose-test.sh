#!/bin/sh
# Invariants compose.yaml must hold, checked against the config docker compose
# actually renders - anchors, merge keys, !reset and profiles all resolved, so
# these test what runs rather than what the file looks like.
#
# `docker compose config` never contacts the daemon, so this touches nothing.
# Run with `make test`.
set -eu

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"

pass=0
fail=0

# stremio-lan is deliberately outside "all" - it is the alternative to stremio,
# never both - so it has to be named, or its block would go unchecked until
# someone enabled the profile.
PROFILES="all,stremio-lan"

if ! command -v docker >/dev/null 2>&1; then
    printf 'compose-test.sh: docker is required to render compose.yaml\n' >&2
    exit 1
fi

# Piped straight into the checker, never through a shell variable: the render
# inlines the contents of every env_file, so it is a secret until the checker
# has reduced it to the fields the invariants need. Only compose's stderr is
# captured, so a failure can say why without the config being anywhere near it.
render_errors="$(mktemp)"
trap 'rm -f "$render_errors"' EXIT

# --env-file /dev/null so .env is never read: the render is then the same on
# any machine, and one less place a password can come from. That leaves
# ${DATA_LOCATION:-./data} to resolve, and a relative bind source makes
# compose 2.38 (what ubuntu-latest ships) fail, so it gets an absolute value.
# It is never created - `config` resolves paths, it does not touch them.
#
# --no-interpolate would have kept even more out, but the same compose reads
# the `:-` of a literal ${DATA_LOCATION:-./data} as a volume separator and
# rejects the file: "invalid spec ... too many colons".
out="$(DATA_LOCATION=/nonexistent/compose-test COMPOSE_PROFILES="$PROFILES" \
    docker compose --env-file /dev/null -f "$REPO_DIR/compose.yaml" \
    config --format json 2>"$render_errors" \
    | python3 "$TESTS_DIR/compose-invariants.py" "$REPO_DIR")" || {
    printf 'compose-test.sh: could not render compose.yaml\n' >&2
    docker compose version >&2 || true
    sed 's/^/  /' "$render_errors" >&2
    exit 1
}

# Each category is a class of drift, so a failure names every instance rather
# than only the first.
ok() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  got  [%s]\n  want [%s]\n' "$1" "$2" "$3"
    fi
}

none() {
    _label="$1"
    _prefix="$2"
    _hits="$(printf '%s\n' "$out" | grep "^$_prefix " || true)"
    if [ -z "$_hits" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n' "$_label"
        printf '%s\n' "$_hits" | sed "s/^$_prefix /  /"
    fi
}

# The failure this file exists to catch: authelia once waited on lldap, which
# declared no healthcheck, so it never started and took the services behind it
# with it. Compose reports nothing - the dependency simply never resolves.
none "every service_healthy target declares a healthcheck" HEALTH

# A moving tag makes a rebuild non-reproducible and a rollback impossible.
none "every image is pinned by tag or digest" IMAGE

# A router reachable from the LAN with no middlewares has neither the ip
# allowlist nor forward auth on it.
none "every publicly routed router carries middlewares" ROUTER

# Adding a Postgres-backed service means adding its role, or it silently uses
# none and the password rotation misses it.
none "every Postgres-backed service owns a role" POSTGRES

# The failure that lasted longest: five `deploy: resources: reservations: cpus:`
# tiers across 40 services, all of which compose drops outside swarm. It read as
# policy for months while every container sat at the default cpu.weight.
none "every resource key is one the kernel actually reads" RESOURCE

# The IPv6 allowlist bypass this stack shipped once: a bare "443:443" also binds
# [::], and without an IPv6 address behind it docker-proxy rewrites every client
# source into ALLOW_IP_RANGES.
none "every published port names a host address" PORT

# An IPv6 subnet on a shared network reaches gluetun, and the three containers
# sharing its namespace would then leave the VPN tunnel.
none "only the two single-member networks enable IPv6" NETWORK

# A rendering that half-breaks still returns something, and every check above
# would pass having inspected four services.
none "the rendered stack is the expected size" FLOOR

# --- the checker must actually catch each of them ---------------------------
#
# Five green assertions above prove nothing on their own: a checker that looks
# at the wrong key, or a rule that stops matching after a compose schema
# change, reports the same silence as a clean stack. So feed it a rendering
# that is broken on purpose, one category at a time.

catches() {
    _label="$1"
    _prefix="$2"
    _json="$3"
    _got="$(printf '%s' "$_json" | python3 "$TESTS_DIR/compose-invariants.py" "$REPO_DIR" \
        | grep -c "^$_prefix " || true)"
    if [ "$_got" -gt 0 ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s (the checker reported nothing)\n' "$_label"
    fi
}

catches "a service_healthy wait on a service with no healthcheck" HEALTH '{"services":{
  "waiter": {"image": "x:1", "depends_on": {"target": {"condition": "service_healthy"}}},
  "target": {"image": "x:1"}
}}'

catches "a service_healthy wait on a service this profile drops" HEALTH '{"services":{
  "waiter": {"image": "x:1", "depends_on": {"absent": {"condition": "service_healthy"}}}
}}'

catches "a moving tag" IMAGE '{"services": {"drifting": {"image": "somewhere/thing:latest"}}}'

catches "an image with no tag at all" IMAGE '{"services": {"untagged": {"image": "somewhere/thing"}}}'

catches "a public router with no middlewares" ROUTER '{"services": {"exposed": {"image": "x:1", "labels": {
  "traefik.http.routers.exposed.rule": "Host(`x`)",
  "traefik.http.routers.exposed.entrypoints": "websecure"
}}}}'

catches "a Postgres-backed service with no role" POSTGRES '{"services":{
  "newthing": {"image": "x:1", "depends_on": {"postgres": {"condition": "service_started"}}}
}}'

catches "a bare port that also binds [::]" PORT '{"services": {"exposed": {"image": "x:1",
  "ports": [{"mode": "ingress", "target": 443, "published": "443", "protocol": "tcp"}]}}}'

catches "IPv6 on a network gluetun sits on" NETWORK '{"services": {"x": {"image": "x:1"}},
  "networks": {"frontend": {"enable_ipv6": true, "ipam": {"config": [{"subnet": "fd00:30:11::/64"}]}}}}'

catches "a rendering that came back nearly empty" FLOOR '{"services": {"lonely": {"image": "x:1"}}}'

catches "a deploy: block compose drops outside swarm" RESOURCE '{"services": {"decorative": {
  "image": "x:1", "mem_limit": 1000000,
  "deploy": {"resources": {"reservations": {"cpus": "0.20"}}}
}}}'

catches "a service with no memory ceiling" RESOURCE '{"services": {"boundless": {"image": "x:1"}}}'

catches "a reservation as large as the limit it sits under" RESOURCE '{"services": {"pointless": {
  "image": "x:1", "mem_limit": "512m", "mem_reservation": "512m"
}}}'

catches "a memswap_limit that silently disables swap" RESOURCE '{"services": {"swapless": {
  "image": "x:1", "mem_limit": "512m", "memswap_limit": "512m"
}}}'

# --- and it must never echo a value it was handed ---------------------------
#
# `docker compose config` inlines every env_file, so what the checker reads
# includes ntfy's passwords and API tokens and homepage's widget keys. The
# projection in compose-invariants.py drops all of it, and this is what keeps
# that true: hand the checker a canary in each of those places, on a service
# broken enough to be reported, and fail if the canary comes back out.
canary="c4n4ry-must-not-appear-b7f3"
leaked="$(printf '%s' '{"services": {"leaky": {
  "image": "somewhere/thing:latest",
  "environment": {"NTFY_PASSWORD": "CANARY"},
  "env_file": ["CANARY"],
  "labels": {"homepage.widget.key": "CANARY",
             "traefik.http.routers.leaky.rule": "Host(`CANARY`)",
             "traefik.http.routers.leaky.entrypoints": "websecure"}
}}}' | sed "s/CANARY/$canary/g" \
    | python3 "$TESTS_DIR/compose-invariants.py" "$REPO_DIR" | grep -c "$canary" || true)"
ok "no value reaches a finding, only names" "$leaked" 0

# --- the service set CI starts is computed, not maintained -------------------
#
# The workflow used to carry that list by hand, and a hand-written list is how a
# newly added optional service ends up never started in CI with nothing to
# report it. Rendered with every profile enabled, ci-excluded included, so each
# service is present carrying the profiles both compose files gave it.

ci_errors="$(mktemp)"
trap 'rm -f "$render_errors" "$ci_errors"' EXIT

ci_profiles="$(DATA_LOCATION=/nonexistent/compose-test COMPOSE_PROFILES=all,stremio-lan,ci-excluded \
    docker compose --env-file /dev/null -f "$REPO_DIR/compose.yaml" -f "$REPO_DIR/compose.test.yaml" \
    config --format json 2>"$render_errors" \
    | python3 "$TESTS_DIR/ci-profiles.py" 2>"$ci_errors")" || true

if [ -n "$ci_profiles" ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    printf 'FAIL the profile list CI starts could not be computed\n'
    sed 's/^/  /' "$ci_errors"
    sed 's/^/  /' "$render_errors"
fi

profile_lines() { printf '%s' "$ci_profiles" | tr ',' '\n'; }

ok "the computed list asks for the optional services" \
    "$(profile_lines | grep -cx 'nextcloud')" 1
# stremio-lan sits outside the `all` catch-all, so the selector reaches it only
# by naming the service. Asserted positively: it used to be excluded.
ok "and for the one that only its own name selects" \
    "$(profile_lines | grep -cx 'stremio-lan')" 1
ok "and for the gateway that used to ride in on open-webui's profile" \
    "$(profile_lines | grep -cx 'agentgateway')" 1
ok "and for none compose.test.yaml excludes" \
    "$(profile_lines | grep -cxE 'gluetun|qbittorrent|stremio|llama-cpp|parakeet|piper|headplane')" 0
ok "and never for the catch-all, which would re-enable them" \
    "$(profile_lines | grep -cx 'all')" 0

# --- and it must refuse a selection that is not sound -----------------------
#
# Same reasoning as the catches() block above: a computation that quietly
# returned a short list, or stopped noticing a collision, reads exactly like a
# clean stack. So hand it renderings that are wrong on purpose.

refuses() {
    _label="$1"
    _needle="$2"
    _json="$3"
    _got="$(printf '%s' "$_json" | python3 "$TESTS_DIR/ci-profiles.py" 2>&1 >/dev/null || true)"
    case "$_got" in
        *"$_needle"*) pass=$((pass + 1)) ;;
        *)
            fail=$((fail + 1))
            printf 'FAIL %s\n  got  [%s]\n  want [*%s*]\n' "$_label" "$_got" "$_needle"
            ;;
    esac
}

# The failure this pays for: gluetun once listed `shelfmark` among its profiles,
# so asking for the book search also started the VPN container CI has no
# credentials for, and the run died six minutes later on an unhealthy container.
refuses "a ci-excluded service sharing a profile with a selected one" \
    "is ci-excluded but carries profile" '{"services": {
  "shelfmark": {"image": "x:1", "profiles": ["shelfmark", "all"]},
  "gluetun": {"image": "x:1", "profiles": ["gluetun", "shelfmark", "all", "ci-excluded"]}
}}'

refuses "a selection that came back nearly empty" \
    "expected at least" '{"services": {"lonely": {"image": "x:1", "profiles": ["lonely"]}}}'

refuses "a service reachable only through the catch-all" \
    "cannot ask for it on its own" '{"services": {"vague": {"image": "x:1", "profiles": ["all"]}}}'

printf '%s\n' "$out" | grep '^CHECKED ' | sed 's/^CHECKED/compose-test.sh: checked/'
printf '\ncompose-test.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
