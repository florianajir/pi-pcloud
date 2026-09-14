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

# In lib.sh, because changed-services.sh has to resolve the same selection.
resolve_compose_profiles

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

# Services compose reports as anything other than up-and-healthy. A container
# with no healthcheck counts as ready once it is running, which is the rule
# `compose up --wait` applies too.
unready_services() {
    compose ps --format '{{.Service}} {{.State}} {{.Health}}' 2>/dev/null |
        awk '$2 != "running" || ($3 != "" && $3 != "healthy") { print $1 }'
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
    while [ "$_i" -lt "$_deadline_loops" ]; do
        _unready="$(unready_services)"
        [ -n "$_unready" ] || return 0
        sleep "$HEALTH_INTERVAL"
        _i=$((_i + 1))
    done

    _unready="$(unready_services)"
    [ -n "$_unready" ] || return 0
    log "warning: still not healthy after ${HEALTH_TIMEOUT}s: $(printf '%s' "$_unready" | tr '\n' ' ')"
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
