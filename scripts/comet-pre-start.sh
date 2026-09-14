#!/bin/sh
set -eu

# Generates the two passwords Comet's own web pages ask for.
#
# ADMIN_DASHBOARD_PASSWORD guards the admin dashboard; CONFIGURE_PAGE_PASSWORD
# guards the configuration page that mints the `/s/<token>/` URLs. Only that
# token path is internet-facing, so these are what stand between a passer-by
# and the ability to issue one.
#
# Not derived from PASSWORD - no account behind either - so
# rotate-password.sh leaves them alone, like n8n's and ntfy's own secrets.

. "$(dirname "$0")/lib.sh"

ensure_env_secrets "${PROJECT_DIR}/config/comet/comet.env" \
    ADMIN_DASHBOARD_PASSWORD CONFIGURE_PAGE_PASSWORD
