#!/bin/sh
# Tests for scripts/stack-up.sh, the start sequence shared by the systemd unit
# and `make update`, and for scripts/run-hooks.sh, which declares the hooks that
# sequence runs. CI runs the same two phases against the stack it starts, so the
# list has to have exactly one home.
#
# Everything runs against a throwaway copy of the scripts with stub hooks and a
# stub `docker` on PATH, so no container, no systemd and no host change.
# Run with `make test`.
set -eu

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
SCRIPT="$REPO_DIR/scripts/stack-up.sh"
HOOKS="$REPO_DIR/scripts/run-hooks.sh"
UNIT="$REPO_DIR/config/systemd/system/pi-pcloud.service"
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

# The entries run-hooks.sh declares, in order: "script.sh", "service:script.sh",
# or "service,service:script.sh" for a hook whose service is started by more
# than one profile.
hook_entries() {
    grep -oE '^[a-z0-9,-]*:?[a-z0-9-]+\.sh$' "$HOOKS"
}

# --- the sequence is complete -----------------------------------------------
#
# The drift this file exists to catch: a hook script sitting in scripts/ that
# nothing in the sequence runs. By filename convention, so a service added
# later is covered without touching this test.

declared="$(hook_entries | sed 's/.*://' | sort -u)"
for path in "$REPO_DIR"/scripts/*-pre-start.sh "$REPO_DIR"/scripts/*-bootstrap.sh; do
    name="$(basename "$path")"
    if printf '%s\n' "$declared" | grep -qx "$name"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s is in scripts/ but run-hooks.sh never runs it\n' "$name"
    fi
done

# --- a generated file is handed back to the project owner --------------------
#
# The systemd unit runs these as root, so a file a hook generates lands
# root:root 0600. The next non-root `make update` then dies inside the blocking
# pre-start phase reading its own secret, and a non-root `docker compose up`
# cannot read an env_file it just wrote - `required: false` covers a missing
# file, not an unreadable one. Three hooks shipped without the handback before
# this was checked, so it is checked rather than remembered.
#
# safe_chmod is the signal because it is lib.sh's host-path helper: a bootstrap
# that writes inside a container (shelfmark's, through `docker exec`) chowns to
# the service's own uid instead and must not appear here.
for path in "$REPO_DIR"/scripts/*-pre-start.sh "$REPO_DIR"/scripts/*bootstrap.sh; do
    grep -qE 'safe_chmod 6[0-7][0-7]' "$path" || continue
    name="$(basename "$path")"
    if grep -q 'fix_ownership' "$path"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s writes a 0600 file and never calls fix_ownership\n' "$name"
    fi
done

# And exactly one home for it: a list left behind in stack-up.sh would be the
# one the boot path used while CI kept running the other.
ok "stack-up.sh declares no hook list of its own" \
    "$(grep -cE '^[a-z0-9,-]*:?[a-z0-9-]+\.sh$' "$SCRIPT" || true)" 0

# The unit must go through the script, or boot and update drift apart again.
contains "the unit starts the stack through stack-up.sh" \
    "$(grep '^ExecStart=' "$UNIT")" "scripts/stack-up.sh"

# --- a sandbox that runs the real script ------------------------------------

mkdir -p "$WORK/scripts" "$WORK/bin"
cp "$SCRIPT" "$HOOKS" "$REPO_DIR/scripts/lib.sh" "$REPO_DIR/scripts/run-if-enabled.sh" "$WORK/scripts/"

# One stub per declared hook, announcing itself so the run is a transcript.
hook_entries | sed 's/.*://' | sort -u | while read -r name; do
    printf '#!/bin/sh\necho "HOOK %s"\n' "$name" >"$WORK/scripts/$name"
done

# Announces every call, and fails the next `up` once when the control file
# exists — enough to exercise the fallback without looping.
cat >"$WORK/bin/docker" <<STUB
#!/bin/sh
echo "DOCKER \$*"
if [ "\$1" = compose ] && [ "\$2" = up ] && [ -f "$WORK/fail-up" ]; then
    cat "$WORK/fail-up"
    rm -f "$WORK/fail-up"
    exit 1
fi
exit 0
STUB
chmod +x "$WORK/bin/docker"
PATH="$WORK/bin:$PATH"
export PATH

# run_rc <compose-profiles-line> [args...] : write the .env line ("none" for no
# COMPOSE_PROFILES at all), run the script once — the stub's failure mode is
# one-shot, so a second run would not see it — and leave the output in $out and
# the status in $rc. COMPOSE_PROFILES is unset, the way make leaves it.
run_rc() {
    if [ "$1" = none ]; then
        : >"$WORK/.env"
    else
        printf 'COMPOSE_PROFILES=%s\n' "$1" >"$WORK/.env"
    fi
    shift
    out="$(env -u COMPOSE_PROFILES sh "$WORK/scripts/stack-up.sh" "$@" 2>&1)" && rc=0 || rc=$?
}

# Same, for the cases that only care about the output.
run() {
    run_rc "$@"
    printf '%s\n' "$out"
}

# --- no arguments -----------------------------------------------------------
#
# Refused rather than ignored, so a caller passing an option is told instead of
# silently getting a different start than the unit's.

run_rc all --remove-orphans
ok       "an argument is refused"             "$rc" 1
contains "and named"                          "$out" "takes no arguments"

# --- gating -----------------------------------------------------------------

out="$(run qbittorrent)"
contains "an ungated hook always runs"        "$out" "HOOK authelia-pre-start.sh"
contains "the selected service's hook runs"   "$out" "HOOK qbittorrent-pre-start.sh"
contains "and so does its bootstrap"          "$out" "HOOK qbittorrent-bootstrap.sh"
lacks    "an unselected service is skipped"   "$out" "HOOK prowlarr-pre-start.sh"

# agentgateway carries open-webui's profile as well as its own, so a hook gated
# on its own name alone was skipped on exactly the boots that start it.
out="$(run open-webui)"
contains "a hook gated on two profiles runs on either" "$out" "HOOK agentgateway-pre-start.sh"
lacks    "and still gates an unrelated service"        "$out" "HOOK kavita-pre-start.sh"

# A .env with no COMPOSE_PROFILES line is a pre-profiles install: everything is
# enabled, matching the unit's Environment=COMPOSE_PROFILES=all fallback.
out="$(run none)"
contains "no line at all means everything"    "$out" "HOOK prowlarr-pre-start.sh"

# A verbatim .env read hands back the quotes; unstripped, the selection matches
# nothing while --remove-orphans deletes the containers.
out="$(run '"qbittorrent"')"
contains "a quoted value is unquoted"         "$out" "HOOK qbittorrent-pre-start.sh"
lacks    "and still gates the others"         "$out" "HOOK prowlarr-pre-start.sh"

# Defined but empty is core-only — what docker compose itself does with it.
out="$(run "")"
contains "core hooks still run when empty"    "$out" "HOOK ntfy-pre-start.sh"
lacks    "empty selects no optional service"  "$out" "HOOK kavita-oidc-bootstrap.sh"

# --- stremio / stremio-lan are exclusive ------------------------------------
#
# One server in two networking modes, sharing a data volume and the same Traefik
# host rules. Refused before anything starts rather than left to fight at runtime.

run_rc stremio,stremio-lan
ok       "both stremio modes are refused"     "$rc" 1
contains "and the reason is named"            "$out" "stremio-lan"

run_rc stremio
ok       "stremio alone is fine"              "$rc" 0

run_rc stremio-lan
ok       "stremio-lan alone is fine"          "$rc" 0

# "all" does not carry stremio-lan, so the catch-all must not trip the guard.
run_rc all
ok       "all is not treated as both"         "$rc" 0

# It does carry stremio, though: adding stremio-lan to it is the same conflict
# spelled differently, and the obvious way someone would reach for casting.
run_rc all,stremio-lan
ok       "all plus stremio-lan is refused"    "$rc" 1
contains "and the reason is named"            "$out" "stremio-lan"

# Exact entries only: the substring must not make stremio-lan match stremio.
run_rc stremio-lan,comet
ok       "no substring match on the guard"    "$rc" 0

# --- ordering and the compose call ------------------------------------------

# --remove-orphans is the script's own, so both callers get the same start.
out="$(run all)"
contains "compose is asked to start the stack" "$out" "DOCKER compose up -d --remove-orphans"

# Configuration is rendered before anything starts, bootstraps only after.
order="$(printf '%s\n' "$out" | grep -nE 'HOOK authelia-pre-start|DOCKER compose up|HOOK homepage-widgets')"
ok "pre-start, then up, then bootstrap" \
    "$(printf '%s\n' "$order" | sed 's/^[0-9]*://' | cut -d' ' -f1-2 | tr '\n' '|')" \
    "HOOK authelia-pre-start.sh|DOCKER compose|HOOK homepage-widgets-bootstrap.sh|"

# --- failure semantics ------------------------------------------------------
#
# The `-` prefix the unit used to carry, now expressed by the two lists: a
# pre-start failure must stop the start, a bootstrap failure must not.

printf '#!/bin/sh\nexit 1\n' >"$WORK/scripts/ntfy-pre-start.sh"
run_rc all
ok       "a failed pre-start hook fails the start" "$rc" 1
lacks    "and nothing is started"                  "$out" "DOCKER compose up"
printf '#!/bin/sh\necho "HOOK ntfy-pre-start.sh"\n' >"$WORK/scripts/ntfy-pre-start.sh"

printf '#!/bin/sh\nexit 1\n' >"$WORK/scripts/pihole-bootstrap.sh"
run_rc all
ok       "a failed bootstrap does not fail the start" "$rc" 0
contains "it warns instead"                           "$out" "pihole-bootstrap.sh failed"
contains "and the later bootstraps still run"         "$out" "HOOK homepage-widgets-bootstrap.sh"

# --- a hook that went missing -----------------------------------------------
#
# Same rule as a failure: fatal before the start, a warning after it — and for
# a disabled service, nothing at all, as the unit's gate did.

rm -f "$WORK/scripts/kavita-oidc-bootstrap.sh"
run_rc all
ok       "a missing bootstrap does not fail the start"    "$rc" 0
contains "it is named"                                    "$out" "kavita-oidc-bootstrap.sh is missing"

rm -f "$WORK/scripts/prowlarr-pre-start.sh"
run_rc qbittorrent
ok       "a disabled service's missing hook is ignored"   "$rc" 0
lacks    "and is not reported as missing"                 "$out" "prowlarr-pre-start.sh is missing"
contains "the start goes ahead"                           "$out" "DOCKER compose up"
printf '#!/bin/sh\necho "HOOK prowlarr-pre-start.sh"\n' >"$WORK/scripts/prowlarr-pre-start.sh"

rm -f "$WORK/scripts/backrest-pre-start.sh"
run_rc all
ok       "a missing pre-start hook fails the start"       "$rc" 1
lacks    "and nothing is started either"                  "$out" "DOCKER compose up"
printf '#!/bin/sh\necho "HOOK backrest-pre-start.sh"\n' >"$WORK/scripts/backrest-pre-start.sh"

# --- a network or volume definition that moved ------------------------------
#
# compose cannot apply that in place, so it has to be allowed one down — or an
# update aborts with the images already pulled.

printf 'network pi-web_default was found but has incorrect label\n' >"$WORK/fail-up"
out="$(run all)"
contains "the failure is diagnosed"      "$out" "needs the stack down"
contains "compose is allowed a down"     "$out" "DOCKER compose down --remove-orphans"
ok "and the up is retried after it" \
    "$(printf '%s\n' "$out" | grep -c 'DOCKER compose up -d --remove-orphans')" 2

# Any other failure is a real one and must not be papered over with a restart.
printf 'error: pull access denied for ghcr.io/nope\n' >"$WORK/fail-up"
run_rc all
ok       "an unrelated failure stops the start" "$rc" 1
lacks    "without taking the stack down"        "$out" "DOCKER compose down"

# --- what a caller other than the boot path may ask for ---------------------
#
# CI runs the same two phases, and needs two things the unit does not: a hook it
# cannot satisfy at all left out (there is no headscale container on a runner),
# and the bootstraps held to the same standard as the pre-starts, because there a
# bootstrap that cannot finish is the thing under test.

# The cases above left two stubs broken on purpose; put every one of them back,
# so what follows tests run-hooks.sh and not the wreckage of an earlier case.
hook_entries | sed 's/.*://' | sort -u | while read -r name; do
    printf '#!/bin/sh\necho "HOOK %s"\n' "$name" >"$WORK/scripts/$name"
done

# run_hooks <compose-profiles> <phase> [mode] : as run_rc, for run-hooks.sh.
run_hooks() {
    printf 'COMPOSE_PROFILES=%s\n' "$1" >"$WORK/.env"
    shift
    out="$(env -u COMPOSE_PROFILES sh "$WORK/scripts/run-hooks.sh" "$@" 2>&1)" && rc=0 || rc=$?
}

run_hooks all pre-start
ok       "the pre-start phase runs on its own"   "$rc" 0
contains "and runs the pre-start hooks"          "$out" "HOOK authelia-pre-start.sh"
lacks    "and only those"                        "$out" "HOOK postgres-bootstrap.sh"

run_hooks all post-start
ok       "the post-start phase runs on its own"  "$rc" 0
contains "and runs the bootstraps"               "$out" "HOOK postgres-bootstrap.sh"
lacks    "and only those"                        "$out" "HOOK authelia-pre-start.sh"

run_hooks all sideways
ok       "an unknown phase is refused"           "$rc" 1
contains "and named"                             "$out" "pre-start|post-start"

run_hooks all post-start sideways
ok       "an unknown mode is refused"            "$rc" 1
contains "and named"                             "$out" "blocking or tolerant"

# HOOKS_SKIP leaves one out entirely — and says so, so a list that grew stays
# visible in the log it was added to keep quiet.
out="$(HOOKS_SKIP=postgres-bootstrap.sh env -u COMPOSE_PROFILES \
    sh "$WORK/scripts/run-hooks.sh" post-start 2>&1)"
lacks    "a skipped hook does not run"           "$out" "HOOK postgres-bootstrap.sh"
contains "and the skip is logged"                "$out" "postgres-bootstrap.sh skipped (HOOKS_SKIP)"
contains "the rest still run"                    "$out" "HOOK homepage-widgets-bootstrap.sh"

# The mode the caller asks for wins: the same failing bootstrap that must not
# stop a boot has to fail a CI run.
printf '#!/bin/sh\nexit 1\n' >"$WORK/scripts/pihole-bootstrap.sh"
run_hooks all post-start
ok       "a failed bootstrap is tolerated by default" "$rc" 0
run_hooks all post-start blocking
ok       "and fatal when the caller asks for blocking" "$rc" 1
contains "and named"                                   "$out" "pihole-bootstrap.sh failed"
printf '#!/bin/sh\necho "HOOK pihole-bootstrap.sh"\n' >"$WORK/scripts/pihole-bootstrap.sh"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
