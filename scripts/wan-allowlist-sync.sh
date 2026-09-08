#!/bin/sh
set -eu

# Keeps the two entries of the `lan@docker` allowlist that the ISP owns - and
# so expire without warning - equal to what the line presents right now, in
# .env and in the running Traefik:
#
#   WAN_HAIRPIN_IP    this line's public IPv4, as a /32
#   HOST_LAN_SUBNET6  the IPv6 prefix delegated to the LAN
#
# What each admits and why it is needed at all: docs/NETWORKING.md,
# docs/SECURITY.md.
#
# A timer rather than a one-off because both expire with the line, and a stale
# entry keeps allowlisting whoever inherits the address.
#
# The IPv4 address comes from `tailscale netcheck` - a STUN observation of what
# the line presents *now*, which is exactly what the router SNATs a hairpinned
# connection to. ddns-updater's state file is the obvious source and the wrong
# one: it records what was last *published*, and is only rewritten when that
# changes, so it reports agreement forever once publishing has broken.
#
# The IPv6 prefix comes from the LAN interface's routing table, for the same
# reason. There is no hairpin to observe over IPv6 - with no NAT a LAN client
# reaches the Pi's global address directly - so what has to be allowlisted is
# the prefix its neighbours draw their addresses from.

. "$(dirname "$0")/lib.sh"

TRAEFIK_CONTAINER="pi-traefik"
LAN_RANGE_LABEL="traefik.http.middlewares.lan.ipallowlist.sourcerange"

# A shared or private address must never be allowlisted: on a CGNAT line that
# /32 is every other subscriber's source address too, and 100.64.0.0/10 is
# already in ALLOW_IP_RANGES for the tailnet.
is_globally_routable() {
    case "$1" in
        0.*|10.*|127.*|169.254.*|192.168.*) return 1 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 1 ;;
    esac
    return 0
}

# Global unicast only (2000::/3), so link-local and ULA - which every interface
# has, and which ALLOW_IP_RANGES already covers - never land here.
is_lan_prefix6() {
    local len=""

    case "$1" in
        [23]*:*/*) ;;
        *) return 1 ;;
    esac

    len="${1#*/}"
    case "$len" in
        ''|*[!0-9]*) return 1 ;;
    esac
    # Anything longer than a /64 is a host route, not a range neighbours draw
    # from; anything shorter than the /48 an ISP delegates to a site is a chunk
    # of its allocation, and allowlisting that admits other customers.
    [ "$len" -ge 48 ] && [ "$len" -le 64 ]
}

# Whether the live label already carries $2 as one of its comma-separated
# members. Compared against the *running* label, not just .env: a compose call
# that failed last time leaves the two out of step, and keying off .env alone
# would then short-circuit every later run and leave the stale range live
# indefinitely.
# Whether the live label still carries a member this key owns, used when the
# value has been cleared and there is no desired string left to look for. The
# fixed members of ALLOW_IP_RANGES hold no global unicast, so a match can only
# have come from HOST_LAN_SUBNET6.
label_has_owned_member() {
    local label="$1"
    local test_fn="$2"
    local member=""

    for member in $(printf '%s' "$label" | tr ',' ' '); do
        "$test_fn" "$member" && return 0
    done
    return 1
}

label_has_member() {
    case "$1" in
        "$2"|"$2,"*|*",$2,"*|*",$2") return 0 ;;
    esac
    return 1
}

# Rewrite one .env key, or die having changed nothing. Through a copy,
# not in place: a sed that dies midway leaves a truncated .env, and every
# interpolated value in compose.yaml with it. .env.tmp* is gitignored, and
# `cp -p` carries the 0600 mode and owner across so the mv cannot widen them.
write_env_key() {
    local key="$1"
    local desired="$2"
    local tmp_env="$ENV_FILE.tmp.$$"

    trap 'rm -f "$tmp_env" "$tmp_env.a" "$tmp_env.b"' EXIT INT TERM
    cp -p "$ENV_FILE" "$tmp_env" || die "could not copy $ENV_FILE"

    if grep -q "^$key=" "$tmp_env"; then
        sed -i "s|^$key=.*|$key=$(sed_escape "$desired")|" "$tmp_env" \
            || die "could not rewrite $key"
    else
        # An .env predating this variable: append, so the next run has a line to
        # rewrite rather than appending a second one.
        printf '%s=%s\n' "$key" "$desired" >> "$tmp_env" \
            || die "could not append $key"
    fi

    [ "$(unquote_env_value "$(read_env_value_from_file "$tmp_env" "$key")")" = "$desired" ] \
        || die "$key did not land as $desired, leaving $ENV_FILE untouched"

    # rotate-password.sh and rotate-secret.sh edit .env in place. Replacing the
    # file wholesale would silently revert a rotation that landed since the copy
    # above, so refuse unless everything except this one line still matches.
    grep -v "^$key=" "$ENV_FILE" > "$tmp_env.a" || true
    grep -v "^$key=" "$tmp_env" > "$tmp_env.b" || true
    cmp -s "$tmp_env.a" "$tmp_env.b" \
        || die "$ENV_FILE changed while this ran - leaving it alone, the next run retries"

    mv "$tmp_env" "$ENV_FILE" || die "could not replace $ENV_FILE"
    trap - EXIT INT TERM
    rm -f "$tmp_env.a" "$tmp_env.b"
    safe_chmod 600 "$ENV_FILE"
    # The timer runs this as root, whose mv would otherwise leave the file
    # unreadable to the account that owns the checkout.
    fix_ownership "$ENV_FILE"
}

