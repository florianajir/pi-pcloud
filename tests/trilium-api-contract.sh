#!/bin/sh
# The Trilium HTTP contract scripts/trilium-bootstrap.sh is built on, asserted
# against the image compose.yaml pins.
#
# That hook drives Trilium's *private* endpoints - the setup wizard, a password
# sign-in, the CSRF handshake, `PUT /api/options` - because none of the AI or
# MCP settings exist as configuration. That surface has moved before:
# `/api/login/token` answers `{"token": ...}` while the project's own
# internal.openapi.yaml still documents `{"authToken": ...}`.
#
# CI cannot catch that on its own. The hook is deliberately tolerant, since
# declining is correct on an instance whose password the stack does not own, so
# a bump that broke the wiring looks exactly like a hook stepping aside. Each
# behaviour is asserted separately here, so a bump names the one that changed.
#
# Touches nothing of the running stack: own container, own network, no volumes,
# no published ports. Run with `make test`.
set -eu

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"

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

# The status class, not the exact code: the bootstrap only needs these calls to
# succeed, and pinning 204 where 200 would do turns an upstream tidy-up into a
# red build that changes nothing.
succeeds() {
    case "$2" in
        2*) pass=$((pass + 1)) ;;
        *)
            fail=$((fail + 1))
            printf 'FAIL %s\n  got  [%s]\n  want [a 2xx]\n' "$1" "$2"
            ;;
    esac
}

contains() {
    case "$2" in
        *"$3"*) pass=$((pass + 1)) ;;
        *)
            fail=$((fail + 1))
            printf 'FAIL %s\n  got  [%s]\n  want it to contain [%s]\n' "$1" "$2" "$3"
            ;;
    esac
}

if ! command -v docker >/dev/null 2>&1; then
    printf 'trilium-api-contract.sh: docker is required\n' >&2
    exit 1
fi

# The pinned reference, digest included, read from compose.yaml rather than
# repeated here - a test that names its own tag stops testing what ships the
# moment the two drift.
# Overridable so a candidate image can be checked before the bump is committed:
#   TRILIUM_CONTRACT_IMAGE=ghcr.io/triliumnext/trilium:v0.106.0 sh tests/trilium-api-contract.sh
IMAGE="${TRILIUM_CONTRACT_IMAGE:-}"
[ -n "$IMAGE" ] || IMAGE="$(DATA_LOCATION=/nonexistent/trilium-contract COMPOSE_PROFILES=trilium \
    docker compose --env-file /dev/null -f "$REPO_DIR/compose.yaml" \
    config --format json 2>/dev/null \
    | jq -r '.services.trilium.image // empty')"

if [ -z "$IMAGE" ]; then
    printf 'trilium-api-contract.sh: could not read the trilium image from compose.yaml\n' >&2
    exit 1
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    printf 'trilium-api-contract.sh: pulling %s\n' "$IMAGE"
    docker pull -q "$IMAGE" >/dev/null 2>&1 || {
        printf 'trilium-api-contract.sh: could not pull %s\n' "$IMAGE" >&2
        exit 1
    }
fi

NET="trilium-contract-net-$$"
BOX="trilium-contract-$$"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.12.1}"
PASSWORD="contract-test-password"

