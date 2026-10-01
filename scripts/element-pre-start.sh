#!/bin/sh
# Pre-start: render Element Web's config.json from config/element/ with this
# install's hostname.
#
# The file is world-readable on purpose: Element serves it as the unprivileged
# nginx user, and it holds nothing secret - a hostname, and which parts of the
# UI are switched off.
#
# One of those is account deactivation. An account is created from LLDAP on
# its first sign-in and that localpart is then taken for good, so a person who
# deactivated theirs could never sign in again: Tuwunel refuses rather than
# invent another name (UNIQUE_ID_FALLBACKS=false in compose).
#
# Written only when the rendering changed. The container binds this single
# file, which pins an inode, so replacing it on every start would leave a
# running Element serving a deleted copy until its next recreate.
#
# A pre-start hook (scripts/run-hooks.sh). Idempotent.

set -eu

. "$(dirname "$0")/lib.sh"

TEMPLATE="$PROJECT_DIR/config/element/config.json.template"

render_config() {
    jq --arg server "$1" '
        .default_server_config = {
            "m.homeserver": {base_url: ("https://" + $server), server_name: $server}
        }
        | .permalink_prefix = ("https://" + $server)
        | .room_directory = {servers: [$server]}
    ' "$TEMPLATE"
}

main() {
    local host_name="" server="" data_dir="" config_file="" rendered=""

    host_name="$(get_env_value_clean HOST_NAME)"
    [ -n "$host_name" ] || die "HOST_NAME is not set in .env"
    server="chat.$host_name"

    data_dir="$(resolve_data_location_path)/element"
    config_file="$data_dir/config.json"
    mkdir -p "$data_dir"
    ensure_config_target_is_file "$config_file" || die "Could not restore $config_file as a file"

    rendered="$(render_config "$server")" || die "Failed to render $TEMPLATE"
    [ -n "$rendered" ] || die "Rendering $TEMPLATE produced nothing"

    if [ -f "$config_file" ] && [ "$(cat "$config_file")" = "$rendered" ]; then
        log "Element Web config already up to date"
    else
        write_file_atomic "$config_file" printf '%s\n' "$rendered" \
            || die "Failed to write $config_file"
        log "Rendered Element Web config for $server"
    fi

    # Outside the branch: write_file_atomic leaves its mktemp 0600, and an
    # unchanged file left that way by an interrupted run would otherwise never
    # become readable to the container's nginx user.
    safe_chmod 644 "$config_file"
    fix_ownership "$data_dir"
}

main "$@"
