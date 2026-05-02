#!/bin/bash
# Pre-start: render qBittorrent.conf from template on fresh installs.
# Writes the config only if it does not yet exist, preserving runtime edits.
# Runs as ExecStartPre before docker compose up.

set -euo pipefail

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

    if [ -f "$config_file" ]; then
        log "Config already exists at $config_file, skipping"
        return 0
    fi

    user="$(get_env_value USER)"
    [ -n "$user" ] || die "USER is not set in .env"

    allow_ip_ranges="$(get_env_value ALLOW_IP_RANGES)"
    allow_ip_ranges="${allow_ip_ranges:-127.0.0.1/32,192.168.1.0/24,100.64.0.0/10,172.30.0.0/16}"
    # qBittorrent INI format uses ", " (comma + space) as the list separator
    allow_ip_ranges_ini="$(printf '%s' "$allow_ip_ranges" | sed 's/,/, /g')"

    mkdir -p "$config_dir"

    sed \
        -e "s|__ALLOW_IP_RANGES__|$allow_ip_ranges_ini|g" \
        -e "s|__USER__|$user|g" \
        "$QB_CONFIG_TEMPLATE" > "$config_file"

    log "Rendered qBittorrent config to $config_file"
}

main "$@"
