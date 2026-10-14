#!/bin/sh
# Tests for scripts/uptime-kuma-watchdog.sh: one push per outage, one per
# recovery, silence while the stack is simply down, and a retry when ntfy could
# not be reached. A stub `docker` reports whatever container state a case sets
# and a stub `curl` records what would have been published, so nothing touches
# the real stack. Run with `make test`.
set -eu

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
SCRIPT="$REPO_DIR/scripts/uptime-kuma-watchdog.sh"
# Exported because the stubs below read their fixtures from it.
WORK="$(mktemp -d)"
export WORK
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

ok() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  got  [%s]\n  want [%s]\n' "$1" "$2" "$3"
    fi
}

mkdir -p "$WORK/bin" "$WORK/state"

# `docker inspect` of the ntfy container answers an address; of Kuma, the state
# in $WORK/kuma-state, or no container at all when that file is empty.
cat > "$WORK/bin/docker" <<'STUB'
#!/bin/sh
for last in "$@"; do :; done
if [ "$last" = "pi-ntfy" ]; then
    echo "172.30.0.9 "
    exit 0
fi
state="$(cat "$WORK/kuma-state")"
[ -n "$state" ] || exit 1
echo "$state"
STUB

# Records the Title header of each publish and the config read on stdin, then
# fails if the case asked it to.
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/sh
cat > "$WORK/curl-stdin"
printf '%s\n' "$*" >> "$WORK/curl-args"
while [ "$#" -gt 0 ]; do
    case "$1" in
        Title:*) printf '%s\n' "${1#Title: }" >> "$WORK/published" ;;
    esac
    shift
done
exit "$(cat "$WORK/curl-exit")"
STUB
chmod +x "$WORK/bin/docker" "$WORK/bin/curl"

printf 'NTFY_UPTIME_KUMA_PASSWORD=stub-password\nNTFY_MONITORING_TOPIC=monitoring\n' > "$WORK/ntfy.env"

# Usage: run_watchdog <docker state> [curl exit code]
# Prints the titles published by this run (empty if none) and the exit code.
run_watchdog() {
    printf '%s' "$1" > "$WORK/kuma-state"
    printf '%s' "${2:-0}" > "$WORK/curl-exit"
    : > "$WORK/published"
    status=0
    PATH="$WORK/bin:$PATH" STATE_DIRECTORY="$WORK/state" \
        NTFY_ENV_FILE="$WORK/ntfy.env" sh "$SCRIPT" 2>/dev/null || status=$?
    printf '%s|%s' "$(cat "$WORK/published")" "$status"
}

ok "a healthy Kuma publishes nothing" \
    "$(run_watchdog "running healthy")" "|0"
ok "an unhealthy Kuma publishes one alert" \
    "$(run_watchdog "running unhealthy")" "Uptime Kuma is down|0"
ok "the same outage is not published twice" \
    "$(run_watchdog "running unhealthy")" "|0"
ok "an absent container (stack down) says nothing" \
    "$(run_watchdog "")" "|0"
ok "and does not end the outage either" \
    "$(test -e "$WORK/state/alerted" && echo kept || echo cleared)" "kept"
ok "recovery publishes once" \
    "$(run_watchdog "running healthy")" "Uptime Kuma recovered|0"
ok "and only once" \
    "$(run_watchdog "running healthy")" "|0"
ok "a container stuck restarting counts as down" \
    "$(run_watchdog "restarting ")" "Uptime Kuma is down|0"
run_watchdog "running healthy" >/dev/null

ok "still starting is not an outage" \
    "$(run_watchdog "running starting")" "|0"
ok "an unreachable ntfy fails the unit" \
    "$(run_watchdog "running unhealthy" 7)" "Uptime Kuma is down|1"
ok "and leaves no marker, so the next run retries" \
    "$(run_watchdog "running unhealthy")" "Uptime Kuma is down|0"

ok "the password reaches curl on stdin" \
    "$(grep -c 'stub-password' "$WORK/curl-stdin")" "1"
ok "and never on its command line" \
    "$(grep -c 'stub-password' "$WORK/curl-args" || true)" "0"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
