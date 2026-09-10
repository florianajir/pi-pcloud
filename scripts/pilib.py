#!/usr/bin/env python3
"""The Python half of scripts/lib.sh: the helpers a host-side bootstrap needs,
under the same names and with the same behaviour as their shell counterparts.

Only what a Python bootstrap actually calls is mirrored here. lib.sh stays the
authority for everything else the hooks do (secret generation, config
rendering, the service-specific token helpers) - porting those too would leave
the stack with two implementations of one rule and no way to tell which of them
a given start used. When a helper is needed on both sides, mirror it here and
say so in a comment on both, so a change to one is a visible omission on the
other.

stdlib-only and 3.11-compatible on purpose: this runs on the host interpreter
(3.11 on Raspberry Pi OS bookworm), from a Type=oneshot systemd unit, at a
point in the boot where nothing beyond the base system is guaranteed to exist.
"""

import contextlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import NoReturn

# --- Project paths (lib.sh's SCRIPT_DIR / PROJECT_DIR / ENV_FILE) ---

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = Path(os.environ.get("PROJECT_DIR") or SCRIPT_DIR.parent)
ENV_FILE = Path(os.environ.get("ENV_FILE") or PROJECT_DIR / ".env")

# lib.sh derives this from `basename "$0" .sh`; argv[0] is the .py path here and
# .stem drops the suffix the same way, so the log prefix a hook writes does not
# change with the language its script happens to be in.
SCRIPT_NAME = os.environ.get("SCRIPT_NAME") or Path(sys.argv[0]).stem


# --- Logging ---

# stderr, like lib.sh's log(): stdout is a hook's return channel (several shell
# helpers are consumed as `value=$(helper)`), and a log line written there ends
# up parsed as data by the caller.
def log(msg: str) -> None:
    print(f"[{SCRIPT_NAME}] {datetime.now():%H:%M:%S} {msg}", file=sys.stderr, flush=True)


def die(msg: str) -> NoReturn:
    log(f"ERROR: {msg}")
    raise SystemExit(1)


# --- Environment helpers ---


def read_env_value_from_file(path, key: str) -> str:
    """Last assignment of `key` in `path`, verbatim, or "" if absent.

    Mirrors lib.sh: `grep "^$key=" | tail -n1 | cut -d'=' -f2-`. Last wins, no
    unquoting, no whitespace trimming - the scripts read .env verbatim while
    Compose applies its own parser, and lib.sh's env_value_is_safe is what keeps
    the two from ever seeing different values. A missing file is "" rather than
    an error, as in the shell.

    startswith(), not a regex: `grep "^$key="` treats the key as a BRE, which no
    caller wants and which would misfire on a key holding a regex character.
    """
    prefix = key + "="
    try:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    value = ""
    for line in text.splitlines():
        if line.startswith(prefix):
            value = line[len(prefix) :]
    return value


def get_env_value(key: str) -> str:
    return read_env_value_from_file(ENV_FILE, key)


def upsert_env_value(path, key: str, value: str) -> None:
    """Set `key` in a KEY=VALUE file, replacing the first match and dropping any
    later duplicate, appending if absent.

    The shell version routed the value through awk's ENVIRON rather than -v,
    because awk expands escape sequences in a -v assignment and would rewrite a
    '\\n' or '\\t' inside a token on its way into the file. Nothing here
    interprets the value at all, which is the point.
    """
    path = Path(path)
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        lines = []

    prefix = key + "="
    out: list[str] = []
    done = False
    for line in lines:
        if line.startswith(prefix):
            if not done:
                out.append(prefix + value)
                done = True
            continue
        out.append(line)
    if not done:
        out.append(prefix + value)

    write_file_atomic(path, "".join(line + "\n" for line in out))


def is_truthy(value: str) -> bool:
    """lib.sh's is_truthy. It does not strip, because .env values cannot carry
    surrounding whitespace (env_value_is_safe rejects them at the prompt); strip
    here anyway so a value read from a container's environment, where no such
    rule applies, behaves the same.
    """
    return (value or "").strip().lower() in ("1", "true", "yes", "on")


