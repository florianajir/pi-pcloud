"""Traefik's own routing table, checked against the one compose.yaml declares.

Reads Traefik's runtime API (`GET /api/http/routers`) on stdin, and the record
file tests/traefik-routers.py produced as argv[1].

A router whose rule does not parse, or whose middlewares name something that
does not exist, is dropped from the routing table: Traefik keeps serving, logs
the reason once at startup, and answers 404 for that host from then on. Nothing
else in CI notices — and a 404 is also what a stopped backend gives, so the
routing table is read from the source here instead of inferred from a status
code. This stack has shipped that failure: `lan@docker does not exist` for the
first ten seconds of every start, which would be permanent if the middleware
moved off the traefik service.
"""

import json
import sys


def main():
    if len(sys.argv) != 2:
        print("usage: traefik-api-check.py <records-file>", file=sys.stderr)
        return 2

    with open(sys.argv[1], encoding="utf-8") as handle:
        declared = {line.split()[1] for line in handle if line.startswith("ROUTER ")}

    findings = []
    loaded = set()
    for router in json.load(sys.stdin):
        # Provider-qualified: "kavita@docker", "api@internal".
        name = (router.get("name") or "").split("@", 1)[0]
        loaded.add(name)
        if router.get("status") != "enabled":
            reason = "; ".join(router.get("error") or []) or "no reason given"
            findings.append(f"router {name} is {router.get('status') or 'in no state at all'}: {reason}")

    findings.extend(
        f"router {name} is declared in compose.yaml but Traefik never loaded it" for name in sorted(declared - loaded)
    )

    if findings:
        print("\n".join(findings), file=sys.stderr)
        return 1

    print(f"traefik loaded {len(loaded)} routers, every one of them enabled")
    return 0


if __name__ == "__main__":
    sys.exit(main())
