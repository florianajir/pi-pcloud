"""Read-only system status, as an OpenAPI tool server for Open WebUI.

Open WebUI injects every operation of the spec into the prompt of every message,
and this Pi processes prompts at ~40 tok/s - so the schema is a latency budget,
and so are the replies, which are re-processed on the next turn. One operation
with an enum costs 170 tokens, about +14 per topic added, where one extra
operation costs +72 on its own. `df -h` alone would cost ~400 in padding.

/proc and /sys are host-wide inside a container already; statvfs is not, which is
the only reason / is bind-mounted at /hostfs.

No endpoint takes a command, a path or a pattern, so an injected prompt has
nothing to steer.
"""

from __future__ import annotations

import json
import os
import re
import socket
import sqlite3
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal
from urllib.parse import quote
from urllib.request import Request, urlopen

from fastapi import FastAPI
from fastapi.responses import PlainTextResponse

HOSTFS = Path(os.environ.get("HOSTFS", "/hostfs"))
PROC = HOSTFS / "proc"
SYS = HOSTFS / "sys"
# Per-container memory.pressure lives here. Docker names each scope after the
# full container id, which project_containers() already returns.
CGROUP = SYS / "fs/cgroup"
DOCKER_SOCK = os.environ.get("DOCKER_SOCK", "/var/run/docker.sock")
# The socket is the host's: unfiltered, the list covers containers that have
# nothing to do with this stack, and a stray Exited one reads as a fault.
COMPOSE_PROJECT = os.environ.get("COMPOSE_PROJECT", "pi-web")
# Backrest's data directory is bind-mounted straight in (see compose.yaml); this
# is not a host path resolved under HOSTFS, because DATA_LOCATION is relative to
# the project directory by default and would land somewhere else entirely.
OPLOG = Path(os.environ.get("BACKREST_OPLOG", "/run/backrest/oplog.sqlite"))

# From backrest's proto/v1/operations.proto. WARNING is declared before ERROR but
# numbered after the cancellations, so reading declaration order off the binary
# gets these backwards.
BACKUP_STATUS = {
    0: "state unknown",
    1: "scheduled",
    2: "running",
    3: "succeeded",
    4: "FAILED",
    5: "cancelled by the system",
    6: "cancelled",
    7: "succeeded with warnings",
}
FINISHED = (3, 4, 7)

# A container started this recently is worth mentioning even with no restart
# counted against it, because `docker compose up` resets the counter.
RECENT_START = 3600
LOG_LINES = 3
LOG_WIDTH = 120

# Thresholds for the `anomalies` topic. The first three are Beszel's own alert
# values (scripts/beszel-agent-bootstrap.py), so anything this topic calls
# abnormal is something Beszel has already pushed to ntfy: two voices, one
# number, rather than a second opinion nobody asked for.
DISK_PCT = 85
MEMORY_PCT = 90
TEMP_C = 70
# Beszel has no swap alert, and swap that is merely full is not one either: a
# service that loaded a model and went idle has its cold pages evicted once and
# never faults them back, which is precisely what swap is for. Measured here at
# 103 days of uptime - swap 100% full, 7G of RAM available, no OOM kill, and
# 0.13 MB/min of paging - the fill level alone said "problem" where there was
# none.
#
# PSI answers that question directly instead of inferring it. `full avg300` is
# the share of the last five minutes in which *every* task was stalled waiting
# on memory - not a level that might mean trouble, but time the machine
# provably lost to it. 5% is 15 seconds of dead wall clock out of 300 on a box
# that is otherwise 95% idle.
#
# `some` is deliberately not used: it fires whenever any single process is in
# reclaim, which is a container touching its own mem_limit doing exactly what
# the limit is for.
PSI_MEM_FULL_PCT = 5
# The pre-PSI heuristic, kept for a kernel that has no /proc/pressure: psi=1 is
# added to cmdline.txt by scripts/configure-kernel-params.sh and only takes
# effect on the next reboot, so between install and reboot this is all there
# is. Both conditions have to hold - swap full *while* RAM is tight - because
# neither alone distinguishes the idle-model case above. RAM_PRESSURE_PCT sits
# below MEMORY_PCT on purpose: paging under pressure starts before RAM is
# exhausted.
SWAP_PCT = 50
RAM_PRESSURE_PCT = 80
# `docker compose up` zeroes RestartCount, so this many within one run of the
# stack is a loop rather than a history.
RESTART_LOOP = 3
# Both plans run daily - s3-backup at 04:00 from
# config/backrest/config.json.template, usb-env at 02:00 from
# scripts/backrest-pre-start.sh - putting 24h between a plan's starts; 30
# leaves six hours for a late or long run before the absence counts. Applied
# per plan by backup_runs(), so either one going quiet is caught. Also what the
# Uptime Kuma monitor reads off /health/backups.
BACKUP_MAX_AGE_H = int(os.environ.get("BACKUP_MAX_AGE_HOURS", "30"))

