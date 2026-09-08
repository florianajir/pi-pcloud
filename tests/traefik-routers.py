"""The reverse proxy's routing table, projected out of the rendered compose file.

Reads `docker compose config --format json` on stdin and prints the records
tests/routing-smoke.sh needs to probe a live stack: which routers exist, which
of them are reachable from the LAN only, who is allowed to read Traefik's
runtime API, and whether the address the probe means to arrive from really is
outside the ip allowlist.

Everything is derived from the labels, nothing is hardcoded: the allowlisted
ranges, the address Traefik's internal API trusts and the port it serves on all
come out of the same labels Traefik itself reads. A test that hardcoded them
would keep passing after the stack moved.

`docker compose config` inlines the contents of every env_file, so its output is
a secret. Only labels under `traefik.` and the pinned container addresses are
read, and of those only router names, host names and literal request paths are
printed — never an ip range (those are a home LAN's subnet and its WAN address)
and never a label value from any other namespace.

Usage: traefik-routers.py <candidate-outside-address>
"""

import ipaddress
import json
import re
import sys

# Entrypoints that are not published to the LAN, so a router there is reachable
# by nothing a probe can be: `traefik` serves api@internal to Homepage's widget.
INTERNAL_ENTRYPOINTS = {"traefik"}

# The router that serves Traefik's own runtime API, and the label carrying the
# port it answers on. The API is what tells us a router failed to load at all —
# a rule that does not parse, a middleware whose name does not exist — which no
# amount of probing can distinguish from a backend's own 404.
API_ROUTER = "internalapi"
API_PORT_LABEL = "traefik.http.services.traefik.loadbalancer.server.port"

# Floors, not non-empty checks: a render that half-breaks still yields
# *something*, and every assertion downstream would pass having probed two
# hosts. Raise them when the stack grows well past them.
MIN_ROUTERS = 20
MIN_PROBES = 10

# Only these three matchers are read. `PathRegexp` is deliberately not among
# them: comet's public router excludes a path with one, and a probe aimed at an
# excluded path would test the router next in priority instead. A matcher
# negated with `!` is skipped for the same reason.
MATCHER = re.compile(r"(!\s*)?(Host|PathPrefix|Path)\(\s*`([^`]+)`")

ROUTER_LABEL = re.compile(r"traefik\.http\.routers\.([^.]+)\.(rule|entrypoints|middlewares)$")
ALLOWLIST_LABEL = re.compile(r"traefik\.http\.middlewares\.([^.]+)\.ipallowlist\.sourcerange$")


def labels_of(service):
    labels = service.get("labels") or {}
    if isinstance(labels, list):
        return dict(item.split("=", 1) for item in labels if "=" in item)
    return labels


def pinned_addresses(service):
    """{network: ipv4_address} for every network where the service pins one."""
    networks = service.get("networks") or {}
    if not isinstance(networks, dict):
        return {}
    return {
        name: config["ipv4_address"]
        for name, config in networks.items()
        if isinstance(config, dict) and config.get("ipv4_address")
    }


def middlewares_of(router):
    """The middleware names a router carries, without their provider suffix."""
    raw = router.get("middlewares") or ""
    return [name.split("@", 1)[0] for name in raw.split(",") if name.strip()]


def host_and_path(rule):
    """The host a rule matches and the path to ask for, or (None, None)."""
    host = None
    path = None
    for negated, matcher, value in MATCHER.findall(rule):
        if negated:
            continue
        if matcher == "Host" and host is None:
            host = value
        elif matcher in ("Path", "PathPrefix") and path is None:
            path = value
    return host, (path or "/")


def admitted(address, networks):
    """True when `address` sits in any of `networks`."""
    try:
        parsed = ipaddress.ip_address(address)
    except ValueError:
        return False
    return any(parsed.version == network.version and parsed in network for network in networks)


