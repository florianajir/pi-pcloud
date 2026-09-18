#!/bin/sh
# Tests for scripts/services.sh, the enable/disable/config front end for the
# COMPOSE_PROFILES selection.
#
# Everything runs against a throwaway copy of the repo's scripts and its real
# compose.yaml, with DRY_RUN=1 and a stub `docker` on PATH, so no container and
# no host change. The real compose.yaml on purpose: the rules under test are
# read out of it (profile lists, the pi-pcloud.conflicts-with label), so a
# fixture would let the two drift apart.
# Run with `make test`.
set -eu

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
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

cp -r "$REPO_DIR/scripts" "$WORK/scripts"
cp "$REPO_DIR/compose.yaml" "$WORK/compose.yaml"
cp -r "$REPO_DIR/compose" "$WORK/compose"

# Enough of `docker compose config` for services.sh, answered from the same
# compose/*.yaml the script reads: the declared profiles, and the services a
# selection enables (a service runs when it declares no profile at all, or when
# one of its profiles is selected — which is how gluetun follows qbittorrent).
mkdir -p "$WORK/bin"
cat >"$WORK/bin/docker" <<'STUB'
#!/bin/sh
set -eu
[ "${1:-}" = compose ] && shift || exit 1
# `up` is answered too, for the section that runs without DRY_RUN; everything
# else is a command these tests never expect to reach a real daemon.
case "${1:-}" in
    config) shift ;;
    up) echo "docker compose $*"; exit 0 ;;
    *) exit 1 ;;
