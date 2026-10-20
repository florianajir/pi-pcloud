#!/bin/sh
# Configure the host swap file size via dphys-swapfile (Raspberry Pi OS).
#
# Two settings matter, and only setting the first one silently does nothing:
# CONF_SWAPSIZE is the size we want, but /sbin/dphys-swapfile also carries its
# own CONF_MAXSWAP=2048 default and clamps CONF_SWAPSIZE down to it -
# "restricting to config limit". Any request above 2048 MB needs both raised.
#
# Applying a new size means swapoff, which pages every swapped-out anonymous
# page back into RAM. On a box whose swap is full that is a multi-GB spike, so
# the restart is guarded on available memory and otherwise deferred to reboot.
#
# Idempotent: re-runs are a no-op once the file and the live swap both match.
# Best-effort by design - a host that cannot take a bigger swap file should not
# fail `make install`.
#
# `configure-swap.sh remove` puts the original file back, for uninstall.

set -eu

. "$(dirname "$0")/lib.sh"

DPHYS_CONF="${DPHYS_CONF:-/etc/dphys-swapfile}"
# Headroom multiplier over the swap we have to page back in before we dare
# swapoff. 1.2 leaves 20% slack for whatever else allocates mid-restart.
# Overridable so the guard can be exercised without a real resize.
SAFETY_FACTOR_NUM="${SAFETY_FACTOR_NUM:-12}"
SAFETY_FACTOR_DEN="${SAFETY_FACTOR_DEN:-10}"

# --- Desired size -----------------------------------------------------------

resolve_swap_size_mb() {
    local size
    size="$(get_env_value_clean SWAP_SIZE_MB)"
    [ -n "$size" ] || size=8192

    case "$size" in
        '' | *[!0-9]*)
            die "SWAP_SIZE_MB must be a plain number of megabytes, got '$size'"
            ;;
    esac

    if [ "$size" -lt 256 ]; then
        die "SWAP_SIZE_MB=$size is too small to be deliberate (minimum 256)"
    fi

    printf '%s' "$size"
}

# --- /etc/dphys-swapfile edits ----------------------------------------------

# Set KEY=VALUE whether the line is currently set, commented out, or absent.
# dphys-swapfile ships CONF_MAXSWAP commented, so all three cases are real.
set_conf_key() {
    local key="$1"
    local value="$2"
    local file="$3"

    if grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" "$file"; then
        $SUDO sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}=.*|${key}=${value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" | $SUDO tee -a "$file" >/dev/null
    fi
}

conf_value() {
    # Last uncommented assignment wins, matching `.`-sourcing semantics.
    grep -E "^[[:space:]]*$1=" "$2" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"'
}

# --- Disk ceiling -----------------------------------------------------------

# dphys-swapfile carries a third clamp that neither CONF_SWAPSIZE nor
# CONF_MAXSWAP expresses: CONF_MAXDISK_PCT=50 caps the size at half of (free
# space + the swap file already there), and does it silently - "restricting to
# 50% of remaining disk size". A request above that is not refused, it is
# quietly shrunk, and then the idempotency check in main() never becomes true:
# every `make install-system` would swapoff and rebuild a multi-GB file chasing
# a size it can never reach, warning each time. So the same arithmetic runs
# here and an impossible request is declined once, with the number.
swapfile_path() {
    local path=""
    path="$(conf_value CONF_SWAPFILE "$DPHYS_CONF")"
    printf '%s' "${path:-/var/swap}"
}

swapfile_ceiling_mb() {
    local swapfile="$1"
    local avail_kb=""
    local current_kb=0

    avail_kb="$(df --output=avail "$(dirname "$swapfile")/." 2>/dev/null | tail -n1 | tr -d ' ')"
    case "$avail_kb" in
        '' | *[!0-9]*) return 1 ;;
    esac

    if [ -e "$swapfile" ]; then
        current_kb="$(stat --printf='%s' "$swapfile" 2>/dev/null || echo 0)"
        current_kb=$(( current_kb / 1024 ))
    fi

    printf '%s' $(( (avail_kb + current_kb) / 2048 ))
}

# --- Live swap state --------------------------------------------------------

active_swap_total_mb() {
    awk '/^SwapTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0
}

active_swap_used_mb() {
    awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END {printf "%d", (t-f)/1024}' \
        /proc/meminfo 2>/dev/null || echo 0
}

