#!/bin/sh
# Bootstrap Kavita's libraries: one per kind of content, because the library type
# decides how Kavita parses filenames and how it reads (right-to-left for manga, the
# comic parser for issues, the text reader for epub/pdf). Each reads its own
# read-only mount, declared on the kavita service in compose.yaml.
#
# Also adds every library to the OIDC default set, so accounts auto-provisioned
# through Authelia can see a library added after they first logged in.
#
# Authenticates through lib.sh's kavita_token, which means this can only run once a
# Kavita admin exists; before that it warns and skips.
#
# A post-start hook (scripts/stack-up.sh). Idempotent, best-effort: warns, never
# fails the start.

set -eu

. "$(dirname "$0")/lib.sh"

KAVITA_CONTAINER="${KAVITA_CONTAINER:-pi-kavita}"
API="http://localhost:5000/api"

# name, LibraryType, folders (container paths), FileTypeGroup ids, MetadataProvider.
# LibraryType: Manga=0, Comic=1, Book=2, Images=3, LightNovel=4, ComicVine=5.
# FileTypeGroup: Archive=1, Epub=2, Pdf=3, Images=4.
# Comics uses ComicVine because Kapowarr lays its folders out as "Series (Year)",
# which that parser reads; the provider must be one of /api/Library/metadata-providers.
# It gets a second folder for the same reason Manga does: /comics is Kapowarr's root
# folder and /comics-downloads is the qBittorrent category, for issues grabbed by hand
# when Kapowarr cannot find them. Both feed one library, so the parser and the metadata
# provider are shared and no new library id has to be added to the OIDC default set.
#
# Magazines is Comic (1) though it holds PDFs, because Kavita has no magazine type:
# issue #2578 is closed but LibraryType still ends at ComicVine. Book (2) would group
# on calibre:series, which a scanned PDF has not got, so every issue becomes its own
# series; the comic parser reads "<title> <number>" from the filename and groups them.
# Not ComicVine (5), whose parser falls back to the deepest folder name - the same
# "Volume 01" junk it already produces for Kapowarr's layout.
#
# Two things this costs, both verified on real issues:
#   - an issue must be named "<Series> <NNN>.pdf" to join its series. The folder name
#     is NOT used, so a release left as "Hackable_N59_Mars_Avril.pdf" is a series of
#     its own, and a file loose at the library root is skipped without a word.
#   - a PDF carrying an embedded /Title beats the filename, and there is no fixing
#     that from outside the file.
#
# Provider Hardcover (2) with matching off. /api/Library/metadata-providers takes a
# libraryType and offers only [4,2] for Comic - there is no "none" - and
# ComicBookRoundup (4) would resolve magazines against a comics review site.
DESIRED_LIBRARIES='[
  {"name":"Comics","type":5,"folders":["/comics","/comics-downloads"],"fileGroupTypes":[1,2,3,4],"metadataProvider":4},
  {"name":"Manga","type":0,"folders":["/manga","/manga-downloads"],"fileGroupTypes":[1,2,3,4],"metadataProvider":3},
  {"name":"Books","type":2,"folders":["/books"],"fileGroupTypes":[1,2,3],"metadataProvider":3},
  {"name":"Magazines","type":1,"folders":["/magazines"],"fileGroupTypes":[1,2,3,4],"metadataProvider":2,"allowMetadataMatching":false}
]'

kv_curl() {
    docker exec "$KAVITA_CONTAINER" curl -sS "$@"
}

# kv_post <path>; JSON body on stdin. Echoes the HTTP status code.
kv_post() {
    docker exec -i "$KAVITA_CONTAINER" curl -sS -o /dev/null -w '%{http_code}' \
        -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
        --data @- "$API/$1"
}

# The create and update endpoints take the same DTO; only "id" differs, and update
# refuses an id that does not exist. Everything not in $desired keeps Kavita's
# defaults on create, and its current value on update.
library_payload() {
    printf '%s' "$1" | jq -c --argjson id "$2" '
        {
          id: $id,
          name, type, folders, fileGroupTypes, metadataProvider,
          folderWatching: true,
          includeInDashboard: true,
          includeInSearch: true,
          manageCollections: false,
          manageReadingLists: false,
          allowScrobbling: false,
          # Per-library, defaulting to on so the three original libraries keep the
          # value they were created with. Spelt out rather than `// true`, which
          # would read an explicit false as absent and flip it back on.
          allowMetadataMatching: (if has("allowMetadataMatching") then .allowMetadataMatching else true end),
          enableMetadata: true,
          removePrefixForSortName: false,
          inheritWebLinksFromFirstChapter: false,
          defaultLanguage: "",
          excludePatterns: [""]
        }'
}

