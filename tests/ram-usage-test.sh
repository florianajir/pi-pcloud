#!/bin/sh
# Tests for scripts/ram-usage.sh, which reads what the memory ceilings actually
# cost out of cgroup v2.
#
# Everything runs against a fabricated /sys/fs/cgroup and a stub `docker` on
# PATH, so the numbers are chosen rather than measured and the suite says the
# same thing on a host with no containers, no cgroup v2 and no Docker at all.
# The fixtures are shaped like the real stack anyway - a 6g ceiling, a service
# with no mem_limit, one that was OOM-killed, one started an hour ago - because
# every one of those broke a first draft. Run with `make test`.
set -eu

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
SCRIPT="$REPO_DIR/scripts/ram-usage.sh"
WORK="$(mktemp -d)"
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

contains() {
    case "$2" in
        *"$3"*) ok "$1" yes yes ;;
        *) ok "$1" "$2" "should contain: $3" ;;
    esac
}

lacks() {
    case "$2" in
        *"$3"*) ok "$1" "$2" "should NOT contain: $3" ;;
        *) ok "$1" yes yes ;;
    esac
}

NOW="$(date +%s)"
SLICE="$WORK/cgroup/system.slice"
mkdir -p "$SLICE" "$WORK/bin"

# One container, as the kernel presents it. The id is derived from the name so
# the docker stub and the cgroup tree cannot disagree; a "-" for the peak means
# this kernel predates memory.peak and writes no such file, and a "-" for the
# limit means the service has no mem_limit.
#
# The scope directory is touched last: writing a file into a directory bumps
# its mtime, and that mtime is where the script reads the container start time
# from.
container() { # name cur-mib peak-mib limit-mib anon-mib swap-mib hits oom age-seconds
    _dir="$SLICE/docker-$(printf '%s' "$1" | md5sum | cut -c1-32).scope"
    mkdir -p "$_dir"
    echo $(($2 * 1048576)) >"$_dir/memory.current"
    [ "$3" = - ] || echo $(($3 * 1048576)) >"$_dir/memory.peak"
    if [ "$4" = - ]; then echo max >"$_dir/memory.max"; else echo $(($4 * 1048576)) >"$_dir/memory.max"; fi
    printf 'anon %d\nfile %d\nkernel %d\n' $(($5 * 1048576)) 1024 2048 >"$_dir/memory.stat"
    echo $(($6 * 1048576)) >"$_dir/memory.swap.current"
    printf 'low 0\nhigh 0\nmax %d\noom %d\noom_kill %d\n' "$7" "$8" "$8" >"$_dir/memory.events"
    touch -d "@$((NOW - $9))" "$_dir"
}

DAY=86400

#         name                      cur  peak limit anon swap hits oom age
container llama-cpp                 700  6144  6144  600 2048   44   0 $((4 * DAY))
container flaresolverr              382   768   768   73   47 4300   0 $((4 * DAY))
container kavita                    330  1024  1024  123   73  190   2 $((4 * DAY))
container grafana                   304   512   512  190   14  619   0 $((3 * DAY))
container open-webui                295  1024  1024  152  511  334   0 $((4 * DAY))
container dockhand                  143   192   192   85   45   93   0 $((4 * DAY))
container pihole                     85   192   192   14    3   31   0 $((4 * DAY))
# Room it has never used, and a day of uptime to prove it.
container agentgateway               20    29   640    3    5    0   0 $((4 * DAY))
container stremio-lan                93   113  1024   43   20    0   0 $((4 * DAY))
# Same shape, an hour old: too young to conclude anything from.
container freshrss                   94   100   512   11    0    0   0 3600
# No mem_limit at all, so there is no ceiling to be under or over.
container traefik                    72    95     -   31    0    0   0 $((4 * DAY))
# A kernel without memory.peak: current is the floor, never a zero.
container lldap                      15     -   128    1    0    0   0 $((4 * DAY))