mem_available_mb() {
    awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0
}

# Whether we can afford to swapoff right now: everything currently in swap has
# to fit in available RAM, with headroom.
restart_is_safe() {
    local used avail needed
    used="$(active_swap_used_mb)"
    avail="$(mem_available_mb)"
    needed=$(( used * SAFETY_FACTOR_NUM / SAFETY_FACTOR_DEN ))

    if [ "$avail" -ge "$needed" ]; then
        return 0
    fi

    log "WARNING: not restarting dphys-swapfile now - ${used}MB is swapped out"
    log "         and only ${avail}MB RAM is available (need ~${needed}MB to"
    log "         page it back in). The new size applies on the next reboot."
    return 1
}

# The live swap keeps its size until the next reboot: shrinking it now would
# mean the same swapoff spike restart_is_safe guards against.
restore_original_conf() {
    if [ ! -f "$DPHYS_CONF.pi-pcloud.bak" ]; then
        log "No $DPHYS_CONF.pi-pcloud.bak; leaving $DPHYS_CONF as it is"
        return 0
    fi
    $SUDO mv "$DPHYS_CONF.pi-pcloud.bak" "$DPHYS_CONF"
    log "Restored $DPHYS_CONF (applies on next reboot)"
}

main() {
    case "$*" in
        "") ;;
        remove)
            restore_original_conf
            return 0
            ;;
        *) die "usage: $(basename "$0") [remove]" ;;
    esac

    if [ ! -f "$DPHYS_CONF" ]; then
        log "No $DPHYS_CONF (dphys-swapfile not installed); skipping swap sizing"
        return 0
    fi

    local desired current_size current_max active
    desired="$(resolve_swap_size_mb)"
    current_size="$(conf_value CONF_SWAPSIZE "$DPHYS_CONF")"
    current_max="$(conf_value CONF_MAXSWAP "$DPHYS_CONF")"
    active="$(active_swap_total_mb)"

    # Allow a little slop: dphys rounds, and /proc/meminfo reports slightly
    # less than the file size because of swap header pages.
    if [ "$current_size" = "$desired" ] && [ "$current_max" = "$desired" ] &&
        [ "$active" -ge $(( desired - 16 )) ]; then
        log "Swap already ${active}MB with CONF_SWAPSIZE/CONF_MAXSWAP=$desired; nothing to do"
        return 0
    fi

    local ceiling=""
    if ceiling="$(swapfile_ceiling_mb "$(swapfile_path)")" && [ "$desired" -gt "$ceiling" ]; then
        log "WARNING: SWAP_SIZE_MB=$desired is more than dphys-swapfile will allow here."
        log "         CONF_MAXDISK_PCT=50 caps it at ${ceiling}MB (half of the free space"
        log "         plus the current swap file). Leaving the swap file at ${active}MB:"
        log "         lower SWAP_SIZE_MB or free disk space, or every run would rebuild"
        log "         the file chasing a size it cannot reach."
        return 0
    fi

    if [ ! -f "$DPHYS_CONF.pi-pcloud.bak" ]; then
        $SUDO cp "$DPHYS_CONF" "$DPHYS_CONF.pi-pcloud.bak"
        log "Backed up original to $DPHYS_CONF.pi-pcloud.bak"
    fi

    set_conf_key CONF_SWAPSIZE "$desired" "$DPHYS_CONF"
    set_conf_key CONF_MAXSWAP "$desired" "$DPHYS_CONF"
    log "Set CONF_SWAPSIZE=$desired and CONF_MAXSWAP=$desired in $DPHYS_CONF"

    if [ "$active" -ge $(( desired - 16 )) ]; then
        log "Live swap is already ${active}MB; no restart needed"
        return 0
    fi

    if ! restart_is_safe; then
        return 0
    fi

    log "Resizing swap ${active}MB -> ${desired}MB (swapoff/swapon)..."
    if ! $SUDO systemctl restart dphys-swapfile; then
        log "WARNING: dphys-swapfile restart failed; new size applies on reboot"
        return 0
    fi

    active="$(active_swap_total_mb)"
    if [ "$active" -ge $(( desired - 16 )) ]; then
        log "Swap is now ${active}MB"
    else
        log "WARNING: swap is ${active}MB, expected ~${desired}MB - check"
        log "         'systemctl status dphys-swapfile' and free space on /var"
    fi
}

main "$@"
