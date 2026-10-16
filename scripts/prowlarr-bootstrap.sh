#!/bin/sh
# Bootstrap Prowlarr (idempotent, best-effort — warns, never fails the start):
#   1. register qBittorrent as a download client
#   2. register FlareSolverr as an indexer proxy (Cloudflare solver) with a tag
#   3. maintain a patched copy of one bundled indexer definition, so it maps the
#      infohash the feed sends
#   4. point a health/update notification at ntfy
# Prowlarr shares gluetun's network namespace, so qBittorrent (localhost:8080),
# FlareSolverr (localhost:8191) and the Prowlarr API (localhost:9696) are all reachable
# from inside the container. The API key is read straight from config.xml
# (rendered by prowlarr-pre-start.sh). A post-start hook, so it runs after compose up.

set -eu

. "$(dirname "$0")/lib.sh"

PROWLARR_CONTAINER="${PROWLARR_CONTAINER:-pi-prowlarr}"
QB_CLIENT_NAME="qBittorrent"
QB_HOST="gluetun"
QB_PORT="8080"
# Per-release category mapping on the download client: Prowlarr resolves the
# qBittorrent category as `GetCategoryForRelease(release) ?? Settings.Category`, and
# matches parent categories too. Anything unmapped falls back to the client default
# and stays out of Kavita's library.
# newznab has no manga category - manga ships as 7030 Books/Comics, the same id as
# comics - so 7030 goes to manga here. Comics reach the comics category only through
# a tracker's own id (below); otherwise they come from Kapowarr, which imports into
# its own root folder.
# Audiobooks are 3030 Audio/Audiobook, a sibling of the music ids under 3000 rather
# than a Books subcategory; mapped on its own so 3010 MP3 and 3040 Lossless keep
# falling through to the client default. Shelfmark's own grabs bypass this map - it
# adds them to qBittorrent itself, under QBITTORRENT_CATEGORY_AUDIOBOOK.
#
# 7000, the bare Books parent, is mapped even though it says nothing about *which*
# kind of book: several indexers declare no Books subcategory at all, so without it
# every book grab from them would land in the client default, which nothing indexes.
# Wrong library beats invisible.
#
# Some trackers send their own category ids in release.Categories next to the newznab
# ones, and the map intersects raw ints, so those work as mappings where they say more
# than the newznab id does: 107102/107104 (comics), 107103 (manga) and 107105
# (audiobooks) from a tracker that collapses all four to 7000 for newznab; 117084,
# 156719 and 111160, an anime tracker's Literature ids, which are manga; 107010, the
# Mags id a tracker always sends beside 7010. Tracker ids that only rename a newznab
# leaf are left out: they would add lines that drift and route nothing new.
#
# ORDER MATTERS. Prowlarr takes the first mapping in list order whose ids intersect
# the release's, not the most specific one:
#
#   - books must stay LAST, because 7000 is a catch-all: a release that carries the
#     parent beside a specific id ([7000,107105] for an audiobook) would otherwise
#     land in the Book library.
#   - manga and magazines must stay above books for the same reason, so indexers
#     that report a leaf *and* its parent ([7030,7000]) still reach the leaf's category.
#
# 7010 Books/Mags is the one Books leaf naming a kind rather than a format, so it gets
# its own destination. 7020 Books/EBook stays with books on purpose: monthly magazine
# rips and ordinary ebooks both arrive as 7020, with nothing to tell them apart.
QB_CATEGORY_MAP='[
  {"clientCategory":"comics","categories":[107102,107104]},
  {"clientCategory":"manga","categories":[7030,107103,117084,156719,111160]},
  {"clientCategory":"audiobooks","categories":[3030,107105]},
  {"clientCategory":"magazines","categories":[7010,107010]},
  {"clientCategory":"books","categories":[7000,7020,7040,7050,7060]}
]'
FLARESOLVERR_NAME="FlareSolverr"
FLARESOLVERR_TAG="flaresolverr"
FLARESOLVERR_HOST="http://flaresolverr:8191/"
NTFY_ENV_FILE="$PROJECT_DIR/config/ntfy/ntfy.env"
NTFY_URL="http://ntfy"
NTFY_TOPIC="downloads"
NTFY_NOTIFICATION_NAME="ntfy"
API="http://localhost:9696/api/v1"
MAX_RETRIES=60
RETRY_INTERVAL=5

