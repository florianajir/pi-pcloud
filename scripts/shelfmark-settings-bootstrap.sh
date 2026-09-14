#!/bin/sh
# Configure the Shelfmark settings that live in its own config files rather than
# in its environment: the Authelia OIDC client, the proxy that puts direct
# downloads on the VPN, the Hardcover audiobook metadata provider, and the
# Anna's Archive mirror list.
# A post-start hook (scripts/stack-up.sh). Idempotent: it writes, and restarts
# Shelfmark, only when something actually differs.
#
# Shelfmark keeps each settings tab in /config/plugins/<tab>.json
# (shelfmark/core/settings_registry.py) and resolves a setting from the
# environment first, then from that file. It has no unauthenticated API to set
# them, which is the chicken-and-egg this script exists to break. Everything
# that can safely be an env var already is one, on the service in compose/compose-media.yaml;
# what lands here does so for a reason, noted per section below.

set -eu

. "$(dirname "$0")/lib.sh"

MAX_RETRIES=120
RETRY_INTERVAL=2
SHELFMARK_CONTAINER="${SHELFMARK_CONTAINER:-pi-shelfmark}"
SHELFMARK_URL_DOCKER="${SHELFMARK_URL_DOCKER:-http://pi-shelfmark:8084}"
PLUGINS_DIR="/config/plugins"
# Shelfmark's two core tabs do not get a file of their own: general and
# search_mode both live in this one (core/settings_registry.py
# _get_config_file_path). A plugins/search_mode.json looks plausible, is
# accepted by every write, and is read by nothing.
SETTINGS_FILE="/config/settings.json"
OIDC_ADMIN_GROUP="admin"
# The alias, not "gluetun": SeleniumBase rejects a proxy host with no dot in it.
GLUETUN_HTTP_PROXY="http://gluetun.docker:8888"
# Verified reachable and serving the real site on 2026-09-02. Upstream's readme
# calls out annas-archive.is as not working as a source, and annas-archive.li
# answers with a 1 KB holding page, so neither is seeded.
AA_MIRROR_URL="https://annas-archive.gl"
PUID=1000
PGID=1000

CHANGED=0

read_json() {
    # read_json <path> ; echoes the file, or {} when absent. Returns non-zero if it
    # exists but cannot be read or is not a JSON object - the caller must not
    # merge into a default in that case.
    #
    # The emptiness test has to be the shell's, not jq's: `jq -e` reports success
    # on empty input, because "no values out" is not an error to it - only a
    # parse failure is. So a missing file used to fall through as the empty
    # string, apply() then compared "" against the "" jq echoes back for it, and
    # every tab whose file did not exist yet was silently reported as already
    # current. Only tabs Shelfmark had already written were ever reconciled.
    #
    # Absent is a legitimate {} (Shelfmark has not written that tab yet), but an
    # exec that *failed* is not: treating it as {} makes the merge write back a
    # file holding only the keys this script manages, dropping the neighbours
    # (PROXY_AUTH_*, OIDC_SCOPES, SEARCH_MODE, CALIBRE_WEB_URL...).
    local raw=""
    if ! docker exec "$SHELFMARK_CONTAINER" sh -c '[ -e "$1" ]' _ "$1" 2>/dev/null; then
        printf '%s' '{}'
        return 0
    fi
    raw="$(docker exec "$SHELFMARK_CONTAINER" cat "$1")" || {
        log "ERROR: could not read $1 from $SHELFMARK_CONTAINER"
        return 1
    }
    # `type == "object"` rather than `.`: it also rejects a file holding a bare
    # array or scalar, which the merges below would fail on.
    printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1 || {
        log "ERROR: $1 in $SHELFMARK_CONTAINER is not a JSON object"
        return 1
    }
    printf '%s' "$raw"
}

write_json() {
    # write_json <path> <json> ; writes as root, then hands the file back to the
    # app's uid - docker exec runs as root while Shelfmark runs as PUID:PGID, so
    # without the chown it could read the file but never save that tab again.
    # The mkdir is belt and braces: Shelfmark creates the directory during the
    # startup this script has already waited for, but a `cat >` into a missing
    # directory would fail the whole hook, and a tolerant hook failing here
    # means no OIDC - with no password login to fall back on.
    local path="$1" body="$2" dir=""
    dir="${path%/*}"
    docker exec "$SHELFMARK_CONTAINER" sh -c \
        "mkdir -p '$dir' && chown ${PUID}:${PGID} '$dir'" \
        || return 1
    printf '%s' "$body" | docker exec -i "$SHELFMARK_CONTAINER" sh -c "cat > $path" \
        || return 1
    docker exec "$SHELFMARK_CONTAINER" sh -c \
        "chown ${PUID}:${PGID} '$path' && chmod 600 '$path'" \
        || log "WARNING: could not fix ownership of $path"
}

# tab_path <tab> ; the file that actually backs a settings tab.
tab_path() {
    case "$1" in
        general|search_mode) printf '%s' "$SETTINGS_FILE" ;;
        *)                   printf '%s/%s.json' "$PLUGINS_DIR" "$1" ;;
    esac
}

