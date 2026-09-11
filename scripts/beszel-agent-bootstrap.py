#!/usr/bin/env python3
"""Configure the Beszel hub and bootstrap beszel-agent's credentials.

Runs on every start (a post-start hook, see scripts/run-hooks.sh) and is
idempotent: it reconciles the hub's PocketBase settings from .env (SMTP, S3
file storage and backups, the trusted proxy header), registers the Authelia
OIDC provider, makes sure a universal token exists, writes it and the hub's
public key to config/beszel-agent/agent.env, recreates the agent when that pair
changed, then syncs system visibility, the ntfy webhook and the resource
alerts.

Python rather than shell because this is almost entirely JSON: the shell
version carried 295 lines of Python across 14 separate `python3 -c` blocks, and
what it could not hand to one of them it did with `sed` - including parsing
JSON responses with a greedy regex, which returns the *last* match of a key at
any depth. See AGENTS.md for the rule that governs which language a script here
is written in.
"""

import json
import uuid
from urllib.parse import quote, urlparse

import pilib
from pilib import CurlError, die, get_env_value, log

# --- Constants ---

HUB_CONTAINER = "pi-beszel"
AGENT_CONTAINER = "pi-beszel-agent"

# A container name, not a host address: beszel only `expose`s 8090 to the
# frontend network, so every request below goes through pilib.docker_curl.
HUB_URL = "http://pi-beszel:8090"

MAX_RETRIES = 90
RETRY_INTERVAL = 2

AGENT_ENV_DIR = pilib.PROJECT_DIR / "config" / "beszel-agent"
AGENT_ENV_FILE = AGENT_ENV_DIR / "agent.env"
NTFY_ENV_FILE = pilib.PROJECT_DIR / "config" / "ntfy" / "ntfy.env"

OIDC_PROVIDER_NAME = "oidc"
OIDC_PROVIDER_DISPLAY_NAME = "Authelia"
OIDC_SCOPE = "openid profile email"

DEFAULT_NTFY_TOPIC = "monitoring"
NTFY_SCHEME = "http"

# Only the temperature alert is settable from .env (BESZEL_TEMP_ALERT_VALUE /
# _MIN / _OVERWRITE). The other three are constants on purpose, and
# config/system-tools/app.py deliberately reuses the same numbers: anything the
# chat assistant calls abnormal is then something that has already pushed to
# ntfy, rather than a second opinion that disagrees with your phone. Keep the
# two in step, and keep docs/MONITORING.md's table in step with both.
DEFAULT_TEMP_ALERT_VALUE = 70.0
DEFAULT_TEMP_ALERT_MIN = 5
RESOURCE_ALERT_MIN = 5
RESOURCE_ALERTS = {"CPU": 90.0, "Memory": 90.0, "Disk": 85.0}

# PocketBase's list endpoints paginate; the stack has a handful of users and
# systems, so one large page is the whole collection.
PAGE_SIZE = 500


# --- agent.env ---


class AgentEnv:
    """config/beszel-agent/agent.env - the TOKEN/KEY pair the agent reads as a
    compose env_file, plus whether this run changed it.

    `changed` drives the recreate at the end: an env_file is read at container
    creation, so a rotated token that is only written to disk is a token the
    running agent never sees.
    """

    def __init__(self, path):
        self.path = path
        self.changed = False

    def ensure_exists(self) -> None:
        AGENT_ENV_DIR.mkdir(parents=True, exist_ok=True)
        if self.path.exists():
            return
        pilib.write_file_atomic(self.path, "# Managed by scripts/beszel-agent-bootstrap.py\nTOKEN=\nKEY=\n")
        pilib.safe_chmod(0o600, self.path)
        pilib.fix_ownership(self.path)
        log(f"Created {self.path}")

    def get(self, key: str) -> str:
        return pilib.read_env_value_from_file(self.path, key)

    def set(self, key: str, value: str) -> None:
        pilib.upsert_env_value(self.path, key, value)
        pilib.safe_chmod(0o600, self.path)
        # The systemd unit runs this as root, and compose reads agent.env as an
        # env_file: root:root 0600 is a file the next non-root `docker compose
        # up` cannot read, and `required: false` covers a missing file, not an
        # unreadable one.
        pilib.fix_ownership(self.path)
        self.changed = True


