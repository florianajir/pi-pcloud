#!/bin/sh
set -eu

# Generates the shared secret the n8n task broker and its external runner
# authenticate with.
#
# The broker listens on 0.0.0.0 inside `frontend`, so this is what stops any of
# the ~25 containers there registering as a task runner and receiving the
# workflow code n8n hands out. It must never fall back to a shared default.
#
# Not derived from PASSWORD - machine-to-machine, no login behind it - so
# rotate-password.sh leaves it alone, like Comet's and ntfy's own secrets.

. "$(dirname "$0")/lib.sh"

ensure_env_secrets "${PROJECT_DIR}/config/n8n/n8n.env" N8N_RUNNERS_AUTH_TOKEN