px_curl() {
    docker exec "$PROWLARR_CONTAINER" curl -sS "$@"
}

px_post() {
    # px_post <path> ; JSON body on stdin. Echoes the HTTP status code.
    # docker exec needs -i so curl's --data @- actually receives the piped body.
    local path="$1"
    docker exec -i "$PROWLARR_CONTAINER" curl -sS -o /dev/null -w '%{http_code}' \
        -X POST -H "X-Api-Key: $KEY" -H "Content-Type: application/json" \
        --data @- "$API/$path"
}

px_put() {
    # px_put <path> ; JSON body on stdin. Echoes the HTTP status code.
    local path="$1"
    docker exec -i "$PROWLARR_CONTAINER" curl -sS -o /dev/null -w '%{http_code}' \
        -X PUT -H "X-Api-Key: $KEY" -H "Content-Type: application/json" \
        --data @- "$API/$path"
}

px_post_body() {
    # px_post_body <path> ; JSON body on stdin. Echoes the response body.
    local path="$1"
    docker exec -i "$PROWLARR_CONTAINER" curl -sS \
        -X POST -H "X-Api-Key: $KEY" -H "Content-Type: application/json" \
        --data @- "$API/$path"
}

get_api_key() {
    docker exec "$PROWLARR_CONTAINER" sh -c "grep -oE '<ApiKey>[^<]+</ApiKey>' /config/config.xml" 2>/dev/null \
        | sed -e 's|<ApiKey>||' -e 's|</ApiKey>||' | tr -d '\r\n'
}

wait_for_prowlarr() {
    log "Waiting for Prowlarr API..."
    if wait_for_cmd "$MAX_RETRIES" "$RETRY_INTERVAL" px_curl -f -H "X-Api-Key: $KEY" "$API/system/status"; then
        log "Prowlarr API is ready"
        return 0
    fi
    log "WARNING: Prowlarr API did not become ready in time"
    return 1
}

# Whether qBittorrent is part of the current selection. Asked of compose rather
# than of the running container, so a qBittorrent that is merely down does not
# make this script tear its own registration out and put it back; and asked at
# all because Prowlarr validates a download client when it is created, so
# registering one that is not in the stack answers HTTP 400. That warning has
# been in every CI run's log, and in the log of anyone who runs without the
# download stack.
qbittorrent_selected() {
    compose config --services 2>/dev/null | grep -qx qbittorrent
}

