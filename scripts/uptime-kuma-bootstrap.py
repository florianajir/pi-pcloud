#!/usr/bin/env python3
"""Bootstrap Uptime Kuma 2.x: setup admin, disable built-in auth (Authelia handles it),
configure the ntfy notification tiers, docker host, and the monitor topology.

Monitors are organised in seven groups under the "pi-pcloud" root, split by blast
radius rather than by theme, because in Kuma the alerting granularity is per
monitor: the group a monitor lives in decides its check interval, its retry
budget and which ntfy priority it wakes you up with.

Each group also declares where the notification is attached:

  notify="children"  every monitor alerts on its own (precise message, used for
                     the tiers where you want to know exactly what broke)
  notify="group"     only the group monitor alerts, children stay silent. A Kuma
                     group is a worst-of-children aggregate whose down message
                     lists the failing children, so a gluetun outage sends one
                     "Child monitors down: qbittorrent, prowlarr, ..." instead of
                     six separate pushes.

Beside the per-container docker monitors (which only prove the container runs),
the topology adds end-to-end checks that exercise the actual request path:
HTTP monitors sent to Traefik with a Host header, a DNS resolution check through
Pi-hole, the gluetun public IP, and the age of the last backup. Those catch the
failure modes a docker check is blind to - a dropped Traefik route answers 404
while the container is happily running, and a backup that never started reports
nothing at all.

Optional services are profile-gated (COMPOSE_PROFILES in .env). Every monitor
is still created, but a monitor owned by a disabled service is paused rather
than deleted - pausing keeps its heartbeat history - and resumed when the
service is enabled again. The enabled-service list is computed on the host by
uptime-kuma-bootstrap.sh (docker compose is the authority on profiles) and
passed in as ENABLED_SERVICES; when it is empty or missing, nothing is paused
or resumed, so a plumbing failure can never silence real alerting.

Uses direct Socket.IO calls for Uptime Kuma 2.x compatibility.
"""

import contextlib
import json
import os
import re
import socket as pysocket
import sys
import threading
import time

import socketio

LOG_PREFIX = "[uptime-kuma-bootstrap]"

ROOT_GROUP = "pi-pcloud"

# Heartbeats are kept on the USB drive; a year of 60s beats for ~40 monitors is
# several hundred MB of SQLite for graphs nobody reads past a quarter.
KEEP_DATA_PERIOD_DAYS = 90

# Ceiling on the wait for the server to announce which login path applies.
LOGIN_MODE_WAIT_SECONDS = 15

# ntfy notification tiers. All four publish to the same topic (the "monitoring"
# topic granted to the uptime-kuma ntfy user by scripts/ntfy-pre-start.sh); only
# the priority differs, which is what drives the phone's do-not-disturb
# behaviour. "up" is the recovery priority, "down" the outage one
# (1=min ... 5=urgent).
TIERS = {
    "critical": {"name": "ntfy-critical", "up": 3, "down": 5},
    "high": {"name": "ntfy-high", "up": 2, "down": 4},
    "default": {"name": "ntfy", "up": 2, "down": 3},
    "low": {"name": "ntfy-low", "up": 1, "down": 2},
}

# resend counts are expressed in checks, not minutes: resend * interval is the
# delay before Kuma repeats an ongoing outage (0 = never repeat).
GROUPS = [
    {
        "name": "Core",
        "tier": "critical",
        "notify": "children",
        "interval": 60,
        "retry": 30,
        "maxretries": 3,
        "resend": 30,  # 30 min
        # ntfy sits here and not in Tools on purpose: it is the delivery channel
        # for every other alert, so its own outage is a critical event.
        "containers": [
            "pi-traefik",
            "pi-authelia",
            "pi-lldap",
            "pi-postgres",
            "pi-redis",
            "pi-unbound",
            "pi-pihole",
            "pi-ddns-updater",
            "pi-ntfy",
        ],
    },
    {
        "name": "Remote Access",
        "tier": "high",
        "notify": "children",
        "interval": 60,
        "retry": 60,
        "maxretries": 3,
        "resend": 30,  # 30 min
        "containers": ["pi-headscale", "pi-headplane", "pi-tailscale", "pi-gluetun"],
    },
    {
        "name": "Personal Data",
        "tier": "default",
        "notify": "children",
        "interval": 120,
        "retry": 60,
        "maxretries": 3,
        "resend": 15,  # 30 min
        "containers": [
            "pi-immich",
            "pi-immich-machine-learning",
            "pi-nextcloud",
            "pi-vaultwarden",
            "pi-kavita",
            "pi-audiobookshelf",
            "pi-backrest",
        ],
    },
    {
        "name": "Media & Downloads",
        "tier": "low",
        "notify": "group",
        "interval": 300,
        "retry": 120,
        "maxretries": 2,
        "resend": 0,
        "containers": [
            "pi-qbittorrent",
            "pi-stremio",
            "pi-stremio-lan",
            "pi-comet",
            "pi-prowlarr",
            "pi-kapowarr",
            "pi-flaresolverr",
            "pi-shelfmark",
        ],
    },
    {
        "name": "Tools & Observability",
        "tier": "low",
        "notify": "group",
        "interval": 300,
        "retry": 120,
        "maxretries": 2,
        "resend": 0,
        "containers": ["pi-homepage", "pi-beszel", "pi-beszel-agent", "pi-dockhand"],
        # Any container found in compose.yaml but absent from every list above
        # lands here, so a newly added service is still monitored (quietly).
        "fallback": True,
    },
    {
        "name": "Automation & AI",
        "tier": "low",
        "notify": "group",
        "interval": 300,
        "retry": 120,
        "maxretries": 2,
        "resend": 0,
        "containers": [
            "pi-n8n",
            "pi-n8n-runners",
            "pi-open-webui",
            "pi-llama-cpp",
            "pi-piper",
            # agentgateway's only check: distroless, so it has no healthcheck.
            "pi-agentgateway",
        ],
    },
    {
        "name": "External Chain",
        "tier": "high",
        "notify": "children",
        "interval": 120,
        "retry": 60,
        "maxretries": 3,
        "resend": 15,  # 30 min
        "containers": [],
    },
]

