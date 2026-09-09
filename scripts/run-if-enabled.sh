#!/bin/sh
# Gate per-service pre-start/bootstrap work on COMPOSE_PROFILES.
#
# Usage:
#   run-if-enabled.sh <service>[,<service>...] <command> [args...]
#       Exec <command> if any of the services is enabled; otherwise print a
#       short skip notice and exit 0 (so a blocking pre-start hook still passes).
#   run-if-enabled.sh <service>[,<service>...]
#       Test mode: exit 0 if enabled, 1 if disabled. Meant for systemd
#       ExecCondition, where a 1..254 exit skips the unit without failing it.
#
# A service is enabled when the comma-separated COMPOSE_PROFILES list contains
# "all" or the exact service name (no substring matching; spaces around
# entries are tolerated). A defined-but-empty value disables every optional
# service, matching what docker compose does with it (core-only). Only when
# COMPOSE_PROFILES is defined nowhere (an install predating per-service
# profiles) is everything treated as enabled.
#
# More than one service may be named, because COMPOSE_PROFILES records what was
# *asked for* while compose starts more: a service listing another's name in its
# own `profiles:` runs whenever that one does - agentgateway under open-webui,
# gluetun under qbittorrent. A hook on such a service has to name every profile
# that starts it, or it is skipped on exactly the boots that need it.
#
# When COMPOSE_PROFILES is not set in the environment (a unit without
# EnvironmentFile=, e.g. nextcloud-cron.service), it is read from the .env
# file in this script's parent directory instead.
#
# Deliberately self-contained: does NOT source lib.sh, so it stays usable
# from minimal contexts (some repo scripts are mounted into containers).

set -eu

if [ "$#" -lt 1 ]; then
    echo "Usage: $(basename "$0") <service> [command ...]" >&2
    exit 2
fi

service="$1"
shift

profiles="${COMPOSE_PROFILES-}"
defined="${COMPOSE_PROFILES+x}"

# Fallback: COMPOSE_PROFILES not exported at all -> read the project .env.
if [ -z "$defined" ]; then
    env_file="$(cd "$(dirname "$0")/.." && pwd)/.env"
    if [ -f "$env_file" ] && grep -q '^COMPOSE_PROFILES=' "$env_file"; then
        defined=x
        profiles="$(grep '^COMPOSE_PROFILES=' "$env_file" | tail -n1 | cut -d'=' -f2- | tr -d '\r')"
        # Strip optional surrounding quotes.
        case "$profiles" in
            \"*\") profiles="${profiles#\"}"; profiles="${profiles%\"}" ;;
            \'*\') profiles="${profiles#\'}"; profiles="${profiles%\'}" ;;
        esac
    fi
fi

# profile_listed <profiles> <service>: 0 if <profiles> names <service> exactly,
# or "all". Empty list -> disabled: that is what docker compose runs (core-only).
profile_listed() {
    _profiles="$1"
    _service="$2"

    set -f
    IFS=', '
    # shellcheck disable=SC2086 # intentional split on commas (and spaces)
    set -- $_profiles
    unset IFS
    set +f

    for _entry in "$@"; do
        if [ "$_entry" = "all" ] || [ "$_entry" = "$_service" ]; then
            return 0
        fi
    done
    return 1
}

# service_enabled <profiles> <service>[,<service>...]: 0 if any of them is. Its
# own loop rather than a wider IFS above, so both sides stay exact comparisons.
service_enabled() {
    _wanted="$2"

    while [ -n "$_wanted" ]; do
        if profile_listed "$1" "${_wanted%%,*}"; then
            return 0
        fi
        case "$_wanted" in
            *,*) _wanted="${_wanted#*,}" ;;
            *) _wanted="" ;;
        esac
    done
    return 1
}

# COMPOSE_PROFILES defined nowhere -> legacy install, everything enabled.
if [ -z "$defined" ] || service_enabled "$profiles" "$service"; then
    [ "$#" -gt 0 ] || exit 0
    exec "$@"
fi

[ "$#" -gt 0 ] || exit 1
echo "run-if-enabled: $service disabled (COMPOSE_PROFILES=$profiles), skipping: $*"
exit 0
