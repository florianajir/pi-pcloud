#!/bin/sh
# The Trilium HTTP contract scripts/trilium-bootstrap.sh is built on, asserted
# against the image compose.yaml actually pins.
#
# That bootstrap is unusually version-coupled: Trilium exposes none of its AI or
# MCP settings as environment variables, so the hook drives the same private
# endpoints the browser does - the setup wizard, a password sign-in, the CSRF
# handshake and `PUT /api/options`. None of that is a published API, and it has
# already moved under us once: `/api/login/token` answers `{"token": ...}` while
# the project's own internal.openapi.yaml still documents `{"authToken": ...}`.
#
# An image bump is therefore the risk, and CI cannot see it any other way: the
# post-start hook is deliberately tolerant, because declining is the correct
# behaviour on an instance whose password the stack does not own. A hook that
# quietly stopped wiring anything looks exactly like a hook that correctly
# stepped aside. This test removes that ambiguity by asserting each behaviour
# separately, on a throwaway instance, so a bump says which one changed.
#
# Touches nothing of the running stack: its own container, its own network, no
# volumes, no published ports. Run with `make test`.
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
# succeed, and asserting 204 where 200 would do as well turns an upstream tidy-up
# into a red build that costs an investigation and changes nothing.
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
# No volume: the data directory lives and dies with the container, so this can
# never touch ${DATA_LOCATION}/trilium.
docker run -d --name "$BOX" --network "$NET" \
    -e TRILIUM_DATA_DIR=/home/node/trilium-data \
    "$IMAGE" >/dev/null

BASE="http://$BOX:8080"

# `-i` for the responses whose cookies matter, and never -f: the contract here
# includes which status codes come back, so curl must not swallow them.
probe() {
    docker run --rm -i --network "$NET" "$CURL_IMAGE" \
        -sS --connect-timeout 5 --max-time 30 "$@" 2>/dev/null || true
}

# Wait for the server rather than the healthcheck: this container has none of
# the stack's compose wiring.
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

# --- 1. The setup wizard, which is how a fresh install is claimed ---

status="$(probe "$BASE/api/setup/status")"
ok "/api/setup/status exposes isInitialized" \
   "$(printf '%s' "$status" | jq -r 'has("isInitialized")')" true
ok "a virgin instance reports isInitialized false" \
   "$(printf '%s' "$status" | jq -r '.isInitialized | tostring')" false

# An empty body on purpose: the handler reads only `locale` and the
# `skipDemoDb` query parameter. internal.openapi.yaml claims a password is
# required here; it is not, and set-password below is what actually sets one.
code="$(printf '{}' | probe -o /dev/null -w '%{http_code}' -X POST --data @- \
    -H 'Content-Type: application/json' "$BASE/api/setup/new-document")"
succeeds "POST /api/setup/new-document accepts an empty body" "$code"

ok "and the instance is initialized afterwards" \
   "$(probe "$BASE/api/setup/status" | jq -r '.isInitialized | tostring')" true

# --- 2. Setting the owner password, unauthenticated and without CSRF ---

code="$(printf '{"password1":"%s","password2":"%s"}' "$PASSWORD" "$PASSWORD" \
    | probe -o /dev/null -w '%{http_code}' -X POST --data @- \
        -H 'Content-Type: application/json' "$BASE/set-password")"
# Deliberately not asserted as success or failure: it answers 302 either way -
# `res.redirect("login")` on success, and the same from checkPasswordNotSet's
# refusal - which is precisely why the bootstrap judges this by signing in
# afterwards rather than by reading a status. What matters here is only that it
# is reachable unauthenticated and without a CSRF token.
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
# Every cookie that response set, the refreshed session id included: the token
# is bound to a session id, so pairing it with an older cookie is a 403.
cookies="$(printf '%s' "$boot" | tr -d '\r' \
    | sed -n 's/^[Ss]et-[Cc]ookie: *\([^;]*\).*/\1/p' | paste -sd'; ' -)"
[ -n "$cookies" ] || cookies="$session"

# --- 4. The options the whole feature is made of ---

body='{"aiEnabled":"true","mcpEnabled":"true","llmProviders":"[]"}'
code="$(printf '%s' "$body" | probe -o /dev/null -w '%{http_code}' -X PUT --data @- \
    -H "Cookie: $cookies" -H "x-csrf-token: $csrf_token" \
    -H 'Content-Type: application/json' "$BASE/api/options")"
ok "PUT /api/options accepts the session and the x-csrf-token header" "$code" 204

# Read back rather than trust the status: an option missing from the server's
# ALLOWED_OPTIONS is rejected per name, and the call as a whole still succeeds.
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

# --- 6. The MCP endpoint that token is for ---

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
