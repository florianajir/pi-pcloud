#!/bin/sh
# The hook sequence around `docker compose up`, and the only place it is
# declared. scripts/stack-up.sh runs both phases on boot and on `make update`,
# and CI runs the same two against the stack it starts — so neither can keep a
# list of its own and let it rot.
#
# Declared twice, CI's copy had already drifted: it started Prowlarr with no
# config.xml (the first-run wizard, not the External auth a real install gets),
# and ntfy and Uptime Kuma with no ntfy.env at all.
#
# Usage: run-hooks.sh <pre-start|post-start> [blocking|tolerant]
#
# The mode defaults to what the boot path needs, and a caller may override it:
#   pre-start   blocking - nothing should start against a half-written config
#   post-start  tolerant - these need their service answering, and a slow one
#               must not fail the boot; all are idempotent, so the next start
#               picks up whatever was missed
# CI asks for post-start blocking, because there a bootstrap that cannot finish
# is the thing under test rather than a delay to absorb.
#
# HOOKS_SKIP is a space-separated list of script names to leave out entirely,
# for a caller that cannot satisfy one at all — CI has no headscale container to
# talk to. It is not a way to quieten a hook that fails: each skip is logged, so
# a list that grew stays visible in the log it was added to hide from.
#
# An entry is "script.sh", or "service:script.sh" to gate it on that optional
# service being selected in COMPOSE_PROFILES. It may name several, comma-
# separated, for a service more than one profile starts - litellm runs whenever
# open-webui does, so its hook has to too.
#
# Host-only, never mounted into a container, so sourcing lib.sh is fine here.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

phase="${1:-}"
case "$phase" in
    pre-start) mode=blocking ;;
    post-start) mode=tolerant ;;
    *) die "usage: $(basename "$0") <pre-start|post-start> [blocking|tolerant]" ;;
esac

if [ "$#" -ge 2 ]; then
    case "$2" in
        blocking | tolerant) mode="$2" ;;
        *) die "mode must be blocking or tolerant (got: $2)" ;;
    esac
fi
[ "$#" -le 2 ] || die "takes at most two arguments (got: $*)"

# --- The sequence ---

# redis-pre-start.sh before authelia-pre-start.sh: the latter restarts Authelia
# when configuration.yml changes, and that config carries the Redis password.
PRE_START_HOOKS='
redis-pre-start.sh
authelia-pre-start.sh
headscale-pre-start.sh
backrest-pre-start.sh
ntfy-pre-start.sh
vaultwarden:vaultwarden-pre-start.sh
qbittorrent:qbittorrent-pre-start.sh
prowlarr:prowlarr-pre-start.sh
kapowarr:kapowarr-pre-start.sh
kavita:kavita-pre-start.sh
shelfmark:shelfmark-pre-start.sh
audiobookshelf:audiobookshelf-pre-start.sh
nextcloud:nextcloud-pre-start.sh
llama-cpp:llama-cpp-pre-start.sh
litellm,open-webui:litellm-pre-start.sh
agentgateway:agentgateway-pre-start.sh
stremio-lan:stremio-lan-pre-start.sh
comet:comet-pre-start.sh
n8n:n8n-pre-start.sh
'

POST_START_HOOKS='
postgres-bootstrap.sh
headscale-init.sh
beszel-agent:beszel-agent-bootstrap.sh
dockhand:dockhand-oidc-bootstrap.sh
nextcloud:nextcloud-oidc-bootstrap.sh
pihole-bootstrap.sh
qbittorrent:qbittorrent-bootstrap.sh
prowlarr:prowlarr-bootstrap.sh
kapowarr:kapowarr-bootstrap.sh
uptime-kuma:uptime-kuma-bootstrap.sh
kavita:kavita-oidc-bootstrap.sh
kavita:kavita-library-bootstrap.sh
shelfmark:shelfmark-settings-bootstrap.sh
audiobookshelf:audiobookshelf-bootstrap.sh
open-webui:open-webui-bootstrap.sh
homepage-widgets-bootstrap.sh
'

# --- Running them ---

# Both read $mode — the `-` prefix the systemd unit's Exec* lines used to carry,
# now carried by which phase a hook is in and what the caller asked for.
hook_problem() {
    [ "$mode" = tolerant ] || die "$1"
    log "warning: $1 (continuing)"
}

hook_skipped() {
    for _skip in ${HOOKS_SKIP:-}; do
        [ "$_skip" = "$1" ] || continue
        return 0
    done
    return 1
}

case "$phase" in
    pre-start) list="$PRE_START_HOOKS" ;;
    post-start) list="$POST_START_HOOKS" ;;
esac

# Word splitting on the list is the parse; no entry contains whitespace.
# shellcheck disable=SC2086
for entry in $list; do
    service=""
    script="$entry"
    case "$entry" in
        *:*)
            service="${entry%%:*}"
            script="${entry#*:}"
            ;;
    esac

    if hook_skipped "$script"; then
        log "$script skipped (HOOKS_SKIP)"
        continue
    fi

    # Gate before the script is looked at: the unit's `run-if-enabled.sh <svc>
    # <cmd>` returned 0 for a disabled service without ever reaching it.
    if [ -n "$service" ] && ! /bin/sh "$SCRIPT_DIR/run-if-enabled.sh" "$service"; then
        log "$script skipped ($service disabled)"
        continue
    fi

    if [ ! -f "$SCRIPT_DIR/$script" ]; then
        hook_problem "$script is missing"
        continue
    fi

    /bin/sh "$SCRIPT_DIR/$script" || hook_problem "$script failed"
done