def outside_verdict(address, ranges):
    """(is `address` outside every range?, how many ranges did not parse)."""
    outside = True
    malformed = 0
    for entry in ranges:
        try:
            network = ipaddress.ip_network(entry.strip(), strict=False)
        except ValueError:
            # Counted, never printed: ALLOW_IP_RANGES is a home LAN's subnet
            # and its WAN address. A range that does not parse is Traefik's
            # problem too, so it is reported rather than skipped past.
            malformed += 1
            continue
        if address.version == network.version and address in network:
            outside = False
    return outside, malformed


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    try:
        candidate = ipaddress.ip_address(sys.argv[1])
    except ValueError:
        print(f"{sys.argv[1]} is not an ip address", file=sys.stderr)
        return 2

    services = json.load(sys.stdin).get("services") or {}
    labels_by_service = {name: labels_of(service) for name, service in services.items()}

    routers = {}
    allowlists = {}
    for labels in labels_by_service.values():
        for key, value in labels.items():
            match = ROUTER_LABEL.match(key)
            if match:
                # A router name may be declared by two services (qbittorrent's
                # is, once behind gluetun and once standalone). Traefik sees one
                # router either way, so merging by name is what it does too.
                routers.setdefault(match.group(1), {})[match.group(2)] = value
                continue
            match = ALLOWLIST_LABEL.match(key)
            if match:
                allowlists[match.group(1)] = value.split(",")

    findings = []
    out = []

    published = {}
    for name, router in routers.items():
        entrypoints = {e.strip() for e in (router.get("entrypoints") or "").split(",") if e.strip()}
        # No entrypoints at all means every entrypoint, which is how Traefik
        # reads it and how tests/compose-invariants.py classifies it. Treating
        # the empty set as internal would leave a router that is reachable from
        # the LAN out of the probes entirely.
        if not entrypoints or entrypoints - INTERNAL_ENTRYPOINTS:
            published[name] = router
        out.append(f"ROUTER {name}")

    # One router per host, or the probe cannot say which of them answered: a
    # host with several routers is decided by priority, and asserting against
    # the wrong one would fail a stack that is correct. Those routers are still
    # covered by the API check above, which needs no request at all.
    hosts = {}
    for name, router in published.items():
        host, _ = host_and_path(router.get("rule") or "")
        if host:
            hosts.setdefault(host, []).append(name)

    gated_ranges = []
    probes = 0
    for host, names in sorted(hosts.items()):
        if len(names) != 1:
            continue
        name = names[0]
        _, path = host_and_path(published[name].get("rule") or "")
        gates = [m for m in middlewares_of(published[name]) if m in allowlists]
        for gate in gates:
            gated_ranges.extend(allowlists[gate])
        out.append(f"PROBE {name} {host} {path} {'lan' if gates else 'open'}")
        probes += 1

    # The whole outside half of the test rests on this: an address that turns
    # out to be inside the allowlist would make every "must be refused" pass
    # for the wrong reason.
    if not gated_ranges:
        findings.append("no probe router carries an ip allowlist, so nothing checks the LAN gate")
    else:
        outside, malformed = outside_verdict(candidate, gated_ranges)
        if malformed:
            findings.append(f"{malformed} of the ip allowlist's ranges are not valid CIDR")
        elif outside:
            out.append("OUTSIDE ok")
        else:
            findings.append(f"{candidate} is inside the ip allowlist, so it cannot stand in for the internet")

    # Who may read the runtime API, and where. Derived from the allowlist the
    # API's own router carries: whichever container is pinned to the single
    # address it admits is the one container that can ask.
    api_gates = [m for m in middlewares_of(routers.get(API_ROUTER, {})) if m in allowlists]
    api_admits = []
    for gate in api_gates:
        for entry in allowlists[gate]:
            try:
                api_admits.append(ipaddress.ip_network(entry.strip(), strict=False))
            except ValueError:
                findings.append(f"a range on {gate} is not valid CIDR")

    # Containment, not a string match on the address: the allowlist is a /32
    # today, and comparing text would refuse the whole file the day it is
    # widened by one bit. A wider range can admit more than one container, so
    # every candidate is emitted and the caller tries them in turn.
    api_port = next((labels[API_PORT_LABEL] for labels in labels_by_service.values() if API_PORT_LABEL in labels), None)
    api_rule_label = f"traefik.http.routers.{API_ROUTER}.rule"
    api_probes = []
    for name, service in sorted(services.items()):
        for net, address in sorted(pinned_addresses(service).items()):
            if not admitted(address, api_admits):
                continue
            # The API answers wherever Traefik itself sits on that network.
            api_host = next(
                (
                    pinned_addresses(services[other]).get(net)
                    for other, labels in sorted(labels_by_service.items())
                    if api_rule_label in labels
                ),
                None,
            )
            if api_host and api_port:
                api_probes.append(f"APIPROBE {name} http://{api_host}:{api_port}")

    if api_probes:
        out.extend(api_probes)
    else:
        findings.append(f"could not work out who reads Traefik's {API_ROUTER} API, or where")

    if len(routers) < MIN_ROUTERS:
        findings.append(f"only {len(routers)} routers in the render, expected at least {MIN_ROUTERS}")
    if probes < MIN_PROBES:
        findings.append(f"only {probes} routers sit alone on their host, expected at least {MIN_PROBES}")

    if findings:
        print("\n".join(findings), file=sys.stderr)
        return 1

    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
