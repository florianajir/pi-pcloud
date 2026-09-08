#!/bin/sh
# Pre-start: render qBittorrent.conf from template on fresh installs.
# Writes the config only if it does not yet exist, preserving runtime edits.
# A pre-start hook (scripts/stack-up.sh), so it runs before docker compose up.

set -eu

. "$(dirname "$0")/lib.sh"

QB_CONFIG_TEMPLATE="$PROJECT_DIR/config/qbittorrent/qBittorrent.conf.template"

main() {
    local data_location allow_ip_ranges user config_dir config_file

    data_location="$(get_env_value DATA_LOCATION)"
    data_location="${data_location:-./data}"
    case "$data_location" in
        /*) : ;;
        *) data_location="$PROJECT_DIR/$data_location" ;;
    esac

    config_dir="$data_location/qbittorrent/qBittorrent"
    config_file="$config_dir/qBittorrent.conf"

    # -s, not -f: an empty file left by a failed render would be accepted forever,
    # and qBittorrent then boots with no AuthSubnetWhitelist and no username.
    if [ -s "$config_file" ]; then
        log "Config already exists at $config_file, skipping"
        return 0
    fi

    user="$(get_env_value ADMIN_USER)"
    [ -n "$user" ] || die "ADMIN_USER is not set in .env"

    allow_ip_ranges="$(get_env_value ALLOW_IP_RANGES)"
    allow_ip_ranges="${allow_ip_ranges:-127.0.0.1/32,192.168.1.0/24,100.64.0.0/10,172.30.0.0/16,::1/128,fd7a:115c:a1e0::/48}"
    # qBittorrent INI format uses ", " (comma + space) as the list separator
    allow_ip_ranges_ini="$(printf '%s' "$allow_ip_ranges" | sed 's/,/, /g')"

    mkdir -p "$config_dir"

    # qBittorrent writes WebUI\Password_PBKDF2 and the ntfy bearer token back into
    # this file, so it must not be world-readable.
    sed \
        -e "s|__ALLOW_IP_RANGES__|$(sed_escape "$allow_ip_ranges_ini")|g" \
        -e "s|__USER__|$(sed_escape "$user")|g" \
        "$QB_CONFIG_TEMPLATE" | write_secret_file "$config_file" ||
        die "could not render $config_file"
    fix_ownership "$config_file"

    log "Rendered qBittorrent config to $config_file"
}

main "$@"