cleanup() {
    docker rm -f "$BOX" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker network create "$NET" >/dev/null
# No volume: the data directory dies with the container, so this can never
# touch ${DATA_LOCATION}/trilium.
docker run -d --name "$BOX" --network "$NET" \
    -e TRILIUM_DATA_DIR=/home/node/trilium-data \
    "$IMAGE" >/dev/null

BASE="http://$BOX:8080"

# Never -f: the status codes are part of the contract, so curl must not
# swallow them. `-i` where the cookies matter.
probe() {
    docker run --rm -i --network "$NET" "$CURL_IMAGE" \
        -sS --connect-timeout 5 --max-time 30 "$@" 2>/dev/null || true
}

# Wait on the server, not a healthcheck: this container has none of the
# stack's compose wiring.
ready=0
i=0
while [ "$i" -lt 60 ]; do
    if [ -n "$(probe -o /dev/null -w '%{http_code}' "$BASE/api/setup/status" | grep -x 200 || true)" ]; then
        ready=1
        break
    fi
    i=$((i + 1))
    sleep 2
done

if [ "$ready" -ne 1 ]; then
    printf 'trilium-api-contract.sh: %s never answered /api/setup/status\n' "$IMAGE" >&2
    docker logs "$BOX" 2>&1 | tail -20 >&2
    exit 1
fi

printf 'trilium-api-contract.sh: %s\n' "$IMAGE"

# --- 0. The healthcheck compose.yaml declares, on this architecture ---

# Run here rather than trusted from the image: the bundled probe is wrapped in
# `gosu` on arm64 and `su-exec` on amd64, so a command copied from one variant
# fails on the other before reaching the server, and the container just sits
# unhealthy. compose.yaml therefore drops the privilege step - this asserts
# what it actually runs.
hc="$(DATA_LOCATION=/nonexistent/trilium-contract COMPOSE_PROFILES=trilium \
    docker compose --env-file /dev/null -f "$REPO_DIR/compose.yaml" \
    config --format json 2>/dev/null \
    | jq -r '.services.trilium.healthcheck.test | .[1:] | join(" ")')"
# The status captured through `if`, and the architecture resolved *before* the
# call: run bare under `set -e` a failing probe aborts the whole file before any
# FAIL is recorded, and a `$(...)` in an earlier argument of `ok` overwrites the
# `$?` the later one was meant to read - which made this pass unconditionally.
arch="$(docker version -f '{{.Server.Arch}}')"
# shellcheck disable=SC2086  # the command and its argument, split on purpose
if docker exec "$BOX" $hc >/dev/null 2>&1; then hc_rc=0; else hc_rc=1; fi
ok "compose.yaml's healthcheck command runs on $arch" "$hc_rc" 0

# --- 1. The setup wizard, which is how a fresh install is claimed ---

status="$(probe "$BASE/api/setup/status")"
ok "/api/setup/status exposes isInitialized" \
   "$(printf '%s' "$status" | jq -r 'has("isInitialized")')" true
ok "a virgin instance reports isInitialized false" \
   "$(printf '%s' "$status" | jq -r '.isInitialized | tostring')" false

# Empty body on purpose: the handler reads only `locale` and the `skipDemoDb`
# query parameter. internal.openapi.yaml claims a password is required; it is
# not. ?skipDemoDb exactly as the bootstrap sends it - upstream tests
# `!== undefined`, so presence is the switch, and the assertion further down is
# what would notice that becoming a boolean.
code="$(printf '{}' | probe -o /dev/null -w '%{http_code}' -X POST --data @- \
    -H 'Content-Type: application/json' "$BASE/api/setup/new-document?skipDemoDb=true")"
succeeds "POST /api/setup/new-document accepts an empty body" "$code"

ok "and the instance is initialized afterwards" \
   "$(probe "$BASE/api/setup/status" | jq -r '.isInitialized | tostring')" true

# --- 2. Setting the owner password, unauthenticated and without CSRF ---

code="$(printf '{"password1":"%s","password2":"%s"}' "$PASSWORD" "$PASSWORD" \
    | probe -o /dev/null -w '%{http_code}' -X POST --data @- \
        -H 'Content-Type: application/json' "$BASE/set-password")"
# Not asserted as success or failure: it answers 302 either way - success and
# checkPasswordNotSet's refusal are both `res.redirect("login")`, which is why
# the bootstrap judges it by signing in afterwards. All that matters here is
# that it is reachable without auth or CSRF.
case "$code" in
    2* | 3*) pass=$((pass + 1)) ;;
    *)
        fail=$((fail + 1))
        printf 'FAIL POST /set-password is reachable without auth or CSRF\n  got  [%s]\n' "$code"
        ;;
esac

# --- 3. Signing in, and the CSRF handshake ---

headers="$(printf '{"password":"%s"}' "$PASSWORD" \
    | probe -i -o - -X POST --data @- -H 'Content-Type: application/json' "$BASE/login")"