def resolve_key_from_env() -> str:
    """A hub public key supplied by hand in .env, under any of the three names
    the Beszel docs have used."""
    for name in ("BESZEL_AGENT_KEY", "BESZEL_KEY", "KEY"):
        value = get_env_value(name)
        if value:
            return value
    return ""


# --- The hub API ---


class Hub:
    """Authenticated PocketBase calls to the Beszel hub.

    Bodies always travel on stdin (pilib.docker_curl's only mode): the payloads
    here carry the login password, the OIDC client secret and an ntfy URL with a
    password in its userinfo, and `docker run` puts its argv in the host's
    process table where any local `ps` can read it.
    """

    def __init__(self, token: str):
        self.token = token

    def get(self, path: str, **params):
        args = ["-G", "-H", f"Authorization: {self.token}"]
        for key, value in params.items():
            args += ["--data-urlencode", f"{key}={value}"]
        return pilib.docker_curl_json(*args, HUB_URL + path)

    def send(self, method: str, path: str, payload):
        return pilib.docker_curl_json(
            "-X",
            method,
            "-H",
            f"Authorization: {self.token}",
            "-H",
            "Content-Type: application/json",
            HUB_URL + path,
            body=json.dumps(payload, separators=(",", ":")),
        )

    def records(self, collection: str, **params) -> list[dict]:
        params.setdefault("page", 1)
        params.setdefault("perPage", PAGE_SIZE)
        data = self.get(f"/api/collections/{collection}/records", **params)
        return data.get("items") or []


def login(collection: str, email: str, password: str) -> str:
    """Authenticate against a PocketBase auth collection; "" on failure.

    `users` is the ordinary account, `_superusers` the admin one. They are
    separate collections with separate tokens, and which one applies depends on
    whether the hub has password auth disabled - see main().
    """
    data = pilib.docker_curl_json(
        "-X",
        "POST",
        "-H",
        "Content-Type: application/json",
        f"{HUB_URL}/api/collections/{collection}/auth-with-password",
        body=json.dumps({"identity": email, "password": password}, separators=(",", ":")),
    )
    return data.get("token") or ""


def get_hub_public_key(hub: Hub) -> str:
    return (hub.get("/api/beszel/getkey") or {}).get("key") or ""


def lookup_user_id_by_email(hub: Hub, email: str) -> str:
    """Empty when the account cannot be resolved, including when the call itself
    fails: the token is then created without a user binding, which is what the
    shell version's `|| true` at every call site produced."""
    target = email.strip().lower()
    try:
        records = hub.records("users", fields="id,email")
    except CurlError as exc:
        log(f"WARNING: Could not look up users.id for {email}: {exc}")
        return ""
    for item in records:
        if (item.get("email") or "").strip().lower() == target:
            return item.get("id") or ""
    return ""


# --- Universal token ---


def get_or_create_permanent_universal_token(hub: Hub, user_id: str) -> str:
    """The token the agent authenticates with, in password-auth mode.

    Beszel API compatibility: some versions reject permanent=1 with HTTP 400, so
    the permanent form is tried first and a plain one is accepted as a fallback.
    """
    current = hub.get("/api/beszel/universal-token")
    token = current.get("token") or ""
    if token and current.get("active"):
        return token

    attempts = [{"enable": 1, "permanent": 1, "token": token}, {"enable": 1, "token": token}]
    created: dict = {}
    for params in attempts:
        if user_id:
            params["user"] = user_id
        try:
            created = hub.get("/api/beszel/universal-token", **params)
        except CurlError:
            continue
        if created.get("token"):
            break

    token = created.get("token") or ""
    if not token or not created.get("active"):
        log("ERROR: Failed to create universal token")
        return ""

    if created.get("permanent"):
        log("Created permanent universal token")
    else:
        log("Created non-permanent universal token (API does not support permanent mode)")
    return token


