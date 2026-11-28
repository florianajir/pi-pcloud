#!/usr/bin/env python3
"""OpenClaw's config, as scripts/openclaw-pre-start.py renders it, checked
against the image compose.yaml pins.

The gateway reads that config read-only, so the migrations `openclaw doctor
--fix` applies on an upgrade never run here, and a release's notes do not
reliably announce them. A key the schema no longer knows stops the gateway at
boot, which CI's smoke test reports only as an unhealthy container. Worse, a
setting the release now reads elsewhere can be accepted and silently ignored:
nothing refuses it, only doctor would move or drop it.

So each config is validated, then handed to the image's own doctor on a copy,
offline. It passes when it is valid and doctor would neither drop nor change
anything render_config() sets; what doctor only adds - migration markers,
plugins it enables anyway - is printed, not failed. This only reports: the
read-only config is a security boundary, and a migration can change behaviour,
so a person carries it over.

Touches nothing of the running stack: throwaway containers with no network and
no volumes. A candidate image can be checked before the bump is committed:
  make openclaw-check image=ghcr.io/openclaw/openclaw:<tag>
"""

import importlib.util
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
_spec = importlib.util.spec_from_file_location("openclaw_pre_start", ROOT / "scripts" / "openclaw-pre-start.py")
pre_start = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pre_start)

CONFIG_PATH = f"{pre_start.STATE_DIR}/openclaw.json"
SECRET_ENV = [pre_start.GATEWAY_TOKEN, pre_start.MATRIX_PASSWORD, pre_start.LLM_KEY]
# The mounts compose gives the gateway, without which the Nextcloud plugin's
# load path is reported missing.
MOUNTS = [
    (ROOT / "config" / "openclaw" / "skills", "/opt/household-skills"),
    (ROOT / "config" / "openclaw" / "plugins", pre_start.HOUSEHOLD_PLUGINS),
]
# Doctor tries to install the npm plugins the bootstrap provides; offline, npm
# fails at once instead of retrying DNS for minutes.
DOCTOR_ENV = ["npm_config_offline=true"]
DOCTOR_TIMEOUT = 600
# Stamped on every write, so they would show in every diff.
NOISE_PREFIXES = ("meta.lastTouchedVersion", "wizard.")

PEOPLE = [
    {"id": "alice", "agent": "alice", "name": "Alice", "email": "alice@example.com"},
    {"id": "bob.k", "agent": "bob-k", "name": "Bob"},
]
# Before the first bootstrap nobody is listed and there is no family room,
# which renders a different config: both have to start.
FIXTURES = {
    "fresh install": ([], ""),
    "household with a family room": (PEOPLE, "!family:chat.test.local"),
}


def pinned_image():
    image = os.environ.get("OPENCLAW_CONTRACT_IMAGE", "")
    if image:
        return image
    compose = ["docker", "compose", "--env-file", "/dev/null", "-f", str(ROOT / "compose.yaml")]
    rendered = subprocess.run(
        [*compose, "config", "--format", "json"],
        env={**os.environ, "COMPOSE_PROFILES": "openclaw", "DATA_LOCATION": "/nonexistent/openclaw-contract"},
        capture_output=True,
        text=True,
    )
    try:
        return json.loads(rendered.stdout)["services"]["openclaw"]["image"]
    except (json.JSONDecodeError, KeyError):
        sys.exit("openclaw-config-contract: could not read the openclaw image from compose.yaml")


def ensure_image(image):
    if subprocess.run(["docker", "image", "inspect", image], capture_output=True).returncode == 0:
        return
    print(f"pulling {image}")
    if subprocess.run(["docker", "pull", "-q", image], capture_output=True).returncode != 0:
        sys.exit(f"openclaw-config-contract: could not pull {image}")


def docker_args(env=()):
    args = ["--network", "none", "--entrypoint", "node"]
    for name in SECRET_ENV:
        args += ["-e", f"{name}=contract-test"]
    for item in env:
        args += ["-e", item]
    for source, target in MOUNTS:
        args += ["-v", f"{source}:{target}:ro"]
    return args


def validate(image, config):
    """The schema issues that make the gateway refuse this config.
    Warnings are not issues: the npm plugins are only installed by the
    bootstrap, so they are always reported missing here."""
    with tempfile.TemporaryDirectory() as work:
        path = Path(work) / "openclaw.json"
        path.write_text(json.dumps(config, indent=2), encoding="utf-8")
        # The container's node user is not the runner's uid.
        path.chmod(0o644)
        Path(work).chmod(0o755)
        mount = ["-v", f"{path}:{CONFIG_PATH}:ro", "-e", "OPENCLAW_CONFIG_READONLY=1"]
        result = subprocess.run(
            ["docker", "run", "--rm", *docker_args(), *mount, image, "openclaw.mjs", "config", "validate", "--json"],
            capture_output=True,
            text=True,
        )
    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError:
        return [f"config validate printed no report (exit {result.returncode}): {result.stderr.strip()[-500:]}"]
    if report.get("valid"):
        return []
    return [f"{issue.get('path')}: {issue.get('message')}" for issue in report.get("issues", [])] or [
        report.get("error", {}).get("message", "invalid, with no issue listed")
    ]