session="$(printf '%s' "$headers" | tr -d '\r' \
    | sed -n 's/^[Ss]et-[Cc]ookie: *\(trilium\.sid=[^;]*\).*/\1/p' | head -1)"
ok "POST /login accepts a JSON password and sets trilium.sid" \
   "$([ -n "$session" ] && echo yes || echo no)" yes

boot="$(probe -i "$BASE/bootstrap" -H "Cookie: $session")"
boot_body="$(printf '%s' "$boot" | tr -d '\r' | sed -n '/^$/,$p' | tail -n +2)"
ok "GET /bootstrap confirms the session is logged in" \
   "$(printf '%s' "$boot_body" | jq -r '.loggedIn | tostring')" true
ok "GET /bootstrap carries the CSRF token" \
   "$(printf '%s' "$boot_body" | jq -r 'has("csrfToken")')" true
contains "GET /bootstrap sets the CSRF cookie" "$boot" "trilium-csrf="

csrf_token="$(printf '%s' "$boot_body" | jq -r '.csrfToken')"
# Every cookie that response set: the token is bound to a session id, so an
# older cookie is a 403.
# `-d';'`, one character: paste cycles through the -d list, so `-d'; '` would
# join a third cookie with a space rather than a semicolon.
cookies="$(printf '%s' "$boot" | tr -d '\r' \
    | sed -n 's/^[Ss]et-[Cc]ookie: *\([^;]*\).*/\1/p' | paste -sd';' -)"
[ -n "$cookies" ] || cookies="$session"

# --- 4. The options the whole feature is made of ---

body='{"aiEnabled":"true","mcpEnabled":"true","llmProviders":"[]"}'
code="$(printf '%s' "$body" | probe -o /dev/null -w '%{http_code}' -X PUT --data @- \
    -H "Cookie: $cookies" -H "x-csrf-token: $csrf_token" \
    -H 'Content-Type: application/json' "$BASE/api/options")"
succeeds "PUT /api/options accepts the session and the x-csrf-token header" "$code"

# Read back rather than trust the status: an option missing from the server's
# ALLOWED_OPTIONS is rejected by name while the call still succeeds.
opts="$(probe "$BASE/api/options" -H "Cookie: $cookies")"
ok "aiEnabled survived the write" "$(printf '%s' "$opts" | jq -r '.aiEnabled')" true
ok "mcpEnabled survived the write" "$(printf '%s' "$opts" | jq -r '.mcpEnabled')" true
ok "llmProviders survived the write" "$(printf '%s' "$opts" | jq -r '.llmProviders')" "[]"

# --- 5. The token agentgateway's MCP target presents ---

token_body="$(printf '{"password":"%s","tokenName":"contract"}' "$PASSWORD" \
    | probe -X POST --data @- -H 'Content-Type: application/json' "$BASE/api/login/token")"
etapi="$(printf '%s' "$token_body" | jq -r '.token // empty')"
ok "POST /api/login/token returns the token under .token" \
   "$([ -n "$etapi" ] && echo yes || echo no)" yes

# --- 6. The demo document ?skipDemoDb was supposed to leave out ---

# Root's children, not a note count: the help subtree lands under _hidden
# either way, so counting rows cannot tell a skipped demo from a seeded one.
# With the demo, root also carries "Trilium Demo", "Journal" and
# "Miscellaneous".
root_children="$(probe -H "Authorization: $etapi" "$BASE/etapi/notes/root" \
    | jq -c '.childNoteIds' 2>/dev/null)"
ok "?skipDemoDb leaves root with only the hidden subtree" "$root_children" '["_hidden"]'

# --- 7. The MCP endpoint that token is for ---

mcp='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"contract","version":"1"}}}'
code="$(printf '%s' "$mcp" | probe -o /dev/null -w '%{http_code}' -X POST --data @- \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    "$BASE/mcp")"
ok "/mcp refuses a request with no Authorization" "$code" 401

answer="$(printf '%s' "$mcp" | probe -X POST --data @- \
    -H "Authorization: $etapi" -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' "$BASE/mcp")"
contains "/mcp accepts the ETAPI token in Authorization" "$answer" '"serverInfo"'

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
