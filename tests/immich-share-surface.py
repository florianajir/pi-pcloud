"""Immich's anonymous API, as the image itself declares it, held against the edge.

A share link is opened by a browser that holds nothing but the link's `key` or
`slug`, and `immich-public` lets it through a path at a time. That list is
written against one Immich release. The next one may call an endpoint the list
has never seen, and a share opened off the LAN then dies on lan@docker's 403 —
in a visitor's browser, long after the bump merged green. So the list is checked
against the OpenAPI document the running image serves (`/api/spec.json`), and the
release that changes the surface fails tests/routing-smoke.sh instead.

What each operation must do is Immich's own declaration, not a list kept here:
  * a `key` or `slug` query parameter marks an operation a share link may call:
    from outside it must reach Immich with either, and be refused with neither;
  * no `security` at all marks a public one: it must reach Immich from outside,
    unless LAN_ONLY_* below names it — and then it stays refused even when a
    `key` rides along, since Immich's guard ignores the key on a public route;
  * everything else needs a signed-in user and must be refused from outside.

Every probe is a HEAD with placeholder ids, and Traefik's rules match no method,
so nothing here can create, restore or sign anything in. An answer in JSON came
from Immich; lan@docker's refusal is a plain-text 403.

Usage:
  immich-share-surface.py probes < spec.json          "<expect> <path>" lines
  immich-share-surface.py verdict PROBES < ANSWERS     "ok|no <message>" lines
ANSWERS holds one "<path> <status> <content-type>" line per probe, in order.
"""

import json
import re
import sys

# Public in Immich, but nothing a share page calls. Whole namespaces where a
# share visitor has no business — signing in, first-run setup, administration —
# so a new public endpoint there stays refused without a review. A new public
# endpoint anywhere else fails the run until it is admitted or listed here.
LAN_ONLY_PREFIXES = ("/api/auth/", "/api/oauth/", "/api/passkeys/", "/api/admin/")
# The two version endpoints name the exact release, which is what a scan for a
# known Immich CVE asks first. Ping is simply of no use to a share page.
LAN_ONLY_PATHS = {"/api/server/ping", "/api/server/version", "/api/server/version-history"}

SHARE_PARAMETERS = ("key", "slug")
PLACEHOLDER_ID = "00000000-0000-4000-8000-000000000000"
PLACEHOLDER_KEY = "routing-smoke"
PATH_PARAMETER = re.compile(r"\{[^}]+\}")
HTTP_METHODS = {"get", "put", "post", "delete", "options", "head", "patch", "trace"}

# Floors, not non-empty checks: a document Immich reshapes — the share key
# moved to a header, `security` renamed — still parses, and every operation
# would then land in one class and pass having checked nothing.
MIN_SHARED = 10
MIN_PUBLIC = 5
MIN_SIGNED_IN = 50

OPEN = "open"
REFUSED = "refused"


def operations(spec):
    """(kind, path) for every operation, kind one of shared/public/signed-in."""
    for path, item in (spec.get("paths") or {}).items():
        for method, operation in item.items():
            if method not in HTTP_METHODS or not isinstance(operation, dict):
                continue
            query = {p.get("name") for p in operation.get("parameters") or [] if p.get("in") == "query"}
            if query & set(SHARE_PARAMETERS):
                kind = "shared"
            elif not operation.get("security"):
                kind = "public"
            else:
                kind = "signed-in"
            yield kind, "/api" + PATH_PARAMETER.sub(PLACEHOLDER_ID, path)


def lan_only(path):
    return path in LAN_ONLY_PATHS or path.startswith(LAN_ONLY_PREFIXES)


def expectations(kind, path):
    with_key = [f"{path}?{name}={PLACEHOLDER_KEY}" for name in SHARE_PARAMETERS]
    if kind == "shared":
        return [(OPEN, url) for url in with_key] + [(REFUSED, path)]
    if kind == "public" and not lan_only(path):
        return [(OPEN, path)]
    if kind == "public":
        return [(REFUSED, path), (REFUSED, with_key[0])]
    return [(REFUSED, path)]


def probes(spec):
    """{probe path: expectation}, or the reason the document cannot be used."""
    counts = {"shared": 0, "public": 0, "signed-in": 0}
    wanted = {}
    findings = []
    for kind, path in operations(spec):
        counts[kind] += 1
        for expect, url in expectations(kind, path):
            # Methods that disagree on one path — a public GET beside a
            # signed-in POST — are one request to rules that match no method.
            if wanted.setdefault(url, expect) != expect:
                findings.append(f"{url} must be both reachable and refused, and the rules match no method")
    for kind, floor in (("shared", MIN_SHARED), ("public", MIN_PUBLIC), ("signed-in", MIN_SIGNED_IN)):
        if counts[kind] < floor:
            findings.append(f"only {counts[kind]} {kind} operations in the document, expected at least {floor}")
    return wanted, findings


def verdict(wanted, answers):
    """("ok"|"no", message) lines: one per failure, one summary per class."""
    out = []
    tally = {OPEN: 0, REFUSED: 0}
    if len(answers) != len(wanted):
        return [("no", f"immich: {len(answers)} answers for {len(wanted)} probes")]
    for (url, expect), line in zip(wanted.items(), answers, strict=True):
        fields = line.split(" ", 2)
        if fields[0] != url:
            return [("no", f"immich: answers out of step with the probes at {url}")]
        status = fields[1] if len(fields) > 1 else "000"
        content_type = fields[2] if len(fields) > 2 else ""
        reached = content_type.startswith("application/json")
        refused = status == "403" and not reached
        if expect == OPEN and reached:
            tally[OPEN] += 1
        elif expect == REFUSED and refused:
            tally[REFUSED] += 1
        elif expect == OPEN:
            out.append(("no", f"immich: {url} is anonymous in Immich but answered {status} from outside"))
        elif reached:
            out.append(("no", f"immich: {url} reached Immich from outside, and lan@docker should have refused it"))
        else:
            out.append(("no", f"immich: {url} answered {status} {content_type or '-'} from outside, expected a 403"))
    out.append(("ok", f"immich: {tally[OPEN]} anonymous requests reach Immich from outside"))
    out.append(("ok", f"immich: {tally[REFUSED]} signed-in, LAN-only or keyless requests are refused from outside"))
    return out


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "probes":
        try:
            spec = json.load(sys.stdin)
        except json.JSONDecodeError as error:
            print(f"/api/spec.json is not JSON: {error}", file=sys.stderr)
            return 1
        wanted, findings = probes(spec)
        if findings:
            print("\n".join(findings), file=sys.stderr)
            return 1
        print("\n".join(f"{expect} {url}" for url, expect in wanted.items()))
        return 0
    if len(sys.argv) == 3 and sys.argv[1] == "verdict":
        wanted = {}
        with open(sys.argv[2], encoding="utf-8") as handle:
            for line in handle.read().splitlines():
                expect, url = line.split(" ", 1)
                wanted[url] = expect
        answers = sys.stdin.read().splitlines()
        for result, message in verdict(wanted, answers):
            print(result, message)
        return 0
    print("usage: immich-share-surface.py probes < SPEC | verdict PROBES < ANSWERS", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