ensure_download_client() {
    local user password schema payload code existing current id updated

    # Before anything is read or written: an existing registration is left
    # exactly as it is, because disabling the profile is not a request to
    # unconfigure Prowlarr.
    if ! qbittorrent_selected; then
        log "qbittorrent is not enabled; leaving Prowlarr's download client alone"
        return 0
    fi

    user="$(get_env_value ADMIN_USER)"
    password="$(get_env_value PASSWORD)"
    [ -n "$user" ] && [ -n "$password" ] || { log "WARNING: ADMIN_USER/PASSWORD not set; skipping download client"; return 0; }

    existing="$(px_curl -H "X-Api-Key: $KEY" "$API/downloadclient" 2>/dev/null)"
    current="$(printf '%s' "$existing" | jq -c --arg n "$QB_CLIENT_NAME" '.[]? | select(.name==$n)' 2>/dev/null)"

    if [ -n "$current" ] && [ "$current" != "null" ]; then
        # Reconcile the two fields this script owns: the host (migrating an older
        # localhost:8080 install after Prowlarr moved off the VPN) and the category
        # map. Comparing the re-serialised object rather than each field keeps the
        # "nothing to do" case quiet without a check per field; jq assignment keeps
        # existing keys in place, so both sides serialise in the same order.
        id="$(printf '%s' "$current" | jq -r '.id')"
        updated="$(printf '%s' "$current" | jq -c --arg h "$QB_HOST" --argjson cats "$QB_CATEGORY_MAP" \
            '.fields = ([.fields[] | if .name=="host" then .value=$h else . end])
             | .categories = $cats')"
        if [ "$updated" = "$current" ]; then
            log "qBittorrent download client already present, skipping"
            return 0
        fi
        code="$(printf '%s' "$updated" | px_put "downloadclient/$id")"
        case "$code" in
            20*) log "Updated qBittorrent download client (host $QB_HOST, library category map)" ;;
            *)   log "WARNING: qBittorrent downloadclient PUT returned HTTP $code" ;;
        esac
        return 0
    fi

    # Build the create body from the live schema so field names track the Prowlarr version.
    schema="$(px_curl -H "X-Api-Key: $KEY" "$API/downloadclient/schema" 2>/dev/null)"
    payload="$(printf '%s' "$schema" | jq -c \
        --arg name "$QB_CLIENT_NAME" --arg host "$QB_HOST" --argjson port "$QB_PORT" \
        --arg user "$user" --arg pass "$password" --argjson cats "$QB_CATEGORY_MAP" '
        (.[] | select(.implementation == "QBittorrent"))
        | .name = $name
        | .enable = true
        | .categories = $cats
        | .fields = ([.fields[]
            | if   .name == "host"     then .value = $host
              elif .name == "port"     then .value = $port
              elif .name == "username" then .value = $user
              elif .name == "password" then .value = $pass
              elif .name == "useSsl"   then .value = false
              else . end])
    ' 2>/dev/null)"
    [ -n "$payload" ] && [ "$payload" != "null" ] || { log "WARNING: could not build qBittorrent payload from schema"; return 0; }

    code="$(printf '%s' "$payload" | px_post "downloadclient")"
    case "$code" in
        20*) log "Added qBittorrent download client to Prowlarr (host: $QB_HOST)" ;;
        *)   log "WARNING: Prowlarr downloadclient POST returned HTTP $code" ;;
    esac
}

# Return the id of the FlareSolverr tag, creating it if needed. Empty on failure.
ensure_tag() {
    local tags id
    tags="$(px_curl -H "X-Api-Key: $KEY" "$API/tag" 2>/dev/null)"
    id="$(printf '%s' "$tags" | jq -r --arg l "$FLARESOLVERR_TAG" '.[]? | select(.label==$l) | .id' 2>/dev/null)"
    if [ -n "$id" ] && [ "$id" != "null" ]; then
        printf '%s' "$id"
        return 0
    fi
    printf '{"label":"%s"}' "$FLARESOLVERR_TAG" | px_post_body "tag" 2>/dev/null \
        | jq -r '.id // empty' 2>/dev/null
}

# Wait until FlareSolverr answers, else Prowlarr's connection test on save fails
# (Chrome needs ~45s to init on a fresh boot).
wait_for_flaresolverr() {
    wait_for_cmd "$MAX_RETRIES" "$RETRY_INTERVAL" px_curl -f "${FLARESOLVERR_HOST%/}/health"
}