def resolve_data_location_path() -> Path:
    """DATA_LOCATION from .env, made absolute against PROJECT_DIR, trailing
    slashes stripped (every caller appends "/something" and a doubled slash
    reaches anything that prints or compares these paths).
    """
    data_location = get_env_value("DATA_LOCATION") or "./data"
    while len(data_location) > 1 and data_location.endswith("/"):
        data_location = data_location[:-1]
    if data_location.startswith("/"):
        return Path(data_location)
    return PROJECT_DIR / data_location


# --- Files and permissions ---


def write_file_atomic(path, content: str) -> None:
    """Write via a temp file in the destination directory, then rename.

    `open(path, "w")` truncates before the content is known to be complete, so a
    failure half-way leaves an empty file behind - and every "already generated?"
    guard in this repo reads an empty file as generated, forever. The temp file
    is created beside the destination so the replace is atomic and inherits the
    directory's filesystem.
    """
    path = Path(path)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def safe_chmod(mode: int, path) -> None:
    try:
        os.chmod(path, mode)
    except OSError:
        log(f"WARNING: could not chmod {mode:o} {path} (insufficient permissions?)")


def fix_ownership(path) -> None:
    """Give a generated file the project directory's owner.

    The systemd unit runs the hooks as root, so anything they create is
    root:root - and a 0600 root:root file that compose reads as an env_file is
    one the next non-root `make update` cannot open at all. Best-effort: a
    non-root run cannot chown and does not need to.

    Recursive on a directory, like lib.sh's `chown -R`.
    """
    try:
        stat = PROJECT_DIR.stat()
    except OSError:
        return
    if (stat.st_uid, stat.st_gid) == (0, 0):
        return

    path = Path(path)
    targets = [path, *path.rglob("*")] if path.is_dir() else [path]
    for target in targets:
        with contextlib.suppress(OSError):
            os.chown(target, stat.st_uid, stat.st_gid)


# --- Docker ---


def _docker_stdout(args: list[str]) -> str:
    try:
        proc = subprocess.run(
            ["docker", *args], capture_output=True, text=True, check=False
        )
    except OSError:
        return ""
    return proc.stdout if proc.returncode == 0 else ""


def container_is_running(name: str) -> bool:
    return name in _docker_stdout(["ps", "--format", "{{.Names}}"]).splitlines()


def container_env_value(container: str, key: str) -> str:
    """Last value of `key` in a running container's baked environment.

    Reads the container's config rather than `docker exec printenv`, so it also
    sees a variable the image's entrypoint never exports into a shell.
    """
    out = _docker_stdout(["inspect", "--format", "{{range .Config.Env}}{{println .}}{{end}}", container])
    prefix = key + "="
    value = ""
    for line in out.splitlines():
        if line.startswith(prefix):
            value = line[len(prefix) :]
    return value


def wait_for_container(name: str, max_retries: int = 120, interval: float = 2) -> bool:
    log(f"Waiting for {name} container to appear...")
    for _ in range(max_retries):
        if container_is_running(name):
            log(f"{name} container is running")
            return True
        time.sleep(interval)
    log(f"ERROR: {name} container did not start in time")
    return False


def wait_for_health(name: str, max_retries: int = 120, interval: float = 2) -> bool:
    log(f"Waiting for {name} health status...")
    fmt = "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}"
    for _ in range(max_retries):
        if _docker_stdout(["inspect", "--format", fmt, name]).strip() == "healthy":
            log(f"{name} container is healthy")
            return True
        time.sleep(interval)
    log(f"ERROR: {name} container did not become healthy in time")
    return False


def compose(*args: str, check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["docker", "compose", *args],
        cwd=str(PROJECT_DIR),
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
        check=check,
    )


# --- HTTP through a throwaway curl container ---

