"""The COMPOSE_PROFILES value CI has to use, computed from the compose files.

Reads `docker compose -f compose.yaml -f compose.test.yaml config --format json`
on stdin — rendered with every profile enabled, so each service is present with
its merged `profiles` — and prints the comma-separated list that starts
everything CI can run.

Computed rather than maintained: the workflow used to carry the list by hand,
and a hand-written list is how a newly added optional service ends up never
started in CI with nothing to report it.

`docker compose config` inlines the contents of every env_file, so its output is
a secret. Only service names and profile names are read out of it, and only
profile names are ever printed.
"""

import json
import sys

# What compose.test.yaml marks a service with when a runner cannot run it: real
# credentials, /dev/net/tun, a physical parent interface, gigabytes of weights.
CI_EXCLUDED = "ci-excluded"

# The catch-all every optional service carries. Never selected: passing it would
# re-enable precisely the ci-excluded ones, since compose merges profile lists
# across files rather than replacing them.
CATCH_ALL = "all"

# A floor, not a non-empty check: a render that half-breaks still yields
# *something*, and CI would then start the core services only while every check
# downstream passed. Raise it when the stack grows well past it, and never lower
# one to make a failure go away.
MIN_PROFILES = 15


def selector(service, profiles):
    """The one profile CI passes to start `service`, or None if it has no own."""
    if service in profiles:
        return service
    for profile in profiles:
        if profile not in (CATCH_ALL, CI_EXCLUDED):
            return profile
    return None


def main():
    services = json.load(sys.stdin).get("services") or {}
    profiles_of = {name: list(service.get("profiles") or []) for name, service in services.items()}

    excluded = {name for name, profiles in profiles_of.items() if CI_EXCLUDED in profiles}

    # Core services carry no profile at all and start unconditionally.
    selected = {}
    problems = []
    for name, profiles in sorted(profiles_of.items()):
        if name in excluded or not profiles:
            continue
        chosen = selector(name, profiles)
        if chosen is None:
            problems.append(f"{name} carries only '{CATCH_ALL}', so CI cannot ask for it on its own")
            continue
        selected[chosen] = name

    # A profile is a set, not a service: enabling one starts *every* service
    # carrying it. This is the failure that shipped once — gluetun listed
    # `shelfmark` among its profiles, so asking for the book search also started
    # the VPN container CI has no credentials for, and the run died six minutes
    # later on an unhealthy container instead of here.
    for name in sorted(excluded):
        for profile in profiles_of[name]:
            if profile in selected:
                problems.append(
                    f"{name} is ci-excluded but carries profile '{profile}', "
                    f"which CI enables for {selected[profile]}"
                )

    if len(selected) < MIN_PROFILES and not problems:
        problems.append(f"only {len(selected)} profiles selected, expected at least {MIN_PROFILES}")

    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1

    print(",".join(sorted(selected)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
