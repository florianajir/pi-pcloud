#!/bin/sh
# The stack's start sequence: pre-start hooks, `docker compose up -d`, then the
# bootstraps. pi-pcloud.service runs it as its ExecStart and `make update` runs
# it directly, so an update applies changes without stopping anything first and
# the two cannot drift. Takes no arguments, so neither caller can ask for a
# different start than the other.
#
# Which hooks run, and in what order, is scripts/run-hooks.sh — CI runs the same
# two phases against the stack it starts, and a list kept in both places is a
# list that only one of them maintains.
#
# Host-only, never mounted into a container, so sourcing lib.sh is fine here.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

[ "$#" -eq 0 ] || die "takes no arguments (got: $*)"

# How long await_healthy below gives the stack before it reports what is still
# down. Overridable for CI, which starts a subset and has no reason to wait the
# full boot budget. The last full boot measured 4m15s wall clock, most of it
# image-heavy services starting in parallel, so 300s is a ceiling rather than a
# target: the loop returns as soon as everything is healthy.
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-5}"
# Both reach $(( )) below, where dash reads a non-number as 0 and then treats
# the division by zero as a fatal *shell* error, not a failed command: the
# `await_healthy || true` at the call site cannot contain it, and a stack-up.sh
# that exits non-zero is a failed ExecStart - which systemd follows with
# ExecStop, `docker compose down`. A typo in an override must not do that.
case "$HEALTH_TIMEOUT" in '' | *[!0-9]*) HEALTH_TIMEOUT=300 ;; esac
case "$HEALTH_INTERVAL" in '' | *[!0-9]*) HEALTH_INTERVAL=5 ;; esac
# `0` is not the only way to spell zero, and a glob cannot say "numerically
# greater than zero": `00` passes the case above and divides just as fatally.
# The redirection is for a value too large for the shell's integers, which is
# an error here rather than a comparison.
[ "$HEALTH_INTERVAL" -gt 0 ] 2>/dev/null || HEALTH_INTERVAL=5

# In lib.sh, because changed-services.sh has to resolve the same selection.
resolve_compose_profiles

# The services this selection actually runs. `compose ps -a` below lists the
# containers of *disabled* ones too: compose leaves them behind when a profile
# stops selecting them - a profile-disabled service is not an orphan, so
# --remove-orphans does not touch it - and they sit `exited` forever. A service
# that is off is not a service that is unhealthy.
#
# Measured on the first deploy of the health report, 2026-09-15: kapowarr had
# been disabled for months and its stopped container was named in the warning
# on every single start.
#
# Empty means "could not ask", not "nothing runs", so the filter is skipped
# rather than applied - reporting a container that turns out to be disabled is
# noise, reporting none at all is the silence this whole report exists to end.
SELECTED_SERVICES="$(compose config --services 2>/dev/null | tr '\n' ' ')"

# `stremio` and `stremio-lan` are one server in two networking modes, sharing a
# single data volume and the same Traefik host rules. Compose cannot express
# mutual exclusion, so refuse the combination before anything starts. The pair
# is spelled out here rather than read from compose/compose-media.yaml's
# pi-pcloud.conflicts-with label (which is what services.sh and the picker use),
# so the boot path stays a plain string check.
profiles_have() {
    case ",$(printf '%s' "${COMPOSE_PROFILES:-}" | tr -d ' \r')," in
        *",$1,"*) return 0 ;;
    esac
    return 1
}

# "all" covers stremio and deliberately not stremio-lan, so `all,stremio-lan`
# is the same conflict spelled differently and must not slip through.
if profiles_have stremio-lan && { profiles_have stremio || profiles_have all; }; then
    die "COMPOSE_PROFILES lists both stremio and stremio-lan: same server, two networking modes, one data volume - keep only one"
fi