# Named by `docker ps` but with no cgroup behind it - the window between a
# container exiting and the listing being printed.
cat >"$WORK/bin/docker" <<'STUB'
#!/bin/sh
[ "${1:-}" = ps ] || exit 1
for svc in llama-cpp flaresolverr kavita grafana open-webui dockhand pihole \
           agentgateway stremio-lan freshrss traefik lldap ghost; do
    printf '%s %s\n' "$svc" "$(printf '%s' "$svc" | md5sum | cut -c1-32)"
done
STUB
chmod +x "$WORK/bin/docker"

PATH="$WORK/bin:$PATH"
export PATH CGROUP_ROOT="$WORK/cgroup" PROJECT_DIR="$WORK"

# --- snapshot ----------------------------------------------------------------

snap="$(sh "$SCRIPT" snapshot)"
field() { printf '%s\n' "$snap" | awk -v svc="$1" -v col="$2" '$1 == svc { print $col }'; }

ok "every container with a cgroup is reported" \
    "$(printf '%s\n' "$snap" | grep -c .)" 12
ok "  and the one without is skipped, not fatal" \
    "$(field ghost 1)" ""

# The regression that made this suite worth writing: mawk clamps %d at INT_MAX,
# so every ceiling of 2 GiB or more printed as 2147483647 - silently, and only
# for the services big enough to matter.
ok "a 6 GiB ceiling survives the formatting" "$(field llama-cpp 4)" 6442450944
ok "  and so does a 6 GiB peak"              "$(field llama-cpp 3)" 6442450944

ok "a service with no mem_limit reports a 0 ceiling" "$(field traefik 4)" 0
ok "a kernel without memory.peak falls back to current" \
    "$(field lldap 3)" "$(field lldap 2)"

ok "the ceiling hits come from memory.events" "$(field flaresolverr 7)" 4300
ok "  and the OOM kills from the same file"   "$(field kavita 8)" 2
ok "anonymous memory is read out of memory.stat" \
    "$(field open-webui 5)" "$((152 * 1048576))"
ok "swap is charged to the container that swapped" \
    "$(field open-webui 6)" "$((511 * 1048576))"

# The peak is only worth as much as the window it covers, and the window is the
# scope directory's mtime - which is the container start, not its creation.
ok "the start time is the scope mtime" \
    "$(field freshrss 9)" "$((NOW - 3600))"

# --- report ------------------------------------------------------------------

out="$(sh "$SCRIPT" report)"

contains "the totals say held, worst case and declared" "$out" \
    "2.5G held now, 10.0G had every peak landed together, 11.9G declared (12 containers)"

contains "an OOM kill is reported on its own"  "$out" "✘ kavita OOM-killed 2x in 4d"
contains "the binding ceilings are listed"     "$out" "7 services are pressing against their ceiling"
contains "  worst first"                       "$out" "flaresolverr              4300x in 4d"
contains "  with what the reclaim cost"        "$out" "295M held of 1.0G,   511M swapped"
contains "  and the tail collapsed into a count" "$out" "… and 2 more: llama-cpp, pihole"

contains "unused ceiling is reported too"      "$out" "of ceiling never approached"
contains "  biggest first"                     "$out" "stremio-lan              peaked   113M of 1.0G"
contains "  including the one with no peak file" "$out" "lldap                    peaked    15M of 128M"
lacks "  but never a container too young to judge" "$out" "freshrss"
lacks "  nor one with no ceiling to be under"      "$out" "traefik"

# --- nothing to measure ------------------------------------------------------
#
# Every caller prints this next to something it can say on its own, so an
# absent reading is a quiet line, never an error.

out="$(CGROUP_ROOT="$WORK/absent" sh "$SCRIPT" report)" && rc=0 || rc=$?
ok "a host without cgroup v2 reports no container" "$out" "  · no running container to measure"
ok "  and exits 0"                                 "$rc" 0

out="$(PATH=/nonexistent /bin/sh "$SCRIPT" snapshot)" && rc=0 || rc=$?
ok "a host without docker prints nothing" "$out" ""
ok "  and exits 0"                        "$rc" 0

sh "$SCRIPT" nonsense >/dev/null 2>&1 && rc=0 || rc=$?
ok "an unknown subcommand is refused" "$rc" 1

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
