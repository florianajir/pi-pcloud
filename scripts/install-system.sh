#!/bin/sh
# Everything this repository installs outside itself: sysctl, swap, the kernel
# command line, the /etc/hosts record, the systemd units (rendered with this
# checkout's path) and the pi-pcloud command. `make install` runs it, and
# `make update` again after every pull: these are copies, so a unit or a
# completion changed upstream would otherwise sit stale on the host until the
# next install. Every step is idempotent.
#
# `install-system.sh --remove` takes all of it back out, for `make uninstall`,
# from the same lists - so nothing installed here can be forgotten there.
#
# Host-only, never mounted into a container, so sourcing lib.sh is fine here.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

UNITS_DIR="$PROJECT_DIR/config/systemd/system"
RENDERED_UNITS='pi-pcloud.service pi-pcloud-authelia-ntfy.service
pi-pcloud-wan-allowlist.service nextcloud-cron.service tuwunel-backup.service
openclaw-sync.service pi-pcloud-kuma-watchdog.service'
ENABLED_UNITS='pi-pcloud.service pi-pcloud-authelia-ntfy.service'
TIMERS='nextcloud-cron.timer pi-pcloud-wan-allowlist.timer tuwunel-backup.timer
openclaw-sync.timer pi-pcloud-kuma-watchdog.timer'

# /usr/local/bin is on PATH for both users and sudo; the completion directories
# are Debian's own.
BIN_LINK=/usr/local/bin/pi-pcloud
BASH_COMPLETION=/usr/share/bash-completion/completions/pi-pcloud
ZSH_COMPLETION=/usr/share/zsh/vendor-completions/_pi-pcloud
SYSCTL_DROP_IN=/etc/sysctl.d/99-pi-pcloud.conf
HOSTS_BEGIN='# pi-pcloud local overrides'
HOSTS_END='# end pi-pcloud local overrides'