def get_or_create_db_universal_token_for_user(hub: Hub, user_id: str) -> str:
    """The same token, but written straight to the universal_tokens collection.

    Used in passwordless mode, where we hold a _superusers token:
    /api/beszel/universal-token binds ownership to e.Auth.Id, which would be the
    superuser id - not a valid value for systems.users, so the agent would
    connect and never be visible to the account that has to see it.
    """
    items = hub.records("universal_tokens", perPage=1, fields="id,token,user", filter=f"user='{user_id}'")
    record = items[0] if items else {}
    if record.get("token"):
        return record["token"]

    token = str(uuid.uuid4())
    payload = {"user": user_id, "token": token}
    if record.get("id"):
        hub.send("PATCH", f"/api/collections/universal_tokens/records/{record['id']}", payload)
    else:
        hub.send("POST", "/api/collections/universal_tokens/records", payload)
    return token


def has_active_system(hub: Hub) -> bool:
    try:
        return bool(hub.records("systems", perPage=1, filter="(status='up')"))
    except CurlError as exc:
        log(f"WARNING: Could not check for an active system: {exc}")
        return False


# --- OIDC ---


def build_oidc_payload(host_name: str, client_secret: str) -> dict:
    issuer = f"https://auth.{host_name}"
    return {
        "oauth2": {
            "enabled": True,
            "mappedFields": {"id": "", "name": "name", "username": "", "avatarURL": "avatar"},
            "providers": [
                {
                    "name": OIDC_PROVIDER_NAME,
                    "displayName": OIDC_PROVIDER_DISPLAY_NAME,
                    "clientId": "beszel",
                    "clientSecret": client_secret,
                    "authURL": f"{issuer}/api/oidc/authorization",
                    "tokenURL": f"{issuer}/api/oidc/token",
                    "userInfoURL": f"{issuer}/api/oidc/userinfo",
                    "pkce": True,
                    "extra": {"scope": OIDC_SCOPE},
                }
            ],
        }
    }


def has_expected_oidc_provider(auth_methods: dict) -> bool:
    oauth2 = auth_methods.get("oauth2") or {}
    if not oauth2.get("enabled"):
        return False
    return any(
        provider.get("name") == OIDC_PROVIDER_NAME
        and (provider.get("displayName") or "") == OIDC_PROVIDER_DISPLAY_NAME
        for provider in (oauth2.get("providers") or [])
    )


def configure_oidc_provider(email: str, password: str) -> bool:
    """Applied with a _superusers token even in password-auth mode: the OIDC
    config lives on the users *collection*, which an ordinary user cannot
    PATCH."""
    token = login("_superusers", email, password)
    if not token:
        log("WARNING: Could not authenticate as Beszel superuser; skipping OIDC bootstrap")
        return False
    hub = Hub(token)

    host_name = get_env_value("HOST_NAME") or "pi.lan"
    client_secret = pilib.get_oidc_secret("beszel", "BESZEL_OIDC_CLIENT_SECRET")
    if not client_secret:
        log("WARNING: Could not read Beszel OIDC client secret; skipping OIDC bootstrap")
        return False

    hub.send("PATCH", "/api/collections/users", build_oidc_payload(host_name, client_secret))

    try:
        auth_methods = hub.get("/api/collections/users/auth-methods")
    except CurlError:
        auth_methods = {}
    if has_expected_oidc_provider(auth_methods):
        log(f"Beszel OIDC provider is configured ({OIDC_PROVIDER_DISPLAY_NAME})")
        return True

    log("WARNING: OIDC bootstrap ran but verification did not detect the expected provider")
    return False


# --- PocketBase settings ---