# Mirrors lib.sh's docker_curl. The host cannot resolve a compose service name,
# and most services expose their port to the frontend network only, so a
# host-side urllib call has nothing to connect to: the request has to originate
# from a container on that network. This also means no service needs curl
# installed to be driven.
#
# The timeouts matter: hooks run under a Type=oneshot unit with no
# TimeoutStartSec, so a service that accepts the connection and never answers
# would hang the whole start sequence forever.
CURL_IMAGE = os.environ.get("CURL_IMAGE") or "curlimages/curl:8.12.1"
CURL_TIMEOUTS = ["--connect-timeout", "5", "--max-time", "30"]
DOCKER_CURL_NETWORK = os.environ.get("DOCKER_CURL_NETWORK") or "frontend"


class CurlError(RuntimeError):
    """A non-2xx response or a transport failure. curl runs with -f, so a 4xx is
    an exit code here rather than a body the caller has to inspect."""

    def __init__(self, args: list[str], returncode: int, stderr: str):
        self.returncode = returncode
        self.stderr = stderr.strip()
        # The command is deliberately not interpolated into the message: a
        # caller passing a URL with a query string could put a token in it.
        super().__init__(f"curl exited {returncode}: {self.stderr or 'no error output'}")


def docker_curl(*args: str, body: str | None = None, timeout: float = 60) -> str:
    """One curl call from a container on DOCKER_CURL_NETWORK; returns stdout.

    A request body is passed on stdin (`--data @-`), never as `-d <payload>`:
    `docker run` puts its whole argv in the host's process table, where any
    local `ps` can read it for the length of the call. Every payload this stack
    sends carries a credential somewhere (a password, an OIDC client secret, an
    ntfy webhook URL with its password in the userinfo), so there is no variant
    of this helper that takes a body on the command line.
    """
    cmd = ["docker", "run", "--rm"]
    if body is not None:
        cmd.append("-i")
    cmd += ["--network", DOCKER_CURL_NETWORK, CURL_IMAGE, "-fsS", *CURL_TIMEOUTS]
    if body is not None:
        cmd += ["--data", "@-"]
    cmd += list(args)

    try:
        proc = subprocess.run(
            cmd,
            input=body if body is not None else "",
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise CurlError(cmd, -1, "docker run did not return") from exc
    except OSError as exc:
        raise CurlError(cmd, -1, str(exc)) from exc

    if proc.returncode != 0:
        raise CurlError(cmd, proc.returncode, proc.stderr)
    return proc.stdout


def docker_curl_json(*args: str, body: str | None = None, timeout: float = 60):
    """docker_curl, with the response parsed. An empty body is {} rather than a
    decode error: several PocketBase endpoints answer 204 to a successful PATCH.
    """
    out = docker_curl(*args, body=body, timeout=timeout).strip()
    if not out:
        return {}
    try:
        return json.loads(out)
    except json.JSONDecodeError as exc:
        raise CurlError(list(args), 0, f"response was not JSON: {exc}") from exc


# --- OIDC ---


def get_oidc_secret(client_name: str, env_var_name: str = "") -> str:
    """The client secret for an Authelia OIDC client.

    Falls back from the environment to the rendered secret file to a `docker
    exec` into Authelia, so it resolves both before the file exists on a fresh
    install and after the stack is up. Returns "" when none of the three works.
    """
    if env_var_name:
        value = os.environ.get(env_var_name) or get_env_value(env_var_name)
        if value:
            return value

    secret_file = resolve_data_location_path() / "authelia-config" / "secrets" / f"oidc_{client_name}_secret.txt"
    try:
        return secret_file.read_text(encoding="utf-8").strip("\r\n")
    except OSError:
        pass

    if shutil.which("docker"):
        proc = compose("exec", "-T", "authelia", "sh", "-ec", f"cat /config/secrets/oidc_{client_name}_secret.txt")
        if proc.returncode == 0:
            return proc.stdout.strip("\r\n")

    return ""
