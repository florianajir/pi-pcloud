"""Invariants the compose files must hold, checked against the rendered config.

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

import fnmatch
import json
import os
import re
import subprocess
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

# The basename pattern Dependabot's docker-compose fetcher matches, copied from
# dependabot-core docker/lib/dependabot/docker_compose/file_fetcher.rb. Ruby's
# atomic group (?>...) has no Python spelling and changes nothing here, so a
# plain group stands in for it. The match is unanchored there too, hence search.
DEPENDABOT_COMPOSE_NAME = re.compile(r"(docker-)?compose(-[\w]+)?(\.[\w-]+)?\.ya?ml", re.I)

# Where a compose file may live. The fetcher lists one directory and does not
# descend, so each of these has to be named in .github/dependabot.yml on its own.
COMPOSE_DIRS = ("", "compose")

# The sibling pattern for the `docker` ecosystem, from
# dependabot-core docker/lib/dependabot/docker/file_fetcher.rb. Unanchored and
# matched against the basename, so Dockerfile.dev and my.containerfile count.
DEPENDABOT_DOCKERFILE_NAME = re.compile(r"dockerfile|containerfile", re.I)

# Pruned when walking for Dockerfiles: .git is enormous and `data` is the
# gitignored DATA_LOCATION default, neither of which can hold a build context.
SKIP_DIRS = {".git", "data", "node_modules", "__pycache__"}


def yaml_files(base):
    """Every YAML file directly in one directory, both spellings of the suffix.

    `.yml` is included because the fetcher's own pattern ends in `\\.ya?ml`: a
    compose/foo.yml would otherwise be a file no check here ever opens, which
    is the blind spot rather than the fix for it.
    """
    return sorted([*base.glob("*.yaml"), *base.glob("*.yml")])


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


def bind_sources(service):
    """The host paths a service reads: its env_file entries and its bind mounts.

    Paths only, never a value. `docker compose config` inlines the *contents* of
    every env_file, which is the whole reason project() is an allowlist - but the
    path is the one part of an env_file that is safe to keep, and the only part
    recreate_mapping_gaps needs to see who reads whose config tree.
    """
    found = set()
    for entry in service.get("env_file") or []:
        found.add(entry.get("path") if isinstance(entry, dict) else entry)
    for volume in service.get("volumes") or []:
        if isinstance(volume, dict):
            if volume.get("type") == "bind":
                found.add(volume.get("source"))
        elif isinstance(volume, str):
            # The short `source:target[:mode]` spelling, which compose normally
            # expands - kept for a render that did not.
            found.add(volume.split(":", 1)[0])
    return {str(path) for path in found if path}


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
        # A service name, never a credential - and the one thing that says which
        # containers a recreate cannot leave behind. See recreate_mapping_gaps.
        "network_mode": service.get("network_mode"),
        # Paths, never values - see bind_sources. The other half of what says
        # which containers a recreate cannot leave behind.
        "bind_sources": sorted(bind_sources(service)),
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


def anchor_nodes(text):
    """The top-level `x-*:` nodes of a compose file, comments stripped.

    Textual on purpose: two blocks that render the same mapping but spell it
    differently are still a copy someone will have to reconcile by hand, and
    this is the check that says so.
    """
    nodes = {}
    name = None
    for line in text.split("\n"):
        if re.match(r"^x-[A-Za-z0-9_.-]+:", line):
            name = line.split(":", 1)[0]
            nodes[name] = [line.strip()]
            continue
        if name is None:
            continue
        if line.startswith("  "):
            stripped = line.strip()
            if stripped and not stripped.startswith("#"):
                nodes[name].append(stripped)
            continue
        name = None
    return {key: tuple(value) for key, value in nodes.items()}


def include_entries(text):
    """The `include:` list of a compose file, one dedented entry per element.

    Comment lines are dropped rather than folded into the entry they sit in, so
    that no check downstream has to reason about whether what it matched was
    commented out.
    """
    block = []
    inside = False
    for line in text.split("\n"):
        if re.match(r"^include:\s*$", line):
            inside = True
            continue
        if inside and line.lstrip().startswith("#"):
            continue
        if inside and line and not line.startswith((" ", "\t")):
            break
        if inside:
            block.append(line)
    entries = re.split(r"^[ \t]*-[ \t]+", "\n".join(block), flags=re.M)[1:]
    return [re.sub(r"^[ \t]+", "", entry, flags=re.M).strip() for entry in entries if entry.strip()]


def layout_drift(repo_dir):
    """compose.yaml includes every domain file, and every copied anchor matches.

    YAML anchors are file-scoped and `include:` parses each file on its own, so
    the tier definitions cannot be shared - each compose/*.yaml carries a copy.
    compose.yaml holds the canonical one and starts no service of its own; this
    is what keeps the copies from drifting apart silently.
    """
    root_path = Path(repo_dir, "compose.yaml")
    root = root_path.read_text()
    messages = []

    if re.search(r"^services:", root, re.M):
        messages.append("compose.yaml declares services of its own; they belong in compose/compose-<domain>.yaml")

    # Entry by entry, not two totals: a count check passes just as happily on an
    # include carrying both keys twice beside one carrying neither.
    # The compose- prefix is matched here, not merely described: it is what
    # makes the file one Dependabot's fetcher opens, and this is the check that
    # owns what compose.yaml may include. dependabot_blind_spots below catches
    # the same rename from the other side, by the image pins it hides.
    included = set()
    for entry in include_entries(root):
        name = re.search(r"^path:\s*\./compose/(compose-[A-Za-z0-9_-]+\.ya?ml)\s*$", entry, re.M)
        if not name:
            messages.append(f"an include names no ./compose/compose-<domain>.yaml path: {entry.splitlines()[0]}")
            continue
        name = name.group(1)
        included.add(name)
        # Without it, compose resolves that file's ./config and ./data binds
        # against compose/ - paths that do not exist.
        if not re.search(r"^project_directory:\s*\.\s*$", entry, re.M):
            messages.append(f"compose/{name} is included without `project_directory: .`, so its bind paths move")
        # Without it, the include reads <project_directory>/.env on its own,
        # whatever --env-file said: see the note in compose.yaml.
        if not re.search(r"^env_file:\s*/dev/null\s*$", entry, re.M):
            messages.append(
                f"compose/{name} is included without `env_file: /dev/null`, so it reads the real .env"
            )

    present = {path.name for path in yaml_files(Path(repo_dir, "compose"))}
    for name in sorted(present - included):
        messages.append(f"compose/{name} exists but compose.yaml never includes it, so nothing it declares runs")
    for name in sorted(included - present):
        messages.append(f"compose.yaml includes compose/{name}, which does not exist")

    canonical = anchor_nodes(root)
    if not canonical:
        messages.append("compose.yaml defines no x- anchors, so nothing here checks the copies")
    for name in sorted(present & included):
        copy = anchor_nodes(Path(repo_dir, "compose", name).read_text())
        for key, body in sorted(canonical.items()):
            if key not in copy:
                messages.append(f"compose/{name} is missing {key}, which compose.yaml defines")
            elif copy[key] != body:
                messages.append(f"compose/{name}'s {key} no longer matches compose.yaml's")
    return messages