def build_pocketbase_settings_payload() -> dict:
    payload: dict = {}

    smtp_host = get_env_value("SMTP_HOST")
    if smtp_host:
        smtp_port = get_env_value("SMTP_PORT") or "587"
        smtp = {
            "enabled": True,
            "host": smtp_host,
            "port": int(smtp_port),
            # STARTTLS on 587, implicit TLS on 465.
            "tls": smtp_port == "465",
        }
        for key, name in (("username", "SMTP_USERNAME"), ("password", "SMTP_PASSWORD")):
            value = get_env_value(name)
            if value:
                smtp[key] = value
        payload["smtp"] = smtp

        email = get_env_value("EMAIL")
        if email:
            payload["meta"] = {"senderName": "Beszel", "senderAddress": email}

    s3 = build_s3_settings()
    if s3:
        payload["s3"] = dict(s3)

    backup_cron = get_env_value("BESZEL_BACKUP_CRON")
    if backup_cron:
        backups = {"cron": backup_cron, "cronMaxKeep": int(get_env_value("BESZEL_BACKUP_MAX_KEEP") or "7")}
        if s3:
            backups["s3"] = dict(s3)
        payload["backups"] = backups

    # Traefik terminates TLS in front of Beszel, so without this the client IP
    # every log line records is the proxy's.
    payload["trustedProxy"] = {"headers": ["X-Forwarded-For"], "useLeftmostIP": True}
    payload["logs"] = {"logIP": True}
    return payload


def build_s3_settings() -> dict:
    endpoint = get_env_value("S3_ENDPOINT")
    bucket = get_env_value("S3_BUCKET")
    if not endpoint or not bucket:
        return {}
    return {
        "enabled": True,
        "endpoint": endpoint,
        "bucket": bucket,
        "region": get_env_value("S3_REGION"),
        "accessKey": get_env_value("S3_ACCESS_KEY_ID"),
        "secret": get_env_value("S3_SECRET_ACCESS_KEY"),
        "forcePathStyle": pilib.is_truthy(get_env_value("BESZEL_S3_FORCE_PATH_STYLE") or "true"),
    }


def configure_pocketbase_settings(email: str, password: str) -> None:
    token = login("_superusers", email, password)
    if not token:
        log("WARNING: Could not authenticate as Beszel superuser; skipping PocketBase settings")
        return
    Hub(token).send("PATCH", "/api/settings", build_pocketbase_settings_payload())
    log("PocketBase settings reconciled from .env")


# --- System visibility ---


def build_system_user_sync_updates(systems: list[dict], all_user_ids: set[str]) -> list[dict]:
    """One {"id", "users"} update per system that is missing a user.

    Systems are grouped by name because an agent that reconnects under a new
    token registers a *second* record with the same name; the authoritative one
    is whichever is up, and failing that the most recently updated. Its users
    become the union of every same-named record's users and every known account,
    so a system stays visible to everyone after a duplicate is cleaned up.
    """
    groups: dict[str, list[dict]] = {}
    for item in systems:
        name = (item.get("name") or "").strip()
        if name:
            groups.setdefault(name, []).append(item)

    updates = []
    for group in groups.values():
        up = [item for item in group if (item.get("status") or "").lower() == "up"]
        target = max(up or group, key=lambda item: item.get("updated") or "")

        merged = set(all_user_ids)
        for item in group:
            merged.update(user_id for user_id in (item.get("users") or []) if user_id)
        if not merged:
            continue

        current = {user_id for user_id in (target.get("users") or []) if user_id}
        if current != merged:
            updates.append({"id": target.get("id"), "users": sorted(merged)})
    return updates


def sync_system_user_access(hub: Hub) -> None:
    all_user_ids = {item["id"] for item in hub.records("users", fields="id") if item.get("id")}
    updates = build_system_user_sync_updates(hub.records("systems"), all_user_ids)

    if not updates:
        log("System access is already in sync")
        return

    log(f"Synchronizing users on active system records ({len(updates)} update(s))")
    for update in updates:
        system_id = update["id"]
        if not system_id or not update["users"]:
            continue
        try:
            hub.send("PATCH", f"/api/collections/systems/records/{system_id}", {"users": update["users"]})
        except CurlError as exc:
            log(f"WARNING: Failed to sync users for system id={system_id}: {exc}")
            continue
        log(f"Synchronized users for system id={system_id}")


# --- Notifications and alerts ---


