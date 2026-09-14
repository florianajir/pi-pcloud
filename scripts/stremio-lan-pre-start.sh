#!/bin/sh
# Check Stremio's macvlan address before the stack tries to claim it.
#
# STREMIO_IP arrived with the stremio-lan profile, so an .env written by an
# earlier install does not carry it and compose falls back to .env.dist's
# 192.168.1.251 (compose/media.yaml, `ipv4_address: ${STREMIO_IP:-192.168.1.251}`).
# On any other LAN that address is outside the macvlan pool and `up` fails with
# "Invalid address ... does not belong to any of this network's subnets", which
# says nothing about which variable to set. install.sh derives the value for a
# fresh install; this is the same check for every .env that predates it.
#
# Blocking on purpose (see PRE_START_HOOKS in stack-up.sh): the address is
# wrong, not missing, and starting anyway only produces the cryptic failure.
set -eu

. "$(dirname "$0")/lib.sh"

STREMIO_IP="${STREMIO_IP:-$(get_env_value STREMIO_IP)}"
[ -n "$STREMIO_IP" ] || STREMIO_IP=192.168.1.251
SUBNET="${HOST_LAN_SUBNET:-$(get_env_value HOST_LAN_SUBNET)}"

# Nothing to compare against: a missing or non-/24 subnet is the operator's to
# get right, and refusing the start over it would be worse than trying.
case "$SUBNET" in
    *.0/24) ;;
    *) exit 0 ;;
esac

case "$STREMIO_IP" in
    "${SUBNET%.0/24}".*) ;;
    *)
        die "STREMIO_IP ($STREMIO_IP) is outside HOST_LAN_SUBNET ($SUBNET): set it in .env to a free address in that subnet, outside the DHCP range (PIHOLE_IP's neighbour, e.g. ${SUBNET%.0/24}.251)"
        ;;
esac