HEADSCALE_URL = os.environ.get("HEADSCALE_URL", "")
HEADSCALE_KEY_FILE = Path(os.environ.get("HEADSCALE_KEY_FILE", "/run/secrets/headscale_api_key"))
# All of them fit in a digest at this size; past it, offline devices are trimmed
# oldest-first and the reply says how many it dropped.
DEVICE_LINES = 25

# Named rather than discovered: enumerating the host's mount table meant
# filtering two dozen pseudo-filesystems and container layers down to these.
# topic_overview reports the first line, so `/` stays first.
FILESYSTEMS = ("/", "/mnt/usbdrive", "/mnt/sdcard")

app = FastAPI(
    title="Pi system status",
    description="Read-only status of the server this assistant runs on.",
    version="1.0.0",
)


def read(path: Path, default: str = "") -> str:
    try:
        return path.read_text()
    except OSError:
        return default


def human_bytes(num: float) -> str:
    for unit in ("B", "K", "M", "G", "T"):
        if abs(num) < 1024 or unit == "T":
            return f"{num:.0f}{unit}" if unit in ("B", "K") else f"{num:.1f}{unit}"
        num /= 1024
    return f"{num:.1f}T"


def duration(seconds: float) -> str:
    days, rem = divmod(int(seconds), 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    parts = []
    if days:
        parts.append(f"{days}d")
    if hours or days:
        parts.append(f"{hours}h")
    parts.append(f"{minutes}m")
    return " ".join(parts)


def disk_usage() -> list[tuple[str, int, int, int]]:
    """(mount, percent used, bytes free, bytes total) per mounted filesystem."""
    rows = []
    for mount in FILESYSTEMS:
        path = HOSTFS / mount.lstrip("/")
        # An unmounted drive leaves an empty directory on the root filesystem,
        # for which statvfs answers with the root filesystem's own numbers.
        if not path.is_mount():
            continue
        try:
            st = os.statvfs(path)
        except OSError:
            continue
        total = st.f_blocks * st.f_frsize
        if not total:
            continue
        free = st.f_bavail * st.f_frsize
        used = total - st.f_bfree * st.f_frsize
        rows.append((mount, used * 100 // total, free, total))
    return rows


def topic_disk() -> str:
    lines = [
        f"{mount}: {human_bytes(free)} free of {human_bytes(total)} ({pct}% used)"
        for mount, pct, free, total in disk_usage()
    ]
    return "\n".join(lines) or "no filesystem readable"


def cpu_times() -> list[list[int]]:
    rows = []
    for entry in read(PROC / "stat").splitlines():
        if not entry.startswith("cpu"):
            break
        rows.append([int(v) for v in entry.split()[1:]])
    return rows


def topic_cpu() -> str:
    # Two samples 300ms apart: /proc/stat is cumulative since boot, so a single
    # read would report the average since power-on rather than "right now".
    first = cpu_times()
    time.sleep(0.3)
    second = cpu_times()
    if not first or not second:
        return "cpu unreadable"

    def busy(before: list[int], after: list[int]) -> float:
        total = sum(after) - sum(before)
        idle = (after[3] + after[4]) - (before[3] + before[4])
        return 100.0 * (total - idle) / total if total > 0 else 0.0

    cores = len(first) - 1
    lines = [f"usage: {busy(first[0], second[0]):.0f}% over {cores} cores"]
    per_core = ", ".join(f"{busy(first[i], second[i]):.0f}%" for i in range(1, len(first)))
    lines.append(f"per core: {per_core}")

    load = read(PROC / "loadavg").split()
    if len(load) >= 3:
        lines.append(f"load average: {load[0]} {load[1]} {load[2]} (1/5/15 min, saturated above {cores})")

    temp = read(SYS / "class/thermal/thermal_zone0/temp").strip()
    if temp.isdigit():
        lines.append(f"temperature: {int(temp) / 1000:.1f}C")

    freqs = sorted(SYS.glob("devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq"))
    values = [int(read(f).strip() or 0) for f in freqs]
    if any(values):
        lines.append(f"clock: {max(values) // 1000} MHz")

    return "\n".join(lines)


def meminfo() -> dict[str, int]:
    info = {}
    for entry in read(PROC / "meminfo").splitlines():
        key, _, value = entry.partition(":")
        info[key] = int(value.split()[0]) * 1024 if value.split() else 0
    return info


def vmstat() -> dict[str, int]:
    stat = {}
    for entry in read(PROC / "vmstat").splitlines():
        key, _, value = entry.partition(" ")
        if value.strip().isdigit():
            stat[key] = int(value)
    return stat


def pressure(path: Path) -> dict[str, float]:
    """`{"some_avg300": 0.4, "full_avg300": 0.1, ...}`, or {} without usable PSI.

    The file is two lines of `key avg10=N avg60=N avg300=N total=N`. Absent
    means the kernel was built CONFIG_PSI_DEFAULT_DISABLED=y and never given
    psi=1 - the same read as any other missing /proc file, so no probe is
    needed to tell the two apart.
    """
    values = {}
    for line in read(path).splitlines():
        fields = line.split()
        for field in fields[1:]:
            key, _, value = field.partition("=")
            if key.startswith("avg"):
                try:
                    values[f"{fields[0]}_{key}"] = float(value)
                except ValueError:
                    return {}
    # All or nothing, keyed on the one field the caller actually judges on. A
    # half-read file would otherwise be truthy, take the PSI branch, find no
    # full_avg300, default it to 0 and quietly never fire - the same silence as
    # a healthy box. Returning {} sends it to the swap heuristic instead.
    return values if "full_avg300" in values else {}


def container_cgroup(container: dict) -> Path:
    return CGROUP / "system.slice" / f"docker-{container.get('Id', '')}.scope"


def worst_pressured_containers(limit: int = 3) -> list[tuple[str, float]]:
    """The containers stalling most on memory, worst first.

    Only called once the host is already over PSI_MEM_FULL_PCT: it is one read
    per container, which is cheap but pointless while nothing is wrong, and the
    whole point of this topic is to stay under a tenth of a second.
    """
    stalled = []
    for container in project_containers():
        full = pressure(container_cgroup(container) / "memory.pressure").get("full_avg300")
        if full:
            stalled.append((short_name(container), full))
    stalled.sort(key=lambda item: item[1], reverse=True)
    return stalled[:limit]


def topic_memory() -> str:
    info = meminfo()
    total, available = info.get("MemTotal", 0), info.get("MemAvailable", 0)
    if not total:
        return "memory unreadable"
    used_percent = (total - available) * 100 // total
    lines = [f"RAM: {human_bytes(available)} available of {human_bytes(total)} ({used_percent}% used)"]
    swap_total, swap_free = info.get("SwapTotal", 0), info.get("SwapFree", 0)
    if swap_total:
        lines.append(f"swap: {human_bytes(swap_total - swap_free)} used of {human_bytes(swap_total)}")
    # zswap compresses an evicted page and keeps it in RAM, reaching the disk
    # only once its pool is full, so "swap used" on its own no longer says how
    # much of that cost was actually paid in I/O. The ratio does.
    stat = vmstat()
    to_zswap, to_disk = stat.get("zswpout", 0), stat.get("pswpout", 0)
    if to_zswap + to_disk:
        lines.append(
            f"swap writes: {to_zswap * 100 // (to_zswap + to_disk)}% absorbed by zswap "
            f"in RAM ({to_zswap} pages compressed, {to_disk} to disk, since boot)"
        )
    psi = pressure(PROC / "pressure/memory")
    if psi:
        lines.append(
            f"memory pressure: {psi.get('full_avg300', 0):.2f}% of the last 5 min fully "
            f"stalled, {psi.get('some_avg300', 0):.2f}% partially"
        )
    return "\n".join(lines)


def topic_uptime() -> str:
    # split() rather than `or "0"`: a whitespace-only read is truthy.
    fields = read(PROC / "uptime").split()
    if not fields:
        return "uptime unreadable"
    up = float(fields[0])
    booted = time.strftime("%Y-%m-%d %H:%M", time.localtime(time.time() - up))
    return f"up {duration(up)} (booted {booted})\nhost time: {time.strftime('%Y-%m-%d %H:%M %Z')}"


def docker_raw(path: str) -> bytes:
    """No client library: this is a GET over a unix socket."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(5)
            sock.connect(DOCKER_SOCK)
            sock.sendall(f"GET {path} HTTP/1.0\r\nHost: docker\r\n\r\n".encode())
            chunks = []
            while data := sock.recv(65536):
                chunks.append(data)
        return b"".join(chunks).split(b"\r\n\r\n", 1)[1]
    except (OSError, IndexError):
        return b""


def docker_get(path: str) -> object | None:
    try:
        return json.loads(docker_raw(path))
    except ValueError:
        return None


def project_containers() -> list[dict]:
    query = quote(json.dumps({"label": [f"com.docker.compose.project={COMPOSE_PROJECT}"]}))
    containers = docker_get(f"/containers/json?all=1&filters={query}")
    return containers if isinstance(containers, list) else []


def short_name(container: dict) -> str:
    return (container.get("Names") or ["?"])[0].lstrip("/").removeprefix("pi-")


_RFC3339_HEAD = re.compile(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})")


def rfc3339(value: str) -> float | None:
    """Docker and headscale both carry nanoseconds, which %f cannot read; an event
    that never happened is reported as year 0001.

    Fractional seconds are optional in RFC 3339, so the seconds field can be
    followed straight by the zone designator ("...T10:00:00Z"). Splitting on "."
    left that Z attached and %S rejected it, reporting a live node as never
    seen; matching only the leading date-time handles both shapes. Both sources
    emit UTC, which is what the tzinfo below assumes.
    """
    if not value or value.startswith("0001"):
        return None
    head = _RFC3339_HEAD.match(value)
    if not head:
        return None
    try:
        stamp = datetime.strptime(head.group(1), "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None
    return stamp.replace(tzinfo=UTC).timestamp()


def topic_services() -> str:
    containers = project_containers()
    if not containers:
        return "container list unavailable"
    healthy, degraded = [], []
    for container in containers:
        name = short_name(container)
        status = container.get("Status", "")
        state = container.get("State", "")
        if state == "running" and "unhealthy" not in status:
            healthy.append(name)
        else:
            degraded.append(f"{name} ({status or state})")
    lines = [f"{len(healthy)} of {len(containers)} containers running and healthy"]
    if degraded:
        lines.append("needs attention: " + ", ".join(sorted(degraded)))
    else:
        lines.append("nothing needs attention")
    return "\n".join(lines)


def topic_restarts() -> str:
    lines = []
    now = time.time()
    for container in project_containers():
        detail = docker_get(f"/containers/{container['Id']}/json")
        if not isinstance(detail, dict):
            continue
        state = detail.get("State") or {}
        count = detail.get("RestartCount") or 0
        started = rfc3339(state.get("StartedAt", ""))
        age = now - started if started else None
        if count:
            note = f"{short_name(container)}: {count} restart{'s' if count > 1 else ''}"
            stopped = rfc3339(state.get("FinishedAt", ""))
            if stopped:
                note += f", last exit code {state.get('ExitCode')} {duration(now - stopped)} ago"
            lines.append((age if age is not None else 0.0, note))
        elif age is not None and age < RECENT_START:
            lines.append((age, f"{short_name(container)}: started {duration(age)} ago"))
    if not lines:
        return "no container has restarted"
    lines.sort()
    return "\n".join(note for _, note in lines[:6])


def restart_loops() -> list[tuple[str, int]]:
    """Containers restarting often enough to be looping rather than to have a
    history. RestartCount only comes back from an inspect per container, so this
    walk costs what topic_restarts costs; neither is called often enough to make
    caching it worth the staleness."""
    loops = []
    for container in project_containers():
        detail = docker_get(f"/containers/{container['Id']}/json")
        if not isinstance(detail, dict):
            continue
        count = detail.get("RestartCount") or 0
        if count >= RESTART_LOOP:
            loops.append((short_name(container), count))
    return sorted(loops)


def failing_containers() -> list[dict]:
    return [
        container
        for container in project_containers()
        if container.get("State") != "running" or "unhealthy" in container.get("Status", "")
    ]


def log_lines(body: bytes) -> list[str]:
    """Docker prefixes every chunk with an 8-byte frame header, unless the
    container was given a TTY, in which case the stream is verbatim."""
    chunks, offset = [], 0
    while offset + 8 <= len(body):
        if body[offset] not in (0, 1, 2) or body[offset + 1 : offset + 4] != b"\x00\x00\x00":
            break
        size = int.from_bytes(body[offset + 4 : offset + 8], "big")
        chunks.append(body[offset + 8 : offset + 8 + size])
        offset += 8 + size
    if not chunks:
        chunks = [body]
    text = b"".join(chunks).decode("utf-8", "replace")
    return [line.strip() for line in text.splitlines() if line.strip()]


def topic_errors() -> str:
    failing = failing_containers()
    if not failing:
        return "no container is failing, so there is nothing to quote"
    blocks = []
    # Only containers already known to be broken, and only their tail: the model
    # never names what gets read, and a reply is prompt tokens on every later turn.
    for container in failing[:3]:
        lines = log_lines(
            docker_raw(f"/containers/{container['Id']}/logs?stderr=1&stdout=1&tail={LOG_LINES}")
        )[-LOG_LINES:]
        header = f"{short_name(container)} ({container.get('Status') or container.get('State')}):"
        body = "\n".join(f"  {line[:LOG_WIDTH]}" for line in lines) or "  (no output)"
        blocks.append(f"{header}\n{body}")
    if len(failing) > 3:
        blocks.append(f"({len(failing) - 3} more failing, not quoted)")
    return "\n".join(blocks)


def backup_runs() -> list[dict] | None:
    """The last finished run of every plan, from backrest's operation log.

    Read from the log rather than backrest's API: the repos live on a remote, and
    the log answers "did last night run" without a restic password.

    None means the log could not be read, which is not the same answer as a log
    that records no backup yet - one is ignorance, the other is a fact.
    """
    try:
        with sqlite3.connect(f"file:{OPLOG}?mode=ro", uri=True) as log:
            rows = log.execute(
                "SELECT g.plan_id, g.repo_id, o.status, o.start_time_ms, o.snapshot_id "
                "FROM operations o JOIN operation_groups g ON g.ogid = o.ogid "
                "WHERE g.plan_id != '_system_' ORDER BY o.start_time_ms DESC"
            ).fetchall()
    except sqlite3.Error:
        return None

    now = time.time()
    latest, scheduled, failures = {}, {}, {}
    for plan, repo, status, start_ms, snapshot in rows:
        key = f"{plan} -> {repo}"
        when = start_ms / 1000
        if status in FINISHED:
            failures[key] = failures.get(key, 0) + (status == 4)
            latest.setdefault(key, (when, status, snapshot))
        elif status == 1 and when > now:
            scheduled[key] = when

    # Ages, not timestamps: every caller wants "how long ago", and resolving it
    # here keeps one `now` across the whole reply.
    return [
        {
            "key": key,
            "age": now - when,
            "status": status,
            "snapshot": snapshot,
            "failures": failures.get(key, 0),
            "next": scheduled[key] - now if key in scheduled else None,
        }
        for key, (when, status, snapshot) in latest.items()
    ]


def topic_backups() -> str:
    runs = backup_runs()
    if runs is None:
        return "backup log unreadable"
    if not runs:
        return "no backup recorded"
    lines = []
    for run in runs:
        line = f"{run['key']}: {BACKUP_STATUS.get(run['status'], run['status'])} {duration(run['age'])} ago"
        if run["snapshot"]:
            line += f" (snapshot {run['snapshot'][:8]})"
        if run["failures"]:
            line += f", {run['failures']} failed run(s) on record"
        if run["next"] is not None:
            line += f"; next in {duration(run['next'])}"
        lines.append(line)
    return "\n".join(lines)


def topic_devices() -> str:
    """The tailnet is served by headscale (config/headscale), so this reads its
    node API rather than tailscale's SaaS one. Every device is listed with when it
    was last seen, which is what makes "when was X last online" answerable without
    a parameter naming X - the model reads it off the list."""
    if not HEADSCALE_URL:
        return "tailnet not configured"
    key = read(HEADSCALE_KEY_FILE).strip()
    if not key:
        return "tailnet key unavailable"
    try:
        request = Request(f"{HEADSCALE_URL}/api/v1/node", headers={"Authorization": f"Bearer {key}"})
        with urlopen(request, timeout=5) as response:
            nodes = json.load(response).get("nodes") or []
    except (OSError, ValueError):
        return "tailnet unreachable"
    if not nodes:
        return "no device registered"

    now = time.time()
    online, offline = [], []
    for node in nodes:
        label = node.get("givenName") or node.get("name") or "?"
        owner = (node.get("user") or {}).get("name") or "?"
        if node.get("online"):
            online.append(f"online   {label} ({owner})")
        else:
            seen = rfc3339(node.get("lastSeen", ""))
            when = f"last seen {duration(now - seen)} ago" if seen else "never seen"
            offline.append((seen or 0.0, f"offline  {label} ({owner}), {when}"))

    offline.sort(reverse=True)
    users = sorted({(node.get("user") or {}).get("name") or "?" for node in nodes})
    header = f"{len(online)} of {len(nodes)} devices online, {len(users)} users: {', '.join(users)}"
    room = max(DEVICE_LINES - len(online), 0)
    lines = [header] + online + [line for _, line in offline[:room]]
    if len(offline) > room:
        lines.append(f"({len(offline) - room} more offline, not listed)")
    return "\n".join(lines)


def topic_overview() -> str:
    return "\n".join(
        [
            topic_uptime().splitlines()[0],
            topic_cpu().splitlines()[0],
            topic_memory().splitlines()[0],
            topic_disk().splitlines()[0],
            topic_services().splitlines()[0],
        ]
    )


def topic_anomalies() -> str:
    """Every reading that is outside its threshold, and nothing else.

    The other topics report; this one decides. It exists because otherwise the
    model has to work out on its own whether "12G free of 230G" is a problem, and
    a 4B model comparing numbers mid-sentence gets it wrong often enough to
    matter. The thresholds are in code, so the same box gets the same verdict
    every time it is asked.

    No CPU sample here: topic_cpu sleeps 300ms to take one, and the 5-minute load
    average already says whether the machine is saturated - sustained, which is
    the only version worth reporting.
    """
    findings = []

    for mount, pct, free, _total in disk_usage():
        if pct >= DISK_PCT:
            findings.append(
                f"disk {mount}: {pct}% used, only {human_bytes(free)} free "
                f"(threshold {DISK_PCT}%)"
            )

    info = meminfo()
    total = info.get("MemTotal", 0)
    ram_pct = (total - info.get("MemAvailable", 0)) * 100 // total if total else 0
    if total and ram_pct >= MEMORY_PCT:
        findings.append(f"memory: {ram_pct}% used (threshold {MEMORY_PCT}%)")
    swap_total = info.get("SwapTotal", 0)
    swap_pct = (swap_total - info.get("SwapFree", 0)) * 100 // swap_total if swap_total else 0
    psi = pressure(PROC / "pressure/memory")
    if psi:
        # The measurement, not a proxy for it: swap fill and RAM percentage are
        # both levels that may or may not cost anything, and needing two of
        # them at once was how that was worked around. `full avg300` is the
        # time already lost. Swap comes along as context, never as the trigger.
        full = psi.get("full_avg300", 0)
        if full >= PSI_MEM_FULL_PCT:
            detail = f"memory pressure: {full:.1f}% of the last 5 min fully stalled"
            detail += f" (threshold {PSI_MEM_FULL_PCT}%); RAM {ram_pct}% used"
            if swap_total:
                detail += f", swap {swap_pct}%"
            stalled = worst_pressured_containers()
            if stalled:
                detail += " - worst: " + ", ".join(
                    f"{name} {value:.1f}%" for name, value in stalled
                )
            findings.append(detail)
    elif swap_total and swap_pct >= SWAP_PCT and ram_pct >= RAM_PRESSURE_PCT:
        # No PSI: the pre-reboot heuristic. Both, not either - see SWAP_PCT.
        findings.append(
            f"swap: {swap_pct}% used while RAM is at {ram_pct}% "
            f"(thresholds {SWAP_PCT}% and {RAM_PRESSURE_PCT}%, no PSI on this kernel)"
        )

    temp = read(SYS / "class/thermal/thermal_zone0/temp").strip()
    if temp.isdigit() and int(temp) / 1000 >= TEMP_C:
        findings.append(f"temperature: {int(temp) / 1000:.1f}C (threshold {TEMP_C}C)")

    load = read(PROC / "loadavg").split()
    cores = max(len(cpu_times()) - 1, 1)
    if len(load) >= 2 and float(load[1]) > cores:
        findings.append(
            f"load average: {load[1]} over the last 5 min on {cores} cores"
        )

    failing = failing_containers()
    if failing:
        names = ", ".join(
            f"{short_name(c)} ({c.get('Status') or c.get('State')})"
            for c in sorted(failing, key=short_name)
        )
        findings.append(f"containers: {len(failing)} not healthy: {names}")

    for name, count in restart_loops():
        findings.append(
            f"restarts: {name} has restarted {count} times since the stack came up"
        )

    runs = backup_runs()
    if runs is None:
        findings.append("backups: the log cannot be read, so their state is unknown")
    elif not runs:
        findings.append("backups: none recorded yet")
    else:
        for run in runs:
            if run["status"] == 4:
                findings.append(
                    f"backups: {run['key']} failed on its last run, "
                    f"{duration(run['age'])} ago"
                )
            elif run["age"] > BACKUP_MAX_AGE_H * 3600:
                findings.append(
                    f"backups: {run['key']} last ran {duration(run['age'])} ago, "
                    f"past the {BACKUP_MAX_AGE_H}h it is expected within"
                )

    if not findings:
        return (
            "nothing abnormal: disk, memory, swap, temperature, load, containers, "
            "restarts and backups are all within their thresholds"
        )
    return "\n".join(findings)


TOPICS = {
    "overview": topic_overview,
    "anomalies": topic_anomalies,
    "disk": topic_disk,
    "cpu": topic_cpu,
    "memory": topic_memory,
    "uptime": topic_uptime,
    "services": topic_services,
    "restarts": topic_restarts,
    "errors": topic_errors,
    "backups": topic_backups,
    "devices": topic_devices,
}

Topic = Literal[
    "overview", "anomalies", "disk", "cpu", "memory", "uptime",
    "services", "restarts", "errors", "backups", "devices",
]


@app.get(
    "/status/{topic}",
    operation_id="get_system_status",
    summary="Live status of the server this assistant runs on",
    description=(
        "Returns current server measurements. Topics: overview (a summary of all of them), "
        "anomalies (only what is outside its threshold, or that nothing is), "
        "disk (free space per filesystem), cpu (usage, load, temperature), "
        "memory (RAM, swap, zswap and memory pressure), "
        "uptime, services (are the containers up), "
        "restarts (what restarted and why), errors (log tail of whatever is failing), "
        "backups (last backup and whether it worked), "
        "devices (tailnet devices, who owns them, which are online and when the "
        "offline ones were last seen). Call this instead of guessing."
    ),
    response_class=PlainTextResponse,
)
def get_system_status(topic: Topic) -> str:
    return TOPICS[topic]()


@app.get("/health", include_in_schema=False)
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/health/backups", include_in_schema=False)
def health_backups() -> dict[str, str]:
    """Backup freshness as a verdict, for the Uptime Kuma monitor that
    scripts/uptime-kuma-bootstrap.py creates against this path.

    Backrest reports what it ran, so a failed backup notifies and a backup that
    never started says nothing at all; this is the half nothing else covers.
    Kept out of the schema because the model reads the `backups` topic instead,
    and every operation in the schema is prompt tokens on every message.

    No status is a substring of another, so a json-query matching on any of them
    cannot match two.
    """
    runs = backup_runs()
    if runs is None:
        return {"status": "unknown", "detail": "backup log unreadable"}
    if not runs:
        return {"status": "stale", "detail": "no backup recorded yet"}
    failed = [run for run in runs if run["status"] == 4]
    if failed:
        return {
            "status": "failed",
            "detail": "; ".join(
                f"{run['key']} failed {duration(run['age'])} ago" for run in failed
            ),
        }
    stale = [run for run in runs if run["age"] > BACKUP_MAX_AGE_H * 3600]
    if stale:
        return {
            "status": "stale",
            "detail": "; ".join(
                f"{run['key']} last ran {duration(run['age'])} ago, "
                f"over the {BACKUP_MAX_AGE_H}h limit"
                for run in stale
            ),
        }
    return {
        "status": "ok",
        "detail": "; ".join(f"{run['key']} {duration(run['age'])} ago" for run in runs),
    }