ensure_flaresolverr_proxy() {
    local existing current current_host id tag_id schema payload code updated
    existing="$(px_curl -H "X-Api-Key: $KEY" "$API/indexerproxy" 2>/dev/null)"
    current="$(printf '%s' "$existing" | jq -c --arg n "$FLARESOLVERR_NAME" '.[]? | select(.name==$n)' 2>/dev/null)"

    if [ -n "$current" ] && [ "$current" != "null" ]; then
        current_host="$(printf '%s' "$current" | jq -r '.fields[]? | select(.name=="host") | .value' 2>/dev/null)"
        [ "$current_host" = "$FLARESOLVERR_HOST" ] && { log "FlareSolverr proxy already present, skipping"; return 0; }
    fi

    if ! wait_for_flaresolverr; then
        log "WARNING: FlareSolverr not reachable at $FLARESOLVERR_HOST; skipping proxy (will retry next start)"
        return 0
    fi

    if [ -n "$current" ] && [ "$current" != "null" ]; then
        # Migrate the host (e.g. localhost:8191 -> flaresolverr:8191 after moving off the VPN).
        id="$(printf '%s' "$current" | jq -r '.id')"
        updated="$(printf '%s' "$current" | jq -c --arg h "$FLARESOLVERR_HOST" \
            '.fields = ([.fields[] | if .name=="host" then .value=$h else . end])')"
        code="$(printf '%s' "$updated" | px_put "indexerproxy/$id")"
        case "$code" in
            20*) log "Updated FlareSolverr proxy host to $FLARESOLVERR_HOST" ;;
            *)   log "WARNING: FlareSolverr proxy PUT returned HTTP $code" ;;
        esac
        return 0
    fi

    tag_id="$(ensure_tag)"
    [ -n "$tag_id" ] || { log "WARNING: could not obtain '$FLARESOLVERR_TAG' tag; skipping FlareSolverr proxy"; return 0; }

    schema="$(px_curl -H "X-Api-Key: $KEY" "$API/indexerproxy/schema" 2>/dev/null)"
    payload="$(printf '%s' "$schema" | jq -c \
        --arg name "$FLARESOLVERR_NAME" --arg host "$FLARESOLVERR_HOST" --argjson tag "$tag_id" '
        (.[] | select(.implementation == "FlareSolverr"))
        | .name = $name
        | .tags = [$tag]
        | .fields = ([.fields[] | if .name=="host" then .value=$host else . end])
    ' 2>/dev/null)"
    [ -n "$payload" ] && [ "$payload" != "null" ] || { log "WARNING: could not build FlareSolverr payload from schema"; return 0; }

    code="$(printf '%s' "$payload" | px_post "indexerproxy")"
    case "$code" in
        20*) log "Added FlareSolverr proxy to Prowlarr (host: $FLARESOLVERR_HOST, tag: $FLARESOLVERR_TAG)" ;;
        *)   log "WARNING: Prowlarr indexerproxy POST returned HTTP $code" ;;
    esac
}

ensure_ntfy_notification() {
    local pw existing schema payload code
    pw="$(read_env_value_from_file "$NTFY_ENV_FILE" NTFY_PROWLARR_PASSWORD)"
    [ -n "$pw" ] || { log "WARNING: NTFY_PROWLARR_PASSWORD not found in $NTFY_ENV_FILE; skipping ntfy notification"; return 0; }

    existing="$(px_curl -H "X-Api-Key: $KEY" "$API/notification" 2>/dev/null)"
    if printf '%s' "$existing" | jq -e --arg n "$NTFY_NOTIFICATION_NAME" '.[]? | select(.name==$n)' >/dev/null 2>&1; then
        log "ntfy notification already present, skipping"
        return 0
    fi

    # Prowlarr posts a test notification to ntfy on save, so ntfy must be reachable with
    # the prowlarr user's credentials by then (it is, once ntfy-pre-start ran + ntfy recreated).
    schema="$(px_curl -H "X-Api-Key: $KEY" "$API/notification/schema" 2>/dev/null)"

    # onGrab stays off: a "grab" is any hit on /api/v1/indexer/{id}/download, and
    # AIOStreams' scraper calls it once per result to read an infoHash out of the
    # .torrent. Measured 2026-09-18..21, 1631 of 1647 grabs were that, not a release
    # sent anywhere - enough to empty Prowlarr's ntfy bucket and drop 105 messages
    # with 42901, health alerts among them.
    #
    # Nothing is lost: real grabs are announced by Shelfmark and again by qBittorrent
    # on completion. What stays below is what only Prowlarr can report.
    payload="$(printf '%s' "$schema" | jq -c \
        --arg name "$NTFY_NOTIFICATION_NAME" --arg url "$NTFY_URL" --arg topic "$NTFY_TOPIC" \
        --arg user "prowlarr" --arg pass "$pw" '
        (.[] | select(.implementation == "Ntfy"))
        | .name = $name
        | .onGrab = false
        | .onHealthIssue = true
        | .onHealthRestored = true
        | .onApplicationUpdate = true
        | .fields = ([.fields[]
            | if   .name == "serverUrl" then .value = $url
              elif .name == "userName"  then .value = $user
              elif .name == "password"  then .value = $pass
              elif .name == "topics"    then .value = [$topic]
              else . end])
    ' 2>/dev/null)"
    [ -n "$payload" ] && [ "$payload" != "null" ] || { log "WARNING: could not build ntfy payload from schema"; return 0; }

    code="$(printf '%s' "$payload" | px_post "notification")"
    case "$code" in
        20*) log "Added ntfy notification to Prowlarr (topic: $NTFY_TOPIC)" ;;
        *)   log "WARNING: Prowlarr notification POST returned HTTP $code" ;;
    esac
}

