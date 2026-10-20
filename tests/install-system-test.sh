#!/bin/sh
# Tests for scripts/install-system.sh, which puts the stack's files on the host
# and takes them back out (--remove), and for scripts/uninstall.sh, which wraps
# that removal with the data's.
#
# Both run against a throwaway checkout with a `sudo` stub that records each
# privileged command and runs none of them, so no file outside $WORK is written
# or deleted. What a command *would* install or remove is computed by the stub,
# which is what lets the removal be checked against the install: anything put on
# the host must come back off it. Run with `make test`.
set -eu

# Under root lib.sh leaves SUDO empty, so every privileged command - an rm
# under /etc included - would run for real instead of reaching the stub.
if [ "$(id -u)" = "0" ]; then
    echo "install-system-test.sh: skipped as root (the sudo stub cannot intercept)"
    exit 0
fi

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
        *) ok "$1" "$2" "(contains) $3" ;;
    esac
}

lacks() {
    case "$2" in
        *"$3"*) ok "$1" "$2" "(lacks) $3" ;;
        *) ok "$1" yes yes ;;
    esac
}

CALLS="$WORK/calls"
INSTALLED="$WORK/installed"
REMOVED="$WORK/removed"
HOSTS_OUT="$WORK/hosts"
UNITS_OUT="$WORK/units"
export CALLS INSTALLED REMOVED HOSTS_OUT UNITS_OUT

# --- stubs ----------------------------------------------------------------------

mkdir -p "$WORK/bin" "$UNITS_OUT"

# Records the command and, for one that writes or deletes a host path, which
# path: the destination of a cp/install/ln (a directory destination gets the
# source's name, as cp would), every operand of an rm. Runs nothing.
cat >"$WORK/bin/sudo" <<'STUB'
#!/bin/sh
echo "sudo $*" >>"$CALLS"
if [ -n "${FAIL_SUDO:-}" ]; then
    case "$*" in *"$FAIL_SUDO"*) exit 1 ;; esac
fi
case "$1" in
    cp | install | ln)
        eval "src=\${$(($# - 1))}"
        eval "dst=\${$#}"
        case "$dst" in */) dst="$dst$(basename "$src")" ;; esac
        echo "$dst" >>"$INSTALLED"
        [ "$1" != install ] || cp "$src" "$UNITS_OUT/$(basename "$dst")"
        ;;
    rm)
        shift
        for arg in "$@"; do
            case "$arg" in -*) ;; *) echo "$arg" >>"$REMOVED" ;; esac
        done
        ;;
    tee) cat >>"$HOSTS_OUT" ;;
esac
exit 0
STUB

cat >"$WORK/bin/docker" <<'STUB'
#!/bin/sh
echo "docker $*" >>"$CALLS"
STUB

chmod +x "$WORK/bin/"*
PATH="$WORK/bin:$PATH"
export PATH

# --- a checkout ------------------------------------------------------------------

APP="$WORK/app"
mkdir -p "$APP/scripts" "$APP/config"
cp "$REPO_DIR/scripts/install-system.sh" "$REPO_DIR/scripts/uninstall.sh" \
    "$REPO_DIR/scripts/lib.sh" "$APP/scripts/"
cp -R "$REPO_DIR/config/systemd" "$REPO_DIR/config/sysctl.d" \
    "$REPO_DIR/config/completion" "$APP/config/"
for stub in configure-swap.sh configure-kernel-params.sh; do
    printf '#!/bin/sh\necho "%s $*" >>"$CALLS"\n' "$stub" >"$APP/scripts/$stub"
done

write_env() {
    printf 'HOST_NAME=example.test\nHOST_LAN_IP=192.0.2.10\nHOST_LAN_PARENT="eth1"\n' >"$APP/.env"
    [ -z "${1:-}" ] || printf 'POSTGRES_DATA_LOCATION=%s\n' "$1" >>"$APP/.env"
}
write_env

reset_records() {
    : >"$CALLS"
    : >"$INSTALLED"
    : >"$REMOVED"
    : >"$HOSTS_OUT"
}

# Sets $out and $rc.
run() {
    rc=0
    out="$(env -u PROJECT_DIR -u ENV_FILE "$@" 2>&1)" || rc=$?
}

# --- install ---------------------------------------------------------------------

reset_records
run sh "$APP/scripts/install-system.sh"
ok "install succeeds" "$rc" 0
cp "$INSTALLED" "$WORK/installed-by-install"

