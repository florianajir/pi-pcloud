#!/bin/sh
# Function-level tests for install.sh.
#
# install.sh is sourced with its final `main "$@"` line stripped, so its
# functions can be exercised with the network detection, the terminal and ping
# stubbed out — the paths that decide what lands in .env are covered without
# touching the host or needing a LAN. Run with `make test`.
#
# shellcheck disable=SC2034 # the stubs below are read by the sourced installer
set -eu

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Fails loudly rather than silently sourcing a script that would run the real
# installer (which ends in `make install`) if that line is ever renamed.
grep -q '^main "\$@"$' "$REPO_DIR/install.sh" \
    || { echo "install.sh no longer ends with 'main \"\$@\"'; update $0" >&2; exit 1; }
sed '/^main "\$@"$/d' "$REPO_DIR/install.sh" >"$WORK/install-lib.sh"

# shellcheck disable=SC1091 # generated above from install.sh
. "$WORK/install-lib.sh"
# install.sh sets -e for its own run; the assertions below check failure paths.
set +e

INSTALL_DIR="$REPO_DIR"
# shellcheck source=tests/testlib.sh
. "$(dirname "$0")/testlib.sh"

# Status as a word, so a helper's exit code cannot be mistaken for the result.
yn() { if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }

# expect_die <description> <expected substring> <shell snippet>
# The snippet is eval'd in a subshell so it sees the functions sourced above
# and its die() cannot take this script down with it.
expect_die() {
    desc="$1"
    needle="$2"
    out="$( ( eval "$3" ) 2>&1 || true )"
    case "$out" in
        *"$needle"*) pass=$((pass + 1)) ;;
        *)
            fail=$((fail + 1))
            printf 'FAIL %s\n  wanted substring [%s]\n  got [%s]\n' "$desc" "$needle" "$out"
            ;;
    esac
}

# --- the .env value rule, as install.sh sees it through scripts/lib.sh -------

load_value_rules
ok "value rules loaded" "$([ -n "$VALUE_RULES" ] && echo yes || echo no)" yes

ok "accepts a hostname"        "$(yn value_is_safe 'pi.example.com')" yes
ok "accepts a subnet"          "$(yn value_is_safe '192.168.1.0/24')" yes
ok "accepts a mid backslash"   "$(yn value_is_safe 'hun\ter2')" yes
ok "rejects a dollar"          "$(yn value_is_safe 'hun$ter2')" no
ok "rejects a trailing space"  "$(yn value_is_safe 'hunter2 ')" no
ok "rejects a leading space"   "$(yn value_is_safe ' hunter2')" no
ok "rejects a trailing slash"  "$(yn value_is_safe 'hunter2\')" no
ok "rejects an inline comment" "$(yn value_is_safe 'hunter2 #x')" no
ok "rejects wrapping quotes"   "$(yn value_is_safe '"hunter2"')" no
ok "rejects a newline"         "$(yn value_is_safe "$(printf 'a\nb')")" no
ok "empty is safe (unwritten)" "$(yn value_is_safe '')" yes

# --- the required-variable list is check-env's own, not a copy -------------

ok "required vars are the ones check-env enforces" \
    "$(read_required_vars)" \
    "$(sh "$REPO_DIR/scripts/check-env.sh" --list | sed 's/^/ /' | tr -d '\n')"

mkdir -p "$WORK/injected/scripts"
printf 'printf "HOST_NAME\\nx;reboot\\n"\n' >"$WORK/injected/scripts/check-env.sh"
expect_die "refuses a token that is not a variable name" "unexpected token 'x;reboot'" \
    'INSTALL_DIR="$WORK/injected" read_required_vars'

expect_die "dies without check-env.sh" "could not read the required variables" \
    'INSTALL_DIR="$WORK/missing" read_required_vars'

# --- .env reads are delegated, with no shadow parser to drift --------------

ok "reads .env.dist" "$(read_env_key "$REPO_DIR/.env.dist" PIHOLE_IP)" "192.168.1.250"
ok "missing key is empty" "$(read_env_key "$REPO_DIR/.env.dist" NO_SUCH_KEY_HERE)" ""

mkdir -p "$WORK/broken/scripts"
cp "$REPO_DIR/.env.dist" "$WORK/broken/"
expect_die "dies on an unusable lib.sh" "is $WORK/broken/scripts/lib.sh intact?" \
    'INSTALL_DIR="$WORK/broken" read_env_key "$WORK/broken/.env.dist" PIHOLE_IP'

