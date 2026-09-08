"""Invariants compose.yaml must hold, checked against the rendered config.

Reads `docker compose config --format json` on stdin and prints one line per
finding, prefixed by category, for tests/compose-test.sh to assert on.

`docker compose config` inlines the contents of every `env_file:` - ntfy's
passwords and API tokens among them - so its output is a secret. project()
below reduces each service to the handful of fields the invariants need,
before anything else looks at it: what is not kept cannot be printed by a
failure message, now or after someone adds a check here. The caller also
passes --no-interpolate, which keeps ${PASSWORD} and the homepage widget keys
literal, and pipes straight into this script so the raw render never lands in
a shell variable.
"""

import json
import re
import sys
from pathlib import Path

# --- deliberate exceptions, each with the reason it is not a bug -------------

# depends_on: service_healthy targets whose healthcheck is baked into the image
# instead of compose.yaml. Compose honours those, but the file itself says
# nothing, which is exactly how a *missing* healthcheck stays invisible - so
# each one is named here rather than skipped by a rule.
IMAGE_HEALTHCHECK = {
    # docker image inspect ghcr.io/immich-app/immich-server
    #   -> {"Test": ["CMD-SHELL", "immich-healthcheck"]}
    "immich-server": "the image ships HEALTHCHECK immich-healthcheck",
}

# Traefik entrypoints that are not published to the LAN. A router there needs no
# middleware: `internalapi` serves api@internal on :8080 to Homepage's widget.
INTERNAL_ENTRYPOINTS = {"traefik"}

# Talks to postgres without owning a role: backrest is the backup client, it
# reads every database through the superuser.
NO_PG_ROLE = {"backrest"}

# Services allowed to run with swap disabled, i.e. memswap_limit equal to
# mem_limit. Nothing needs it today: with no swap, every spike over the limit
# has to be resolved by reclaim inside the cgroup, which is how qbittorrent
# collected 98842 memory.max events. Named here rather than skipped by a rule,
# because the key reads as a limit and behaves as an off switch.
NO_SWAP = set()

# Where the compose service name and the postgres role name differ.
PG_ROLE_ALIAS = {"immich-server": "immich"}

# Networks allowed an IPv6 subnet, and the reason each one is safe to have.
# Everything else stays IPv4-only: an IPv6 address on a shared segment reaches
# gluetun, whose network namespace qbittorrent, stremio and kapowarr share, and
# their traffic would then leave outside the VPN tunnel on the residential
# address. Named here rather than skipped by a rule, because the file reads as
# an ordinary subnet either way.
IPV6_NETWORKS = {
    "ingress6": "traefik alone, and the IPv6 ingress",
    "egress_ddns": "ddns-updater alone, which has to observe its own public v6 address",
}

# Floors, not just non-empty checks: a profile list that half-breaks still
# renders *something*, and every assertion below would pass having inspected
# four services. Raise these when the stack grows well past them, and never
# lower one to make a failure go away.
MIN_SERVICES = 38
MIN_ROUTERS = 28
MIN_HEALTH_DEPS = 18
MIN_MEM_RESERVATIONS = 12


def labels_of(service):
    labels = service.get("labels") or {}
    if isinstance(labels, list):
        return dict(item.split("=", 1) for item in labels if "=" in item)
    return labels


