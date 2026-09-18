#!/bin/sh
# Manage optional pi-pcloud services through Docker Compose profiles.
#
# Every optional service in compose/*.yaml carries a profile named after itself
# (plus the catch-all "all"); COMPOSE_PROFILES in .env selects which run. A
# missing line means everything (pre-profiles installs); an explicitly empty
# value means core-only, matching what docker compose does with it.
# Enabled-ness is computed with `docker compose config --services` under the
# current selection, which is authoritative and handles coupled profiles
# (e.g. stremio auto-enabling gluetun) for free.
#
# Subcommands:
#   list               List optional services and whether each is enabled
#   enable <service>   Add to COMPOSE_PROFILES, start it, run its init hooks
#   disable <service>  Remove from COMPOSE_PROFILES, stop and remove it
#   config             Interactive picker (scripts/services-picker.py)
#   pick               Same picker, printing the chosen COMPOSE_PROFILES value
#                      instead of applying it (used by install.sh)
#   names              The optional service names, one per line (completion)
#
# enable (and config, for newly-enabled services) runs the same per-service
# hooks the systemd unit runs around `docker compose up`:
#   scripts/<svc>-pre-start.sh                      before starting
#   scripts/<svc>-*bootstrap.{sh,py}                after starting
# Hooks are found by filename convention, never hardcoded, so future services
# get theirs automatically. Post hooks tolerate failure, like the systemd
# unit's `-` prefix does.
#
# DRY_RUN=1 prints the docker/hook commands and the would-be .env line
# instead of executing/writing anything. ENV_FILE=<path> (honored by lib.sh)
# points at another env file, mainly for tests; the effective selection is
# always passed to `docker compose up` explicitly so it never depends on
# which .env compose happens to read.
#
# Host-only: this script is never mounted into containers, so sourcing
# lib.sh is fine here (scripts that backrest mounts must not source it).

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

# --- Helpers ---

is_dry_run() { [ "${DRY_RUN:-0}" = "1" ]; }

require_env_file() {
    if [ ! -f "$ENV_FILE" ]; then
        echo "❌ .env missing (copy .env.dist)" >&2
        exit 1
    fi
}

has_profiles_line() {
    grep -qE '^COMPOSE_PROFILES=' "$ENV_FILE"
}

# Every declared profile except the catch-all "all", one per line, sorted.
known_profiles() {
    compose config --profiles | grep -v '^all$' | sort
}

# Services docker compose would run under the given selection.
services_for_profiles() {
    (cd "$PROJECT_DIR" && COMPOSE_PROFILES="$1" docker compose config --services)
}

# in_lines <newline-list> <item>: 0 if <item> is an exact line of the list.
in_lines() {
    printf '%s\n' "$1" | grep -qx "$2"
}

# 0 if the comma-separated selection lists <name> exactly. \r is stripped along
# with spaces, as in stack-up.sh: a .env edited from Windows over Samba ends its
# COMPOSE_PROFILES line with one, and the guards below have to see through it.
selection_has() {
    case ",$(printf '%s' "$1" | tr -d ' \r')," in
        *",$2,"*) return 0 ;;
    esac
    return 1
}

