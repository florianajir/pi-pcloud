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
#   record     the same, merged into the observation cache on the way out, so a
#              caller that wants both pays for one `docker ps`
#   observed   the cache as "<service> <held-mib> <peak-mib>", which is the only
#              thing that can put a number beside a service that is *not*
#              running - the question `make config` asks about every unticked
#              box, and the one a live reading can never answer
#   report     the human block `make doctor` prints
#
# CGROUP_ROOT, PROJECT_DIR and RAM_OBSERVED_FILE are honored from the
# environment, for the tests.
set -eu

CGROUP_ROOT="${CGROUP_ROOT:-/sys/fs/cgroup}"
PROJECT_DIR="${PROJECT_DIR:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}"
# Beside .env, because it is the same kind of thing: host state, specific to
# this machine, never committed. Not under DATA_LOCATION, which the root-run
# unit owns and may point at another disk - this file is written by whoever
# typed `make`, and the replacement is a rename into a directory that user
# already owns, so a copy left behind by a `sudo make` does not freeze it.
RAM_OBSERVED_FILE="${RAM_OBSERVED_FILE:-$PROJECT_DIR/.ram-observed}"

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

# A container in its first minutes holds its startup footprint, not its working
# set, so a sample that young does not get to overwrite a settled one.
RECORD_MIN_AGE=3600

# snapshot, plus what it teaches, merged into the cache.
#
# The snapshot goes to stdout either way: every caller that records also wants
# to display, and making them call both would mean two `docker ps` and two
# readings a second apart that do not add up.
#
# What the cache is for: memory.peak dies with the container and there is no
# reading at all for a service that is switched off, which is exactly the
# service the picker is being asked about. So the peak is kept as a maximum
# across restarts, and what a service holds survives it being disabled.
#
# Failing to write is not an error. The cache is an improvement on the numbers,
# never the source of them, and a read-only checkout or a stale root-owned copy
# must not turn `make services` into a failure.
record() {
    _snap="$(snapshot)"
    # Before the echo, not after: `printf '%s\n' ""` is a blank line, and a
    # caller summing the output counted it as one container holding nothing.
    [ -n "$_snap" ] || return 0
    printf '%s\n' "$_snap"

    _body="$(printf '%s\n' "$_snap" | awk -v now="$(date +%s)" \
        -v minage="$RECORD_MIN_AGE" -v cache="$RAM_OBSERVED_FILE" '
        # The cache as it stands, read here rather than as a second input file:
        # the usual FNR == NR is true for the *first* record of the second file
        # too when the first one is empty, and on a host with no cache yet that
        # filed every snapshot row as a cached one - bytes stored where MiB
        # belonged, and the ceiling stored where the timestamp belonged.
        # getline returns -1 on a file that is not there, so no /dev/null stand-in
        # and no readability test.
        BEGIN {
            while ((getline line < cache) > 0) {
                if (line ~ /^#/) continue
                if (split(line, f, " ") < 4) continue
                held[f[1]] = f[2] + 0; peak[f[1]] = f[3] + 0; seen[f[1]] = f[4] + 0
            }
            close(cache)
        }
        # Rows for services that are not running now are carried over
        # untouched - that is the whole point of the file.
        {
            svc = $1
            cur = int($2 / 1048576)
            pk  = int($3 / 1048576)
            up  = (now > $9 && $9 > 0) ? now - $9 : 0
            fresh = (svc in seen) ? 0 : 1
            if (pk > peak[svc]) peak[svc] = pk
            if (up >= minage || fresh) held[svc] = cur
            seen[svc] = now
        }
        END { for (svc in seen) printf "%s %d %d %d\n", svc, held[svc], peak[svc], seen[svc] }
    ' | LC_ALL=C sort)"

    # The whole write is a subshell with its stderr closed, not just the
    # redirection: a redirection that cannot be opened is reported by the shell
    # itself, on the shell's stderr, so `>"$_tmp" 2>/dev/null` silences
    # everything except the one message it was written for. umask rather than a
    # chmod afterwards, so the file is never briefly private.
    _tmp="$RAM_OBSERVED_FILE.tmp.$$"
    if (
        umask 022
        {
            echo "# What each service was measured holding on this host, in MiB."
            echo "# service held peak updated-epoch — written by scripts/ram-usage.sh"
            printf '%s\n' "$_body"
        } >"$_tmp"
    ) 2>/dev/null; then
        mv -f "$_tmp" "$RAM_OBSERVED_FILE" 2>/dev/null || rm -f "$_tmp" 2>/dev/null || true
    else
        rm -f "$_tmp" 2>/dev/null || true
    fi
}

# The cache, as "<service> <held-mib> <peak-mib>". Silence when there is none.
observed() {
    [ -r "$RAM_OBSERVED_FILE" ] || return 0
    awk '$0 !~ /^#/ && NF >= 3 { print $1, $2, $3 }' "$RAM_OBSERVED_FILE"
}

# The block `make doctor` prints under its own heading. Three lists, in the
# order they deserve attention: what died, what is being squeezed, what was
# given room it has never used.
report() {
    _snap="$(record)"
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
    echo "Usage: ram-usage.sh {snapshot|record|observed|report}" >&2
}

case "${1:-}" in
    snapshot) snapshot ;;
    record) record ;;
    observed) observed ;;
    report) report ;;
    *) usage; exit 1 ;;
esac
