#!/bin/sh
# Mirror the IPv6 half of Tailscale's exit-node firewall, which tailscaled never
# installed here: it advertises ::/0 and carries ts-input/ts-forward/
# ts-postrouting in iptables, but ip6tables holds none of them, so a client's
# IPv6 leaves the uplink with its fd7a:115c:a1e0::/48 source and dies upstream.
# Background and how to check it: docs/TAILSCALE.md.
#
# The mirror is a hardcoded copy of the v4 rules, so a tailscaled that starts
# managing v6 itself gets overwritten rather than left alone. Re-check on every
# tailscale image bump.
#
# Host-only, never mounted into a container, so sourcing lib.sh is fine here.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

TS_IF=tailscale0
CHANGED=0

# Rebuild $2 in table $1 from stdin, only when it differs. Rebuilt rather than
# appended-if-missing because order is load-bearing: ts-forward's ULA DROP has
# to precede the catch-all ACCEPT, and an append loop cannot repair an order
# that has already gone wrong.
sync_chain() {
    _table="$1"
    _chain="$2"
    _wanted="$(cat)"

    _current="$($SUDO "$IP6T" -t "$_table" -S "$_chain" 2>/dev/null | grep -v '^-N ' || true)"

    [ "$_current" != "$_wanted" ] || return 0

    # ip6table_nat is not universal; without the die, a set -e abort here leaves
    # the chains built earlier in this run with nothing jumping to them.
    $SUDO "$IP6T" -t "$_table" -N "$_chain" 2>/dev/null ||
        $SUDO "$IP6T" -t "$_table" -F "$_chain" ||
        die "could not create or flush $_chain in table $_table"

    # The loop body is a subshell, so set -e cannot carry a failure out of it -
    # hence the explicit exit and the || die.
    printf '%s\n' "$_wanted" | while IFS= read -r _rule; do
        [ -n "$_rule" ] || continue
        # Word splitting is the parse: every token here is one we wrote.
        # shellcheck disable=SC2086
        $SUDO "$IP6T" -t "$_table" $_rule || exit 1
    done || die "could not rebuild the $_chain chain in table $_table"

    CHANGED=1
}

# Inserted at position 1, where tailscaled puts the v4 jump. Appending would put
# these ACCEPTs behind any DROP Docker or ufw already added, leaving the exit
# node broken while this reported success.
ensure_jump() {
    $SUDO "$IP6T" -t "$1" -C "$2" -j "$3" 2>/dev/null && return 0
    $SUDO "$IP6T" -t "$1" -I "$2" 1 -j "$3"
    CHANGED=1
}

has_tailnet_addr6() {
    ip -6 -oneline addr show dev "$TS_IF" scope global 2>/dev/null | grep -q inet6
}

main() {
    if [ ! -e "/sys/class/net/$TS_IF" ]; then
        log "No $TS_IF interface; tailscaled is not routing here. Nothing to mirror."
        return 0
    fi

    # The v6 rules have to land in whichever backend holds the v4 ones, or they
    # sit in a table nothing consults. Docker programs nft here, tailscaled
    # legacy; both coexist on the same hooks, which is why the gap was invisible.
    IP6T=""
    V4T=""
    for _candidate in iptables-legacy iptables-nft; do
        $SUDO "$_candidate" -t nat -S ts-postrouting >/dev/null 2>&1 || continue
        V4T="$_candidate"
        IP6T="ip6tables-${_candidate#iptables-}"
        break
    done

    if [ -z "$IP6T" ]; then
        log "No IPv4 ts-postrouting chain either iptables backend can read; nothing to mirror (userspace mode, --netfilter-mode=off, or tailscaled on its native nftables backend)."
        return 0
    fi
    # Probed through $SUDO as it is used: /usr/sbin is off a non-root PATH, so
    # `command -v` reports it missing on runs that can still call it.
    $SUDO "$IP6T" -V >/dev/null 2>&1 || die "$IP6T is missing, but $V4T holds the v4 chains"

    # tailscale0 exists before the node registers, but carries no address until
    # it has. Nothing re-runs a post-start hook before the next boot, so wait.
    if ! wait_for_cmd 15 2 has_tailnet_addr6; then
        log "$TS_IF has no global IPv6 address; skipping (a later run picks it up)"
        return 0
    fi

    # From the interface, not headscale's prefixes.v6: a config the container
    # has not reloaded yet would give a rule matching nothing.
    TS_ADDR6="$(ip -6 -oneline addr show dev "$TS_IF" scope global 2>/dev/null |
        awk '{print $4}' | head -n1)"
    [ -n "$TS_ADDR6" ] || die "could not read $TS_IF's global IPv6 address"

    # fd7a:115c:a1e0::1/128 -> fd7a:115c:a1e0::/48; the ULA is a /48, so three
    # hextets are the whole prefix.
    TS_ULA6="$(printf '%s' "${TS_ADDR6%%/*}" | cut -d: -f1-3)::/48"
    case "$TS_ULA6" in
        *:*:*::/48) : ;;
        *) die "could not derive the tailnet ULA from $TS_ADDR6 (got $TS_ULA6)" ;;
    esac

    # Read off the v4 rule so --port= in TS_TAILSCALED_EXTRA_ARGS stays the one
    # place it is set.
    WG_PORT="$($SUDO "$V4T" -t filter -S ts-input 2>/dev/null |
        sed -n 's/.*--dport \([0-9]\{1,\}\).*/\1/p' | head -n1)"
    [ -n "$WG_PORT" ] ||
        die "no --dport in the v4 ts-input chain; refusing to guess the WireGuard port"

    # The only v4 rule without a counterpart is the RETURN for 100.115.92.0/23,
    # the ChromeOS Crostini range. Each jump goes in right after its chain is
    # built, so a table this kernel lacks costs only that chain.
    sync_chain filter ts-input <<EOF
-A ts-input -s $TS_ADDR6 -i lo -j ACCEPT
-A ts-input -i $TS_IF -j ACCEPT
-A ts-input -p udp -m udp --dport $WG_PORT -j ACCEPT
-A ts-input -s $TS_ULA6 ! -i $TS_IF -j DROP
EOF
    ensure_jump filter INPUT ts-input

    sync_chain filter ts-forward <<EOF
-A ts-forward -i $TS_IF -j MARK --set-xmark 0x40000/0xff0000
-A ts-forward -m mark --mark 0x40000/0xff0000 -j ACCEPT
-A ts-forward -s $TS_ULA6 -o $TS_IF -j DROP
-A ts-forward -o $TS_IF -j ACCEPT
EOF
    ensure_jump filter FORWARD ts-forward

    sync_chain nat ts-postrouting <<EOF
-A ts-postrouting -m mark --mark 0x40000/0xff0000 -j MASQUERADE
EOF
    ensure_jump nat POSTROUTING ts-postrouting

    if [ "$CHANGED" = 1 ]; then
        log "Mirrored Tailscale's exit-node rules into $IP6T (tailnet $TS_ULA6)"
    else
        log "IPv6 exit-node rules already in step with the v4 ones"
    fi
}

main "$@"
