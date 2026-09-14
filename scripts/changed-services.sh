#!/bin/sh
# Which services a range of commits obliges `make update` to recreate.
#
# `docker compose up -d` compares a container's image and its spec, never the
# *contents* of the files bind-mounted into it. So a pull that rewrites
# config/authelia/configuration.yml leaves the running Authelia reading the old
# one, and something has to say so. `make update` used to answer with
# `systemctl restart pi-pcloud.service`, whose ExecStop is `compose down`: one
# changed config file took all 46 containers down, Traefik and Postgres
# included. Measured 2026-09-14, 134 of the 258 commits in the preceding 30 days
# touched config/ or scripts/ - more than half of all updates paid that price.
#
# The mapping this needs was already in the tree, as a naming convention: 24 of
# the 28 config/ directories carry a service's name, and 47 of the 66 scripts
# are prefixed with one. Nothing here invents metadata; it reads that
# convention, and tests/compose-invariants.py fails the build when a file stops
# following it. Silence would be the dangerous outcome - a config nothing
# recreates is a config nothing reads - so every unrecognised path answers ALL.
#
# Usage: changed-services.sh <rev-a> <rev-b>
#
# Prints, one per line:
#   ALL          a change no single service owns; recreate everything
#   <service>    recreate exactly this one (already filtered to enabled ones)
# and nothing at all when no running container has to be told about the change.
#
# Host-only, never mounted into a container, so sourcing lib.sh is fine here.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

[ "$#" -eq 2 ] || die "usage: $(basename "$0") <rev-a> <rev-b>"

rev_a="$1"
rev_b="$2"

# --- deliberate exceptions, each with the reason it is not a bug -------------

# config/ subdirectories `make install-system` copies to /etc rather than
# mounting into a container: the systemd units, the sysctl drop-in and the shell
# completions. install-system runs before this and owns the daemon-reload, so
# there is no container to recreate for one.
HOST_CONFIG_DIRS='completion sysctl.d systemd'

# The machinery every hook is built on. A change to one of these can alter any
# rendered config, and the path alone cannot say which - so all of them. lib.sh
# and pilib.py are the shared libraries, run-hooks.sh owns the hook list and its
# order, run-if-enabled.sh gates them, stack-up.sh is the sequence itself.
SHARED_START_PATH='lib.sh pilib.py run-hooks.sh run-if-enabled.sh stack-up.sh'

# Mounted into backrest (compose-monitoring.yaml) but executed as a fresh
# process on every backup run, so a rewrite is picked up with nothing recreated.
# Named here rather than skipped by a rule, because by path they are exactly as
# ownerless as the SHARED_START_PATH ones above.
PER_INVOCATION='db-backup.sh sqlite-backup.sh'

# Host-side tooling: operator commands, CI helpers, and the two install-system
# steps. None is mounted into a container, none renders a file a container
# reads, so their contents changing obliges no recreate at all.
#
# rotate-password.sh and rotate-secret.sh do rewrite secrets containers read -
# but only when *run*, and they restart what they touch themselves. Editing
# their code changes nothing about a stack nobody has re-run them on.
# wan-allowlist-sync.sh is the same shape, on a timer.
#
# This list exists so those changes stop costing a full restart: without it they
# fall to the ALL fallback below, which is correct but wasteful, and they are
# common. Keeping it honest is tests/compose-invariants.py's job - it fails the
# build on any scripts/ file that is neither owned by a service nor named here.
HOST_ONLY='api-keys.sh configure-kernel-params.sh configure-swap.sh lint.sh
pg-major-upgrade.sh pi-pcloud recovery-kit.sh rotate-password.sh rotate-secret.sh
sarif-merge.py services.sh services-picker.py wan-allowlist-sync.sh'

# config/<dir> trees read by services not named after the directory, spelled
# <dir>:<service>[,<service>]. One tree, two containers: both immich services
# mount config/immich. Kept in the same greppable shape as the lists above so
# tests/compose-invariants.py can read every exception from one place.
CONFIG_DIR_ALIASES='immich:immich-server,immich-machine-learning'