def build_user_settings_patches(records: list[dict], webhook_url: str) -> list[tuple[str, dict]]:
    """(record_id, patch) for every user_settings record needing the webhook.

    Every ntfy webhook this script owns (same host, beszel user) is dropped
    whatever its topic, so the configured topic stays authoritative: matching on
    the topic too would leave the previous one behind on a topic change, and
    Beszel would keep publishing to a topic its ntfy ACL no longer grants.
    """
    target = urlparse(webhook_url)
    patches = []
    for item in records:
        record_id = item.get("id")
        if not record_id:
            continue
        settings = item.get("settings") or {}
        webhooks = [
            webhook
            for webhook in (settings.get("webhooks") or [])
            if not _is_own_ntfy_webhook(urlparse(webhook), target)
        ]
        if webhook_url not in webhooks:
            webhooks.append(webhook_url)
        settings["webhooks"] = webhooks
        patches.append((record_id, {"settings": settings}))
    return patches


def _is_own_ntfy_webhook(parsed, target) -> bool:
    return (
        parsed.scheme == "ntfy"
        and (parsed.hostname or "") == (target.hostname or "")
        and (parsed.username or "") == "beszel"
    )


def build_alert_payload(name: str, value, minutes, systems: list[dict], overwrite: bool) -> dict:
    try:
        value = float(value)
    except (TypeError, ValueError):
        value = DEFAULT_TEMP_ALERT_VALUE
    try:
        minutes = int(float(minutes))
    except (TypeError, ValueError):
        minutes = DEFAULT_TEMP_ALERT_MIN
    return {
        "name": name,
        "value": value,
        "min": minutes,
        "systems": [item["id"] for item in systems if item.get("id")],
        "overwrite": overwrite,
    }


def configure_ntfy_webhook_and_alerts(hub: Hub) -> None:
    if not NTFY_ENV_FILE.exists():
        log(f"WARNING: {NTFY_ENV_FILE} not found; skipping Beszel notifications bootstrap")
        return

    ntfy_password = pilib.read_env_value_from_file(NTFY_ENV_FILE, "NTFY_BESZEL_PASSWORD")
    if not ntfy_password:
        log("WARNING: NTFY_BESZEL_PASSWORD missing; skipping Beszel notifications bootstrap")
        return
    topic = pilib.read_env_value_from_file(NTFY_ENV_FILE, "NTFY_BESZEL_TOPIC") or DEFAULT_NTFY_TOPIC

    webhook_url = f"ntfy://beszel:{quote(ntfy_password, safe='')}@ntfy/{quote(topic, safe='')}?scheme={NTFY_SCHEME}"

    log("Ensuring Beszel notification webhook is configured for all users")
    patches = build_user_settings_patches(hub.records("user_settings"), webhook_url)
    if not patches:
        log("WARNING: No user_settings records found; skipping notifications webhook bootstrap")
    for record_id, patch in patches:
        try:
            hub.send("PATCH", f"/api/collections/user_settings/records/{record_id}", patch)
        except CurlError as exc:
            log(f"WARNING: Failed to configure ntfy webhook for user_settings id={record_id}: {exc}")
            continue
        log(f"Configured ntfy webhook for user_settings id={record_id}")

    log("Ensuring default resource alerts are configured")
    systems = hub.records("systems", fields="id")
    if not systems:
        log("No systems found yet; skipping resource alert bootstrap")
        return

    # Off by default: the thresholds below are a floor, and a value edited in the
    # UI is a deliberate choice this hook must not undo on the next start.
    overwrite = pilib.is_truthy(get_env_value("BESZEL_TEMP_ALERT_OVERWRITE") or "false")

    alerts = [
        (
            "Temperature",
            get_env_value("BESZEL_TEMP_ALERT_VALUE") or DEFAULT_TEMP_ALERT_VALUE,
            get_env_value("BESZEL_TEMP_ALERT_MIN") or DEFAULT_TEMP_ALERT_MIN,
        )
    ]
    alerts += [(name, value, RESOURCE_ALERT_MIN) for name, value in RESOURCE_ALERTS.items()]

    for name, value, minutes in alerts:
        payload = build_alert_payload(name, value, minutes, systems, overwrite)
        try:
            hub.send("POST", "/api/beszel/user-alerts", payload)
        except CurlError as exc:
            log(f"WARNING: Failed to configure the {name} alert: {exc}")