# Subdomain -> group for the end-to-end route checks. These go through Traefik
# with a Host header, so they cover routing + TLS termination + (where enabled)
# the Authelia forward-auth hop, none of which a docker monitor can see.
ROUTES = [
    ("auth", "External Chain"),
    ("immich", "External Chain"),
    ("nextcloud", "External Chain"),
    ("vault", "External Chain"),
    ("kavita", "External Chain"),
    ("ntfy", "External Chain"),
    ("homepage", "External Chain"),
    # The gluetun-served routers are the ones that silently vanish when gluetun
    # goes unhealthy; keep their check in the media group so it stays low noise.
    ("qbittorrent", "Media & Downloads"),
]

# Traefik answers 302/307 on the Authelia-protected routers (redirect to the SSO
# portal) and on apps that redirect to their own login page, so those count as
# healthy. A dropped router answers 404 and a broken backend 5xx: both are down.
ROUTE_STATUSCODES = ["200-299", "301", "302", "307", "308"]

# Subdomain -> compose service owning the route, where the two names differ.
# A subdomain absent from this map is assumed to be named after its service
# (nextcloud, kavita, ntfy, homepage, qbittorrent all are).
ROUTE_SERVICES = {
    "auth": "authelia",
    "immich": "immich-server",
    "vault": "vaultwarden",
}

# Synthetic (non-container) monitor -> the compose service whose profile gates
# it. dns/TLS belong to profile-less core services, so compose always lists
# them and those two never pause in practice; "vpn public ip" follows gluetun,
# which compose enables whenever any of its dependent profiles is on; "backup
# freshness" follows system-tools because that is the container serving its
# probe endpoint (backrest itself is core, but the probe dies with the tool).
SPECIAL_MONITOR_SERVICES = {
    "vpn public ip": "gluetun",
    "dns resolution": "pihole",
    "TLS certificate": "traefik",
    "backup freshness": "system-tools",
}


def log(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"{LOG_PREFIX} {ts} {msg}", file=sys.stderr, flush=True)


def env(key, default=""):
    return os.environ.get(key, default).strip()


def read_env_file(path):
    """Read a dotenv-style file into a dict."""
    values = {}
    if not os.path.isfile(path):
        return values
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                k, v = line.split("=", 1)
                v = v.strip()
                # One layer of matching quotes, as Compose and lib.sh's
                # unquote_env_value do. Left in, a quoted ADMIN_USER becomes a
                # Kuma admin whose name literally contains the quotes, and every
                # later login fails.
                if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
                    v = v[1:-1]
                values[k.strip()] = v
    return values


def get_container_names_from_compose(project_dir):
    """Extract container names from compose.yaml."""
    compose_path = os.path.join(project_dir, "compose.yaml")
    if not os.path.isfile(compose_path):
        log(f"ERROR: compose.yaml not found at {compose_path}")
        return []
    containers = []
    with open(compose_path) as f:
        for line in f:
            match = re.search(r"container_name:\s*(\S+)", line)
            if match:
                containers.append(match.group(1))
    return containers


def get_service_containers_from_compose(project_dir):
    """Map compose service name -> list of its container_name values.

    A stateful line parse (kept dependency-free, like
    get_container_names_from_compose): inside the top-level `services:` block,
    a two-space-indented `name:` line selects the current service and every
    container_name line attaches to it. Other top-level blocks (x-* anchors,
    volumes, networks) are skipped so their two-space keys cannot be mistaken
    for services.
    """
    compose_path = os.path.join(project_dir, "compose.yaml")
    if not os.path.isfile(compose_path):
        log(f"ERROR: compose.yaml not found at {compose_path}")
        return {}
    services = {}
    in_services = False
    current = None
    with open(compose_path) as f:
        for line in f:
            if re.match(r"^services:\s*$", line):
                in_services = True
                current = None
                continue
            if re.match(r"^[A-Za-z0-9_-]+:", line):  # another top-level block
                in_services = False
                current = None
                continue
            if not in_services:
                continue
            match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
            if match:
                current = match.group(1)
                services.setdefault(current, [])
                continue
            match = re.match(r"^\s+container_name:\s*(\S+)", line)
            if match and current:
                services[current].append(match.group(1))
    return services


def parse_enabled_services(raw):
    """ENABLED_SERVICES ("a,b,c") -> set of service names, or None when unknown.

    Empty means unknown, never "none enabled": the bootstrap only runs when
    uptime-kuma itself is an enabled service, so a genuinely computed list is
    never empty and an empty value can only be a plumbing failure.
    """
    services = {part.strip() for part in raw.split(",") if part.strip()}
    return services or None


def route_service(subdomain):
    """Compose service that owns the `route <subdomain>` monitor."""
    return ROUTE_SERVICES.get(subdomain, subdomain)


def monitor_should_be_active(service, enabled_services):
    """Whether a monitor should run, given the compose service that owns it.

    `service` is None for monitors not owned by a single service (groups,
    unmapped containers): those always run. An unknown enabled set (None)
    also pauses nothing - see parse_enabled_services.
    """
    if enabled_services is None or service is None:
        return True
    return service in enabled_services


