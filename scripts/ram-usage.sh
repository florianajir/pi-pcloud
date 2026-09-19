#!/bin/sh
# What the memory ceilings cost in practice, measured rather than declared.
#
# `mem_limit` is what a service *may* take; this reads what it *does* take, out
# of the cgroup Docker gives every container. The two are nothing alike and
# both matter: the full stack declares ~34G of ceilings on a 16G host while
# holding ~8.5G of it, so the declared total on its own says nothing about
# whether the machine is comfortable - and it is the only number the picker
# behind `make config` has ever had.
#
# Three readings do the work, and none of them costs anything: one `docker ps`
# for the container-to-service mapping, then files under /sys/fs/cgroup.
#
#   memory.current / memory.peak  what it holds, and the most it has held since
#                                 the container started. memory.peak is Linux
#                                 5.19+; without it peak reads as current, so a
#                                 caller never has to special-case a zero.
#   memory.events "max"           how many times it reached its ceiling and had
#                                 to reclaim to stay under it - the one reading
#                                 that says a ceiling is *binding*, and nothing
#                                 in the stack looked at it. Per-container
#                                 memory.pressure, which system-tools does
#                                 read, sits at 0.00 for every container on a
#                                 healthy host even while one of them hits its
#                                 ceiling thousands of times a day, because
#                                 dropping page cache is cheap and stalls
#                                 nobody.
#   memory.swap.current           what that reclaim actually cost, for the part
#                                 that came out of anonymous memory instead.
#
# Host-only: /sys/fs/cgroup paths and the Docker socket, never mounted into a
# container. Every subcommand is read-only and degrades to silence - not to an
# error - when there is nothing to measure, because its callers (`make
# services`, `make enable`, `make doctor`) all have something useful to say
# with or without it.
#
# Subcommands:
#   snapshot   one line per running container of this project, as
#              "<service> <current> <peak> <limit> <anon> <swap> <hits> <oom> <started>"
#              Bytes, except <hits>/<oom> (counts) and <started> (epoch
#              seconds). <limit> is 0 for a container with no mem_limit.
#   report     the human block `make doctor` prints
#
# CGROUP_ROOT and PROJECT_DIR are honored from the environment, for the tests.
set -eu

CGROUP_ROOT="${CGROUP_ROOT:-/sys/fs/cgroup}"
PROJECT_DIR="${PROJECT_DIR:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}"

# How many rows each list in `report` prints before collapsing into a count.
LIST_SHOWN=5
# A peak under this share of the ceiling is slack worth reporting...
SLACK_PCT=40
# ...but only once the container has had this long to grow into it. Without the
# floor, every service restarted an hour ago reads as oversized.
SLACK_MIN_AGE=86400

# The containers of this project, as "<service> <full-id>".
#
# Selected on the working_dir label rather than the project name: Compose
# derives that name from the directory but COMPOSE_PROJECT_NAME overrides it,
# and matching the path means nothing here has to know which of the two is in
# force. --no-trunc is what makes {{.ID}} the full id the cgroup is named after.
project_containers() {
    docker ps --no-trunc \
        --filter "label=com.docker.compose.project.working_dir=$PROJECT_DIR" \
        --format '{{.Label "com.docker.compose.service"}} {{.ID}}' 2>/dev/null
}

# When the container started, as epoch seconds - which is exactly the window
# its memory.peak covers, since the kernel creates the scope with the container
# and the peak dies with it. Taken from the scope directory rather than from
# `docker inspect`: it is free, and it is the *start* time. Docker's own
# RunningFor is the creation time, which a plain `docker restart` leaves
# untouched while resetting the peak - the one direction that would matter,
# since it makes a fresh container look like it has had days to grow.
scope_started() {
    stat -c %Y "$1" 2>/dev/null || echo 0
}

snapshot() {
    command -v docker >/dev/null 2>&1 || return 0
    [ -d "$CGROUP_ROOT/system.slice" ] || return 0
    project_containers | while read -r _svc _id; do
        if [ -z "${_svc:-}" ] || [ -z "${_id:-}" ]; then continue; fi
        _dir="$CGROUP_ROOT/system.slice/docker-$_id.scope"
        [ -r "$_dir/memory.current" ] || continue
        # Listed rather than globbed, and only the readable ones: awk treats a
        # missing file as fatal and skips its END block, so one kernel without
        # memory.peak would drop the container from the snapshot entirely
        # instead of reporting it with one field short.
        _files="$_dir/memory.current $_dir/memory.max"
        for _extra in memory.peak memory.stat memory.events memory.swap.current; do
            if [ -r "$_dir/$_extra" ]; then
                _files="$_files $_dir/$_extra"
            fi
        done
        # shellcheck disable=SC2086 # a cgroup path never contains whitespace
        awk -v svc="$_svc" -v since="$(scope_started "$_dir")" '
            FILENAME ~ /\/memory\.current$/       { cur  = $1; next }
            FILENAME ~ /\/memory\.peak$/          { peak = $1; next }
            FILENAME ~ /\/memory\.max$/           { lim  = ($1 == "max" ? 0 : $1); next }
            FILENAME ~ /\/memory\.swap\.current$/ { swap = $1; next }
            FILENAME ~ /\/memory\.stat$/          { if ($1 == "anon") anon = $2; next }
            FILENAME ~ /\/memory\.events$/ {
                if ($1 == "max") hits = $2
                else if ($1 == "oom_kill") oom = $2
                next
            }
            END {
                # No memory.peak on this kernel: current is the only floor
                # there is, and it beats publishing a zero every caller would
                # have to recognise.
                if (peak < cur) peak = cur
                # %.0f, not %d: mawk clamps %d at INT_MAX, so every ceiling of
                # 2 GiB or more came out as 2147483647 - the 6g on llama-cpp
                # and the 3g on immich-server alike. awk numbers are doubles,
                # which hold a byte count exactly far past any memory this
                # will ever be pointed at.
                printf "%s %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f\n",
                    svc, cur, peak, lim, anon, swap, hits, oom, since
            }
        ' $_files
    done
}

