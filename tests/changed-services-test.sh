#!/bin/sh
# Tests for scripts/changed-services.sh, which decides what `make update` does
# with a pull: recreate one container, recreate a few, or take all 46 down.
#
# Both wrong answers are expensive and only one of them is loud. Naming too much
# costs a restart nobody needed; naming too little leaves a service reading the
# config the pull replaced, with nothing on the host to say so. So the
# conventions are asserted here in both directions, against the real exception
# lists in the script.
#
# Everything runs against a throwaway git repository with a stub `docker` on
# PATH, so no container, no compose render and no host change. Run with
# `make test`.
set -eu

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
SCRIPT="$REPO_DIR/scripts/changed-services.sh"
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

# The compose render, stubbed: `all,stremio-lan` is the ownership list (every
# declared service), anything else is the enablement one. They differ on
# purpose, and the way a real host differs - stremio and stremio-lan are the
# same server in two networking modes, so a host runs exactly one of them, and
# freshrss stands for a service the operator turned off.
ALL_SERVICES='traefik kavita ntfy backrest uptime-kuma immich-server
immich-machine-learning gluetun qbittorrent kapowarr stremio stremio-lan
postgres freshrss'
ENABLED_SERVICES='traefik kavita ntfy backrest uptime-kuma immich-server
immich-machine-learning gluetun qbittorrent kapowarr stremio-lan postgres'
export ALL_SERVICES ENABLED_SERVICES

mkdir -p "$WORK/scripts" "$WORK/bin"
cp "$SCRIPT" "$REPO_DIR/scripts/lib.sh" "$WORK/scripts/"

cat >"$WORK/bin/docker" <<'STUB'
#!/bin/sh
if [ "$1" = compose ] && [ "$2" = config ] && [ "$3" = --services ]; then
    case "${COMPOSE_PROFILES:-}" in
        all,stremio-lan) printf '%s\n' $ALL_SERVICES ;;
        *) printf '%s\n' $ENABLED_SERVICES ;;
    esac
    exit 0
fi
exit 0
STUB
chmod +x "$WORK/bin/docker"
PATH="$WORK/bin:$PATH"
export PATH

# Not `all,stremio-lan`, or the stub could not tell the two questions apart.
printf 'COMPOSE_PROFILES=kavita,ntfy\n' >"$WORK/.env"

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
git -C "$WORK" init -q
git -C "$WORK" add -A
git -C "$WORK" commit -qm base

# answer <label> <expected> <path>... : commit the paths as one change, ask the
# script about that commit, and compare. The expected value is the whole stdout
# with newlines folded to spaces, so "" asserts that nothing is recreated - the
# answer that is right for a host-only script and wrong for everything else.
answer() {
    _label="$1"
    _want="$2"
    shift 2
    # A comment line, because one of the paths under test is the copy of
    # lib.sh this very script sources: the change has to be visible to git and
    # invisible to everything else.
    for _p in "$@"; do
        mkdir -p "$(dirname "$WORK/$_p")"
        printf '# %s\n' "$(date +%s%N)" >>"$WORK/$_p"
    done
    git -C "$WORK" add -A
    git -C "$WORK" commit -qm "$_label"
    _got="$(env -u COMPOSE_PROFILES /bin/sh "$WORK/scripts/changed-services.sh" HEAD~1 HEAD |
        tr '\n' ' ' | sed 's/ $//')"
    ok "$_label" "$_got" "$_want"
}

# --- the conventions ---------------------------------------------------------

answer "a config tree names its own service"       "kavita" config/kavita/settings.json
answer "so does a script prefix"                   "kavita" scripts/kavita-pre-start.sh
answer "and both together name it once"            "kavita" \
    config/kavita/settings.json scripts/kavita-pre-start.sh

# The longest prefix wins, and it is resolved against every *declared* service:
# with the enabled list instead, stremio-lan-pre-start.sh would read as
# stremio's on the one host that runs stremio-lan, and be dropped in silence.
answer "the longest service name owns a script"    "stremio-lan" \
    scripts/stremio-lan-pre-start.sh

# --- the couplings -----------------------------------------------------------

# ntfy.env is an env_file for backrest and uptime-kuma, and env_file values are
# frozen at container creation: a restart keeps the old token.
answer "an env_file drags its readers along" "backrest ntfy uptime-kuma" \
    config/ntfy/ntfy.env

# qbittorrent, stremio and kapowarr run in gluetun's network namespace, which
# docker resolves to a container id at create time. stremio is declared and not
# enabled here, so it is filtered out rather than passed to compose.
answer "a shared namespace does too" "gluetun kapowarr qbittorrent" \
    config/gluetun/gluetun.env

answer "a config tree read under another name" \
    "immich-machine-learning immich-server" config/immich/config.yaml

# --- nothing to recreate -----------------------------------------------------

answer "host-side tooling touches no container"     "" scripts/lint.sh
answer "a per-invocation backup hook neither"       "" scripts/db-backup.sh
answer "nor a file install-system copies to /etc"   "" config/completion/pi-pcloud.bash
answer "nor the sysctl drop-in"                     "" config/sysctl.d/pi-pcloud.conf
answer "nor a path outside config/ and scripts/"    "" docs/COMMANDS.md
answer "nor a disabled service's own config"        "" config/freshrss/x.php

# /docker-entrypoint-initdb.d/ is read over an empty data directory and never
# again, so recreating postgres for it applies nothing - while `--no-deps`
# leaves every service holding a connection to that database unrestarted through
# the bounce. Exempt by path and not by directory, which the second assertion is
# what proves.
answer "nor a file only a first init reads"         "" \
    config/postgres/init-databases.sh
answer "but the rest of that tree still counts"     "postgres" \
    config/postgres/postgresql.conf

# --- everything ---------------------------------------------------------------
#
# A systemd unit is copied to /etc like the two above, but install-system only
# reloads the definition - it never restarts the unit - so a changed
# ExecStartPre or Environment= would sit loaded and unapplied until the next
# reboot. Only the restart applies it.
#
# The fallback is the whole safety argument: a config nothing recreates is a
# config nothing reads, so a path the convention cannot attribute must answer
# ALL rather than silently answer nothing.

answer "the shared start path answers ALL"   "ALL" scripts/lib.sh
answer "a systemd unit does too"             "ALL" config/systemd/system/pi-pcloud.service
answer "an unowned config tree too"          "ALL" config/notaservice/settings.yaml
answer "a loose file straight under config/" "ALL" config/settings.yaml
answer "a script naming no service"          "ALL" scripts/nothing-owns-this.sh
answer "a script in a subdirectory of it"    "ALL" scripts/helpers/thing.sh

# One unattributable path is enough, however much else in the same pull is
# perfectly attributable.
answer "and one such path outvotes the rest" "ALL" \
    config/kavita/settings.json config/notaservice/settings.yaml

# --- usage -------------------------------------------------------------------

rc=0
env -u COMPOSE_PROFILES /bin/sh "$WORK/scripts/changed-services.sh" HEAD >/dev/null 2>&1 || rc=$?
ok "one revision is a usage error" "$rc" 1

printf 'changed-services-test.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