# --- Agent ---


def persist_agent_config(agent_env: AgentEnv, token: str, hub_key: str) -> bool:
    if agent_env.get("TOKEN") != token:
        agent_env.set("TOKEN", token)
        log(f"Updated TOKEN in {agent_env.path}")
    else:
        log(f"TOKEN already up to date in {agent_env.path}")

    target_key = hub_key or resolve_key_from_env()
    if not target_key:
        log("ERROR: KEY is required but no hub key (or override key) is available")
        return False

    if agent_env.get("KEY") != target_key:
        agent_env.set("KEY", target_key)
        log(f"Updated KEY in {agent_env.path}")
    else:
        log(f"KEY already up to date in {agent_env.path}")
    return True


def restart_agent_if_needed(agent_env: AgentEnv) -> None:
    # container_is_running is asked for pi-beszel-agent, the container_name in
    # compose.yaml - not the service name `beszel-agent`, which never appears in
    # `docker ps` and once made this check false unconditionally, leaving the
    # branch that reloads a rotated TOKEN/KEY unreachable.
    running = pilib.container_is_running(AGENT_CONTAINER)
    if not agent_env.changed and running:
        log("Agent config unchanged and beszel-agent already running, skipping restart")
        return

    log("Applying beszel-agent configuration...")
    # --force-recreate when it is already up: an env_file is read at container
    # creation, so a restart would keep the old TOKEN/KEY.
    args = ["up", "-d", "--no-deps", "beszel-agent"]
    if running:
        args.insert(2, "--force-recreate")

    if pilib.compose(*args).returncode != 0:
        verb = "recreate" if running else "start"
        log(f"WARNING: beszel-agent {verb} failed" + ("" if running else "; it will start via the main stack"))
        return
    log("beszel-agent recreated" if running else "beszel-agent is up")


# --- Main ---


def reconcile_hub(email: str, password: str, hub: Hub, tolerate_notifications: bool = False) -> None:
    """Everything that is not the agent's credentials, in the order the hub
    wants it.

    Run on every path through main(), including the one a healthy passwordless
    install takes on every start: without it the S3 credentials and SMTP
    settings in .env are only ever applied at first bootstrap, and a rotated S3
    key leaves Beszel's own nightly backups failing silently.

    The two settings steps are best-effort. The notification step is not, except
    on the path that returns early with credentials it already had: a bootstrap
    that cannot reach the hub's notification API is the thing under test when CI
    runs the post-start phase in blocking mode.
    """
    try:
        configure_pocketbase_settings(email, password)
    except CurlError as exc:
        log(f"WARNING: Could not reconcile PocketBase settings: {exc}")
    try:
        sync_system_user_access(hub)
    except CurlError as exc:
        log(f"WARNING: Could not sync system access: {exc}")

    if not tolerate_notifications:
        configure_ntfy_webhook_and_alerts(hub)
        return
    try:
        configure_ntfy_webhook_and_alerts(hub)
    except CurlError as exc:
        log(f"WARNING: Could not configure notifications: {exc}")


def main() -> int:
    log("=== Beszel Agent Bootstrap ===")

    if not pilib.ENV_FILE.exists():
        die(f".env missing at {pilib.ENV_FILE}")

    agent_env = AgentEnv(AGENT_ENV_FILE)
    agent_env.ensure_exists()

    email = get_env_value("EMAIL")
    password = get_env_value("PASSWORD")
    if not email or not password:
        die("EMAIL and PASSWORD must be set in .env")

    if not pilib.wait_for_container(HUB_CONTAINER, MAX_RETRIES, RETRY_INTERVAL):
        return 1
    if not pilib.wait_for_health(HUB_CONTAINER, MAX_RETRIES, RETRY_INTERVAL):
        return 1

    try:
        if not configure_oidc_provider(email, password):
            log("Continuing without enforced OIDC bootstrap verification")
    except CurlError as exc:
        log(f"WARNING: OIDC bootstrap failed: {exc}")

    # compose.yaml sets DISABLE_PASSWORD_AUTH=true, so this is the normal path:
    # the `users` collection refuses auth-with-password and only _superusers
    # answers. The password branch below is what a hub with the flag turned off
    # takes, and what a first install needs before OIDC is reachable.
    if pilib.is_truthy(pilib.container_env_value(HUB_CONTAINER, "DISABLE_PASSWORD_AUTH")):
        return main_passwordless(agent_env, email, password)
    return main_password_auth(agent_env, email, password)