ensure_libraries() {
    local existing="" desired="" name="" current="" id="" code="" drift=""
    existing="$(kv_curl -H "Authorization: Bearer $TOKEN" "$API/Library/libraries" 2>/dev/null)"
    printf '%s' "$existing" | jq -e 'type == "array"' >/dev/null 2>&1 || {
        log "WARNING: could not list Kavita libraries; skipping"
        return 0
    }

    # One desired library per line, compact, so the loop can stay POSIX.
    printf '%s' "$DESIRED_LIBRARIES" | jq -c '.[]' | while IFS= read -r desired; do
        name="$(printf '%s' "$desired" | jq -r '.name')"
        current="$(printf '%s' "$existing" | jq -c --arg n "$name" '.[] | select(.name == $n)')"

        if [ -z "$current" ]; then
            code="$(library_payload "$desired" 0 | kv_post "Library/create")"
            case "$code" in
                20*) log "Created Kavita library '$name'" ;;
                *)   log "WARNING: creating Kavita library '$name' returned HTTP $code" ;;
            esac
            continue
        fi

        # Only the fields this script owns are compared; the folder list is compared
        # as a set so Kavita reordering it is not read as drift.
        id="$(printf '%s' "$current" | jq -r '.id')"
        drift="$(printf '%s' "$current" | jq --argjson d "$desired" '
            (.type != $d.type)
            or ((.folders | sort) != ($d.folders | sort))
            or ((.libraryFileTypes | sort) != ($d.fileGroupTypes | sort))
            or (.allowMetadataMatching != (if ($d | has("allowMetadataMatching")) then $d.allowMetadataMatching else true end))')"

        if [ "$drift" != "true" ]; then
            log "Kavita library '$name' already correct"
            continue
        fi

        code="$(library_payload "$desired" "$id" | kv_post "Library/update")"
        case "$code" in
            20*) log "Updated Kavita library '$name' (type/folders/file types)" ;;
            *)   log "WARNING: updating Kavita library '$name' returned HTTP $code" ;;
        esac
    done
}

# Auto-provisioned OIDC accounts only get the libraries listed here, and the list is
# frozen at the value it had when each library was created - so a library added later
# is invisible to them until it is added.
ensure_oidc_default_libraries() {
    local settings="" ids="" updated="" code=""
    settings="$(kv_curl -H "Authorization: Bearer $TOKEN" "$API/Settings" 2>/dev/null)"
    printf '%s' "$settings" | jq -e '.oidcConfig' >/dev/null 2>&1 || {
        log "WARNING: could not read Kavita settings; skipping OIDC default libraries"
        return 0
    }

    ids="$(kv_curl -H "Authorization: Bearer $TOKEN" "$API/Library/libraries" 2>/dev/null \
        | jq -c '[.[].id] | sort')"
    [ -n "$ids" ] || return 0

    if [ "$(printf '%s' "$settings" | jq -c --argjson i "$ids" '(.oidcConfig.defaultLibraries | sort) == $i')" = "true" ]; then
        log "OIDC default libraries already cover every library"
        return 0
    fi

    updated="$(printf '%s' "$settings" | jq -c --argjson i "$ids" '.oidcConfig.defaultLibraries = $i')"
    code="$(printf '%s' "$updated" | kv_post "Settings")"
    case "$code" in
        20*) log "OIDC default libraries set to $ids" ;;
        *)   log "WARNING: updating Kavita settings returned HTTP $code" ;;
    esac
}

main() {
    container_is_running "$KAVITA_CONTAINER" || { log "Kavita not running, skipping"; return 0; }
    wait_for_http_endpoint "http://$KAVITA_CONTAINER:5000/api/health" "Kavita HTTP API" 60 5 >/dev/null 2>&1 || true

    TOKEN="$(kavita_token "$KAVITA_CONTAINER" || true)"
    if [ -z "${TOKEN:-}" ]; then
        # Expected on a fresh install: no admin has registered yet, so no API key.
        log "WARNING: no Kavita admin API key yet; skipping library bootstrap"
        return 0
    fi

    ensure_libraries
    ensure_oidc_default_libraries
    log "Kavita library bootstrap complete"
}

main "$@"
