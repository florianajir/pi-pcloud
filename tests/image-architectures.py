#!/usr/bin/env python3
"""Refuse an image reference the Raspberry Pi could not run.

Reads a unified diff on stdin, takes the image references it *adds*, and asks
each registry which platforms that reference resolves to. CI runs on amd64
runners, so `docker compose pull` proves nothing about the architecture the
stack actually runs on: an image published for amd64 alone passes every other
check and only fails at the next `make update`.

Only added lines are read, so a pull request that touches nothing pins nothing
and this costs no registry call at all. That matters: a manifest request counts
against Docker Hub's anonymous pull quota, and GitHub runners share their egress
addresses.
"""

import json
import re
import subprocess
import sys

# The Pi is arm64, and runs 32-bit userland containers too (a Cortex-A76 keeps
# AArch32 at EL0), which is what mvance/unbound-rpi has always relied on.
RUNNABLE = {"arm64", "arm"}

# Locally built images carry no registry manifest; compose builds them from
# config/<svc>/Dockerfile, whose own FROM line is read from the same diff.
LOCAL_SUFFIX = ":local"

IMAGE_LINE = re.compile(r"^\+\s*image:\s*(?P<ref>\S+)")
FROM_LINE = re.compile(
    r"^\+\s*FROM\s+(?:--\S+\s+)*(?P<ref>\S+)",
    re.IGNORECASE,
)
# Read from every line of the diff, added or not: a hunk that rewrites a later
# stage's `FROM builder` leaves the `... AS builder` that names it as unchanged
# context, and "builder" resolved against a registry is a red build on a
# Dockerfile that is perfectly fine.
STAGE_ALIAS = re.compile(
    r"^[ +-]?\s*FROM\s+(?:--\S+\s+)*\S+\s+AS\s+(?P<alias>\S+)",
    re.IGNORECASE,
)


def added_refs(diff):
    """Image references added by the diff, in first-seen order."""
    lines = [line for line in diff.splitlines() if not line.startswith("+++")]
    aliases = {match.group("alias") for match in map(STAGE_ALIAS.match, lines) if match}
    refs = []
    for line in lines:
        match = IMAGE_LINE.match(line) or FROM_LINE.match(line)
        if not match:
            continue
        ref = match.group("ref")
        if ref.endswith(LOCAL_SUFFIX) or ref in aliases:
            continue
        if ref not in refs:
            refs.append(ref)
    return refs


def inspect(ref, template=None):
    argv = ["docker", "buildx", "imagetools", "inspect"]
    argv += ["--format", template] if template else ["--raw"]
    result = subprocess.run(
        [*argv, ref], capture_output=True, text=True, check=False, timeout=120
    )
    if result.returncode != 0:
        # Last line only - buildx prints the registry's answer there - but a
        # stderr holding nothing but whitespace splits to an empty list, and an
        # IndexError here would abort the run and leave every later reference
        # unchecked.
        reported = result.stderr.strip().splitlines()
        raise RuntimeError(reported[-1] if reported else "inspect failed")
    return json.loads(result.stdout)


def platforms(ref):
    """Every os/architecture `ref` resolves to.

    An image published for one platform has no manifest list, and its
    architecture lives in the config blob rather than in the manifest - reading
    only the index would report nothing and pass by accident.
    """
    manifest = inspect(ref)
    entries = manifest.get("manifests")
    if entries is None:
        config = inspect(ref, "{{json .Image}}") or {}
        return [(config.get("os"), config.get("architecture"))]
    found = []
    for entry in entries:
        platform = entry.get("platform", {})
        # Attestations and SBOMs ride in the index as unknown/unknown.
        if platform.get("architecture") == "unknown":
            continue
        found.append((platform.get("os"), platform.get("architecture")))
    return found


def main():
    refs = added_refs(sys.stdin.read())
    if not refs:
        print("no image reference added")
        return 0
    failed = False
    for ref in refs:
        try:
            found = platforms(ref)
        # OSError covers the one every local run hits first: no docker on PATH,
        # which is a FileNotFoundError, not a SubprocessError.
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
            print(f"UNRESOLVED {ref}: {error}")
            failed = True
            continue
        runnable = sorted(
            {arch for os_name, arch in found if os_name == "linux" and arch in RUNNABLE}
        )
        listed = ", ".join(f"{os_name}/{arch}" for os_name, arch in found) or "none"
        if runnable:
            print(f"OK {ref}: {listed}")
        else:
            print(f"NO ARM {ref}: {listed}")
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