def resolve_container_ip(name):
    """Resolve a container name to its IP on the network this script runs in.

    Kuma's DNS monitor hands the resolver straight to Node's dns.setServers(),
    which only accepts IP addresses - a container name throws. The address is
    re-resolved and converged on every run, so a docker-assigned IP that changes
    when the stack is recreated repairs itself at the next bootstrap.
    """
    try:
        return pysocket.gethostbyname(name)
    except OSError:
        return ""


def monitor_display_name(container_name):
    """pi-nextcloud -> nextcloud (the naming convention already in the instance)."""
    return container_name[3:] if container_name.startswith("pi-") else container_name


class UptimeKumaBootstrap:
    """Socket.IO client for Uptime Kuma 2.x bootstrap operations."""

    def __init__(self, url, timeout=30):
        self.url = url
        self.timeout = timeout
        self.sio = socketio.Client(logger=False, engineio_logger=False)
        self._connected = threading.Event()
        self._auto_logged_in = threading.Event()
        self._need_setup = threading.Event()
        self._ready = threading.Event()

        self.docker_hosts = []
        self.notifications = []
        self.monitors = {}

        self.sio.on("connect", self._on_connect)
        self.sio.on("autoLogin", self._on_auto_login)
        self.sio.on("setup", self._on_setup)
        self.sio.on("dockerHostList", self._on_docker_host_list)
        self.sio.on("notificationList", self._on_notification_list)
        self.sio.on("monitorList", self._on_monitor_list)

    def _on_connect(self):
        self._connected.set()

    def _on_auto_login(self, *args):
        self._auto_logged_in.set()

    def _on_setup(self, *args):
        self._need_setup.set()

    def _on_docker_host_list(self, data):
        if isinstance(data, list):
            self.docker_hosts = data
        log(f"Received {len(self.docker_hosts)} docker host(s)")

    def _on_notification_list(self, data):
        if isinstance(data, list):
            self.notifications = data
        log(f"Received {len(self.notifications)} notification(s)")

    def _on_monitor_list(self, data):
        if isinstance(data, dict):
            self.monitors = {
                m["name"]: m for m in data.values()
                if isinstance(m, dict) and "name" in m
            }
        self._ready.set()
        log(f"Received {len(self.monitors)} monitor(s)")

    def connect(self):
        """Connect to Uptime Kuma Socket.IO server."""
        log(f"Connecting to {self.url}")
        deadline = time.time() + 180
        last_err = None
        while time.time() < deadline:
            try:
                self.sio.connect(self.url, transports=["websocket"], wait_timeout=self.timeout)
                self._connected.wait(timeout=self.timeout)
                self._wait_for_login_mode()
                return
            except Exception as e:
                last_err = e
                time.sleep(2)
        log(f"ERROR: Could not connect: {last_err}")
        sys.exit(1)

    def _wait_for_login_mode(self):
        """Wait for autoLogin (auth disabled) or setup (fresh instance).

        Both arrive on the server's own schedule, and a container that has just
        been recreated routinely takes longer than a flat sleep: falling through
        early means attempting the password login, which is not the intended
        path once auth is disabled, and that exits the bootstrap. An instance
        with auth still enabled emits neither event, so this is a ceiling rather
        than a wait.
        """
        deadline = time.time() + LOGIN_MODE_WAIT_SECONDS
        while time.time() < deadline:
            if self._auto_logged_in.is_set() or self._need_setup.is_set():
                return
            time.sleep(0.2)
        log(f"No autoLogin or setup within {LOGIN_MODE_WAIT_SECONDS}s; assuming auth is enabled")

    def disconnect(self):
        with contextlib.suppress(Exception):
            self.sio.disconnect()

    def wait_ready(self):
        """Wait for monitorList event (signals all data has been sent).

        Fatal, not a warning: without that event self.monitors stays empty, and
        every ensure_* below then takes its "does not exist yet" branch and adds
        a second copy of all ~50 monitors, each alerting on its own. The hook
        runs again on the next start, so exiting here costs one reconcile.
        """
        if not self._ready.wait(timeout=self.timeout):
            log(f"ERROR: no monitorList within {self.timeout}s - refusing to "
                "reconcile against an empty monitor list (it would duplicate "
                "every monitor). Retry on the next start.")
            sys.exit(1)

    def _call(self, event, *args):
        """Emit a Socket.IO event and wait for the callback response.

        Multiple arguments are sent as a tuple (Socket.IO array).
        """
        result = {}
        done = threading.Event()

        def callback(*cb_args):
            if cb_args:
                result["data"] = cb_args[0] if len(cb_args) == 1 else cb_args
            done.set()

        # python-socketio sends multiple args via a tuple as the data param
        data = args[0] if len(args) == 1 else args if args else None
        self.sio.emit(event, data, callback=callback)
        if not done.wait(timeout=self.timeout):
            raise TimeoutError(f"Timeout waiting for {event} response")
        return result.get("data", {})

    def setup(self, username, password):
        """Create initial admin account.
        Server signature: setup(username, password, callback)
        """
        r = self._call("setup", username, password)
        if not r.get("ok"):
            raise Exception(r.get("msg", "Setup failed"))
        log(f"Created admin account: {username}")
        return r

    def login(self, username, password):
        """Login with username and password.
        Server signature: login(data, callback) where data={username, password}
        """
        r = self._call("login", {"username": username, "password": password})
        if not r.get("ok"):
            raise Exception(r.get("msg", "Login failed"))
        log(f"Logged in as {username}")
        return r

    def setup_or_login(self, username, password):
        """Setup initial account or login with existing credentials."""
        if self._auto_logged_in.is_set():
            log("Auto-logged in (auth disabled)")
            self.wait_ready()
            return

        if self._need_setup.is_set():
            log("Fresh instance detected, creating admin account")
            self.setup(username, password)
            # Reconnect after setup to get proper auth context
            self.disconnect()
            time.sleep(2)
            self._reset_state()
            self.connect()
            if not self._auto_logged_in.is_set():
                self.login(username, password)
            self.wait_ready()
            return

        try:
            self.login(username, password)
            self.wait_ready()
        except Exception as e:
            log(f"Login failed: {e}")
            sys.exit(1)

    def _reset_state(self):
        """Reset all event flags and data for reconnection."""
        self._connected.clear()
        self._auto_logged_in.clear()
        self._need_setup.clear()
        self._ready.clear()
        self.docker_hosts = []
        self.notifications = []
        self.monitors = {}

    def get_settings(self):
        """Return the general settings dict."""
        r = self._call("getSettings")
        if isinstance(r, dict) and r.get("ok"):
            return r.get("data", {}) or {}
        log(f"WARNING: getSettings failed: {r}")
        return {}

    def apply_settings(self, patch, password):
        """Merge `patch` into the general settings and save them.

        setSettings must always be handed the *whole* settings object: the
        server assigns `server.entryPage = data.entryPage` unconditionally, and
        it logs every connected client out when `disableAuth` is missing while
        auth is currently disabled. Sending only the changed keys would silently
        break the entry page and kick browser sessions.
        """
        current = self.get_settings()
        drift = {k: v for k, v in patch.items() if current.get(k) != v}
        if not drift:
            return False

        data = dict(current)
        data.update(patch)
        r = self._call("setSettings", data, password or "")
        if isinstance(r, dict) and r.get("ok"):
            log(f"Settings updated: {', '.join(f'{k}={v}' for k, v in drift.items())}")
            return True
        log(f"WARNING: setSettings failed: {r}")
        return False

    def auth_already_disabled(self):
        """True when the server auto-logged us in, which only happens with auth off.

        The `disableAuth` row is stored with an empty settings type, so it never
        comes back from getSettings("general") and cannot be compared there; the
        autoLogin event is the reliable signal.
        """
        return self._auto_logged_in.is_set()

    def disable_auth(self, password):
        """Disable built-in auth (Authelia handles authentication)."""
        if self.auth_already_disabled():
            log("Built-in auth already disabled")
            return
        self.apply_settings({"disableAuth": True}, password)

    def set_retention(self, days, password):
        """Cap heartbeat retention so the SQLite file stays small on the USB drive."""
        self.apply_settings({"keepDataPeriodDays": days}, password)

    def add_docker_host(self, name, docker_type="socket", docker_daemon="/var/run/docker.sock"):
        """Add a Docker host.
        Server signature: addDockerHost(dockerHost, dockerHostID, callback)
        """
        r = self._call("addDockerHost", {
            "name": name,
            "dockerType": docker_type,
            "dockerDaemon": docker_daemon,
        }, None)
        if not r.get("ok"):
            raise Exception(r.get("msg", "Failed to add docker host"))
        log(f"Added Docker host '{name}' (id={r.get('id')})")
        return r.get("id")

    def ensure_docker_host(self):
        """Ensure local Docker socket host exists. Returns its ID."""
        for host in self.docker_hosts:
            dtype = host.get("dockerType", host.get("_dockerType", ""))
            if dtype in (1, "socket"):  # SOCKET
                log(f"Docker host exists (id={host['id']}, name={host['name']})")
                return host["id"]

        return self.add_docker_host("Local Docker")

    @staticmethod
    def _notification_config(notif):
        config = notif.get("config", {})
        if isinstance(config, str):
            try:
                config = json.loads(config)
            except Exception:
                config = {}
        return config

    def find_notification(self, name, ntfy_url):
        """Return an existing ntfy notification by name, for the configured server."""
        for notif in self.notifications:
            config = self._notification_config(notif)
            if config.get("type") != "ntfy" or config.get("ntfyserverurl") != ntfy_url:
                continue
            if notif.get("name") == name or config.get("name") == name:
                return notif
        return None

    def ensure_ntfy_tier(self, tier, ntfy_url, topic, ntfy_username, ntfy_password):
        """Ensure the ntfy notification for one alert tier exists with the right priorities.

        Server signature: addNotification(notification, notificationID, callback);
        passing an existing ID updates it in place.
        """
        name = tier["name"]
        existing = self.find_notification(name, ntfy_url)
        existing_config = self._notification_config(existing) if existing else {}

        config = {
            "name": name,
            "type": "ntfy",
            # Never default and never "apply existing": the whole point of the
            # tiers is a hand-picked per-monitor mapping, and applyExisting would
            # bind this notification to every monitor in the instance.
            "isDefault": False,
            "applyExisting": False,
            "ntfyserverurl": ntfy_url,
            "ntfytopic": topic,
            "ntfyAuthenticationMethod": "usernamePassword",
            "ntfyusername": ntfy_username,
            "ntfypassword": ntfy_password or existing_config.get("ntfypassword", ""),
            "ntfyPriority": tier["up"],
            "ntfyPriorityDown": tier["down"],
            "ntfyUseTemplate": False,
        }

        if existing:
            drifted = {
                k: v for k, v in config.items()
                if k not in ("applyExisting",) and existing_config.get(k) != v
            }
            if not drifted:
                return existing["id"]
            r = self._call("addNotification", config, existing["id"])
            if not r.get("ok"):
                raise Exception(r.get("msg", "Failed to update notification"))
            log(f"Updated notification '{name}' (id={existing['id']}): "
                f"{', '.join(k for k in drifted if 'password' not in k.lower())}")
            return existing["id"]

        r = self._call("addNotification", config, None)
        if not r.get("ok"):
            raise Exception(r.get("msg", "Failed to add notification"))
        log(f"Added notification '{name}' (id={r.get('id')})")
        return r.get("id")

    def add_monitor(self, monitor_data):
        """Add a monitor.
        Server signature: add(monitor, callback)
        """
        r = self._call("add", monitor_data)
        if not r.get("ok"):
            raise Exception(r.get("msg", "Failed to add monitor"))
        return r

    def edit_monitor(self, monitor_data):
        """Edit an existing monitor. Requires the full object, including its id.
        Server signature: editMonitor(monitor, callback)
        """
        r = self._call("editMonitor", monitor_data)
        if not r.get("ok"):
            raise Exception(r.get("msg", "Failed to edit monitor"))
        return r

    def pause_monitor(self, monitor_id):
        """Pause a monitor, keeping its heartbeat history.
        Server signature: pauseMonitor(monitorID, callback)
        """
        r = self._call("pauseMonitor", monitor_id)
        if not r.get("ok"):
            raise Exception(r.get("msg", "Failed to pause monitor"))
        return r

    def resume_monitor(self, monitor_id):
        """Resume a paused monitor.
        Server signature: resumeMonitor(monitorID, callback)
        """
        r = self._call("resumeMonitor", monitor_id)
        if not r.get("ok"):
            raise Exception(r.get("msg", "Failed to resume monitor"))
        return r

    def reconcile_monitor_active(self, name, monitor_id, should_be_active):
        """Pause or resume one monitor so it tracks its service's compose profile.

        Runs right after ensure_monitor. The current state comes from the
        monitorList snapshot taken at login; a monitor added in this run is
        not in it, and the server starts new monitors active, so missing means
        active. ensure_monitor edits cannot flip the state in between (the
        server's editMonitor never assigns `active`), so the snapshot stays
        truthful and only real transitions emit a call - an idempotent re-run
        over a converged instance stays quiet.
        """
        if monitor_id is None:
            return
        existing = self.monitors.get(name)
        currently_active = bool(existing.get("active", True)) if existing else True
        if currently_active == should_be_active:
            return
        try:
            if should_be_active:
                self.resume_monitor(monitor_id)
                log(f"Resumed monitor '{name}' (service enabled again)")
            else:
                self.pause_monitor(monitor_id)
                log(f"Paused monitor '{name}' (service disabled via COMPOSE_PROFILES)")
        except Exception as e:
            action = "resume" if should_be_active else "pause"
            log(f"WARNING: Failed to {action} monitor '{name}': {e}")

    @staticmethod
    def _comparable(value):
        """Normalise a field so server-side and desired representations compare equal."""
        if isinstance(value, dict):
            # notificationIDList: {"4": true} vs {4: True}
            return {str(k) for k, v in value.items() if v}
        if isinstance(value, list):
            return [str(v) for v in value]
        return value

    def ensure_monitor(self, name, desired, defaults=None):
        """Create the monitor if it is missing, otherwise converge the desired fields.

        Converging (rather than skipping known names) is what lets this script
        re-shape an instance that was already bootstrapped: reparenting the flat
        list into groups, retuning intervals, or moving a monitor to another
        alert tier all happen through here. `active` is deliberately never part
        of `desired`, and the server-side editMonitor never assigns it (it only
        restarts a monitor that is already active), so this method never flips
        a paused monitor back on. Pause state is owned by
        reconcile_monitor_active, which runs after this and tracks
        COMPOSE_PROFILES; monitors it does not manage (groups) keep whatever
        the user set by hand.
        """
        existing = self.monitors.get(name)
        if existing:
            drifted = {
                k: v for k, v in desired.items()
                if self._comparable(existing.get(k)) != self._comparable(v)
            }
            if not drifted:
                return existing.get("id")
            updated = dict(existing)
            updated.update(desired)
            self.edit_monitor(updated)
            log(f"Updated monitor '{name}': {', '.join(sorted(drifted))}")
            return existing.get("id")

        payload = dict(defaults or {})
        payload.update(desired)
        payload["name"] = name
        r = self.add_monitor(payload)
        monitor_id = r.get("monitorID")
        log(f"Added monitor '{name}' (id={monitor_id})")
        return monitor_id

    def ensure_group_monitor(self, name, parent_id, notification_id, resend=0):
        """Ensure a group monitor exists, with the right parent and alert binding.

        Group monitors are checked often and with no retry of their own: their
        children have already burned their retry budget before flipping to DOWN,
        and a child in retry reports PENDING, which keeps the group out of the
        DOWN state until the failure is confirmed.
        """
        desired = {
            "type": "group",
            "parent": parent_id,
            "interval": 60,
            "retryInterval": 60,
            "maxretries": 0,
            "resendInterval": resend,
            "notificationIDList": {str(notification_id): True} if notification_id else {},
        }
        return self.ensure_monitor(name, desired, defaults={
            "accepted_statuscodes": ["200-299"],
            "conditions": [],
        })

    def ensure_container_monitor(self, container_name, docker_host_id, parent_id, group, notification_id):
        """Ensure a Docker container monitor exists with its group's timing and tier."""
        desired = {
            "type": "docker",
            "parent": parent_id,
            "docker_container": container_name,
            "docker_host": docker_host_id,
            "interval": group["interval"],
            "retryInterval": group["retry"],
            "maxretries": group["maxretries"],
            "resendInterval": group["resend"],
            "notificationIDList": {str(notification_id): True} if notification_id else {},
        }
        return self.ensure_monitor(monitor_display_name(container_name), desired, defaults={
            "accepted_statuscodes": ["200-299"],
            "conditions": [],
        })

    def ensure_route_monitor(self, subdomain, host_name, parent_id, group, notification_id):
        """Ensure an end-to-end HTTP check that goes through Traefik for one router.

        The request is sent to the Traefik container with a `Host` header instead
        of to the public URL: Kuma resolves `<sub>.<host_name>` to the WAN address,
        so the request would hairpin through the router and reach Traefik with a
        source IP outside ALLOW_IP_RANGES, which the lan@docker middleware answers
        with 403. Talking to the container directly keeps the source inside the
        frontend subnet (already covered by ALLOW_IP_RANGES) while still exercising
        the real router rules, the middlewares and the backend service.

        TLS verification is off because the certificate is issued for the public
        name, not for `pi-traefik`; certificate expiry has its own daily monitor.
        """
        desired = {
            "type": "http",
            "parent": parent_id,
            "url": "https://pi-traefik/",
            "method": "GET",
            "headers": json.dumps({"Host": f"{subdomain}.{host_name}"}),
            "ignoreTls": True,
            "maxredirects": 0,
            "accepted_statuscodes": ROUTE_STATUSCODES,
            # An HTTP monitor left at timeout 0 aborts its own request through
            # AbortSignal and is permanently down.
            "timeout": 30,
            "expiryNotification": False,
            "interval": group["interval"],
            "retryInterval": group["retry"],
            "maxretries": group["maxretries"],
            "resendInterval": group["resend"],
            "notificationIDList": {str(notification_id): True} if notification_id else {},
        }
        return self.ensure_monitor(f"route {subdomain}", desired, defaults={"conditions": []})

    def ensure_tls_monitor(self, host_name, parent_id, group, notification_id):
        """Ensure the wildcard certificate is checked daily via a public HTTPS route.

        The URL has to be a route that is NOT behind the lan@docker allowlist.
        Kuma resolves the public hostname to the WAN address, so the request comes
        back through the router with a source IP outside ALLOW_IP_RANGES; on a
        LAN-restricted route Traefik answers 403 and the monitor can never be up.
        auth is deliberately public (external SSO needs it) and serves the same
        wildcard certificate, so it is the one host that works here.
        """
        desired = {
            "type": "http",
            "parent": parent_id,
            "url": f"https://auth.{host_name}",
            "timeout": 48,
            "interval": 86400,
            "retryInterval": 3600,
            "maxretries": 1,
            "resendInterval": 0,
            "expiryNotification": True,
            "notificationIDList": {str(notification_id): True} if notification_id else {},
        }
        return self.ensure_monitor("TLS certificate", desired, defaults={
            "accepted_statuscodes": ["200-299"],
            "conditions": [],
        })

    def ensure_dns_monitor(self, resolver_ip, parent_id, group, notification_id):
        """Ensure name resolution itself is checked, not just the DNS containers.

        Querying an external name through Pi-hole exercises the whole chain in one
        check: Pi-hole is up, it forwards to Unbound, and Unbound can still reach
        the root servers. A container-level check on either sees none of that.
        """
        desired = {
            "type": "dns",
            "parent": parent_id,
            "hostname": "github.com",
            "dns_resolve_server": resolver_ip,
            "dns_resolve_type": "A",
            "port": 53,
            "interval": group["interval"],
            "retryInterval": group["retry"],
            "maxretries": group["maxretries"],
            "resendInterval": group["resend"],
            "notificationIDList": {str(notification_id): True} if notification_id else {},
        }
        return self.ensure_monitor("dns resolution", desired, defaults={
            "accepted_statuscodes": ["200-299"],
            "conditions": [],
        })

    def ensure_vpn_monitor(self, parent_id, group, notification_id):
        """Ensure the VPN tunnel is actually carrying traffic.

        gluetun's control server answers with the public IP seen from inside the
        tunnel; an empty value means the container is running but egress is not
        going through the VPN. The unauthenticated read on this route is already
        granted to the Homepage widget (config/gluetun/auth-config.toml).
        """
        desired = {
            "type": "json-query",
            "parent": parent_id,
            "url": "http://pi-gluetun:8000/v1/publicip/ip",
            "method": "GET",
            "jsonPath": "public_ip",
            "jsonPathOperator": "contains",
            "expectedValue": ".",
            "timeout": 30,
            "accepted_statuscodes": ["200-299"],
            "interval": group["interval"],
            "retryInterval": group["retry"],
            "maxretries": group["maxretries"],
            "resendInterval": group["resend"],
            "notificationIDList": {str(notification_id): True} if notification_id else {},
        }
        return self.ensure_monitor("vpn public ip", desired, defaults={"conditions": []})

    def ensure_backup_freshness_monitor(self, parent_id, group, notification_id):
        """Ensure a backup that never ran is noticed, not just one that failed.

        Backrest's hook fires on the runs that happen: a plan that never started
        sends nothing, and the pi-backrest container monitor beside it stays green
        the whole time. system-tools reads the age of the last finished run off
        backrest's operation log and answers `ok` only while it is inside
        BACKUP_MAX_AGE_HOURS - the daily 04:00 schedule plus six hours of slack.

        Hourly with a single retry: what is being measured moves once a day, so a
        tighter interval would only add heartbeats to the database. The status is
        matched rather than the HTTP code so the down message names the reason,
        and a fresh install is legitimately down here until its first backup.
        """
        desired = {
            "type": "json-query",
            "parent": parent_id,
            "url": "http://pi-system-tools:8000/health/backups",
            "method": "GET",
            "jsonPath": "status",
            "jsonPathOperator": "==",
            "expectedValue": "ok",
            "timeout": 30,
            "accepted_statuscodes": ["200-299"],
            "interval": 3600,
            "retryInterval": 3600,
            "maxretries": 1,
            "resendInterval": 0,
            "notificationIDList": {str(notification_id): True} if notification_id else {},
        }
        return self.ensure_monitor("backup freshness", desired, defaults={"conditions": []})

    def status_page_exists(self, slug):
        """Check via the public (auth-free) HTTP API whether a status page slug exists."""
        import urllib.error
        import urllib.request

        try:
            urllib.request.urlopen(f"{self.url}/api/status-page/{slug}", timeout=10)
            return True
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return False
            raise
        except Exception:
            return False

    def ensure_status_page(self, slug, title, group_name, monitor_ids):
        """Ensure a public status page exists containing the given monitor IDs.

        Used by the Homepage 'uptimekuma' widget, which has no full API and instead
        reads a public status page by slug (no auth needed). The widget only counts
        up/down monitors on the page, so listing the seven group monitors - rather
        than a single root - is what turns it from a binary indicator into
        "6 up / 1 down" telling you which side of the stack is broken.
        Server signature: addStatusPage(title, slug, callback), then
        saveStatusPage(slug, config, imgDataUrl, publicGroupList, callback).
        """
        if not self.status_page_exists(slug):
            r = self._call("addStatusPage", title, slug)
            if not r.get("ok"):
                raise Exception(r.get("msg", "Failed to add status page"))
            log(f"Created status page '{slug}'")
        else:
            log(f"Status page '{slug}' already exists")

        config = {
            "slug": slug,
            "title": title,
            "description": None,
            "icon": "/icon.svg",
            "autoRefreshInterval": 300,
            "theme": "auto",
            "published": True,
            "showTags": False,
            "customCSS": "",
            "footerText": None,
            "showPoweredBy": False,
            "showCertificateExpiry": False,
            "showOnlyLastHeartbeat": False,
            "rssTitle": None,
            "analyticsId": None,
            "analyticsScriptUrl": None,
            "analyticsType": None,
            "domainNameList": [],
        }
        monitor_list = [{"id": mid} for mid in monitor_ids]
        # imgDataUrl must be a string (not null) or the server's `.startsWith()` check throws.
        r = self._call("saveStatusPage", slug, config, "", [
            {"name": group_name, "weight": 1, "monitorList": monitor_list},
        ])
        if not r.get("ok"):
            raise Exception(r.get("msg", "Failed to save status page"))
        log(f"Status page '{slug}' updated with {len(monitor_ids)} monitor(s)")