def bytes_of(value):
    """A compose size - already an int, or a string like "1536m" or "6g"."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return int(value)
    match = re.fullmatch(r"\s*([0-9]*\.?[0-9]+)\s*([kmg]?b?)\s*", str(value).lower())
    if not match:
        return None
    scale = {"": 1, "b": 1, "k": 1024, "kb": 1024,
             "m": 1024 ** 2, "mb": 1024 ** 2, "g": 1024 ** 3, "gb": 1024 ** 3}
    return int(float(match.group(1)) * scale[match.group(2)])


def project(service):
    """Everything the invariants need, and deliberately nothing else.

    An allowlist rather than a blocklist: a compose release that adds another
    field carrying a credential is safe here by default. healthcheck collapses
    to a boolean because only its presence is ever asked about, and labels keep
    the traefik keys only - homepage's carry widget API keys. `deploy` keeps its
    key names and not their values, so a finding can say which subsection is
    there without echoing anything from it.
    """
    return {
        "deploy_keys": sorted((service.get("deploy") or {}).keys()),
        "ports": [port for port in (service.get("ports") or []) if isinstance(port, dict)],
        "mem_limit": bytes_of(service.get("mem_limit")),
        "mem_reservation": bytes_of(service.get("mem_reservation")),
        "memswap_limit": bytes_of(service.get("memswap_limit")),
        "image": service.get("image"),
        "has_build": bool(service.get("build")),
        "has_healthcheck": bool(service.get("healthcheck")),
        "depends_on": {
            target: spec.get("condition")
            for target, spec in (service.get("depends_on") or {}).items()
        },
        "labels": {
            key: value
            for key, value in labels_of(service).items()
            if key.startswith("traefik.")
        },
    }


def routers_of(services):
    routers = {}
    for name, service in services.items():
        for key, value in service["labels"].items():
            match = re.match(r"traefik\.http\.routers\.([^.]+)\.(.+)", key)
            if match:
                router = routers.setdefault(match.group(1), {"_service": name})
                router[match.group(2)] = value
    return routers


def postgres_roles(repo_dir):
    """The one list that creates a role and a database per service."""
    source = Path(repo_dir, "config/postgres/init-databases.sh").read_text()
    match = re.search(r'^SERVICES="([^"]+)"', source, re.M)
    if not match:
        return None
    return set(match.group(1).split())


def main():
    repo_dir = sys.argv[1]
    config = json.load(sys.stdin)
    services = {name: project(s) for name, s in config["services"].items()}
    findings = []

    def report(category, message):
        findings.append(f"{category} {message}")

    if len(services) < MIN_SERVICES:
        report("FLOOR", f"rendered only {len(services)} services, expected at least {MIN_SERVICES}")

    health_deps = 0
    for name, service in sorted(services.items()):
        for target, condition in sorted(service["depends_on"].items()):
            if condition != "service_healthy":
                continue
            health_deps += 1
            if target not in services:
                report("HEALTH", f"{name} waits on {target}, which this profile does not render")
            elif not services[target]["has_healthcheck"] and target not in IMAGE_HEALTHCHECK:
                report("HEALTH", f"{name} waits for {target} to be healthy, but {target} declares no healthcheck")

    if health_deps < MIN_HEALTH_DEPS:
        report("FLOOR", f"found only {health_deps} service_healthy dependencies, expected at least {MIN_HEALTH_DEPS}")

    reservations = 0
    for name, service in sorted(services.items()):
        if service["deploy_keys"]:
            sections = "/".join(service["deploy_keys"])
            report("RESOURCE", f"{name} declares deploy.{sections}, which compose drops outside swarm")

        limit = service["mem_limit"]
        if limit is None:
            report("RESOURCE", f"{name} declares no mem_limit, so it can take the whole host")
            continue

        reservation = service["mem_reservation"]
        if reservation is not None:
            reservations += 1
            if reservation >= limit:
                report("RESOURCE", f"{name} reserves as much memory as it may use, which reserves nothing")

        memswap = service["memswap_limit"]
        if memswap is not None and memswap <= limit and name not in NO_SWAP:
            report("RESOURCE", f"{name} sets memswap_limit at or below mem_limit, which disables its swap")

    if reservations < MIN_MEM_RESERVATIONS:
        report("FLOOR", f"only {reservations} services reserve memory, expected at least {MIN_MEM_RESERVATIONS}")

    for name, service in sorted(services.items()):
        image = service.get("image")
        if not image:
            if not service["has_build"]:
                report("IMAGE", f"{name} has neither an image nor a build")
            continue
        tag = image.rsplit("/", 1)[-1]
        if "@sha256:" in image or tag.endswith(":local"):
            continue
        if ":" not in tag:
            report("IMAGE", f"{name} uses {image}, which has no tag")
        elif re.search(r":(latest|stable|main|master|edge|nightly)$", image):
            report("IMAGE", f"{name} uses {image}, a moving tag")

    routers = routers_of(services)
    if len(routers) < MIN_ROUTERS:
        report("FLOOR", f"found only {len(routers)} Traefik routers, expected at least {MIN_ROUTERS}")

    for router, spec in sorted(routers.items()):
        if "rule" not in spec:
            continue
        if spec.get("entrypoints") in INTERNAL_ENTRYPOINTS:
            continue
        if "middlewares" not in spec:
            report("ROUTER", f"{router} ({spec['_service']}) is routed publicly with no middlewares")

    # A bare "443:443" binds [::] as well as 0.0.0.0, and an IPv6 listener in
    # front of a container with no IPv6 address is served by userland
    # docker-proxy, which rewrites the client address to a Docker gateway one -
    # inside ALLOW_IP_RANGES, so lan@docker admits every IPv6 caller. Measured.
    for name, service in sorted(services.items()):
        for port in service["ports"]:
            if not port.get("host_ip"):
                published = port.get("published") or port.get("target")
                report("PORT", f"{name} publishes {published} with no host address, so it binds [::] too")

    for name, network in sorted((config.get("networks") or {}).items()):
        subnets = [
            entry.get("subnet") or ""
            for entry in ((network.get("ipam") or {}).get("config") or [])
        ]
        if not network.get("enable_ipv6") and not any(":" in subnet for subnet in subnets):
            continue
        if name not in IPV6_NETWORKS:
            report("NETWORK", f"{name} enables IPv6, which would put gluetun's namespace outside the VPN")

    roles = postgres_roles(repo_dir)
    if roles is None:
        report("POSTGRES", 'could not read SERVICES="..." from config/postgres/init-databases.sh')
    else:
        backed = {
            name for name, service in services.items()
            if "postgres" in service["depends_on"]
        }
        for name in sorted(backed - NO_PG_ROLE):
            if PG_ROLE_ALIAS.get(name, name) not in roles:
                report("POSTGRES", f"{name} depends on postgres but init-databases.sh creates no role for it")
        expected = {PG_ROLE_ALIAS.get(name, name) for name in backed}
        for role in sorted(roles - expected):
            report("POSTGRES", f"init-databases.sh creates role {role}, which no service depends on postgres for")

    for finding in findings:
        print(finding)
    print(f"CHECKED {len(services)} services, {health_deps} health dependencies, {len(routers)} routers")


main()