# The block `make doctor` prints under its own heading. Three lists, in the
# order they deserve attention: what died, what is being squeezed, what was
# given room it has never used.
report() {
    _snap="$(snapshot)"
    if [ -z "$_snap" ]; then
        echo "  · no running container to measure"
        return 0
    fi
    # LC_ALL=C: awk formats %.1f through the locale, and a fr_FR host would
    # print "8,5G" where every other line of the stack prints "8.5G".
    printf '%s\n' "$_snap" | LC_ALL=C awk \
        -v now="$(date +%s)" -v shown="$LIST_SHOWN" \
        -v slack_pct="$SLACK_PCT" -v min_age="$SLACK_MIN_AGE" '
        function human(b) {
            if (b >= 1073741824) return sprintf("%.1fG", b / 1073741824)
            if (b >= 1048576)    return sprintf("%dM", b / 1048576)
            return sprintf("%dK", b / 1024)
        }
        function age(s) {
            if (s >= 172800) return sprintf("%dd", s / 86400)
            if (s >= 7200)   return sprintf("%dh", s / 3600)
            return sprintf("%dm", s / 60)
        }
        # Fills the global ord[1..m] with the rows whose metric is positive,
        # biggest first. A selection sort because mawk has no asort and there
        # are 46 rows: the alternative is a sort(1) per list, and with it a
        # second copy of human() in a second awk program.
        function rank(metric,   i, j, best, used, m) {
            m = 0
            for (j = 1; j <= n; j++) {
                best = 0
                for (i = 1; i <= n; i++)
                    if (!used[i] && metric[i] > 0 &&
                        (best == 0 || metric[i] > metric[best])) best = i
                if (best == 0) break
                used[best] = 1
                ord[++m] = best
            }
            return m
        }
        function more(m,   i, rest) {
            if (m <= shown) return
            rest = ""
            for (i = shown + 1; i <= m; i++) rest = rest (rest == "" ? "" : ", ") svc[ord[i]]
            printf "      … and %d more: %s\n", m - shown, rest
        }
        {
            n++
            svc[n] = $1; cur[n] = $2; peak[n] = $3; lim[n] = $4
            anon[n] = $5; swap[n] = $6; hits[n] = $7; oom[n] = $8
            up[n] = ($9 > 0 && now > $9) ? now - $9 : 0
            tcur += $2; tpeak += $3; tlim += $4
        }
        END {
            printf "  %s held now, %s had every peak landed together, %s declared (%d containers)\n",
                human(tcur), human(tpeak), human(tlim), n

            # An OOM kill is not a hint, so every one of them is listed.
            m = rank(oom)
            for (i = 1; i <= m; i++) {
                r = ord[i]
                printf "  ✘ %s OOM-killed %dx in %s — %s is below what it needs\n",
                    svc[r], oom[r], age(up[r]), human(lim[r])
            }

            m = rank(hits)
            if (m > 0) {
                printf "  ⚠ %d %s pressing against %s ceiling, reclaiming to stay under it:\n",
                    m, (m == 1 ? "service is" : "services are"), (m == 1 ? "its" : "their")
                for (i = 1; i <= m && i <= shown; i++) {
                    r = ord[i]
                    printf "      %-24s %5dx in %-3s · %6s held of %-5s %6s swapped\n",
                        svc[r], hits[r], age(up[r]), human(cur[r]),
                        human(lim[r]) ",", human(swap[r])
                }
                more(m)
            }

            for (i = 1; i <= n; i++) {
                slack[i] = 0
                if (lim[i] > 0 && up[i] >= min_age && peak[i] * 100 < lim[i] * slack_pct) {
                    slack[i] = lim[i] - peak[i]
                    tslack += slack[i]
                }
            }
            m = rank(slack)
            if (m > 0) {
                printf "  · %s of ceiling never approached in over a day of uptime:\n",
                    human(tslack)
                for (i = 1; i <= m && i <= shown; i++) {
                    r = ord[i]
                    printf "      %-24s peaked %6s of %-5s in %s\n",
                        svc[r], human(peak[r]), human(lim[r]), age(up[r])
                }
                more(m)
            }
        }'
}

usage() {
    echo "Usage: ram-usage.sh {snapshot|report}" >&2
}

case "${1:-}" in
    snapshot) snapshot ;;
    report) report ;;
    *) usage; exit 1 ;;
esac