# apply <tab> <jq filter> [jq args...] ; reads the tab, applies the filter, and
# writes it back when the result differs. Sets CHANGED so one restart covers
# every tab this run touched. The filter must merge rather than replace:
# general and search_mode share one file, so a bare object would drop the
# other tab's settings.
apply() {
    local tab="$1"
    shift
    local path="" current="" desired=""
    path="$(tab_path "$tab")"

    current="$(read_json "$path")" ||
        die "Refusing to rewrite $path: its current contents could not be read"
    desired="$(printf '%s' "$current" | jq "$@")" || die "Failed to build $tab.json"

    if [ "$(printf '%s' "$current" | jq -S .)" = "$(printf '%s' "$desired" | jq -S .)" ]; then
        log "$tab settings already current"
        return 0
    fi

    write_json "$path" "$desired" || die "Failed to write $path in $SHELFMARK_CONTAINER"
    log "Updated $tab settings"
    CHANGED=1
}

# The client secret is kept out of the environment so `docker inspect` does not
# print it - see docs/SECURITY.md. DISABLE_LOCAL_AUTH stays an env var because
# Shelfmark reads it at import, before this file is ever loaded.
configure_oidc() {
    local host_name="" secret=""

    host_name="$(get_env_value HOST_NAME)"
    host_name="${host_name:-pi.lan}"

    ensure_authelia_oidc_materials "shelfmark" "Shelfmark" "$MAX_RETRIES" "$RETRY_INTERVAL" \
        || die "Shelfmark OIDC prerequisites are missing in Authelia configuration"

    secret="$(get_oidc_secret "shelfmark")" || die "Could not read Shelfmark OIDC client secret"
    [ -n "$secret" ] || die "Shelfmark OIDC client secret is empty"

    # Merged, not replaced: the tab also carries the proxy-auth and Calibre-Web
    # fields, and a user may have set unrelated ones.
    apply security \
        --arg discovery "https://auth.${host_name}/.well-known/openid-configuration" \
        --arg secret "$secret" \
        --arg group "$OIDC_ADMIN_GROUP" \
        '. + {
            AUTH_METHOD: "oidc",
            OIDC_DISCOVERY_URL: $discovery,
            OIDC_CLIENT_ID: "shelfmark",
            OIDC_CLIENT_SECRET: $secret,
            OIDC_GROUP_CLAIM: "groups",
            OIDC_ADMIN_GROUP: $group,
            OIDC_USE_ADMIN_GROUP: true,
            OIDC_AUTO_PROVISION: true
         }'
}

# Whether gluetun is part of the current selection. Asked of compose rather
# than of run-if-enabled.sh, because gluetun is usually pulled in transitively
# by qbittorrent/stremio/kapowarr and never named in COMPOSE_PROFILES itself;
# and asked of the selection rather than of the running container, so a gluetun
# that is merely down does not flip the setting back and forth.
gluetun_selected() {
    compose config --services 2>/dev/null | grep -qx gluetun
}

# Direct downloads are plain HTTPS from this container, so unlike the torrents
# they would leave on the residential IP. Routing them through gluetun's proxy
# puts them back on the tunnel.
#
# In this file rather than in `environment:` on purpose: HTTP_PROXY and NO_PROXY
# are also the names requests/urllib read straight out of the environment, so
# setting them there would silently proxy every other outbound call too - the
# Prowlarr API, the FlareSolverr hand-off, the OIDC token exchange - against a
# matcher whose syntax differs from Shelfmark's. Here they reach only the
# release-source and download paths, which are the ones that read
# download/network.py get_proxies(). Nothing else breaks when gluetun is down.
configure_proxy() {
    local host_name="" no_proxy=""

    if ! gluetun_selected; then
        # Only ever unwind our own setting: a proxy someone configured by hand
        # is theirs to keep.
        log "gluetun is not enabled; direct downloads will leave on this host's own IP"
        apply network --arg proxy "$GLUETUN_HTTP_PROXY" \
            'if .HTTP_PROXY == $proxy then . + {PROXY_MODE: "none"} else . end'
        return 0
    fi

    host_name="$(get_env_value HOST_NAME)"
    host_name="${host_name:-pi.lan}"
    # Matched with fnmatch, so the glob is the right shape here.
    no_proxy="localhost,127.0.0.1,gluetun,gluetun.docker,prowlarr,flaresolverr,ntfy,*.${host_name}"

    apply network \
        --arg proxy "$GLUETUN_HTTP_PROXY" \
        --arg noproxy "$no_proxy" \
        '. + {PROXY_MODE: "http", HTTP_PROXY: $proxy, NO_PROXY: $noproxy}'
}