expect_die "value rules die on an unusable lib.sh" "could not read the .env value rules" \
    'INSTALL_DIR="$WORK/broken" load_value_rules'

# --- macvlan parent classification, asked of the kernel -------------------

# lo is ARPHRD_LOOPBACK: a stand-in for any non-Ethernet parent (wg0, tun0).
ok "loopback is not usable"  "$(yn is_virtual_parent lo)" yes
ok "unknown iface is usable" "$(yn is_virtual_parent no-such-iface0)" no
ether=""
for dev in /sys/class/net/*; do
    [ "$(cat "$dev/type" 2>/dev/null)" = 1 ] || continue
    [ ! -e "$dev/tun_flags" ] || continue
    ether="$(basename "$dev")"
    break
done
if [ -n "$ether" ]; then
    ok "ethernet parent is usable" "$(yn is_virtual_parent "$ether")" no
else
    echo "SKIP ethernet parent: no ARPHRD_ETHER interface on this host"
fi

# --- resolve_network -------------------------------------------------------

unset HOST_LAN_PARENT HOST_LAN_SUBNET HOST_LAN_GATEWAY ALLOW_IP_RANGES PIHOLE_IP HOST_LAN_IP 2>/dev/null || true
interactive() { return 0; }
confirm() { return 0; }

# A default route with a device but no gateway (LTE modem, on-link route): the
# fallback must be all-or-nothing, never the real subnet plus a placeholder
# gateway.
detect_network() {
    DETECTED_IP=10.1.2.3
    DETECTED_IFACE=eth0
    DETECTED_GATEWAY=""
    DETECTED_SUBNET=10.1.2.0/24
}
resolve_network >/dev/null 2>&1
ok "partial layout: parent dropped"  "$LAN_PARENT" ""
ok "partial layout: subnet dropped"  "$LAN_SUBNET" ""
ok "partial layout: gateway dropped" "$LAN_GATEWAY" ""

expect_die "refuses an injected export" "HOST_LAN_SUBNET must not contain" \
    'HOST_LAN_SUBNET="$(printf "10.0.0.0/8\nINJECTED=1")" resolve_network'

# Nobody reads a warning on an unattended run, so an auto-detected parent that
# macvlan cannot use must stop the install.
interactive() { return 1; }
detect_network() {
    DETECTED_IP=10.1.2.3
    DETECTED_IFACE=lo
    DETECTED_GATEWAY=10.1.2.1
    DETECTED_SUBNET=10.1.2.0/24
}
expect_die "unattended: auto-detected tunnel parent stops" "no terminal is available" \
    'resolve_network'
ok "unattended: exported parent allowed" \
    "$( (HOST_LAN_PARENT=lo resolve_network >/dev/null 2>&1 && echo yes) || echo no )" yes

# --- write_network_settings ------------------------------------------------

stage_env() {
    ENV_STAGE="$WORK/stage.env"
    cp "$REPO_DIR/.env.dist" "$ENV_STAGE"
}
env_line() { grep "^$1=" "$ENV_STAGE" | tail -n1; }

# Detection failed, so the .env.dist LAN defaults stand — but an exported
# value is the documented override and must still be written.
LAN_PARENT="" LAN_SUBNET="" LAN_GATEWAY=""
stage_env
PIHOLE_IP=192.168.1.240 ALLOW_IP_RANGES=10.9.0.0/16 write_network_settings >/dev/null 2>&1
ok "fallback keeps exported PIHOLE_IP"       "$(env_line PIHOLE_IP)" "PIHOLE_IP=192.168.1.240"
ok "fallback keeps exported ALLOW_IP_RANGES" "$(env_line ALLOW_IP_RANGES)" "ALLOW_IP_RANGES=10.9.0.0/16"
ok "fallback writes no LAN parent"           "$(env_line HOST_LAN_PARENT)" \
    "$(grep '^HOST_LAN_PARENT=' "$REPO_DIR/.env.dist" | tail -n1)"

stage_env
STREMIO_IP=192.168.1.239 write_network_settings >/dev/null 2>&1
ok "fallback keeps exported STREMIO_IP"      "$(env_line STREMIO_IP)" "STREMIO_IP=192.168.1.239"

# A fully detected layout rewrites the LAN member of ALLOW_IP_RANGES.
LAN_PARENT=eth0 LAN_SUBNET=10.4.0.0/24 LAN_GATEWAY=10.4.0.1
stage_env
ping() { return 1; }
(unset PIHOLE_IP ALLOW_IP_RANGES; write_network_settings) >/dev/null 2>&1
ok "detected layout writes the subnet"  "$(env_line HOST_LAN_SUBNET)" "HOST_LAN_SUBNET=10.4.0.0/24"
ok "detected layout writes the gateway" "$(env_line HOST_LAN_GATEWAY)" "HOST_LAN_GATEWAY=10.4.0.1"
ok "detected layout picks a Pi-hole IP" "$(env_line PIHOLE_IP)" "PIHOLE_IP=10.4.0.250"
# Left at the .env.dist default, Stremio's macvlan address would sit outside
# the detected subnet and `up stremio-lan` would refuse it.
ok "detected layout picks a Stremio IP" "$(env_line STREMIO_IP)" "STREMIO_IP=10.4.0.251"
case "$(env_line ALLOW_IP_RANGES)" in
    *10.4.0.0/24*) ok "detected layout rebuilds ALLOW_IP_RANGES" yes yes ;;
    *) ok "detected layout rebuilds ALLOW_IP_RANGES" "$(env_line ALLOW_IP_RANGES)" yes ;;
esac

# --- pick_lan_ip -----------------------------------------------------------

LAN_GATEWAY=192.168.1.1
unset HOST_LAN_IP 2>/dev/null || true
ping() { case "$*" in *192.168.1.250) return 0 ;; *) return 1 ;; esac; }
ok "steps past a live .250" "$(pick_lan_ip 192.168.1 "" 250 249 248 247 2>/dev/null)" "192.168.1.249"
ping() { return 0; }
ok "no free address is an error" "$(yn pick_lan_ip 192.168.1 "" 250 249 248 247)" no
ping() { return 1; }
ok "a quiet .250 is taken" "$(pick_lan_ip 192.168.1 "" 250 249 248 247)" "192.168.1.250"
have() { case "$1" in ping) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
ok "no ping binary still picks .250" "$(pick_lan_ip 192.168.1 "" 250 249 248 247)" "192.168.1.250"
have() { command -v "$1" >/dev/null 2>&1; }

# The address already handed to another container is skipped, so Stremio never
# lands on Pi-hole's.
ping() { return 1; }
ok "an address already taken is skipped" \
    "$(pick_lan_ip 192.168.1 192.168.1.251 251 252 253 254)" "192.168.1.252"
ok "the gateway is skipped" "$(pick_lan_ip 192.168.1 "" 1 251)" "192.168.1.251"

# --- ask() ----------------------------------------------------------------

interactive() { return 1; }
out="$( (EMAIL=a@b.c ask EMAIL "Email" "") 2>&1 )"
case "$out" in
    *"Using the exported EMAIL=a@b.c"*) ok "announces an inherited value" yes yes ;;
    *) ok "announces an inherited value" "$out" yes ;;
esac

out="$( (PASSWORD=fake-test-secret-value ask PASSWORD "Password" "" 1) 2>&1 )"
case "$out" in
    *"not displayed"*) ok "announces an inherited secret" yes yes ;;
    *) ok "announces an inherited secret" "$out" yes ;;
esac
case "$out" in
    *fake-test-secret-value*) ok "never logs the secret itself" no yes ;;
    *) ok "never logs the secret itself" yes yes ;;
esac

expect_die "refuses an unsafe detected default" "detected default for TIMEZONE" \
    'unset TIMEZONE; ask TIMEZONE "Timezone" "Etc/UTC\$x"'
expect_die "refuses a missing value with no tty" "no terminal is available" \
    'unset HOST_NAME; ask HOST_NAME "Domain" ""'

# --- configure_env, end to end (unattended, every value exported) ---------

ENV_FILE="$WORK/generated.env"
detect_network() {
    DETECTED_IP=192.168.1.42
    DETECTED_IFACE="${ether:-eth0}"
    DETECTED_GATEWAY=192.168.1.1
    DETECTED_SUBNET=192.168.1.0/24
}
ping() { return 1; }
export HOST_NAME=pi.example.com EMAIL=admin@example.com ADMIN_USER=admin \
    PASSWORD=test-placeholder-password TIMEZONE=Europe/Paris \
    HOST_LAN_IP=192.168.1.42 CLOUDFLARE_DNS_API_TOKEN=ci-token \
    CLOUDFLARE_ZONE_ID=ci-zone
unset PIHOLE_IP ALLOW_IP_RANGES HOST_LAN_PARENT HOST_LAN_SUBNET HOST_LAN_GATEWAY 2>/dev/null || true
( set -e; configure_env ) >/dev/null 2>&1
ok "writes .env"      "$([ -f "$ENV_FILE" ] && echo yes || echo no)" yes
ok "  mode is 600"    "$(stat -c %a "$ENV_FILE")" 600
ok "  HOST_NAME"      "$(grep -c '^HOST_NAME=pi.example.com$' "$ENV_FILE")" 1
ok "  TIMEZONE"       "$(grep -c '^TIMEZONE=Europe/Paris$' "$ENV_FILE")" 1
ok "  HOST_LAN_IP"    "$(grep -c '^HOST_LAN_IP=192.168.1.42$' "$ENV_FILE")" 1
ok "  HOST_LAN_GATEWAY" "$(grep -c '^HOST_LAN_GATEWAY=192.168.1.1$' "$ENV_FILE")" 1
ok "  PIHOLE_IP"      "$(grep -c '^PIHOLE_IP=192.168.1.250$' "$ENV_FILE")" 1
ok "  no duplicate keys" \
    "$(grep -v '^#' "$ENV_FILE" | grep '=' | cut -d= -f1 | sort | uniq -d | tr '\n' ' ')" ""
for var in $(sh "$REPO_DIR/scripts/check-env.sh" --list); do
    ok "  $var is present and non-empty" \
        "$([ -n "$(read_env_key "$ENV_FILE" "$var")" ] && echo yes || echo no)" yes
done

# --- select_services --------------------------------------------------------

load_value_rules

# An exported selection wins, is announced, and the .env value rule applies.
stage_env
(COMPOSE_PROFILES=stremio,nextcloud select_services) >/dev/null 2>&1
ok "exported COMPOSE_PROFILES is written" \
    "$(env_line COMPOSE_PROFILES)" "COMPOSE_PROFILES=stremio,nextcloud"
expect_die "unsafe exported COMPOSE_PROFILES dies" "COMPOSE_PROFILES" \
    'stage_env; COMPOSE_PROFILES="bad\$value" select_services'

# The picker itself lives in scripts/services.sh and is covered there; what
# matters here is how the installer reacts to each of its outcomes, so
# pick_services is stubbed per case.

# No terminal or no python3 (status 2): the .env.dist default stands.
stage_env
pick_services() { return 2; }
out="$( (unset COMPOSE_PROFILES; select_services) 2>&1 )"
ok "no picker keeps every service" \
    "$(env_line COMPOSE_PROFILES)" "COMPOSE_PROFILES=all"
case "$out" in
    *"make config"*) ok "  and points at make config" yes yes ;;
    *) ok "  and points at make config" "$out" yes ;;
esac

# Cancelled (status 1): likewise untouched, with a different reason.
stage_env
pick_services() { return 1; }
out="$( (unset COMPOSE_PROFILES; select_services) 2>&1 )"
ok "cancelled picker keeps every service" \
    "$(env_line COMPOSE_PROFILES)" "COMPOSE_PROFILES=all"
case "$out" in
    *cancelled*) ok "  and says it was cancelled" yes yes ;;
    *) ok "  and says it was cancelled" "$out" yes ;;
esac

# A value comes back: written verbatim, the picker owns the "all" collapse.
stage_env
pick_services() { echo "nextcloud,stremio"; }
(unset COMPOSE_PROFILES; select_services) >/dev/null 2>&1
ok "picked selection is written" \
    "$(env_line COMPOSE_PROFILES)" "COMPOSE_PROFILES=nextcloud,stremio"

stage_env
pick_services() { echo all; }
(unset COMPOSE_PROFILES; select_services) >/dev/null 2>&1
ok "everything picked stays all" \
    "$(env_line COMPOSE_PROFILES)" "COMPOSE_PROFILES=all"

stage_env
pick_services() { echo ""; }
out="$( (unset COMPOSE_PROFILES; select_services) 2>&1 )"
ok "nothing picked writes core-only" \
    "$(env_line COMPOSE_PROFILES)" "COMPOSE_PROFILES="
case "$out" in
    *WARNING*) ok "  and warns about it" yes yes ;;
    *) ok "  and warns about it" "$out" yes ;;
esac

# The rule that guards every other value guards this one too.
stage_env
pick_services() { printf 'bad$value\n'; }
expect_die "an unsafe picked value dies" "COMPOSE_PROFILES" \
    '(unset COMPOSE_PROFILES; select_services)'

finish