# The bundled definition patched here maps every torznab attribute the feed sends
# except infohash, so Prowlarr answers `infoHash: null` and a consumer that needs the
# hash must fetch the .torrent of every result. The tracker declares
# `requestDelay: 1`, so those serialise and a page of results outlasts a 30 s timeout.
#
# Editing the bundled file does not work - Prowlarr restores all of
# /config/Definitions from its own bundle on start, so the edit dies with the restart
# needed to load it. Only a sibling with a unique id, name and filename persists.
#
# Derived at every start rather than vendored, so upstream fixes keep arriving and
# this file can be deleted the day upstream maps infohash itself.
TR4KER_DEFINITION="/config/Definitions/tr4ker.yml"
TR4KER_PATCHED="/config/Definitions/Custom/tr4ker-patched.yml"

ensure_tr4ker_patched_definition() {
    if ! docker exec "$PROWLARR_CONTAINER" test -f "$TR4KER_DEFINITION" 2>/dev/null; then
        return 0
    fi

    # Built to a temp path and only moved into place when it differs, so an unchanged
    # run neither rewrites the file nor restarts Prowlarr.
    if docker exec -i "$PROWLARR_CONTAINER" sh -s "$TR4KER_DEFINITION" "$TR4KER_PATCHED" <<'PATCH'
set -eu
src="$1"
dst="$2"
tmp="$dst.building"
mkdir -p "$(dirname "$dst")"
awk '
  /^id: tr4ker$/   { print "id: tr4ker-patched"; next }
  /^name: TR4KER$/ { print "name: TR4KER (patched)"; next }
  /^    imdbid:$/ && !inserted {
    print "    infohash:"
    print "      selector: \"[name=infohash]\""
    print "      attribute: value"
    inserted = 1
  }
  { print }
' "$src" > "$tmp"
grep -q '^    infohash:' "$tmp"
grep -q '^id: tr4ker-patched$' "$tmp"
if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then
    rm -f "$tmp"
    exit 9
fi
mv "$tmp" "$dst"
exit 0
PATCH
    then
        log "Wrote the patched tr4ker definition; restarting Prowlarr to load it"
        docker restart "$PROWLARR_CONTAINER" >/dev/null 2>&1 || true
        wait_for_prowlarr || return 0
    else
        status=$?
        if [ "$status" -eq 9 ]; then
            log "Patched tr4ker definition already current, skipping"
        else
            docker exec "$PROWLARR_CONTAINER" rm -f "$TR4KER_PATCHED.building" 2>/dev/null || true
            log "WARNING: could not build the patched tr4ker definition"
        fi
    fi
}

main() {
    container_is_running "$PROWLARR_CONTAINER" || { log "Prowlarr not running, skipping"; return 0; }

    KEY="$(get_api_key)"
    [ -n "$KEY" ] || { log "WARNING: could not read Prowlarr API key from config.xml"; return 0; }

    wait_for_prowlarr || return 0

    # First: it may restart Prowlarr, and the calls below want a live API.
    ensure_tr4ker_patched_definition
    ensure_download_client
    ensure_flaresolverr_proxy
    ensure_ntfy_notification
}

main "$@"
