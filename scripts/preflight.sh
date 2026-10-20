#!/bin/sh
# `make preflight`, after check-env: can this host run the stack at all -
# Docker reachable, memory limits enforced, IPv6 in the kernel.
#
# Host-only, never mounted into a container, so sourcing lib.sh is fine here.

set -eu

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

[ "$#" -eq 0 ] || die "takes no arguments (got: $*)"

PROBE_IMAGE='busybox:1.37.0@sha256:9db7b59979c38555a39def84a31fb98b5296952f9e3afd4f6f11f05b07adfab0'

echo "🔍 Preflight..."
if ! docker info >/dev/null 2>&1; then
    echo "❌ Docker not reachable"
    exit 1
fi
echo "✔ Docker OK"

if mount | grep -q ' type cgroup2 '; then
    echo "✔ cgroup v2"
else
    echo "ℹ legacy cgroup"
fi

# Read back from inside a container rather than trusted from the flag: Docker
# accepts `-m` on a kernel that does not enforce it.
if docker run --rm -m 32m "$PROBE_IMAGE" sh -c \
    'cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null' |
    grep -qx 33554432; then
    echo "✔ memory limits enforced"
else
    echo "⚠ memory limits NOT enforced"
fi

# A host with IPv6 but no delegated prefix needs nothing - the allowlist entry
# stays empty and everything runs over IPv4. A kernel with IPv6 compiled out or
# switched off is the one that cannot start the stack as it stands.
if [ -e /proc/net/if_inet6 ]; then
    echo "✔ kernel has IPv6"
else
    echo "⚠ kernel has no IPv6 (ipv6.disable=1?)"
    echo "   Docker cannot create a network with an IPv6 subnet, and docker-proxy"
    echo "   cannot bind [::]:443, so the stack will not start as it stands."
    echo "   docs/NETWORKING.md, 'A host with no IPv6 at all', lists what to remove."
fi
echo "Done"