def dependabot_blind_spots(repo_dir):
    """Every image pin sits in a file Dependabot's fetcher will actually open.

    It matches basenames against one regex, lists a single directory without
    descending, and does not follow compose `include:`. So a domain file called
    core.yaml is invisible to it, and so is a compose/ that no `directories:`
    entry names - either way the daily image-bump PRs simply stop arriving, with
    nothing anywhere reporting that they have.
    """
    messages = []
    needed = set()
    for directory in COMPOSE_DIRS:
        for path in yaml_files(Path(repo_dir, directory)):
            text = path.read_text()
            # A compose file, not merely a YAML one carrying an `image:` key:
            # .hadolint.yaml sits in the root too, and telling someone to rename
            # a manifest Dependabot was never going to fetch is wrong advice.
            if not re.search(r"^services:", text, re.M):
                continue
            if not re.search(r"^\s+image:\s*\S", text, re.M):
                continue
            where = f"{directory}/{path.name}" if directory else path.name
            if not DEPENDABOT_COMPOSE_NAME.search(path.name):
                messages.append(
                    f"{where} pins images under a name Dependabot never fetches; "
                    f"call it compose-{path.name}"
                )
                continue
            needed.add("/" + directory)

    config_path = Path(repo_dir, ".github/dependabot.yml")
    if not config_path.exists():
        return messages
    config = config_path.read_text()

    compose_named = dependabot_directories(config, "docker-compose")
    for directory in sorted(d for d in needed if not covers(compose_named, d)):
        messages.append(
            f"images are pinned under {directory} but no docker-compose update names that "
            f"directory, so nothing bumps them"
        )

    # The same blind spot, one ecosystem over. `docker` reads a directory the
    # same way - one listing, no descent - so a Dockerfile whose directory is
    # not named has a base image nothing ever bumps. (That ecosystem also
    # fetches Kubernetes manifests; this repo has none, so they are not modelled
    # here and a first one would need this widened.)
    named = dependabot_directories(config, "docker")
    present = dockerfile_dirs(repo_dir)
    for directory in sorted(d for d in present if not covers(named, d)):
        messages.append(
            f"{directory} holds a Dockerfile but no docker update names that directory, "
            f"so its base image never bumps"
        )
    for entry in sorted(e for e in named if not any(covers({e}, d) for d in present)):
        messages.append(
            f"a docker update names {entry}, which holds no Dockerfile; Dependabot "
            f"errors on that entry instead of skipping it"
        )
    return messages