def build_container_map():
    """container name -> group definition, for every explicitly mapped container."""
    mapping = {}
    for group in GROUPS:
        for container in group["containers"]:
            mapping[container] = group
    return mapping


def fallback_group():
    for group in GROUPS:
        if group.get("fallback"):
            return group
    return GROUPS[-1]


def main():
    project_dir = env("PROJECT_DIR", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    env_file = os.path.join(project_dir, ".env")
    ntfy_env_file = os.path.join(project_dir, "config", "ntfy", "ntfy.env")
    existing_only = env("UPTIME_KUMA_EXISTING_ONLY").lower() in ("1", "true", "yes", "on")

    log("=== Uptime Kuma Bootstrap ===")

    if existing_only:
        # The running stack has built-in Kuma auth disabled. This mode is used to
        # add monitors without reading any credentials from configuration files.
        username = ""
        password = ""
        ntfy_password = ""
    else:
        ntfy_env = read_env_file(ntfy_env_file)

        # ADMIN_USER comes from the environment: the wrapper passes just this key
        # rather than bind-mounting .env, which would put every secret in the
        # stack inside a container that pip-installs from PyPI at runtime. The
        # file is still read when present, so a direct run outside the wrapper
        # keeps working.
        username = env("ADMIN_USER")
        if not username and os.path.isfile(env_file):
            username = read_env_file(env_file).get("ADMIN_USER", "")
        password = ntfy_env.get("UPTIME_KUMA_ADMIN_PASSWORD", "")
        if not username:
            log("ERROR: ADMIN_USER must be set (environment or .env)")
            sys.exit(1)
        if not password:
            log("ERROR: UPTIME_KUMA_ADMIN_PASSWORD not found in ntfy.env; run ntfy-pre-start.sh first")
            sys.exit(1)
        ntfy_password = ntfy_env.get("NTFY_UPTIME_KUMA_PASSWORD", "")

    ntfy_username = "uptime-kuma"
    # Topic comes from ntfy.env so it stays in sync with the ACL that
    # scripts/ntfy-pre-start.sh grants this user; the tiers differ by priority,
    # not by topic.
    ntfy_topic = read_env_file(ntfy_env_file).get("NTFY_MONITORING_TOPIC") or "monitoring"
    ntfy_url = "http://pi-ntfy"
    kuma_url = env("UPTIME_KUMA_URL", "http://pi-uptime-kuma:3001")

    api = UptimeKumaBootstrap(kuma_url)
    api.connect()

    try:
        api.setup_or_login(username, password)

        # Authelia handles authentication at the reverse proxy.
        if password:
            api.disable_auth(password)

        api.set_retention(KEEP_DATA_PERIOD_DAYS, password)

        docker_host_id = api.ensure_docker_host()

        # Ensure one ntfy notification per alert tier. Without the password the
        # tiers cannot be created from scratch, but existing ones are reused.
        tier_ids = {}
        for key, tier in TIERS.items():
            try:
                tier_ids[key] = api.ensure_ntfy_tier(
                    tier, ntfy_url, ntfy_topic, ntfy_username, ntfy_password,
                )
            except Exception as e:
                log(f"WARNING: Failed to ensure notification '{tier['name']}': {e}")
                existing = api.find_notification(tier["name"], ntfy_url)
                tier_ids[key] = existing["id"] if existing else None

        # Root group. It carries no notification of its own: every child group
        # already alerts, and a nested group would otherwise fire a third,
        # redundant push for the same outage.
        root_id = api.ensure_group_monitor(ROOT_GROUP, None, None)

        group_ids = {}
        for group in GROUPS:
            notification_id = tier_ids.get(group["tier"]) if group["notify"] == "group" else None
            group_ids[group["name"]] = api.ensure_group_monitor(
                group["name"], root_id, notification_id, resend=group["resend"],
            )

        container_map = build_container_map()
        default_group = fallback_group()
        container_names = get_container_names_from_compose(project_dir)
        if not container_names:
            log("WARNING: No container names found in compose.yaml")
        else:
            log(f"Found {len(container_names)} containers to monitor")

        # Profile-disabled services keep their monitors, paused. The enabled
        # list is computed by the host-side wrapper (docker compose is the
        # authority on COMPOSE_PROFILES) and handed over via ENABLED_SERVICES.
        enabled_services = parse_enabled_services(env("ENABLED_SERVICES"))
        if enabled_services is None:
            log("WARNING: ENABLED_SERVICES is empty or unset; treating every "
                "service as enabled - no monitor will be paused or resumed")
        else:
            log(f"Enabled services ({len(enabled_services)}): "
                + ", ".join(sorted(enabled_services)))
        container_services = {
            container: service
            for service, containers in get_service_containers_from_compose(project_dir).items()
            for container in containers
        }

        for container_name in container_names:
            if container_name == "pi-uptime-kuma":
                continue
            group = container_map.get(container_name)
            if group is None:
                group = default_group
                log(f"NOTE: {container_name} is not mapped to a group, "
                    f"falling back to '{group['name']}'")
            notification_id = tier_ids.get(group["tier"]) if group["notify"] == "children" else None
            try:
                monitor_id = api.ensure_container_monitor(
                    container_name, docker_host_id, group_ids[group["name"]], group, notification_id,
                )
                api.reconcile_monitor_active(
                    monitor_display_name(container_name), monitor_id,
                    monitor_should_be_active(
                        container_services.get(container_name), enabled_services,
                    ),
                )
            except Exception as e:
                log(f"WARNING: Failed to ensure monitor for {container_name}: {e}")

        groups_by_name = {group["name"]: group for group in GROUPS}

        def tier_for(group):
            return tier_ids.get(group["tier"]) if group["notify"] == "children" else None

        # End-to-end checks: what a docker monitor cannot see
        # uptime-kuma-bootstrap.sh resolves HOST_NAME from .env and passes it
        # in: this container has no docker CLI and no socket, so there is no
        # fallback to be had here.
        host_name = env("HOST_NAME")
        if host_name:
            for subdomain, group_name in ROUTES:
                group = groups_by_name[group_name]
                try:
                    monitor_id = api.ensure_route_monitor(
                        subdomain, host_name, group_ids[group_name], group, tier_for(group),
                    )
                    api.reconcile_monitor_active(
                        f"route {subdomain}", monitor_id,
                        monitor_should_be_active(route_service(subdomain), enabled_services),
                    )
                except Exception as e:
                    log(f"WARNING: Failed to ensure route monitor for {subdomain}: {e}")

            group = groups_by_name["External Chain"]
            try:
                monitor_id = api.ensure_tls_monitor(
                    host_name, group_ids["External Chain"], group, tier_for(group),
                )
                api.reconcile_monitor_active(
                    "TLS certificate", monitor_id,
                    monitor_should_be_active(
                        SPECIAL_MONITOR_SERVICES["TLS certificate"], enabled_services,
                    ),
                )
            except Exception as e:
                log(f"WARNING: Failed to ensure TLS certificate monitor: {e}")
        else:
            log("WARNING: HOST_NAME is not set; skipping route and TLS certificate monitors")

        resolver_ip = resolve_container_ip("pi-pihole")
        if resolver_ip:
            group = groups_by_name["Core"]
            try:
                monitor_id = api.ensure_dns_monitor(resolver_ip, group_ids["Core"], group, tier_for(group))
                api.reconcile_monitor_active(
                    "dns resolution", monitor_id,
                    monitor_should_be_active(
                        SPECIAL_MONITOR_SERVICES["dns resolution"], enabled_services,
                    ),
                )
            except Exception as e:
                log(f"WARNING: Failed to ensure DNS monitor: {e}")
        else:
            log("WARNING: pi-pihole did not resolve; skipping the DNS resolution monitor")

        group = groups_by_name["Remote Access"]
        try:
            monitor_id = api.ensure_vpn_monitor(group_ids["Remote Access"], group, tier_for(group))
            api.reconcile_monitor_active(
                "vpn public ip", monitor_id,
                monitor_should_be_active(
                    SPECIAL_MONITOR_SERVICES["vpn public ip"], enabled_services,
                ),
            )
        except Exception as e:
            log(f"WARNING: Failed to ensure VPN monitor: {e}")

        # Personal Data, where pi-backrest already sits, and it alerts per child:
        # a missed backup is worth its own message rather than a group aggregate.
        group = groups_by_name["Personal Data"]
        try:
            monitor_id = api.ensure_backup_freshness_monitor(
                group_ids["Personal Data"], group, tier_for(group),
            )
            api.reconcile_monitor_active(
                "backup freshness", monitor_id,
                monitor_should_be_active(
                    SPECIAL_MONITOR_SERVICES["backup freshness"], enabled_services,
                ),
            )
        except Exception as e:
            log(f"WARNING: Failed to ensure backup freshness monitor: {e}")

        # Public status page consumed by the Homepage 'uptimekuma' widget
        try:
            api.ensure_status_page(
                "homepage", "Homepage Widget", "Services",
                [group_ids[group["name"]] for group in GROUPS],
            )
        except Exception as e:
            log(f"WARNING: Failed to ensure Homepage status page: {e}")

        log("Bootstrap completed successfully")

    finally:
        api.disconnect()


if __name__ == "__main__":
    main()