# `up -d` refuses when a network or volume *definition* changed: compose can
# only apply that by removing the object, which needs the stack down. Without
# the fallback an update aborts here, images pulled and host files applied.
#
# The output is captured rather than streamed: a pipeline into tee reports
# tee's status, and dash has no pipefail, so streaming would mean carrying
# compose's own status out of a subshell — and losing it there would report a
# failure that never happened, which under systemd means ExecStop tearing down
# a healthy stack.
start_containers() {
    if _out="$(compose up -d --remove-orphans 2>&1)"; then
        printf '%s\n' "$_out"
        return 0
    fi
    printf '%s\n' "$_out" >&2

    case "$_out" in
        *"has incorrect"* | *"needs to be recreated"*) ;;
        *) die "docker compose up failed" ;;
    esac

    log "A network or volume definition changed; that one needs the stack down"
    compose down --remove-orphans
    compose up -d --remove-orphans
}

# `<service> <state>` for everything compose reports as other than
# up-and-healthy. A container with no healthcheck counts as ready once it is
# running, which is the rule `compose up --wait` applies too.
#
# `-a` is load-bearing: a bare `compose ps` lists only what is running, so a
# container that started and died is not reported as unhealthy - it is not
# reported at all, and the loop below would call the stack healthy. That is the
# one failure this exists to name.
#
# The state comes out with the name because the loop needs it: `-a` also lists
# containers that are never going to move again, and those must not be waited
# on. See await_healthy.
#
# A compose that could not be answered is not a healthy stack either, so the
# failure is named rather than dropped: an empty list here reads as "everything
# is fine", and the bootstraps would then run into a daemon that is not
# answering.
unready_services() {
    if ! _ps="$(compose ps -a --format '{{.Service}} {{.State}} {{.Health}}' 2>/dev/null)"; then
        printf 'compose-ps-unavailable unknown\n'
        return 0
    fi
    printf '%s\n' "$_ps" |
        awk -v selected=" $SELECTED_SERVICES " '
            selected != "  " && index(selected, " " $1 " ") == 0 { next }
            $2 != "running" || ($3 != "" && $3 != "healthy") { print $1, $2 }
        '
}

# Give the stack a bounded chance to settle, then say what did not.
#
# Deliberately *not* `compose up -d --wait`: that makes `up` exit non-zero when
# one container is slow to pass its healthcheck, and under systemd a failed
# ExecStart is followed by ExecStop - `docker compose down`. One flaky service
# would take the whole stack down at boot. This only observes, so both callers
# still get exactly the same start, and a slow healthcheck cannot kill it.
#
# What it buys: `make update` used to print its success line with half the
# stack unhealthy, and the post-start bootstraps ran against services that were
# not answering yet. Now both say so.
await_healthy() {
    _deadline_loops=$((HEALTH_TIMEOUT / HEALTH_INTERVAL))
    _i=0
    while :; do
        _unready="$(unready_services)"
        [ -n "$_unready" ] || return 0

        # Only a container that is still moving can be waited into health. `-a`
        # also lists the ones that started and died, and `exited` is where they
        # stay: Docker restarts a crashing container through `restarting`, so
        # anything reported as exited here has either been stopped by hand or
        # given up on. Polling those costs the whole budget - 300s added to
        # every boot and every `make update`, with the bootstraps queued behind
        # it - and cannot change the answer, so report and move on.
        _settling="$(printf '%s\n' "$_unready" | awk '$2 != "exited" && $2 != "dead" { print $1 }')"
        [ -n "$_settling" ] || break
        [ "$_i" -lt "$_deadline_loops" ] || break

        sleep "$HEALTH_INTERVAL"
        _i=$((_i + 1))
    done

    log "warning: still not healthy after $((_i * HEALTH_INTERVAL))s: $(printf '%s\n' "$_unready" | awk '{ print $1 }' | tr '\n' ' ')"
    return 1
}

# --- Run ---

log "Preparing configuration..."
/bin/sh "$SCRIPT_DIR/run-hooks.sh" pre-start

log "Starting containers (only what changed is recreated)..."
start_containers

log "Waiting for the containers to report healthy..."
# Never fatal, for the reason above - the caller reads the warning, systemd does
# not act on it.
await_healthy || true

log "Running bootstraps..."
/bin/sh "$SCRIPT_DIR/run-hooks.sh" post-start

log "Stack is up"