def as_directory(entry):
    """One `directories:` scalar, normalised for comparison.

    Dependabot accepts "/config/piper" and "/config/piper/" alike; comparing the
    literal scalars would fail the build twice over on the trailing slash - once
    for an uncovered Dockerfile and once for an entry naming nothing.
    """
    trimmed = entry.rstrip("/")
    return trimmed or "/"


def covers(named, directory):
    """Whether a set of `directories:` entries covers one directory.

    Entries may be globs (`/config/*`), which is exactly the edit someone makes
    to stop hand-maintaining five of them - a guard that rejected it would block
    the simplification it argues for.
    """
    return any(fnmatch.fnmatch(directory, entry) for entry in named)


def tracked_files(repo_dir):
    """Every path git tracks, or None when this is not a checkout.

    Dependabot reads the repository, not the working tree: a gitignored
    .venv-lint, a scratch Dockerfile.bak or a worktree checked out inside the
    tree are all invisible to it. The walk below is the fallback for the
    synthetic trees the tests build, which are not git repositories.
    """
    try:
        done = subprocess.run(
            ["git", "-C", str(repo_dir), "ls-files", "-z"],
            capture_output=True, text=True, check=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return [path for path in done.stdout.split("\0") if path]


def dockerfile_dirs(repo_dir):
    """Every directory holding a file the `docker` fetcher would open.

    Nested repositories are pruned along with SKIP_DIRS: a git worktree checked
    out inside the tree (.claude/worktrees/* here) carries its own copy of every
    Dockerfile, and none of it exists in the repository Dependabot reads.
    """
    root = Path(repo_dir)
    found = set()

    tracked = tracked_files(root)
    if tracked is not None:
        for path in tracked:
            if not DEPENDABOT_DOCKERFILE_NAME.search(os.path.basename(path)):
                continue
            rel = os.path.dirname(path)
            found.add("/" + rel if rel else "/")
        return found

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [
            d for d in dirnames
            if d not in SKIP_DIRS and not os.path.exists(os.path.join(dirpath, d, ".git"))
        ]
        if not any(DEPENDABOT_DOCKERFILE_NAME.search(name) for name in filenames):
            continue
        rel = Path(dirpath).relative_to(root).as_posix()
        found.add("/" if rel == "." else "/" + rel)
    return found


def dependabot_directories(config, ecosystem):
    """The directories one `package-ecosystem` update covers.

    Read loosely on purpose: indentation, key order and flow-vs-block style are
    all free in YAML, and a reformat that Dependabot reads identically must not
    come back as "no update names that directory". An entry is split on
    `- <key>:` because that is the one shape a nested sequence item here does
    not take - `directories:` and `labels:` hold bare scalars.
    """
    covered = set()
    name = re.escape(ecosystem)
    for block in re.split(r"^[ \t]*-[ \t]+(?=[A-Za-z_-]+:)", config, flags=re.M)[1:]:
        # Anchored at both ends: unanchored, "docker" also matches the
        # "docker-compose" entry and each would inherit the other's directories.
        # The trailing `(\s+#.*)?` matters in a file where every other line is
        # annotated: without it `package-ecosystem: "docker"  # base images`
        # stops matching and every Dockerfile reads as uncovered.
        if not re.search(rf'^\s*package-ecosystem:\s*"?{name}"?\s*(#.*)?$', block, re.M):
            continue
        covered.update(
            as_directory(d) for d in re.findall(r'^\s*directory:\s*"?([^"\s]+)"?\s*$', block, re.M)
        )
        for inline in re.findall(r"^\s*directories:\s*\[([^\]]*)\]\s*$", block, re.M):
            covered.update(
                as_directory(item.strip().strip("\"'")) for item in inline.split(",") if item.strip()
            )
        listing = False
        for line in block.split("\n"):
            if re.match(r"^\s*directories:\s*$", line):
                listing = True
                continue
            if not listing:
                continue
            item = re.match(r'^\s*-\s*"?([^"\s]+)"?\s*$', line)
            if item:
                covered.add(as_directory(item.group(1)))
            elif line.strip() and not line.lstrip().startswith("#"):
                listing = False
    return covered


def postgres_roles(repo_dir):
    """The one list that creates a role and a database per service."""
    source = Path(repo_dir, "config/postgres/init-databases.sh").read_text()
    match = re.search(r'^SERVICES="([^"]+)"', source, re.M)
    if not match:
        return None
    return set(match.group(1).split())


def recreate_exceptions(repo_dir):
    """The lists scripts/changed-services.sh classifies an unowned path by.

    Read out of the script rather than restated here. This check exists to keep
    one naming convention true; a second copy of its exceptions would be a
    second thing to keep true, and the two would disagree the first time only
    one was updated - which is how the old hardcoded hook names in services.sh
    came to miss half the bootstraps.
    """
    try:
        source = Path(repo_dir, "scripts/changed-services.sh").read_text()
    except OSError:
        # The synthetic trees the tests build hold compose files and nothing
        # else; there is no convention to check there. Same shape as
        # tracked_files() returning None outside a checkout.
        return None
    names = ("HOST_CONFIG_DIRS", "ALWAYS_ALL_CONFIG_DIRS", "SHARED_START_PATH",
             "PER_INVOCATION", "HOST_ONLY", "FIRST_INIT_CONFIG", "CONFIG_DIR_ALIASES",
             "ALSO_RECREATE")
    found = {}
    for name in names:
        match = re.search(rf"^{name}='([^']*)'", source, re.M | re.S)
        found[name] = set(match.group(1).split()) if match else None
    return found


def recreate_mapping_gaps(repo_dir, services):
    """Every config/ tree and scripts/ file resolves to the services reading it.

    `compose up -d` compares a container's image and spec, never the contents of
    the files bind-mounted into it, so something has to name which services a
    changed file obliges `make update` to recreate. That something is a naming
    convention already in the tree - config/<service>/ and
    scripts/<service>-*.sh - which scripts/changed-services.sh reads.

    A path the convention does not cover is answered with ALL, a full-stack
    restart: correct, and the cost the targeted recreate exists to avoid. So the
    gap is reported here instead of being paid on the host, once per update,
    forever.

    The render this is handed is `all,stremio-lan`, i.e. every declared service.
    Should a profile ever hide one from CI again, its config directory shows up
    below - a visible failure rather than a silent hole.
    """
    lists = recreate_exceptions(repo_dir)
    if lists is None:
        return []
    messages = []
    for name, value in sorted(lists.items()):
        if value is None:
            messages.append(f"scripts/changed-services.sh no longer defines {name}, "
                            "so nothing here reads its exceptions")
    if any(value is None for value in lists.values()):
        return messages

    aliased = {}
    for entry in sorted(lists["CONFIG_DIR_ALIASES"]):
        directory, _, readers = entry.partition(":")
        if not readers:
            messages.append(f"CONFIG_DIR_ALIASES entry {entry} names no reader; "
                            "the spelling is <dir>:<service>[,<service>]")
            continue
        aliased[directory] = readers.split(",")
        if not Path(repo_dir, "config", directory).is_dir():
            messages.append(f"CONFIG_DIR_ALIASES maps config/{directory}, which does not exist")
        for reader in aliased[directory]:
            if reader not in services:
                messages.append(f"CONFIG_DIR_ALIASES says {reader} reads config/{directory}, "
                                "but no such service is declared")

    # Which containers each service drags along when it is recreated. A name that
    # stopped being a service is a recreate that silently stops happening, and
    # nothing on the host would say so.
    coupled = {}
    for entry in sorted(lists["ALSO_RECREATE"]):
        owner, _, others = entry.partition(":")
        if not others:
            messages.append(f"ALSO_RECREATE entry {entry} names nothing to recreate with it; "
                            "the spelling is <service>:<service>[,<service>]")
            continue
        coupled[owner] = others.split(",")
        for name in [owner, *coupled[owner]]:
            if name not in services:
                messages.append(f"ALSO_RECREATE names {name}, which is not a declared service")

    # The check that matters: not that the table is well-formed, but that it is
    # complete. `network_mode: service:X` is resolved to a container *id* when
    # the container is created, so recreating X alone leaves every sharer
    # running, healthy-looking, and with no network at all - the exact silent
    # failure this table exists to prevent, and one a fourth sharer added later
    # would reintroduce with CI green.
    for name, service in sorted(services.items()):
        mode = service.get("network_mode") or ""
        if not mode.startswith("service:"):
            continue
        target = mode[len("service:"):]
        if name not in coupled.get(target, []):
            messages.append(
                f"{name} runs in {target}'s network namespace but is not in ALSO_RECREATE under {target}, "
                f"so recreating {target} alone would leave it running with no network"
            )

    # ALSO_RECREATE's *other* shape, and the quieter one: a service reading a
    # config/ tree the convention gives to somebody else. changed-services.sh
    # resolves such a change to the owner and recreates only that, so the reader
    # keeps the file it replaced - and for an env_file, forever, because those
    # values are frozen at container creation and even a `restart` keeps the old
    # ones. Without this, a service added later with
    # `env_file: ./config/ntfy/ntfy.env` ships that hole with CI green.
    config_root = f"{Path(repo_dir).resolve()}/config/"
    matched = 0
    for name, service in sorted(services.items()):
        for source in service.get("bind_sources") or []:
            if not source.startswith(config_root):
                continue
            matched += 1
            directory = source[len(config_root):].split("/")[0]
            owners = aliased.get(directory, [directory])
            if name == directory or name in owners:
                continue
            if any(name in coupled.get(owner, []) for owner in owners):
                continue
            messages.append(
                f"{name} reads config/{directory}/, which the naming convention gives to "
                f"{'/'.join(owners)}; add it to ALSO_RECREATE under {'/'.join(owners)} (or to "
                f"CONFIG_DIR_ALIASES), or a pull rewriting that tree recreates {'/'.join(owners)} "
                f"and leaves {name} on the file it replaced"
            )
    # A path shape this never recognises reads as "nobody shares a config tree",
    # which is the same green as a stack that genuinely does not - so say when
    # the render produced host paths and not one of them landed under config/.
    if not matched and any(service.get("bind_sources") for service in services.values()):
        messages.append(
            f"no service binds anything under {config_root}, so the ALSO_RECREATE completeness "
            "check above looked at nothing; the render's paths are not relative to this repo_dir"
        )

    tracked = tracked_files(repo_dir)
    if tracked is None:
        return messages

    config_dirs = {path.split("/")[1] for path in tracked
                   if path.startswith("config/") and path.count("/") >= 2}
    for directory in sorted(config_dirs):
        if directory in services or directory in aliased:
            continue
        if directory in lists["HOST_CONFIG_DIRS"] or directory in lists["ALWAYS_ALL_CONFIG_DIRS"]:
            continue
        messages.append(
            f"config/{directory} matches no service, so every change under it restarts the whole stack; "
            "rename it after the service that reads it, or add it to HOST_CONFIG_DIRS "
            "(applied without a container), ALWAYS_ALL_CONFIG_DIRS (only a restart applies it) "
            "(host files) or CONFIG_DIR_ALIASES (read by a differently-named service) "
            "in scripts/changed-services.sh"
        )
    for name in ("HOST_CONFIG_DIRS", "ALWAYS_ALL_CONFIG_DIRS"):
        for directory in sorted(lists[name]):
            if directory not in config_dirs:
                messages.append(f"{name} names config/{directory}, which no longer exists")

    # FIRST_INIT_CONFIG is the one list that exempts a file rather than a
    # directory, so a rename leaves it pointing at nothing and silently stops
    # exempting anything - the failure direction here is an unneeded recreate,
    # but a stale entry is also how the next file to move loses its exemption.
    for relative in sorted(lists["FIRST_INIT_CONFIG"]):
        if f"config/{relative}" not in tracked:
            messages.append(f"FIRST_INIT_CONFIG names config/{relative}, which no longer exists")

    # The two shapes the convention has no name for at all, so neither the
    # checks above nor changed-services.sh's rules can classify them: they fall
    # to ALL forever, quietly, which is the cost this whole check exists to
    # avoid paying.
    for path in sorted(p for p in tracked
                       if p.startswith("config/") and p.count("/") == 1):
        messages.append(
            f"{path} sits straight under config/, which names no service, so every change to it "
            "restarts the whole stack; move it into config/<service>/"
        )
    for path in sorted(p for p in tracked
                       if p.startswith("scripts/") and p.count("/") > 1):
        messages.append(
            f"{path} is below scripts/, where the <service>- prefix is not read, so every change "
            "to it restarts the whole stack; keep it directly in scripts/"
        )

    # Top level only: a script in a subdirectory of scripts/ is not a hook the
    # boot path runs, and the convention says nothing about its name.
    scripts = {path[len("scripts/"):] for path in tracked
               if path.startswith("scripts/") and path.count("/") == 1}
    classified = lists["SHARED_START_PATH"] | lists["PER_INVOCATION"] | lists["HOST_ONLY"]
    for script in sorted(scripts):
        # Longest service name prefixing it, the rule services.sh applies to
        # bootstraps so beszel-agent-* does not also read as beszel's.
        if any(script.startswith(f"{service}-") for service in services):
            continue
        if script in classified:
            continue
        messages.append(
            f"scripts/{script} is prefixed by no service name, so every change to it restarts the whole "
            "stack; rename it <service>-*, or classify it in SHARED_START_PATH / PER_INVOCATION / "
            "HOST_ONLY in scripts/changed-services.sh"
        )
    for script in sorted(classified):
        if script not in scripts:
            messages.append(f"scripts/changed-services.sh classifies {script}, which no longer exists")
    return messages


def main():
    repo_dir = sys.argv[1]
    config = json.load(sys.stdin)
    services = {name: project(s) for name, s in config["services"].items()}
    findings = []

    def report(category, message):
        findings.append(f"{category} {message}")

    for message in layout_drift(repo_dir):
        report("LAYOUT", message)

    for message in dependabot_blind_spots(repo_dir):
        report("DEPENDABOT", message)

    for message in recreate_mapping_gaps(repo_dir, services):
        report("RECREATE", message)

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
        # Omitting `tls` does not break the router, which is the problem.
        # websecure sets http.tls.certresolver, and Traefik applies that default
        # only to routers declaring no TLS config of their own: `tls=true`
        # resolves to {options: default} with no certResolver and is served from
        # the wildcard `traefik` and `headscale` obtain, while a router saying
        # nothing inherits the resolver and orders a DNS-01 certificate of its
        # own - one per service, against a Let's Encrypt limit of 50 a week.
        # Measured on v3.7.13, one API snapshot, entrypoint resolver `dummy`:
        #   rule + entrypoints + tls=true -> {"options": "default"}
        #   rule + entrypoints            -> {"certResolver": "dummy", ...}
        if not any(key == "tls" or key.startswith("tls.") for key in spec):
            report("TLS", f"{router} ({spec['_service']}) is routed publicly with no tls label")

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
