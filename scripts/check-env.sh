#!/bin/sh
# `make check-env`: every required variable is set in .env, to a value Docker
# Compose's .env parser passes through unmangled.
#
# The variables arrive as arguments, from the Makefile's REQUIRED_ENV_VARS:
# install.sh reads that same list through `make print-required-vars`, so it is
# kept in one place. The reader and the safety rule come from lib.sh, which
# install.sh's prompt also calls - a second copy here would let the installer
# and this check disagree the moment either is tightened.
#
# Host-only, never mounted into a container, so sourcing lib.sh is fine here.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

[ "$#" -gt 0 ] || die "usage: $(basename "$0") <VARIABLE>..."

require_env_file

echo "🔍 Checking required .env variables..."
missing=0
for var in "$@"; do
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