# The profiles the catch-all "all" stands for, one per line: every profile named
# alongside "all" in a `profiles:` list. Read straight out of compose/*.yaml (no
# docker call, and no pipeline that could swallow its failure), because a
# profile deliberately left out of "all" — stremio-lan — must never be
# treated as covered by it.
profiles_covered_by_all() {
    awk '
        /^[ \t]+profiles:/ {
            list = $0
            sub(/^[^[]*\[/, "", list)
            sub(/\].*$/, "", list)
            gsub(/["\t ]/, "", list)
            if (list ~ /(^|,)all(,|$)/) {
                n = split(list, part, ",")
                for (i = 1; i <= n; i++)
                    if (part[i] != "" && part[i] != "all") print part[i]
            }
        }
    ' "$PROJECT_DIR"/compose/*.yaml | sort -u
}

# 0 if the selection would actually run <name>: listed by name, or covered by
# the catch-all "all". Not the same as selection_has: "all,stremio-lan" lists
# stremio nowhere yet runs it.
selection_runs() {
    selection_has "$1" "$2" && return 0
    selection_has "$1" all || return 1
    in_lines "$(profiles_covered_by_all)" "$2"
}

# The members of a newline-separated profile list that "all" covers.
covered_by_all() {
    _covered="$(profiles_covered_by_all)"
    printf '%s\n' "$1" | while read -r _profile; do
        if in_lines "$_covered" "$_profile"; then printf '%s\n' "$_profile"; fi
    done
}

# "all" written out as the explicit list it stands for, from <known-profiles>.
# Expanding to *every* known profile instead would pull in the ones deliberately
# outside "all" (stremio-lan) and produce a selection that contradicts itself.
explicit_all() {
    covered_by_all "$1" | paste -sd, -
}

# The profiles <name> can never run alongside, space-separated (empty for the
# services that conflict with nothing, which is nearly all of them).
conflicts_of() {
    config_rows | awk -F: -v svc="$1" '$1 == svc { print $5 }'
}

# "<a> <b>" per line: two profiles that must never be selected together, from
# the pi-pcloud.conflicts-with labels in compose/*.yaml. Each pair once, ordered,
# since config_rows reports the relation on both sides.
exclusive_pairs() {
    config_rows | awk -F: '
        $5 != "" {
            n = split($5, other, " ")
            for (i = 1; i <= n; i++) if ($1 < other[i]) print $1, other[i]
        }'
}

# Refuse a selection that would run both halves of a mutually exclusive pair.
# Checked wherever a value is produced, not in stack-up.sh alone, so a bad pick
# never reaches .env and leaves the stack unable to start (see
# docs/CONFIGURATION.md).
check_exclusive() {
    _selection="$1"
    _rc=0
    while read -r _a _b; do
        [ -n "$_a" ] || continue
        selection_runs "$_selection" "$_a" || continue
        selection_runs "$_selection" "$_b" || continue
        echo "❌ $_a and $_b cannot both run: one server in two networking modes," >&2
        echo "   sharing a data volume and the same Traefik host rules. Keep one." >&2
        _rc=1
    done <<EOF
$(exclusive_pairs)
EOF
    return "$_rc"
}

# Shared with rollback_profiles below, so restoring a value cannot drift from
# writing one.
put_profiles_line() {
    if has_profiles_line; then
        sed -i "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=$(sed_escape "$1")|" "$ENV_FILE"
    else
        printf 'COMPOSE_PROFILES=%s\n' "$1" >> "$ENV_FILE"
    fi
}

# Rewrite (or append) the COMPOSE_PROFILES line. Dry mode prints instead.
write_profiles() {
    check_exclusive "$1" || return 1
    if is_dry_run; then
        echo "DRY-RUN: would write to $ENV_FILE: COMPOSE_PROFILES=$1"
        return 0
    fi
    put_profiles_line "$1"
    echo "✏️  Updated COMPOSE_PROFILES in $(basename "$ENV_FILE")"
}

# COMPOSE_PROFILES is written before the hooks run, because a hook may ask
# whether a service is enabled and run-if-enabled.sh reads that from .env. A
# failure after the write therefore leaves the line claiming a service that was
# never started - and since enabled-ness is read back from .env, the next
# `make config` sees nothing left to do. Armed before the write, disarmed once
# the containers are up.
#
# "absent:" is not "value:": no COMPOSE_PROFILES line at all means everything
# enabled (a pre-profiles install), which an empty line does not.
_profiles_backup=""

arm_profiles_rollback() {
    if is_dry_run; then return 0; fi
    if has_profiles_line; then
        _profiles_backup="value:$(get_env_value_clean COMPOSE_PROFILES)"
    else
        _profiles_backup="absent:"
    fi
    trap 'rollback_profiles' EXIT INT TERM
}

disarm_profiles_rollback() {
    _profiles_backup=""
    trap - EXIT INT TERM
}

rollback_profiles() {
    _rc="$?"
    trap - EXIT INT TERM
    [ -n "$_profiles_backup" ] || exit "$_rc"
    # A signal caught between two commands leaves $? at the last one's status,
    # usually 0 - and exiting 0 from a run that just undid its own .env write
    # reports the enable as done. Reaching here at all means it was not.
    [ "$_rc" -ne 0 ] || _rc=1
    case "$_profiles_backup" in
        absent:)
            sed -i '/^COMPOSE_PROFILES=/d' "$ENV_FILE"
            ;;
        value:*)
            put_profiles_line "${_profiles_backup#value:}"
            ;;
    esac
    _profiles_backup=""
    echo "↩️  Restored the previous COMPOSE_PROFILES in $(basename "$ENV_FILE")" >&2
    exit "$_rc"
}

# Mutating docker compose command. Dry mode prints instead.
run_compose() {
    if is_dry_run; then
        echo "DRY-RUN: docker compose $*"
    else
        compose "$@"
    fi
}

# Same, with the output held back and replayed only if the command fails:
# `stop` and `rm` each draw a progress block and `rm` announces every container
# it is about to remove, which repeats what we just printed ourselves.
run_compose_quiet() {
    if is_dry_run; then
        echo "DRY-RUN: docker compose $*"
        return 0
    fi
    _out="$(compose "$@" 2>&1)" || {
        printf '%s\n' "$_out" >&2
        return 1
    }
}

# `docker compose up` with the selection passed explicitly, so the started
# set never depends on which .env compose reads. Dry mode prints instead.
run_compose_up_with() {
    _sel="$1"
    shift
    if is_dry_run; then
        echo "DRY-RUN: COMPOSE_PROFILES=$_sel docker compose $*"
    else
        (cd "$PROJECT_DIR" && COMPOSE_PROFILES="$_sel" docker compose "$@")
    fi
}

# Elevated, because every other caller of these hooks is root: the systemd unit
# runs them through run-hooks.sh, so what they write under DATA_LOCATION is
# root-owned. Unprivileged, authelia-pre-start.sh fails on its first line -
# "mktemp: cannot create .../secrets/jwt_secret.XXXXXX: Permission denied".
# $SUDO is empty when already root (a root-only image often ships no sudo).
#
# Through `env`, because sudo resets the environment: a hook re-deriving
# PROJECT_DIR and ENV_FILE from its own path would ignore the ENV_FILE this run
# was given. Used unelevated too, so both paths run the identical command -
# which is also what makes hook_command's dry-run print honest.
hook_command() {
    printf '%senv PROJECT_DIR=%s ENV_FILE=%s %s %s' \
        "${SUDO:+$SUDO }" "$PROJECT_DIR" "$ENV_FILE" "$(script_interpreter "$1")" "$1"
}

run_hook_script() {
    $SUDO env "PROJECT_DIR=$PROJECT_DIR" "ENV_FILE=$ENV_FILE" \
        "$(script_interpreter "$1")" "$1"
}

# Run scripts/<name> if it exists, under the interpreter its extension calls
# for; tolerate failure like the systemd unit's `-` prefix does. Dry mode prints
# instead.
run_hook() {
    _hook="$PROJECT_DIR/scripts/$1"
    [ -f "$_hook" ] || return 0
    if is_dry_run; then
        echo "DRY-RUN: $(hook_command "$_hook")"
        return 0
    fi
    log "Running hook $1..."
    run_hook_script "$_hook" || log "warning: hook $1 failed (continuing)"
}

# Same, for the pre-start hooks: a failure there stops the start, exactly as it
# does in stack-up.sh's blocking list. They exist to refuse a half-written
# configuration (stremio-lan-pre-start.sh checks STREMIO_IP against the LAN
# subnet), so continuing past one only trades their message for a cryptic one
# out of `docker compose up`.
run_pre_start_hook() {
    _hook="$PROJECT_DIR/scripts/$1"
    [ -f "$_hook" ] || return 0
    if is_dry_run; then
        echo "DRY-RUN: $(hook_command "$_hook")"
        return 0
    fi
    log "Running hook $1..."
    run_hook_script "$_hook" || die "hook $1 failed; nothing was started"
}

# Hooks that belong to an always-on service but write files a *newly enabled*
# one needs. Only `$svc-pre-start.sh` used to run on enable, and every OIDC
# client secret is written by authelia-pre-start.sh rather than by the client's
# own hook - so `make enable s=grafana` on a running stack left
# authelia-config/secrets/oidc_grafana_secret.txt missing, Docker created a
# *directory* at that single-file bind mount's source, and Grafana crash-looped
# on "expanding auth.generic_oauth.client_secret ... is a directory" until the
# directory was removed by hand. Grafana is the one that fails loudly (it mounts
# the secret); the others just fail to authenticate.
#
# Cheap to run unconditionally: the hook compares the rendered configuration.yml
# before writing it, so enabling a service that is not an OIDC client changes
# nothing and Authelia is not restarted. Redis's hook is deliberately not here -
# it is core, so its password file exists by the time anything can be enabled.
run_shared_pre_start_hooks() {
    run_pre_start_hook authelia-pre-start.sh
}

# Every scripts/<svc>-*bootstrap.{sh,py}, matching run-hooks.sh's
# POST_START_HOOKS. Two exact names used to be hardcoded here, which missed the
# -settings- and -library- ones and left those services half-configured.
#
# A script belongs to the longest service name prefixing it, so
# beszel-agent-bootstrap.py stays beszel-agent's and is not also run for beszel.
#
# A .py beside a .sh of the same stem is the wrapper case (kapowarr's runs
# inside the container, uptime-kuma's in a throwaway one): the .sh is the entry
# point and running the .py here as well would run it twice, on the host, where
# it cannot reach what it configures.
run_post_start_hooks() {
    _svc="$1"
    _known="$2"
    for _hook in "$PROJECT_DIR/scripts/$_svc"-*bootstrap.sh "$PROJECT_DIR/scripts/$_svc"-*bootstrap.py; do
        [ -f "$_hook" ] || continue
        case "$_hook" in
            *.py) [ -f "${_hook%.py}.sh" ] && continue ;;
        esac
        _base="${_hook##*/}"
        _owner="$_svc"
        for _other in $_known; do
            case "$_base" in
                "$_other"-*)
                    [ "${#_other}" -gt "${#_owner}" ] && _owner="$_other"
                    ;;
            esac
        done
        [ "$_owner" = "$_svc" ] || continue
        run_hook "$_base"
    done
}