def main_passwordless(agent_env: AgentEnv, email: str, password: str) -> int:
    log("Detected DISABLE_PASSWORD_AUTH=true on Beszel; skipping password-based API bootstrap")

    token = login("_superusers", email, password)
    if not token:
        log("ERROR: Beszel password auth is disabled and superuser auth fallback failed")
        log("Set BESZEL_DISABLE_PASSWORD_AUTH=false temporarily, run bootstrap once, then re-enable OIDC-only mode.")
        return 1
    hub = Hub(token)

    # A KEY supplied by hand in .env is seeded before the completeness check, so
    # an install that carries its own hub key needs no API round trip at all.
    if not agent_env.get("KEY"):
        sourced_key = resolve_key_from_env()
        if sourced_key:
            agent_env.set("KEY", sourced_key)
            log(f"Seeded KEY in {agent_env.path} from environment")

    if agent_env.get("TOKEN") and agent_env.get("KEY"):
        reconcile_hub(email, password, hub, tolerate_notifications=True)
        restart_agent_if_needed(agent_env)
        log(f"Using existing agent TOKEN/KEY from {agent_env.path}")
        log("Bootstrap completed successfully")
        return 0

    log("TOKEN/KEY are incomplete in passwordless mode; trying superuser fallback bootstrap")

    user_id = lookup_user_id_by_email(hub, email)
    if not user_id:
        die(f"Could not resolve users.id for EMAIL={email}")

    universal_token = get_or_create_db_universal_token_for_user(hub, user_id)
    hub_public_key = get_hub_public_key(hub)
    if not universal_token or not hub_public_key:
        die("Failed to bootstrap TOKEN/KEY using superuser fallback")

    universal_token = keep_existing_token_if_active(hub, agent_env, universal_token)
    if not persist_agent_config(agent_env, universal_token, hub_public_key):
        return 1
    restart_agent_if_needed(agent_env)
    reconcile_hub(email, password, hub)
    log("Bootstrap completed successfully (superuser fallback in passwordless mode)")
    return 0


def main_password_auth(agent_env: AgentEnv, email: str, password: str) -> int:
    token = login("users", email, password)
    if not token:
        die("Failed to authenticate to Beszel (no token returned)")
    hub = Hub(token)

    user_id = lookup_user_id_by_email(hub, email)
    universal_token = get_or_create_permanent_universal_token(hub, user_id)
    if not universal_token:
        die("Could not obtain universal token")

    hub_public_key = get_hub_public_key(hub)
    if not hub_public_key:
        die("Could not obtain Beszel hub public key")

    universal_token = keep_existing_token_if_active(hub, agent_env, universal_token)
    if not persist_agent_config(agent_env, universal_token, hub_public_key):
        return 1
    restart_agent_if_needed(agent_env)
    reconcile_hub(email, password, hub)
    log("Bootstrap completed successfully")
    return 0


def keep_existing_token_if_active(hub: Hub, agent_env: AgentEnv, universal_token: str) -> str:
    """Reusing the token already on disk keeps the agent from reconnecting under
    a new identity and registering a duplicate system."""
    existing = agent_env.get("TOKEN")
    if existing and existing != universal_token and has_active_system(hub):
        log("Active system exists; keeping current agent token to prevent duplicate system registration")
        return existing
    return universal_token


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CurlError as exc:
        # -f makes curl exit non-zero on a 4xx/5xx, so an unhandled one here is a
        # step that could not run at all, not a response worth inspecting.
        die(str(exc))