# This line's public IPv4 as a /32. Returns non-zero, with a reason logged, when
# it could not be determined - never an empty value, which now means "clear".
desired_hairpin_ip() {
    local wan_ip=""

    wan_ip="$(
        timeout 40 tailscale netcheck --format=json 2>/dev/null \
            | jq -r '.GlobalV4 // empty' 2>/dev/null \
            | cut -d: -f1 \
            | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    )" || wan_ip=""

    if [ -z "$wan_ip" ]; then
        log "WARNING: tailscale netcheck returned no public IPv4, leaving WAN_HAIRPIN_IP as it is"
        return 1
    fi

    if ! is_globally_routable "$wan_ip"; then
        log "WARNING: $wan_ip is CGNAT or private, not a source worth allowlisting - leaving WAN_HAIRPIN_IP as it is"
        return 1
    fi

    printf '%s/32' "$wan_ip"
}

# Every global prefix on the LAN link, comma-separated; empty when the host has
# no IPv6 at all, which clears the entry. Returns non-zero when it could not
# tell - dash has no pipefail, and a failed `ip` read as "no IPv6" would drop a
# live prefix from the allowlist.
#
# All of them rather than the first: during a renumbering the old and the new
# prefix are both on the link, and picking one would allowlist whichever `ip`
# happened to list first - the dead one half the time, which is a 403 for every
# LAN client until the old route expires. `sort -u` so the value does not churn
# when the kernel reorders them.
lan_prefixes6() {
    local parent=""
    local routes=""
    local candidate=""
    local out=""

    parent="$(get_env_value_clean HOST_LAN_PARENT)"
    parent="${parent:-eth0}"

    if ! routes="$(ip -6 route show dev "$parent" 2>/dev/null)"; then
        log "WARNING: could not read IPv6 routes on $parent, leaving HOST_LAN_SUBNET6 as it is"
        return 1
    fi

    for candidate in $(printf '%s\n' "$routes" \
        | awk '$1 ~ /^[0-9a-fA-F:]+\/[0-9]+$/ { print $1 }' | sort -u); do
        is_lan_prefix6 "$candidate" || continue
        out="${out:+$out,}$candidate"
    done

    # Empty is only believed when a second, independent source agrees. A route
    # table can lose the on-link prefix for a moment - an RA gap, a link flap, a
    # NetworkManager restart - and clearing on that recreates Traefik twice and
    # 403s every LAN IPv6 client in between. An address outlives those.
    if [ -z "$out" ] && ip -6 addr show dev "$parent" scope global 2>/dev/null | grep -q inet6; then
        log "WARNING: $parent has a global IPv6 address but no on-link prefix route, leaving HOST_LAN_SUBNET6 as it is"
        return 1
    fi

    printf '%s' "$out"
}

# Nothing to apply a change to, and .env is rendered into labels at the next
# stack start anyway, so a stopped Traefik means there is nothing useful to do.
container_is_running "$TRAEFIK_CONTAINER" || exit 0

APPLIED="$(docker inspect "$TRAEFIK_CONTAINER" \
    --format "{{index .Config.Labels \"$LAN_RANGE_LABEL\"}}" 2>/dev/null || true)"

NEEDS_APPLY=""

# Only called with a value the caller could actually determine, so an empty one
# means the source is genuinely gone and the entry has to be cleared - leaving it
# would keep allowlisting a range nothing on the link uses any more.
#
# $3 names a predicate matching the label members this key owns. Without it the
# clearing path could only compare .env against itself, and a `compose up` that
# failed after .env was cleared would leave the dead range live in Traefik with
# nothing left to notice it - the same trap label_has_member exists to avoid on
# the path below.
sync_key() {
    local key="$1"
    local desired="$2"
    local owns="${3:-}"
    local current=""

    current="$(get_env_value_clean "$key")"

    if [ -z "$desired" ]; then
        if [ -z "$current" ]; then
            [ -n "$owns" ] || return 0
            label_has_owned_member "$APPLIED" "$owns" || return 0
            log "$key is unset but traefik still carries it - reapplying"
        else
            write_env_key "$key" ""
            log "$key: $current -> <unset>"
        fi
        NEEDS_APPLY=1
        return 0
    fi

    if [ "$current" = "$desired" ] && label_has_member "$APPLIED" "$desired"; then
        return 0
    fi

    if [ "$current" != "$desired" ]; then
        write_env_key "$key" "$desired"
        log "$key: ${current:-<unset>} -> $desired"
    fi
    NEEDS_APPLY=1
}

if HAIRPIN_IP="$(desired_hairpin_ip)"; then
    sync_key WAN_HAIRPIN_IP "$HAIRPIN_IP"
fi
if PREFIXES6="$(lan_prefixes6)"; then
    sync_key HOST_LAN_SUBNET6 "$PREFIXES6" is_lan_prefix6
fi

[ -n "$NEEDS_APPLY" ] || exit 0

# --no-deps so this touches Traefik and nothing else, and `up` rather than
# `restart` because Traefik reads middleware definitions from container labels,
# which are fixed at creation.
compose up -d --no-deps traefik || die "could not apply the allowlist changes to traefik"
log "Applied the current WAN address and LAN IPv6 prefix to the lan allowlist"
