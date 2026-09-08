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

# systemd supplies COMPOSE_PROFILES (EnvironmentFile=.env, falling back to its
# own Environment=all for installs predating per-service profiles). Under make
# there is no such wrapper, so both rules are reproduced here. Empty stays
# empty: that means core-only, not everything.
if [ -z "${COMPOSE_PROFILES+x}" ]; then
    if grep -qE '^COMPOSE_PROFILES=' "$ENV_FILE" 2>/dev/null; then
        # Compose, systemd and run-if-enabled.sh all strip quotes and CR;
        # get_env_value reads verbatim. Left in, `"stremio"` would match no
        # profile while --remove-orphans deleted the optional containers.
        COMPOSE_PROFILES="$(get_env_value_clean COMPOSE_PROFILES)"
    else
        COMPOSE_PROFILES=all
    fi
    export COMPOSE_PROFILES
fi

# `stremio` and `stremio-lan` are one server in two networking modes, sharing a
# single data volume and the same Traefik host rules. Compose cannot express
# mutual exclusion, so refuse the combination before anything starts. The pair
# is spelled out here rather than read from compose.yaml's
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

# --- Run ---

log "Preparing configuration..."
/bin/sh "$SCRIPT_DIR/run-hooks.sh" pre-start

log "Starting containers (only what changed is recreated)..."
start_containers

log "Running bootstraps..."
/bin/sh "$SCRIPT_DIR/run-hooks.sh" post-start

log "Stack is up"