# By path, not by name: sysctl lives in /usr/sbin, which a root shell entered
# with `su` (no dash) does not have on its PATH - and $SUDO is empty there, so
# sudo's secure_path does not cover it either.
sysctl_command() {
    local candidate=""
    for candidate in /usr/sbin/sysctl /sbin/sysctl; do
        if [ -x "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    printf 'sysctl'
}

apply_sysctl() {
    echo "🧰 Applying host sysctl settings..."
    $SUDO cp "$PROJECT_DIR/config/sysctl.d/pi-pcloud.conf" "$SYSCTL_DROP_IN"
    $SUDO "$(sysctl_command)" --system >/dev/null
}

remove_sysctl() {
    echo "🧰 Removing host sysctl settings..."
    $SUDO rm -f "$SYSCTL_DROP_IN"
    $SUDO "$(sysctl_command)" --system >/dev/null
}

# Both best-effort, never blocking: a host that cannot take a bigger swap file
# is not a failed install, and the kernel parameters are diagnostics and
# performance settings a reboot picks up, not prerequisites. Each script says
# why it skipped.
apply_boot_settings() {
    echo "💽 Sizing host swap..."
    run_script configure-swap.sh || echo "  ⚠ swap sizing skipped"
    echo "🐧 Applying kernel command-line parameters..."
    run_script configure-kernel-params.sh || echo "  ⚠ kernel parameters skipped"
}

restore_boot_settings() {
    echo "💽 Restoring original swap config..."
    run_script configure-swap.sh remove || echo "  ⚠ swap config left as it is"
    echo "🐧 Removing kernel command-line parameters..."
    run_script configure-kernel-params.sh remove || echo "  ⚠ kernel parameters left as they are"
}

drop_hosts_override() {
    $SUDO sed -i "/$HOSTS_BEGIN/,/$HOSTS_END/d" /etc/hosts
}

add_hosts_override() {
    local host_name="" lan_ip=""
    echo "🌐 Adding local DNS overrides to /etc/hosts..."
    host_name="$(get_env_value HOST_NAME)"
    lan_ip="$(get_env_value HOST_LAN_IP)"
    if [ -z "$host_name" ] || [ -z "$lan_ip" ]; then
        echo "  ⚠ HOST_NAME or HOST_LAN_IP not set, skipping"
        return 0
    fi
    drop_hosts_override
    printf '%s\n%s\theadscale.%s\n%s\n' "$HOSTS_BEGIN" "$lan_ip" "$host_name" "$HOSTS_END" |
        $SUDO tee -a /etc/hosts >/dev/null
    echo "  ✔ headscale.$host_name -> $lan_ip"
}

remove_hosts_override() {
    echo "🌐 Removing local DNS overrides from /etc/hosts..."
    drop_hosts_override
}

# Rendered through mktemp rather than a predictable /tmp path: any other local
# account could pre-create /tmp/<unit> as a symlink it controls and have its own
# ExecStart installed as a root unit by the sudo below. mktemp also keeps the
# destination untouched if the render fails.
install_systemd_units() {
    local lan_parent="" project_path="" unit=""
    lan_parent="$(get_env_value_clean HOST_LAN_PARENT)"
    lan_parent="$(sed_escape "${lan_parent:-eth0}")"
    project_path="$(sed_escape "$PROJECT_DIR")"
    RENDERED_UNIT="$(mktemp)"
    trap 'rm -f "$RENDERED_UNIT"' EXIT
    trap 'exit 1' INT TERM
    for unit in $RENDERED_UNITS; do
        sed -e "s|__PROJECT_PATH__|$project_path|g" \
            -e "s|__HOST_LAN_PARENT__|$lan_parent|g" \
            "$UNITS_DIR/$unit" >"$RENDERED_UNIT"
        $SUDO install -m 644 -o root -g root "$RENDERED_UNIT" "/etc/systemd/system/$unit"
    done
    for unit in $TIMERS; do
        $SUDO cp "$UNITS_DIR/$unit" /etc/systemd/system/
    done
    $SUDO systemctl daemon-reload
    # shellcheck disable=SC2086 # deliberate word splitting, one unit per word
    $SUDO systemctl enable $ENABLED_UNITS
    # --now on the timers: `enable` alone arms them for the next boot only, so a
    # fresh install waits until then for the first run.
    # shellcheck disable=SC2086 # deliberate word splitting, one timer per word
    $SUDO systemctl enable --now $TIMERS
    echo "✅ Systemd units installed"
}

# Stopping pi-pcloud.service runs its ExecStop, `docker compose down`; the
# timers stop with it, so no backup or cron run starts against a stack being
# taken apart. Errors are silenced because a unit already gone is the expected
# case on a half-removed host.
# shellcheck disable=SC2086 # the unit lists are split on purpose
remove_systemd_units() {
    local unit=""
    echo "🧹 Removing systemd units..."
    $SUDO systemctl stop $TIMERS $RENDERED_UNITS 2>/dev/null
    $SUDO systemctl disable $TIMERS $ENABLED_UNITS 2>/dev/null
    for unit in $RENDERED_UNITS $TIMERS; do
        $SUDO rm -f "/etc/systemd/system/$unit"
    done
    $SUDO systemctl daemon-reload
}

# A symlink, not a copy: the command follows this checkout, so a git pull
# updates it and there is no rendered duplicate to drift.
install_command() {
    echo "🔗 Installing the pi-pcloud command..."
    $SUDO ln -sfn "$PROJECT_DIR/scripts/pi-pcloud" "$BIN_LINK"
    $SUDO mkdir -p "$(dirname "$BASH_COMPLETION")" "$(dirname "$ZSH_COMPLETION")"
    $SUDO cp "$PROJECT_DIR/config/completion/pi-pcloud.bash" "$BASH_COMPLETION"
    $SUDO cp "$PROJECT_DIR/config/completion/_pi-pcloud" "$ZSH_COMPLETION"
    echo "✅ pi-pcloud available on PATH (new shells get completion)"
}

remove_command() {
    echo "🧹 Removing the pi-pcloud command..."
    $SUDO rm -f "$BIN_LINK" "$BASH_COMPLETION" "$ZSH_COMPLETION"
}

install_all() {
    echo "📦 Installing system files..."
    apply_sysctl
    apply_boot_settings
    add_hosts_override
    install_systemd_units
    install_command
}

# Best-effort throughout: a step that fails must not leave the rest of the host
# integration behind.
remove_all() {
    set +e
    remove_systemd_units
    remove_command
    remove_hosts_override
    remove_sysctl
    restore_boot_settings
}

case "$*" in
    "") install_all ;;
    --remove) remove_all ;;
    *) die "usage: $(basename "$0") [--remove]" ;;
esac