# Validate the service argument; on failure print usage plus the valid list.
validate_service() {
    _svc="$1"
    _cmd="$2"
    _known="$3"
    if [ -z "$_svc" ]; then
        echo "❌ Usage: pi-pcloud $_cmd <service> (or make $_cmd <service>). Valid services:" >&2
        printf '%s\n' "$_known" | sed 's/^/  - /' >&2
        exit 1
    fi
    if ! in_lines "$_known" "$_svc"; then
        echo "❌ Unknown service '$_svc'. Valid services:" >&2
        printf '%s\n' "$_known" | sed 's/^/  - /' >&2
        exit 1
    fi
}

# --- Checklist layout ---

# One record per service in compose/*.yaml, pipe-separated, in the order the
# files are read:
#   <section>|<root>|<child>|<name>|<companion-of>|<needs>|<description>|
#   <conflicts-with>|<ram-mib>|<optional>
# config_rows below turns the optional ones into the picker's rows;
# always_on_ram_mib sums the rest. Everything comes out of compose/*.yaml, so
# neither can drift from the stack:
#   homepage.group=            the section the service is listed under
#   pi-pcloud.companion-of=    the service it is pointless without, which is
#                              what the picker draws it indented beneath
#   pi-pcloud.conflicts-with=  a service it can never run alongside (stremio /
#                              stremio-lan: one server, two networking modes,
#                              one data volume). Stated once, reported on both
#                              sides, space-separated if there is ever more
#                              than one
#   homepage.description=      the one-line description shown beside it
#   profiles:                  a service listing others in its own profile list
#                              is a dependency they cannot run without (gluetun
#                              for the containers sharing its network
#                              namespace), reported as <needs>. A service with
#                              no profiles list at all is core: it runs whatever
#                              the selection says, which is <optional>=0
#   mem_limit:                 the memory ceiling, in MiB, shown beside the
#                              service and summed into the picker's header
# The companion and the profile list are different relations on purpose:
# qbittorrent needs gluetun but is a service in its own right, listed under
# Download, while comet only makes sense under stremio. Both propagate when a
# box is toggled; only companion-of nests. A service with no section label
# borrows its companion, else "Other".
compose_rows() {
    awk '
        function mib(line,   value) {
            value = line
            sub(/^[^:]*:[ \t]*/, "", value)
            sub(/[ \t].*$/, "", value)
            gsub(/"/, "", value)
            if (value ~ /[gG]$/) return int((value + 0) * 1024)
            if (value ~ /[mM]$/) return int(value + 0)
            if (value ~ /[kK]$/) return int((value + 0) / 1024)
            return int((value + 0) / 1048576)
        }
        /^services:[ \t]*$/ { in_services = 1; next }
        /^[A-Za-z0-9_-]+:/ {
            if (in_services) collect()
            in_services = 0
            # A top-level x- block can hold a mem_limit that services pick up
            # through a merge key (x-stremio-common is the only one today, and
            # it is where both stremio modes get their ceiling), so the anchors
            # are read on the way past.
            anchor = ""
            if ($0 ~ /&[A-Za-z0-9_-]+/) {
                anchor = $0
                sub(/^[^&]*&/, "", anchor)
                sub(/[^A-Za-z0-9_-].*$/, "", anchor)
            }
            next
        }
        !in_services {
            if (anchor != "" && $0 ~ /^[ \t]+mem_limit:/) anchor_mem[anchor] = mib($0)
            next
        }
        /^  [A-Za-z0-9_-]+:[ \t]*$/ {
            collect()
            svc = $0
            gsub(/[ :]/, "", svc)
            next
        }
        /^[ \t]+profiles:/ { profiles = $0; next }
        /^[ \t]+mem_limit:/ { mem = mib($0); next }
        /^[ \t]+<<:[ \t]*\*/ {
            merge = $0
            sub(/^[^*]*\*/, "", merge)
            sub(/[^A-Za-z0-9_-].*$/, "", merge)
            merged = merged " " merge
            next
        }
        /homepage\.group=/ {
            group = $0
            sub(/.*homepage\.group=/, "", group)
            sub(/"[ \t]*$/, "", group)
            next
        }
        /homepage\.description=/ {
            desc = $0
            sub(/.*homepage\.description=/, "", desc)
            sub(/"[ \t]*$/, "", desc)
            gsub(/\|/, "/", desc)
            next
        }
        /pi-pcloud\.companion-of=/ {
            companion = $0
            sub(/.*pi-pcloud\.companion-of=/, "", companion)
            sub(/"[ \t]*$/, "", companion)
            next
        }
        /pi-pcloud\.conflicts-with=/ {
            conflict = $0
            sub(/.*pi-pcloud\.conflicts-with=/, "", conflict)
            sub(/"[ \t]*$/, "", conflict)
            next
        }
        END {
            collect()
            for (i = 1; i <= n; i++) {
                cnt = split(prof[i], part, ",")
                for (j = 1; j <= cnt; j++)
                    if (part[j] != "" && part[j] != "all" && part[j] != name[i])
                        needs[part[j]] = needs[part[j]] " " name[i]
            }
            # One label states the pair; both sides carry it from here, so
            # nothing downstream has to know which of the two declared it.
            for (i = 1; i <= n; i++) {
                cnt = split(confl[i], part, " ")
                for (j = 1; j <= cnt; j++) {
                    excl[name[i]] = excl[name[i]] " " part[j]
                    excl[part[j]] = excl[part[j]] " " name[i]
                }
            }
            for (i = 1; i <= n; i++) {
                g = grp[i]
                if (g == "" && comp[i] != "")
                    for (k = 1; k <= n; k++)
                        if (name[k] == comp[i] && grp[k] != "") g = grp[k]
                if (g == "") g = "Other"
                section[name[i]] = g
            }
            for (i = 1; i <= n; i++) {
                root = comp[i] != "" ? comp[i] : name[i]
                child = comp[i] != "" ? 1 : 0
                sub(/^ /, "", needs[name[i]])
                sub(/^ /, "", excl[name[i]])
                # A sidecar carries no dashboard description of its own; saying
                # what it runs with beats an empty column.
                text = info[i] != "" ? info[i] : (comp[i] != "" ? "runs with " comp[i] : "")
                printf "%s|%s|%d|%s|%s|%s|%s|%s|%d|%d\n", section[name[i]], root, child, name[i], comp[i], needs[name[i]], text, excl[name[i]], ram[i], optional[i]
            }
        }
        function collect(   i, cnt, part) {
            if (svc != "") {
                # Own ceiling first, then whatever a merge key brought in: a
                # service overriding the anchor keeps its own number.
                if (mem == 0) {
                    cnt = split(merged, part, " ")
                    for (i = 1; i <= cnt; i++)
                        if (part[i] in anchor_mem) mem = anchor_mem[part[i]]
                }
                n++
                name[n] = svc
                grp[n] = group
                comp[n] = companion
                info[n] = desc
                ram[n] = mem
                p = profiles
                sub(/^[^[]*\[/, "", p)
                sub(/\].*$/, "", p)
                gsub(/["\t ]/, "", p)
                prof[n] = p
                optional[n] = profiles != "" ? 1 : 0
                confl[n] = conflict
            }
            svc = ""; profiles = ""; group = ""; companion = ""; desc = ""; conflict = ""
            mem = 0; merged = ""
        }
    ' "$PROJECT_DIR"/compose/*.yaml
}

# One row per optional service, as
# "<service>:<section>:<companion-of>:<needs>:<conflicts-with>:<ram-mib>:<description>"
# (description last, so a colon inside it survives), ordered by section.
# Sorting goes through sort(1) because mawk has no asort. Fields are
# colon-separated, not tab-separated: `read` folds runs of IFS whitespace, which
# would swallow the empty fields a row carries.
config_rows() {
    compose_rows \
        | awk -F'|' '$10 == 1' \
        | sort -t'|' -k1,1 -k2,2 -k3,3n -k4,4 \
        | awk -F'|' '{ printf "%s:%s:%s:%s:%s:%s:%s\n", $4, ($3 == 0 ? $1 : ""), $5, $6, $8, $9, $7 }'
}

# The ceilings of the services the picker never lists, because they run whatever
# it is told: Traefik, Authelia, Postgres, Pi-hole and the rest. Counted into
# every total, since they are what the optional ones are picked on top of.
always_on_ram_mib() {
    compose_rows | awk -F'|' '$10 == 0 { total += $9 } END { print total + 0 }'
}

# Host RAM in MiB, 0 when it cannot be read (no /proc, another kernel).
host_ram_mib() {
    awk '/^MemTotal:/ { printf "%d\n", $2 / 1024; exit }' /proc/meminfo 2>/dev/null || echo 0
}

# One line on what a selection can take at worst: the mem_limit ceilings of
# everything it runs, always-on services included, against the RAM of this host.
#
# Ceilings, not usage, and the difference is the whole point of the wording. The
# stack ships overcommitted on purpose (docs/ARCHITECTURE.md, "Rationing CPU and
# memory"): the reference 16 GB host carries the full stack at 2.3x its RAM and
# sits near 20% of the ceilings at idle, because a limit is what a service may
# take when it misbehaves, not what it holds. So the warning is not at 1x, which
# any interesting selection crosses on a Pi, but past RAM_RATIO_WARN - more
# ceiling than the machine the stack was tuned for was ever asked to carry.
RAM_RATIO_WARN=2.5

ram_note() {
    _picked_ram="$(config_rows | awk -F: -v list="$1" '
        BEGIN { n = split(list, part, "\n"); for (i = 1; i <= n; i++) on[part[i]] = 1 }
        $1 in on { total += $6 }
        END { print total + 0 }')"
    # LC_ALL=C: awk formats %.1f through the locale, and a fr_FR host would
    # print "2,3x" where the picker beside it prints "2.3x".
    LC_ALL=C awk -v picked="$_picked_ram" -v core="$(always_on_ram_mib)" \
        -v ram="$(host_ram_mib)" -v warn="$RAM_RATIO_WARN" '
        function human(mib) {
            return mib >= 1024 ? sprintf("%.1fG", mib / 1024) : sprintf("%dM", mib)
        }
        BEGIN {
            total = picked + core
            if (ram <= 0) {
                printf "🧠 RAM ceilings %s (always-on core included)\n", human(total)
                exit
            }
            printf "🧠 RAM ceilings %s of %s RAM — %.1fx (always-on core included)\n",
                human(total), human(ram), total / ram
            if (total / ram <= warn) exit
            printf "⚠️  More ceiling than this host was built to carry. Untick a heavy\n"
            printf "   service (make config) or expect swapping when several peak together.\n"
        }'
}

# Runs the picker over the current selection and prints the COMPOSE_PROFILES
# value it produced (empty means core services only). Status: 0 printed,
# 1 cancelled, 2 no picker available here. Shared with install.sh through the
# `pick` subcommand, so a fresh install and `make config` offer the same list,
# nesting and linked toggling.
pick_profiles() {
    _enabled="$1"
    # A terminal must exist, but it need not be our stdin or stdout: the value
    # travels through this function's stdout (install.sh captures it) and the
    # installer itself may be running from `curl | sh`, where stdin is the
    # script. The picker is wired to /dev/tty for both directions below.
    { true </dev/tty; } 2>/dev/null || return 2
    command -v python3 >/dev/null 2>&1 || return 2

    # The picker only chooses: it reads
    # "service:section:parent:needs:conflicts:ram:state:description" rows and
    # writes back the services that stay ticked. Files, not a pipe, because it
    # takes over the terminal (see scripts/services-picker.py). The always-on
    # ceilings go with them, since the picker lists none of those services and
    # they are what the selection is stacked on top of.
    _rows="$(mktemp)"
    _picked="$(mktemp)"
    _known="$(known_profiles)"
    while IFS=: read -r _svc _section _parent _needs _conflicts _ram _desc; do
        [ -n "$_svc" ] || continue
        in_lines "$_known" "$_svc" || continue
        if in_lines "$_enabled" "$_svc"; then
            _state=on
        else
            _state=off
        fi
        printf '%s:%s:%s:%s:%s:%s:%s:%s\n' \
            "$_svc" "$_section" "$_parent" "$_needs" "$_conflicts" "$_ram" "$_state" "$_desc" >>"$_rows"
    done <<EOF
$(config_rows)
EOF
    if [ ! -s "$_rows" ]; then
        rm -f "$_rows" "$_picked"
        echo "❌ No optional services declared in compose/*.yaml" >&2
        return 2
    fi
    if ! python3 "$PROJECT_DIR/scripts/services-picker.py" "$_rows" "$_picked" \
        "$(always_on_ram_mib)" </dev/tty >/dev/tty; then
        rm -f "$_rows" "$_picked"
        return 1
    fi
    _selection="$(sort -u "$_picked")"
    rm -f "$_rows" "$_picked"

    # Everything ticked is written as "all", so a service added by a later
    # update is enabled too instead of silently missing from an explicit list.
    # Compared against the profiles "all" actually covers, not every declared
    # one: a profile deliberately outside it (stremio-lan) must stay explicit,
    # otherwise ticking it would collapse to "all" and silently not run it.
    _known_in_all="$(covered_by_all "$_known")"
    if [ "$(printf '%s\n' "$_selection" | grep -v '^$' | sort)" = "$_known_in_all" ]; then
        echo all
    else
        printf '%s\n' "$_selection" | grep -v '^$' | paste -sd, - || true
    fi
}

# The tick state a picker run should start from: what is enabled today.
current_enabled() {
    if has_profiles_line; then
        services_for_profiles "$(get_env_value_clean COMPOSE_PROFILES)"
    else
        services_for_profiles all
    fi
}

# --- Subcommands ---

cmd_list() {
    require_env_file
    if has_profiles_line; then
        profiles="$(get_env_value_clean COMPOSE_PROFILES)"
        echo "🧩 Optional services (COMPOSE_PROFILES=${profiles:-<empty: core only>})"
    else
        profiles=all
        echo "🧩 Optional services (no COMPOSE_PROFILES line in .env = all)"
    fi
    known="$(known_profiles)"
    enabled="$(services_for_profiles "$profiles")"
    for svc in $known; do
        if in_lines "$enabled" "$svc"; then
            printf '  ✅ %s enabled\n' "$svc"
        else
            printf '  ⛔ %s disabled\n' "$svc"
        fi
    done
    ram_note "$enabled"
}

cmd_enable() {
    svc="${1:-}"
    require_env_file
    known="$(known_profiles)"
    validate_service "$svc" enable "$known"
    # Captured before the write, to diff the *effective* service sets below.
    was_enabled="$(current_enabled)"
    if has_profiles_line; then
        current="$(get_env_value_clean COMPOSE_PROFILES)"
    else
        echo "ℹ️  No COMPOSE_PROFILES line in .env (= everything enabled): writing the explicit list first"
        current="$(explicit_all "$known")"
    fi
    # A profile "all" does not cover (stremio-lan) is not already enabled by it,
    # and cannot be added to the literal "all" either: write out the list it
    # stands for, so the addition is expressible at all.
    if [ "$current" = "all" ] && ! selection_runs all "$svc"; then
        echo "ℹ️  COMPOSE_PROFILES=all does not cover $svc: writing the explicit list first"
        current="$(explicit_all "$known")"
    fi
    if [ "$current" = "all" ]; then
        echo "ℹ️  COMPOSE_PROFILES=all: every service is already enabled"
        new="all"
    else
        case ",$current," in
            ",,") new="$svc" ;;
            *",$svc,"*) new="$current"; echo "ℹ️  $svc already in COMPOSE_PROFILES" ;;
            *) new="$current,$svc" ;;
        esac
        # Before the hooks and the container, not after: enabling one half of a
        # mutually exclusive pair has to stop here, with the counterpart named.
        if ! check_exclusive "$new"; then
            for other in $(conflicts_of "$svc"); do
                if selection_runs "$current" "$other"; then
                    echo "   Run 'make disable s=$other' first, then enable $svc." >&2
                fi
            done
            exit 1
        fi
        arm_profiles_rollback
        write_profiles "$new"
    fi

    # Compose starts more than the service named: one that carries this one's
    # profile comes with it - agentgateway under open-webui, gluetun under
    # qbittorrent - and its hooks have to run too, since agentgateway's is what
    # writes the keys its entrypoint reads. Diffing the effective sets is what
    # cmd_config already does; asking for `$svc-pre-start.sh` alone left the
    # dependency unconfigured while reporting success.
    new_enabled="$(services_for_profiles "$new")"
    newly_on=""
    for _svc in $new_enabled; do
        in_lines "$was_enabled" "$_svc" || newly_on="$newly_on $_svc"
    done
    # Already running, so nothing is new: re-run the named service's own hooks
    # rather than silently doing nothing.
    [ -n "$newly_on" ] || newly_on=" $svc"

    run_shared_pre_start_hooks
    for _svc in $newly_on; do
        run_pre_start_hook "$_svc-pre-start.sh"
    done
    echo "🚀 Starting$newly_on..."
    # shellcheck disable=SC2086 # service names, split on purpose
    run_compose_up_with "$new" up -d $newly_on
    disarm_profiles_rollback
    for _svc in $newly_on; do
        run_post_start_hooks "$_svc" "$known"
    done
    echo "✅ $svc enabled"
    ram_note "$new_enabled"
}

cmd_disable() {
    svc="${1:-}"
    require_env_file
    known="$(known_profiles)"
    validate_service "$svc" disable "$known"
    if has_profiles_line; then
        current="$(get_env_value_clean COMPOSE_PROFILES)"
    else
        current=all
    fi
    if [ "$current" = "all" ]; then
        echo "ℹ️  COMPOSE_PROFILES was '$current' (= everything enabled): writing the explicit list first"
        current="$(explicit_all "$known")"
    fi
    new="$(printf '%s\n' "$current" | tr ',' '\n' | grep -vx "$svc" | paste -sd, - || true)"
    [ -n "$new" ] || echo "⚠️  COMPOSE_PROFILES is now empty: only core services will run"
    write_profiles "$new"
    # `|| true`, as when this was a pipeline in the `if` below: compose refusing
    # the new selection must not abort the disable it was asked for.
    new_enabled="$(services_for_profiles "$new" 2>/dev/null || true)"
    if in_lines "$new_enabled" "$svc"; then
        echo "⚠️  $svc is still auto-enabled by another enabled service's profile — it will come back on the next stack restart"
    fi
    echo "🛑 Stopping and removing $svc..."
    run_compose_quiet stop "$svc"
    run_compose_quiet rm -f "$svc"
    echo "✅ $svc disabled"
    ram_note "$new_enabled"
}

# Print the COMPOSE_PROFILES value the user picks, and nothing else, so
# install.sh can offer the same screen while owning its own .env writing.
cmd_pick() {
    require_env_file
    _value="$(pick_profiles "$(current_enabled)")" || return "$?"
    # install.sh writes what comes back straight to .env, so the exclusivity
    # rule is enforced here too and not only in write_profiles. Status 3, since
    # 1 and 2 already mean "cancelled" and "no picker here".
    check_exclusive "$_value" || return 3
    printf '%s\n' "$_value"
}

# Just the service names, one per line: read straight out of compose/*.yaml with
# no docker call, so shell completion stays instant.
cmd_names() {
    config_rows | cut -d: -f1
}

cmd_config() {
    require_env_file
    known="$(known_profiles)"
    old_enabled="$(current_enabled)"

    # `|| rc=$?` keeps set -e out of it: a cancelled picker is a normal outcome.
    rc=0
    new_profiles="$(pick_profiles "$old_enabled")" || rc="$?"
    case "$rc" in
        1)
            echo "Cancelled — no changes."
            return 0
            ;;
        2)
            echo "❌ 'config' needs an interactive terminal and python3 (shipped with" >&2
            echo "   Raspberry Pi OS). Use 'make enable s=<service>' /" >&2
            echo "   'make disable s=<service>' instead." >&2
            exit 1
            ;;
    esac
    [ -n "$new_profiles" ] || echo "⚠️  Nothing selected: COMPOSE_PROFILES will be empty — only core services will run"
    # The picker unticks conflicting boxes itself; this is the backstop, and it
    # has to say that the picks were dropped rather than let set -e end the run.
    if ! check_exclusive "$new_profiles"; then
        echo "   Nothing was changed." >&2
        return 1
    fi
    arm_profiles_rollback
    write_profiles "$new_profiles"

    # Diff effective service sets (not raw profiles), so auto-enabled
    # dependencies are handled and core services cancel out.
    new_enabled="$(services_for_profiles "$new_profiles")"
    newly_on=""
    newly_off=""
    for svc in $known; do
        if in_lines "$new_enabled" "$svc"; then
            in_lines "$old_enabled" "$svc" || newly_on="$newly_on $svc"
        else
            if in_lines "$old_enabled" "$svc"; then newly_off="$newly_off $svc"; fi
        fi
    done

    if [ -z "$newly_on" ] && [ -z "$newly_off" ]; then
        disarm_profiles_rollback
        echo "✅ No service changes (COMPOSE_PROFILES=${new_profiles:-<empty: core only>})"
        ram_note "$new_enabled"
        return 0
    fi

    # Only the services that were just enabled are started, so disabling
    # something does not redraw the whole stack (and does not rebuild images
    # to reach a state it is already in).
    if [ -n "$newly_on" ]; then
        run_shared_pre_start_hooks
        for svc in $newly_on; do
            run_pre_start_hook "$svc-pre-start.sh"
        done
        echo "🚀 Starting$newly_on..."
        # shellcheck disable=SC2086 # service names, split on purpose
        run_compose_up_with "$new_profiles" up -d $newly_on
    fi
    disarm_profiles_rollback

    if [ -n "$newly_off" ]; then
        echo "🛑 Stopping and removing$newly_off..."
        # shellcheck disable=SC2086 # service names, split on purpose
        run_compose_quiet stop $newly_off
        # shellcheck disable=SC2086 # service names, split on purpose
        run_compose_quiet rm -f $newly_off
    fi

    for svc in $newly_on; do
        run_post_start_hooks "$svc" "$known"
    done

    echo "✅ Applied${newly_on:+ · enabled:$newly_on}${newly_off:+ · disabled:$newly_off}"
    ram_note "$new_enabled"
}

# --- Main ---

usage() {
    echo "Usage: services.sh {list|enable <service>|disable <service>|config|pick|names}" >&2
}

cmd="${1:-}"
if [ "$#" -gt 0 ]; then shift; fi
case "$cmd" in
    list) cmd_list ;;
    enable) cmd_enable "${1:-}" ;;
    disable) cmd_disable "${1:-}" ;;
    config) cmd_config ;;
    pick) cmd_pick ;;
    names) cmd_names ;;
    *) usage; exit 1 ;;
esac