for unit in "$APP"/config/systemd/system/*.service; do
    name="$(basename "$unit")"
    if [ -f "$UNITS_OUT/$name" ]; then
        rendered="$(cat "$UNITS_OUT/$name")"
        lacks "$name is rendered with no placeholder left" "$rendered" "__"
    else
        ok "$name is installed" no yes
    fi
done
for timer in "$APP"/config/systemd/system/*.timer; do
    contains "$(basename "$timer") is installed" "$(cat "$INSTALLED")" \
        "/etc/systemd/system/$(basename "$timer")"
done

stack_unit="$(cat "$UNITS_OUT/pi-pcloud.service")"
contains "the stack unit runs from this checkout" "$stack_unit" "ExecStart=/bin/sh $APP/scripts/stack-up.sh"
contains "  with HOST_LAN_PARENT unquoted" "$stack_unit" "ethtool -K eth1 "

ok "the /etc/hosts block names headscale" "$(cat "$HOSTS_OUT")" "$(printf '%s\n%s\theadscale.%s\n%s' \
    '# pi-pcloud local overrides' 192.0.2.10 example.test '# end pi-pcloud local overrides')"
contains "the command links into the checkout" "$(cat "$CALLS")" \
    "sudo ln -sfn $APP/scripts/pi-pcloud /usr/local/bin/pi-pcloud"
contains "swap is sized" "$(cat "$CALLS")" "configure-swap.sh "
contains "the timers start now, not at the next boot" "$(cat "$CALLS")" "systemctl enable --now nextcloud-cron.timer"

# --- remove -----------------------------------------------------------------------

reset_records
run sh "$APP/scripts/install-system.sh" --remove
ok "remove succeeds" "$rc" 0
missing=""
while read -r path; do
    grep -qxF "$path" "$REMOVED" || missing="$missing $path"
done <"$WORK/installed-by-install"
ok "everything install put on the host, remove takes off" "$missing" ""
contains "the stack and its timers are stopped" "$(cat "$CALLS")" "systemctl stop nextcloud-cron.timer"
contains "the /etc/hosts block is dropped" "$(cat "$CALLS")" \
    "sudo sed -i /# pi-pcloud local overrides/,/# end pi-pcloud local overrides/d /etc/hosts"
contains "the swap config is restored" "$(cat "$CALLS")" "configure-swap.sh remove"
contains "the kernel parameters are removed" "$(cat "$CALLS")" "configure-kernel-params.sh remove"

reset_records
run FAIL_SUDO="systemctl stop" sh "$APP/scripts/install-system.sh" --remove
contains "a failing step does not stop the removal" "$(cat "$REMOVED")" "/usr/local/bin/pi-pcloud"

reset_records
run sh "$APP/scripts/install-system.sh" --bogus
[ "$rc" -ne 0 ] && failed=yes || failed=no
ok "an unknown argument is refused" "$failed" yes
ok "  before anything runs" "$(cat "$CALLS")" ""

# --- uninstall: the confirmation ----------------------------------------------------

mkdir -p "$APP/data/nextcloud" "$APP/data/postgres18" "$APP/config/headscale" "$APP/config/ntfy"
: >"$APP/config/headscale/config.yaml"
: >"$APP/config/ntfy/ntfy.env"

# What the stub was asked to delete beyond the checkout's data and the host
# files install put there. lib.sh spells the default data root $APP/./data.
removed_outside() {
    grep -v -E -e "^$APP/(\./)?data/" -e '^/(etc|usr)/' "$REMOVED" || true
}

uninstall() {
    reset_records
    rc=0
    out="$(printf '%s\n' "$1" | env -u PROJECT_DIR -u ENV_FILE ${2:+PROJECT_DIR="$2"} \
        sh "$APP/scripts/uninstall.sh" 2>&1)" || rc=$?
}

uninstall no
[ "$rc" -ne 0 ] && failed=yes || failed=no
ok "anything but yes aborts" "$failed" yes
contains "  and says so" "$out" "Aborted"
ok "  before anything runs" "$(cat "$CALLS")" ""
ok "  and leaves the generated config" "$([ -f "$APP/config/headscale/config.yaml" ] && echo kept)" kept

uninstall YES
contains "the confirmation is exact" "$out" "Aborted"

reset_records
rc=0
out="$(env -u PROJECT_DIR -u ENV_FILE sh "$APP/scripts/uninstall.sh" </dev/null 2>&1)" || rc=$?
contains "no answer at all aborts" "$out" "Aborted"

# --- uninstall: what goes -------------------------------------------------------------

uninstall yes
ok "yes uninstalls" "$rc" 0
contains "  and says so" "$out" "✅ Uninstall complete"
first_stop="$(grep -n 'systemctl stop' "$CALLS" | head -n1 | cut -d: -f1)"
volumes="$(grep -n 'docker compose down -v' "$CALLS" | head -n1 | cut -d: -f1)"
ok "the stack stops before its volumes go" "$([ "${first_stop:-0}" -gt 0 ] && [ "$first_stop" -lt "${volumes:-0}" ] && echo yes)" yes
contains "the data directories go" "$(cat "$REMOVED")" "$APP/./data/nextcloud"
contains "  Nextcloud's config.php with them" "$(cat "$REMOVED")" "$APP/./data/nextcloud-config"
contains "  the versioned Postgres cluster too" "$(cat "$REMOVED")" "$APP/./data/postgres18"
ok "nothing is removed outside the checkout's data and the host files" "$(removed_outside)" ""
ok "the generated config goes" "$([ -e "$APP/config/headscale/config.yaml" ] || echo gone)" gone
ok ".env stays" "$([ -f "$APP/.env" ] && echo kept)" kept

mkdir -p "$WORK/elsewhere/data/nextcloud"
uninstall yes "$WORK/elsewhere"
lacks "an exported PROJECT_DIR is ignored" "$(cat "$REMOVED")" "$WORK/elsewhere"

# --- uninstall: a data root outside the checkout ------------------------------------------

write_env
printf 'DATA_LOCATION=%s\n' "$WORK/usb" >>"$APP/.env"
uninstall yes
contains "the data directories follow DATA_LOCATION" "$(cat "$REMOVED")" "$WORK/usb/nextcloud"
lacks "  and leave the checkout's data/ alone" "$(cat "$REMOVED")" "$APP/./data/nextcloud"

# --- uninstall: the cluster outside data/ ------------------------------------------------

mkdir -p "$WORK/nvme/postgres18"
write_env "$WORK/nvme"
uninstall yes
contains "a cluster under POSTGRES_DATA_LOCATION goes too" "$(cat "$REMOVED")" "$WORK/nvme/postgres18"

write_env /
uninstall yes
contains "a root that resolves to / is refused" "$out" "could not resolve the Postgres data root"
ok "  rather than expanded into /postgres*" \
    "$(removed_outside)" ""

printf 'install-system-test.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
