#!/bin/sh
# Push to ntfy when Uptime Kuma itself is unhealthy. Kuma watches every other
# container but cannot report its own failure: a wedged Kuma just goes quiet,
# and quiet reads as all green. Dockhand's container_unhealthy event used to
# cover this and was dropped because it doubled every other Kuma alert (see
# docs/MONITORING.md). Runs on the host, from pi-pcloud-kuma-watchdog.timer.
#
# One push when Docker reports the container unhealthy, restarting, or still
# starting a whole timer period later, one when it is healthy again. A container
# that is absent or stopped is left alone: that is the stack being down or
# updated, not Kuma failing.
set -eu

. "$(dirname "$0")/lib.sh"

KUMA_CONTAINER="${KUMA_CONTAINER:-pi-uptime-kuma}"
NTFY_ENV_FILE="${NTFY_ENV_FILE:-$PROJECT_DIR/config/ntfy/ntfy.env}"
# Set by the unit's StateDirectory=. The markers survive between runs, which is
# what keeps an outage to one push instead of one every five minutes.
STATE_DIR="${STATE_DIRECTORY:-/var/lib/pi-pcloud-kuma-watchdog}"
ALERTED_MARKER="$STATE_DIR/alerted"
STARTING_MARKER="$STATE_DIR/starting"

# "<status> <health>", e.g. "running unhealthy"; empty when there is no container.
kuma_state() {
    docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
        "$KUMA_CONTAINER" 2>/dev/null || true
}

# Published as Kuma's own ntfy user, to the topic its alerts go to: this stands
# in for the alert Kuma cannot send about itself.
# Usage: notify <title> <priority> <tags> <message>
notify() {
    local password=""
    local topic=""
    password="$(read_env_value_from_file "$NTFY_ENV_FILE" NTFY_UPTIME_KUMA_PASSWORD)"
    topic="$(read_env_value_from_file "$NTFY_ENV_FILE" NTFY_MONITORING_TOPIC)"
    if [ -z "$password" ]; then
        log "WARNING: NTFY_UPTIME_KUMA_PASSWORD missing from $NTFY_ENV_FILE; skipping notification"
        return 1
    fi
    ntfy_publish uptime-kuma "$password" "${topic:-monitoring}" "$1" "$2" "$3" "$4"
}

# Created before anything is published: a manual run that cannot write its
# marker would otherwise push the same outage on every run.
mkdir -p "$STATE_DIR"

state="$(kuma_state)"
# A crash loop is `starting` far more often than `restarting`: every restart
# resets the 180 s start period, so Docker never calls it unhealthy, and the
# restart backoff drops back to 100 ms once the container has run for 10 s.
# A healthy start passes a check within minutes, so `starting` on two runs in
# a row is treated as down.
if [ "$state" != "running starting" ]; then
    rm -f "$STARTING_MARKER"
elif [ ! -e "$STARTING_MARKER" ]; then
    touch "$STARTING_MARKER"
    exit 0
fi

case "$state" in
    "running unhealthy" | "running starting" | restarting*)
        [ ! -e "$ALERTED_MARKER" ] || exit 0
        # A failed publish fails the unit and leaves no marker, so the next run
        # tries again rather than the outage going unreported.
        notify "Uptime Kuma is down" high "rotating_light" \
            "Docker reports $KUMA_CONTAINER as '$state'. No other monitor can alert until it recovers." \
            || exit 1
        touch "$ALERTED_MARKER"
        ;;
    "running healthy")
        [ -e "$ALERTED_MARKER" ] || exit 0
        notify "Uptime Kuma recovered" default "white_check_mark" \
            "$KUMA_CONTAINER is healthy again; monitoring has resumed." \
            || exit 1
        rm -f "$ALERTED_MARKER"
        ;;
esac
