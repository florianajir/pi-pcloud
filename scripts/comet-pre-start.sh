#!/bin/sh
set -eu

# Generates the two passwords Comet's own web pages ask for.
#
# ADMIN_DASHBOARD_PASSWORD guards the admin dashboard; CONFIGURE_PAGE_PASSWORD
# guards the configuration page - the one that holds a user's debrid API key.
#
# CONFIGURE_PAGE_PASSWORD has a second job: setting it *at all* is what makes
# Comet mount every Stremio endpoint under /s/<PUBLIC_API_TOKEN>/
# (_build_stremio_api_prefix in comet/core/models.py), and that prefix is baked
# into the addon URL AIOStreams is configured with. Unsetting it moves every
# endpoint back to the root and breaks that configuration. The token is NOT
# derived from the password - it is persisted in the comet_data volume through
# PUBLIC_API_TOKEN_FILE - so rotating either password here leaves that URL valid.
#
# Nothing of Comet's is published any more: the prefix used to be what
# comet-public@docker let out to the internet, and that router is gone now that
# AIOStreams wraps Comet as a scraper over `frontend`.
#
# Neither is derived from PASSWORD: both are Comet's own login with no Authelia
# forward-auth in front, so reusing the SSO password would turn a PASSWORD leak
# into a debrid-credential leak. rotate-password.sh leaves them alone, like
# n8n's and ntfy's own secrets.

. "$(dirname "$0")/lib.sh"

ensure_env_secrets "${PROJECT_DIR}/config/comet/comet.env" \
    ADMIN_DASHBOARD_PASSWORD CONFIGURE_PAGE_PASSWORD