# Hardcover is the only metadata provider wired here that carries audiobook
# editions. Without it METADATA_PROVIDER_AUDIOBOOK falls back to the book
# provider - Open Library, a *book* catalogue with essentially no audio edition
# data - so audiobook searches come back with paper metadata or nothing.
#
# The key is user-supplied (hardcover.app/account/api) and lives in .env beside
# the other credentials nobody can mint, like CLOUDFLARE_DNS_API_TOKEN. It is
# applied here rather than rendered into shelfmark.env for two reasons:
#
#   - it is a credential, and `environment:` values are printed by
#     `docker inspect` - the same rule that keeps the OIDC secret above out of
#     the environment;
#   - METADATA_PROVIDER_AUDIOBOOK is user_overridable, and an env value "always
#     wins" over a per-user override (core/config.py get). Setting it there
#     would freeze every account's provider choice instead of moving the
#     deployment default, which is all this is meant to do.
#
# Reconciled rather than seeded, so rotating the key in .env is picked up: the
# key being present in .env is what asks for Hardcover in the first place, and
# removing it there releases the audiobook provider again.
configure_hardcover() {
    local key=""

    key="$(get_env_value HARDCOVER_API_KEY)"
    if [ -z "$key" ]; then
        # Unwind, rather than just stop reconciling: leaving Hardcover selected
        # with a key that is no longer supplied points every audiobook search at
        # a provider that can only fail. Releasing the selection falls back to
        # the book provider, which at least answers.
        #
        # Only the selection, and only when it is still ours. The stored key is
        # left alone on purpose: unlike the proxy above there is no constant to
        # compare against, so a key pasted into Settings -> Hardcover by hand is
        # indistinguishable from one this function wrote, and clearing it would
        # destroy someone's credential. Clear it in the UI to be rid of it.
        log "HARDCOVER_API_KEY is not set in .env; releasing the audiobook metadata provider"
        apply search_mode \
            'if .METADATA_PROVIDER_AUDIOBOOK == "hardcover" then .METADATA_PROVIDER_AUDIOBOOK = "" else . end'
        return 0
    fi

    apply hardcover --arg key "$key" \
        '. + {HARDCOVER_ENABLED: true, HARDCOVER_API_KEY: $key}'

    # Only the default, and only when unset: an account that picked another
    # audiobook provider keeps it, and so does an admin who changed this one.
    apply search_mode \
        'if (.METADATA_PROVIDER_AUDIOBOOK // "") == "" then .METADATA_PROVIDER_AUDIOBOOK = "hardcover" else . end'
}

# The default search-language filter, derived from DEFAULT_LANGUAGE: Shelfmark
# filters on two-letter codes (its data/book-languages.json) while
# DEFAULT_LANGUAGE is a BCP 47 tag.
#
# Here rather than in shelfmark.env, where it used to be, because this is the
# one search setting whose own field description promises "Users can override
# this for their own account" - and an environment value wins over exactly that
# (core/config.py get checks is_value_from_env before any per-account override),
# so rendering it there silently froze the language for everyone.
#
# Seeded, never reconciled: only an unset value is filled, so changing
# DEFAULT_LANGUAGE later does not reach back and overwrite a language somebody
# chose. SEARCH_MODE, DESTINATION and DESTINATION_AUDIOBOOK stay environment
# values on purpose - the first is a deployment mode, the other two are
# container paths tied to the mounts in compose/compose-media.yaml, and a per-account
# override of those would write outside them.
seed_book_language() {
    local lang=""

    lang="$(get_env_value DEFAULT_LANGUAGE)"
    lang="${lang%%-*}"
    [ -n "$lang" ] || lang="en"
    lang="$(printf '%s' "$lang" | tr '[:upper:]' '[:lower:]')"

    apply search_mode --arg lang "$lang" \
        'if (.BOOK_LANGUAGE // []) == [] then .BOOK_LANGUAGE = [$lang] else . end'
}

# Seeded, not reconciled: mirror availability moves on its own schedule and the
# list is the user's to curate in Settings -> Mirrors. Only an empty list is
# filled, so an edited one is left alone.
seed_mirrors() {
    apply mirrors \
        --arg mirror "$AA_MIRROR_URL" \
        'if (.AA_MIRROR_URLS // []) == [] then .AA_MIRROR_URLS = [$mirror] else . end'
}

main() {
    log "=== Shelfmark Settings Bootstrap ==="

    [ -f "$ENV_FILE" ] || die ".env missing at $ENV_FILE"

    wait_for_container "$SHELFMARK_CONTAINER" "$MAX_RETRIES" "$RETRY_INTERVAL" || exit 1
    wait_for_http_endpoint "$SHELFMARK_URL_DOCKER/api/health" "Shelfmark HTTP API" "$MAX_RETRIES" "$RETRY_INTERVAL" || exit 1

    configure_oidc
    configure_proxy
    configure_hardcover
    seed_book_language
    seed_mirrors

    if [ "$CHANGED" = "0" ]; then
        log "Shelfmark settings already configured; nothing to do"
        exit 0
    fi

    log "Restarting Shelfmark to apply"
    compose restart shelfmark >/dev/null || die "Failed to restart Shelfmark"
    wait_for_http_endpoint "$SHELFMARK_URL_DOCKER/api/health" "Shelfmark HTTP API" "$MAX_RETRIES" "$RETRY_INTERVAL" || true
    log "Shelfmark settings bootstrap complete"
}

main "$@"