def copy_out(container, path):
    """A file of the container, running or stopped, or None. Through docker cp
    rather than a bind mount, whose files would belong to the container's uid."""
    result = subprocess.run(["docker", "cp", f"{container}:{path}", "-"], capture_output=True)
    if result.returncode != 0:
        return None
    with tarfile.open(fileobj=io.BytesIO(result.stdout)) as archive:
        member = archive.next()
        return archive.extractfile(member).read().decode("utf-8") if member else None


def doctor_fix(image, config):
    """The config `doctor --fix` writes back, or None when it wrote none.
    Doctor goes on to repair plugins and state for minutes once the config is
    written, so the container is removed as soon as the file settles."""
    container = f"openclaw-contract-{os.getpid()}"
    with tempfile.TemporaryDirectory() as work:
        path = Path(work) / "openclaw.json"
        path.write_text(json.dumps(config, indent=2), encoding="utf-8")
        # docker cp hands the file to root; doctor runs as node and rewrites it.
        path.chmod(0o666)
        doctor = ["openclaw.mjs", "doctor", "--fix", "--non-interactive", "--no-workspace-suggestions"]
        subprocess.run(
            ["docker", "create", "--name", container, *docker_args(DOCTOR_ENV), image, *doctor],
            capture_output=True,
            check=True,
        )
        try:
            subprocess.run(["docker", "cp", str(path), f"{container}:{CONFIG_PATH}"], capture_output=True, check=True)
            subprocess.run(["docker", "start", container], capture_output=True, check=True)
            return wait_for_rewrite(container)
        finally:
            subprocess.run(["docker", "rm", "-f", container], capture_output=True)


def wait_for_rewrite(container):
    deadline = time.monotonic() + DOCTOR_TIMEOUT
    previous = None
    while time.monotonic() < deadline:
        running = subprocess.run(
            ["docker", "inspect", "-f", "{{.State.Running}}", container], capture_output=True, text=True
        ).stdout.strip()
        if copy_out(container, f"{CONFIG_PATH}.bak") is not None:
            current = copy_out(container, CONFIG_PATH)
            if current is not None and current == previous:
                return json.loads(current)
            previous = current
        elif running != "true":
            return None
        time.sleep(3)
    # Not None: "doctor changed nothing" would pass a config it never finished reading.
    raise TimeoutError(f"doctor neither wrote the config nor exited within {DOCTOR_TIMEOUT // 60} min")


def flatten(value, prefix=""):
    if isinstance(value, dict) and value:
        flat = {}
        for key, child in value.items():
            flat.update(flatten(child, f"{prefix}.{key}" if prefix else key))
        return flat
    return {prefix: value}


def compare(before, after):
    """What doctor dropped, changed and added, each as printable lines."""
    old, new = flatten(before), flatten(after)
    dropped, changed, added = [], [], []
    for path in sorted(old.keys() | new.keys()):
        if path.startswith(NOISE_PREFIXES) or old.get(path) == new.get(path):
            continue
        if path not in new:
            dropped.append(f"    - {path} = {json.dumps(old[path])}")
        elif path not in old:
            added.append(f"    + {path} = {json.dumps(new[path])}")
        else:
            changed.append(f"    ~ {path}: {json.dumps(old[path])} -> {json.dumps(new[path])}")
    return dropped, changed, added


def check(name, image, config):
    """True when the gateway takes this config as rendered."""
    issues = validate(image, config)
    try:
        migrated = doctor_fix(image, config)
    except TimeoutError as exc:
        issues.append(str(exc))
        migrated = None
    dropped, changed, added = compare(config, migrated) if migrated else ([], [], [])
    passed = not (issues or dropped or changed)
    lines = [f"{'PASS' if passed else 'FAIL'} {name}"]
    if issues:
        lines += ["  refused at boot:", *(f"    {issue}" for issue in issues)]
    if dropped or changed:
        lines += ["  `doctor --fix` would drop or change what render_config() sets:", *dropped, *changed]
    if added and not passed:
        lines += ["  and add (carry over what the lines above need, then re-run):", *added]
    elif added:
        lines.append(f"  doctor would only add {len(added)} setting(s) of its own, e.g. {added[0].strip()[2:]}")
    print("\n".join(lines), flush=True)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary and not passed:
        with open(summary, "a", encoding="utf-8") as out:
            out.write(f"### OpenClaw config contract\n\n{image}\n\n```\n" + "\n".join(lines) + "\n```\n\n")
    return passed


def main():
    image = pinned_image()
    ensure_image(image)
    print(f"checking against {image}; doctor takes about a minute per config", flush=True)
    failed = [
        name
        for name, (people, family_room) in FIXTURES.items()
        if not check(name, image, pre_start.render_config(people, "test.local", "UTC", family_room))
    ]
    if failed:
        sys.exit(f"openclaw-config-contract: {len(failed)} of {len(FIXTURES)} configs need render_config() changes")


if __name__ == "__main__":
    main()
