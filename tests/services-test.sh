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

# Enough of `docker compose config` for services.sh, answered from the same
# compose.yaml the script reads: the declared profiles, and the services a
# selection enables (a service runs when it declares no profile at all, or when
# one of its profiles is selected — which is how gluetun follows qbittorrent).
mkdir -p "$WORK/bin"
cat >"$WORK/bin/docker" <<'STUB'
#!/bin/sh
set -eu
[ "${1:-}" = compose ] && shift || exit 1
[ "${1:-}" = config ] && shift || exit 1
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
' "$PROJECT_DIR/compose.yaml" | sort -u
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
# The whole rule hangs off one label; a rename in compose.yaml would otherwise
# turn every guard below into a no-op that still passes.

ok "compose.yaml declares the conflict" \
    "$(grep -c 'pi-pcloud.conflicts-with=stremio' "$WORK/compose.yaml")" 1

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

sed -n '/^config_rows()/,/^}$/p' "$WORK/scripts/services.sh" >"$WORK/rows.sh"
echo config_rows >>"$WORK/rows.sh"
sh "$WORK/rows.sh" >"$WORK/rows.txt"

# Column 5 is the conflict, and one label in compose.yaml puts it on both rows.
ok "config_rows reports the conflict on stremio" \
    "$(grep -c '^stremio:Video::gluetun:stremio-lan:' "$WORK/rows.txt")" 1
ok "  and on stremio-lan"                     \
    "$(grep -c '^stremio-lan:Video:::stremio:' "$WORK/rows.txt")" 1
ok "  and leaves every other row's empty"     \
    "$(awk -F: '$5 != "" { print $1 }' "$WORK/rows.txt" | sort | tr '\n' ' ')" \
    "stremio stremio-lan "

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
PYCASE

cat >"$WORK/picker-rows.txt" <<'ROWS'
gluetun:Download::::on:VPN
stremio:Video::gluetun:stremio-lan:on:Streaming server
comet::stremio:::on:Addon
stremio-lan:Video:::stremio:off:Casting
ROWS

out="$(python3 "$WORK/picker-test.py" "$WORK/scripts/services-picker.py" "$WORK/picker-rows.txt" 2>&1 || true)"
contains "ticking a mode unticks the other"   "$out" "SWITCH:gluetun,comet,stremio-lan"
contains "a companion follows either mode"    "$out" "COMPANION:gluetun,comet,stremio-lan"
contains "dropping the mode drops the rest"   "$out" "DROP:also unticked: comet|gluetun"
contains "select-all keeps the first mode"    "$out" "ALL:gluetun,stremio,comet"
contains "  and says which it left out"       "$out" "MSG:left unticked (conflict): stremio-lan"

printf '\nservices-test.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
