#!/bin/sh
# `make check-env`: every required variable is set in .env, to a value Docker
# Compose's .env parser passes through unmangled.
#
#   check-env.sh          check the required variables
#   check-env.sh --list   print their names, for install.sh's prompts
#
# The list lives here and nowhere else: install.sh prompts for exactly what this
# check enforces. The reader and the safety rule come from lib.sh, which
# install.sh's prompt also calls - a second copy here would let the installer
# and this check disagree the moment either is tightened.
#
# Host-only, never mounted into a container, so sourcing lib.sh is fine here.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

REQUIRED_ENV_VARS='HOST_NAME TIMEZONE EMAIL ADMIN_USER PASSWORD HOST_LAN_IP
CLOUDFLARE_DNS_API_TOKEN CLOUDFLARE_ZONE_ID'

check_required_vars() {
    local var="" value="" missing=0
    require_env_file
    echo "🔍 Checking required .env variables..."
    for var in $REQUIRED_ENV_VARS; do
        value="$(read_env_value_from_file "$ENV_FILE" "$var")"
        if [ -z "$value" ]; then
            echo "  ❌ $var is not set or empty"
            missing=1
        elif ! env_value_is_safe "$value"; then
            echo "  ❌ $var $ENV_VALUE_RULES"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || exit 1
    echo "✔ Required .env variables OK"
}

case "$*" in
    "") check_required_vars ;;
    --list) printf '%s\n' $REQUIRED_ENV_VARS ;;
    *) die "usage: $(basename "$0") [--list]" ;;
esac