# --- helpers ----------------------------------------------------------------

# in_words <needle> <space-separated list>: 0 when the list holds it exactly.
# Word splitting the list is the parse, as in run-hooks.sh; no entry holds
# whitespace, and a service name could not.
in_words() {
    # shellcheck disable=SC2086 # deliberate word splitting of the list
    for _word in $2; do
        [ "$_word" = "$1" ] && return 0
    done
    return 1
}

# The service a config/ directory belongs to, or the empty string for one no
# service reads. May name several.
#
# `if`, not `in_words ... && printf`: an AND-list is exempt from set -e, but the
# status it leaves is the one the `owners=$(...)` assignment below inherits, and
# a failed assignment is not exempt. Written the short way, this aborted the
# whole script on the first config/ directory naming no service - the case that
# has to reach the ALL answer.
config_dir_readers() {
    for _alias in $CONFIG_DIR_ALIASES; do
        case "$_alias" in
            "$1":*)
                printf '%s' "${_alias#*:}" | tr ',' ' '
                return 0
                ;;
        esac
    done
    if in_words "$1" "$KNOWN"; then printf '%s' "$1"; fi
}

# The service a script belongs to, by longest name prefixing it - the same rule
# services.sh applies to bootstrap hooks, so beszel-agent-bootstrap.py stays
# beszel-agent's and is not also read as beszel's.
script_owner() {
    _base="$1"
    _owner=""
    for _svc in $KNOWN; do
        case "$_base" in
            "$_svc"-*) [ "${#_svc}" -gt "${#_owner}" ] && _owner="$_svc" ;;
        esac
    done
    printf '%s' "$_owner"
}

# --- resolve ----------------------------------------------------------------

resolve_compose_profiles

# Ownership is resolved against every declared service, enablement against the
# selected ones. Two lists, because config/kavita belongs to kavita whether or
# not kavita is running: with one list, disabling a service would silently turn
# its config changes into ALL.
# stderr dropped: compose warns once per unset variable, and `make update` calls
# this before check-env has necessarily been satisfied. An actual failure still
# surfaces, as the empty list the guard below refuses.
KNOWN="$(COMPOSE_PROFILES=all compose config --services 2>/dev/null | tr '\n' ' ')"
ENABLED="$(compose config --services 2>/dev/null | tr '\n' ' ')"

[ -n "$KNOWN" ] || die "docker compose config --services listed nothing"

# No path in this repository contains whitespace, and git quotes one that did,
# which would then match no rule and answer ALL - the safe direction.
changed="$(git -C "$PROJECT_DIR" diff --name-only "$rev_a" "$rev_b" -- config/ scripts/)"

targets=""
for path in $changed; do
    owners=""

    case "$path" in
        config/*/*)
            _dir="${path#config/}"
            _dir="${_dir%%/*}"
            in_words "$_dir" "$HOST_CONFIG_DIRS" && continue
            owners="$(config_dir_readers "$_dir")"
            ;;
        scripts/*)
            _base="${path#scripts/}"
            case "$_base" in */*) ;; # a subdirectory of scripts/ owns nothing by name
            *)
                in_words "$_base" "$PER_INVOCATION" && continue
                in_words "$_base" "$HOST_ONLY" && continue
                in_words "$_base" "$SHARED_START_PATH" && { echo ALL; exit 0; }
                owners="$(script_owner "$_base")"
                ;;
            esac
            ;;
    esac

    # A loose file straight under config/, an unknown directory, a script whose
    # prefix names no service: all of them reach a running container in a way
    # this cannot trace, and guessing "nothing" is the one wrong answer.
    if [ -z "$owners" ]; then
        echo ALL
        exit 0
    fi

    for _owner in $owners; do
        in_words "$_owner" "$ENABLED" || continue
        targets="$targets $_owner"
    done
done

# Sorted and deduplicated: a service with both a config tree and a pre-start
# script appears twice, and `up --force-recreate a a` is an error.
[ -n "$targets" ] || exit 0
# shellcheck disable=SC2086 # deliberate word splitting, one name per line
printf '%s\n' $targets | sort -u