esac
awk -v mode="${1:-}" -v selection="${COMPOSE_PROFILES-all}" '
    function flush() {
        if (svc == "") return
        if (mode == "--profiles") {
            n = split(list, part, ",")
            for (i = 1; i <= n; i++) if (part[i] != "") print part[i]
        } else if (list == "") {
            print svc
        } else {
            n = split(list, part, ",")
            for (i = 1; i <= n; i++)
                if (part[i] != "" && index("," selection ",", "," part[i] ",")) {
                    print svc
                    break
                }
        }
        svc = ""; list = ""
    }
    /^services:[ \t]*$/ { in_services = 1; next }
    /^[A-Za-z0-9_-]+:/ { flush(); in_services = 0; next }
    !in_services { next }
    /^  [A-Za-z0-9_-]+:[ \t]*$/ {
        flush()
        svc = $0
        gsub(/[ :]/, "", svc)
        next
    }
    /^[ \t]+profiles:/ {
        list = $0
        sub(/^[^[]*\[/, "", list)
        sub(/\].*$/, "", list)
        gsub(/["\t ]/, "", list)
        next
    }
    END { flush() }
' "$PROJECT_DIR"/compose/*.yaml | sort -u
STUB
chmod +x "$WORK/bin/docker"

ENV_FILE="$WORK/.env"
export PROJECT_DIR="$WORK" ENV_FILE
PATH="$WORK/bin:$PATH"
export PATH

# Run a subcommand against a .env holding <selection>; "none" writes no
# COMPOSE_PROFILES line at all (a pre-profiles install).
run_rc() {
    if [ "$1" = none ]; then
        : >"$ENV_FILE"
    else
        printf 'COMPOSE_PROFILES=%s\n' "$1" >"$ENV_FILE"
    fi
    shift
    out="$(DRY_RUN=1 sh "$WORK/scripts/services.sh" "$@" 2>&1)" && rc=0 || rc=$?
}

# The COMPOSE_PROFILES value the run would have written (empty if none).
written() {
    printf '%s\n' "$out" | sed -n 's/^DRY-RUN: would write to .*: COMPOSE_PROFILES=//p' | tail -n1
}

# --- the exclusive pair is declared, not assumed -----------------------------
#
# The whole rule hangs off one label; a rename in compose/compose-media.yaml would otherwise
# turn every guard below into a no-op that still passes.

ok "compose/compose-media.yaml declares the conflict" \
    "$(grep -c 'pi-pcloud.conflicts-with=stremio' "$WORK/compose/compose-media.yaml")" 1

# --- "all" is expanded to what it actually covers ----------------------------
#
# The bug this section exists to catch: expanding "all" to every declared
# profile pulls in stremio-lan, which "all" deliberately excludes, and the
# resulting selection is refused by the exclusivity guard — so every disable on
# a default install used to abort before stopping anything.

run_rc all disable kavita
ok       "disable on all succeeds"            "$rc" 0
lacks    "  without pulling in stremio-lan"   "$(written)" "stremio-lan"
contains "  keeping the other mode"           ",$(written)," ",stremio,"
lacks    "  and dropping the named service"   ",$(written)," ",kavita,"
contains "  then stopping the container"      "$out" "docker compose stop kavita"

run_rc none enable kavita
ok       "enable with no line succeeds"       "$rc" 0
lacks    "  without pulling in stremio-lan"   "$(written)" "stremio-lan"
contains "  and starts the service"           "$out" "docker compose up -d kavita"

# Compose starts more than the service named - agentgateway carries open-webui's
# profile - and the dependency's own pre-start hook is what writes the keys its
# entrypoint reads. Asking for `<svc>-pre-start.sh` alone left it unconfigured
# while the command reported success.
run_rc beszel enable open-webui
ok       "enable open-webui succeeds"          "$rc" 0
contains "  and runs the dependency's hook"    "$out" "agentgateway-pre-start.sh"
contains "  starting both"                     "$out" "agentgateway open-webui"

# Grafana's OIDC client secret is written by authelia-pre-start.sh, not by a
# hook of its own, and compose bind-mounts that one file straight into the
# container. Without the always-on hooks running here, enabling grafana left the
# file missing, Docker created a directory at the bind source, and Grafana
# crash-looped on "is a directory" - so this asserts the hook runs, and runs
# before the container is created rather than after.
run_rc beszel enable grafana
ok       "enable grafana succeeds"             "$rc" 0
contains "  runs the authelia hook"            "$out" "authelia-pre-start.sh"
contains "  pulling prometheus in with it"     "$out" "grafana"
ok       "  before the container is created" \
    "$(printf '%s\n' "$out" | grep -nE 'authelia-pre-start\.sh|docker compose up -d' \
        | head -n1 | grep -c 'authelia-pre-start')" 1

# Every optional service's Homepage widget key is minted by homepage's own
# bootstrap rather than the service's, and compose points HOMEPAGE_FILE_* at
# those files unconditionally - so enabling changedetection without running it
# left the dashboard throwing ENOENT on every render until the next full update.
run_rc beszel enable changedetection
ok       "enable changedetection succeeds"      "$rc" 0
contains "  runs its own bootstrap"             "$out" "changedetection-bootstrap.sh"
contains "  and homepage's widget bootstrap"    "$out" "homepage-widgets-bootstrap.sh"
ok "  after the container is started" \
    "$(printf '%s\n' "$out" \
        | grep -nE 'homepage-widgets-bootstrap\.sh|docker compose up -d' \
        | head -n1 | grep -c 'docker compose up -d')" 1
lacks    "  and not Uptime Kuma's, which is off" "$out" "uptime-kuma-bootstrap.sh"

# Uptime Kuma pauses the monitors of services COMPOSE_PROFILES leaves out, so
# the newly enabled one stays paused until its bootstrap reconciles them.
run_rc beszel,uptime-kuma enable changedetection
ok       "enable with Uptime Kuma on succeeds"                "$rc" 0
contains "the monitors are reconciled when Uptime Kuma runs"  "$out" "uptime-kuma-bootstrap.sh"

# ...and exactly once when Uptime Kuma is itself the service being enabled: its
# own post-start hook already ran it, and it is the most expensive hook here (a
# throwaway container that pip-installs its client).
run_rc beszel,uptime-kuma enable uptime-kuma
ok "its own bootstrap is not run twice" \
    "$(printf '%s\n' "$out" | grep -c 'uptime-kuma-bootstrap\.sh')" 1

# The same reconciliation on the way out: a monitor left active against a
# container that was just removed alerts as down until something pauses it.
run_rc changedetection,uptime-kuma disable changedetection
ok       "disable changedetection succeeds"          "$rc" 0
contains "  reconciles the monitors too"             "$out" "uptime-kuma-bootstrap.sh"
ok "  after the container is removed" \
    "$(printf '%s\n' "$out" \
        | grep -nE 'uptime-kuma-bootstrap\.sh|docker compose rm' \
        | head -n1 | grep -c 'docker compose rm')" 1

# config/postgres/init-databases.sh only runs on a fresh PGDATA, so a
# Postgres-backed service enabled later has no role and cannot authenticate at
# all. Its hook has to run *before* the container it would otherwise leave
# crash-looping - the one place a post-start hook is run early.
run_rc beszel enable freshrss
ok       "enable freshrss succeeds"             "$rc" 0
contains "  runs the postgres hook"             "$out" "postgres-bootstrap.sh"
ok "  before the container is created" \
    "$(printf '%s\n' "$out" \
        | grep -nE 'postgres-bootstrap\.sh|docker compose up -d' \
        | head -n1 | grep -c 'postgres-bootstrap')" 1

# --- the two networking modes stay exclusive ---------------------------------

# "all" already runs stremio, so this must not silently start a second server
# against the same volume — and must not write "all" back either.
run_rc all enable stremio-lan
ok       "enable stremio-lan on all refused"  "$rc" 1
contains "  naming the way out"               "$out" "make disable s=stremio"
lacks    "  starting nothing"                 "$out" "docker compose up"
ok       "  writing nothing"                  "$(written)" ""

# Symmetric: the label is declared on one side only, reported on both.
run_rc stremio-lan enable stremio
ok       "enable stremio on stremio-lan refused" "$rc" 1
contains "  naming the way out"               "$out" "make disable s=stremio-lan"

# Switching modes is disable-then-enable, and the second step has to work.
run_rc beszel,qbittorrent enable stremio-lan
ok       "enable stremio-lan once stremio is off" "$rc" 0
contains "  writes it into the selection"     ",$(written)," ",stremio-lan,"
contains "  and starts it"                    "$out" "docker compose up -d stremio-lan"

# A hand-edited .env is still refused, by the same check, before anything runs.
run_rc stremio,stremio-lan disable kavita
ok       "a selection holding both is refused" "$rc" 1
contains "  with the reason"                   "$out" "cannot both run"

# --- list ------------------------------------------------------------------

run_rc all list
contains "all lists stremio as enabled"       "$out" "✅ stremio enabled"
contains "  and stremio-lan as disabled"      "$out" "⛔ stremio-lan disabled"

# --- the row the picker is handed -------------------------------------------

{
    sed -n '/^compose_rows()/,/^}$/p' "$WORK/scripts/services.sh"
    sed -n '/^config_rows()/,/^}$/p' "$WORK/scripts/services.sh"
    sed -n '/^always_on_ram_mib()/,/^}$/p' "$WORK/scripts/services.sh"
    echo '"$@"'
} >"$WORK/rows.sh"
sh "$WORK/rows.sh" config_rows >"$WORK/rows.txt"

# Column 5 is the conflict, and one label in compose.yaml puts it on both rows;
# column 6 is the mem_limit ceiling in MiB.
ok "config_rows reports the conflict on stremio" \
    "$(grep -c '^stremio:Video::gluetun:stremio-lan:1024:' "$WORK/rows.txt")" 1
ok "  and on stremio-lan"                     \
    "$(grep -c '^stremio-lan:Video:::stremio:1024:' "$WORK/rows.txt")" 1
ok "  and leaves every other row's empty"     \
    "$(awk -F: '$5 != "" { print $1 }' "$WORK/rows.txt" | sort | tr '\n' ' ')" \
    "stremio stremio-lan "

# --- the memory ceilings -----------------------------------------------------
#
# Both stremio modes take theirs from the x-stremio-common anchor rather than
# from a key of their own, so the two rows above are also what proves the merge
# key is followed: a parser reading only the literal lines reports 0 for them.

ok "every optional service carries a ceiling" \
    "$(awk -F: '$6 !~ /^[0-9]+$/ || $6 == 0 { print $1 }' "$WORK/rows.txt" | tr '\n' ' ')" ""
ok "  and so does every always-on one" \
    "$(sh "$WORK/rows.sh" compose_rows | awk -F'|' '$10 == 0 && $9 == 0 { print $4 }' \
        | tr '\n' ' ')" ""

ok "a core service is read but kept off the list" \
    "$(sh "$WORK/rows.sh" compose_rows | awk -F'|' '$4 == "postgres" { print $9, $10 }')" \
    "1536 0"
ok "  while an optional one is on it" \
    "$(sh "$WORK/rows.sh" compose_rows | awk -F'|' '$4 == "kavita" { print $9, $10 }')" \
    "1024 1"
ok "  and postgres never reaches the picker" \
    "$(grep -c '^postgres:' "$WORK/rows.txt")" 0

# The picker lists none of the always-on services, so their ceilings have to
# reach it another way or every total it prints is short by a third.
base_ram="$(sh "$WORK/rows.sh" always_on_ram_mib)"
ok "the always-on total is a number" \
    "$(printf '%s' "$base_ram" | grep -cE '^[0-9]+$')" 1
ok "  larger than the largest core service alone" \
    "$([ "$base_ram" -gt 1536 ] && echo yes || echo "$base_ram")" yes
ok "  and counting no optional service" \
    "$([ "$base_ram" -lt "$(awk -F: '{ t += $6 } END { print t }' "$WORK/rows.txt")" ] \
        && echo yes || echo "$base_ram")" yes

# --- the picker acts on that column -----------------------------------------
#
# Ticking one mode has to untick the other rather than hand back a selection
# the stack refuses to start; "select all" likewise cannot tick both.

cat >"$WORK/picker-test.py" <<'PYCASE'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("picker", sys.argv[1])
picker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(picker)



def load(ticked):
    rows = picker.read_rows(sys.argv[2])
    for row in rows:
        row["on"] = row["service"] in ticked
    return rows


def index(rows, service):
    return [row["service"] for row in rows].index(service)


def ticked(rows):
    return ",".join(row["service"] for row in rows if row["on"])


# Ticking one mode drops the other, and everything left without a mode at all.
rows = load({"gluetun", "stremio", "comet"})
picker.toggle(rows, index(rows, "stremio-lan"))
print("SWITCH:" + ticked(rows))

# comet is a companion of stremio, but it runs against either mode: reaching it
# from stremio-lan must not silently switch the user back to the VPN one.
rows = load({"gluetun", "stremio-lan"})
picker.toggle(rows, index(rows, "comet"))
print("COMPANION:" + ticked(rows))

# Dropping the mode outright still drops what needed it.
rows = load({"gluetun", "stremio", "comet"})
print("DROP:" + picker.toggle(rows, index(rows, "stremio")) + "|" + ticked(rows))

rows = load({"gluetun", "stremio", "comet"})
print("MSG:" + picker.set_all(rows, True))
print("ALL:" + ticked(rows))

# The header adds up what is ticked plus the always-on floor it is handed, and
# says which of the three things that is on this host: gluetun, stremio and
# comet are 1792 MiB on top of a 1024 MiB floor.
rows = load({"gluetun", "stremio", "comet"})
print("RAM:" + picker.ram_line(rows, {"base": 1024, "ram": 8192})[0])
print("KEYS:" + ",".join(
    picker.ram_line(rows, {"base": 1024, "ram": size})[1] for size in (8192, 2048, 512)))

# A ceiling is heavy relative to the host, not in absolute terms: 1 GB is a
# rounding error on 16 GB and a quarter of a 4 GB Pi.
print("HEAVY:" + ",".join(
    str(picker.ram_key(1024, size)) for size in (4096, 8192, 16384)))
PYCASE

cat >"$WORK/picker-rows.txt" <<'ROWS'
gluetun:Download::::256:on:VPN
stremio:Video::gluetun:stremio-lan:1024:on:Streaming server
comet::stremio:::512:on:Addon
stremio-lan:Video:::stremio:1024:off:Casting
ROWS

out="$(python3 "$WORK/picker-test.py" "$WORK/scripts/services-picker.py" "$WORK/picker-rows.txt" 2>&1 || true)"
contains "ticking a mode unticks the other"   "$out" "SWITCH:gluetun,comet,stremio-lan"
contains "a companion follows either mode"    "$out" "COMPANION:gluetun,comet,stremio-lan"
contains "dropping the mode drops the rest"   "$out" "DROP:also unticked: comet|gluetun"
contains "select-all keeps the first mode"    "$out" "ALL:gluetun,stremio,comet"
contains "  and says which it left out"       "$out" "MSG:left unticked (conflict): stremio-lan"
contains "the header sums the ticked ceilings" "$out" "RAM:RAM ceilings 2.8G of 8.0G · 0.3x"
contains "  and grades them against the host"  "$out" "KEYS:ok,warn,over"
contains "  a heavy service is one on a share" "$out" "HEAVY:over,warn,None"

# --- the ceilings are reported outside the picker too ------------------------
#
# `make config` needs python3 and a terminal; `make services` needs neither, and
# is the only place a host without them can see what its selection costs.

run_rc all list
contains "list reports the RAM ceilings"      "$out" "🧠 RAM ceilings"
contains "  against the host RAM"             "$out" " of "

run_rc beszel list
first="$(printf '%s\n' "$out" | sed -n 's/^🧠 RAM ceilings \([0-9.]*[MG]\).*/\1/p')"
run_rc all list
second="$(printf '%s\n' "$out" | sed -n 's/^🧠 RAM ceilings \([0-9.]*[MG]\).*/\1/p')"
ok "  and a smaller selection is a smaller total" \
    "$(printf '%s\n%s\n' "$first" "$second" | sort -h | head -n1)" "$first"

# --- the hooks run with the privileges they were written for -----------------
#
# `make config` and `make enable` were the only callers running these hooks
# unprivileged: authelia-pre-start.sh died on "Permission denied" in the
# root-owned secrets directory - after .env had already been rewritten, so the
# service counted as enabled and the next run found nothing left to do.
#
# Runs for real (no DRY_RUN) against stub hooks and a stub `sudo`, replacing
# files in the throwaway tree - so it stays last.

cat >"$WORK/bin/sudo" <<'STUB'
#!/bin/sh
echo "ELEVATED: $*"
exec "$@"
STUB
chmod +x "$WORK/bin/sudo"

rm -f "$WORK"/scripts/*-pre-start.sh "$WORK"/scripts/*bootstrap.sh "$WORK"/scripts/*bootstrap.py

# The one hook left, exiting with the status the test asks for.
authelia_hook_exiting() {
    cat >"$WORK/scripts/authelia-pre-start.sh" <<STUB
#!/bin/sh
echo "authelia hook ran as uid \$(id -u) with PROJECT_DIR=\$PROJECT_DIR"
exit $1
STUB
    chmod +x "$WORK/scripts/authelia-pre-start.sh"
}

written_line() {
    sed -n 's/^COMPOSE_PROFILES=//p' "$ENV_FILE"
}

run_live() {
    printf 'COMPOSE_PROFILES=%s\n' "$1" >"$ENV_FILE"
    shift
    out="$(sh "$WORK/scripts/services.sh" "$@" 2>&1)" && rc=0 || rc=$?
}

authelia_hook_exiting 1
run_live beszel enable kavita
ok       "a failing pre-start hook fails the enable" "$rc" 1
contains "  the hook is given the project paths"    "$out" "PROJECT_DIR=$WORK"
ok       "  and COMPOSE_PROFILES is put back"       "$(written_line)" "beszel"

if [ "$(id -u)" = 0 ]; then
    lacks    "  no sudo when already root"          "$out" "ELEVATED:"
else
    contains "  the hook is elevated"               "$out" "ELEVATED: env PROJECT_DIR=$WORK"
fi

authelia_hook_exiting 0
run_live beszel enable kavita
ok       "a completed enable keeps its .env write"  "$rc" 0
contains "  starting the service"                   "$out" "up -d kavita"
contains "  and leaving it enabled"                 ",$(written_line)," ",kavita,"

printf '\nservices-test.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
