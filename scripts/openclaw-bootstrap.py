#!/usr/bin/env python3
"""Post-start for OpenClaw: everything that needs the stack answering.

1. The Matrix plugin, at exactly the image's version. It is not in the image,
   and the image's own entrypoint would fetch and refresh it from npm on every
   start (compose/compose-ai.yaml explains why that entrypoint is bypassed).
   Installed here instead, into the state volume, by a throwaway container of
   the same image - the only moment anything of this service reaches the
   internet. The native crypto binding the plugin uses for encrypted
   attachments is fetched in the same pass, since the gateway has no egress to
   fetch it at runtime.
2. The bot's Matrix account, @assistant, created through Tuwunel's
   shared-secret endpoint (scripts/tuwunel-pre-start.sh) - registration stays
   off for everyone else - and a server-side backup of its room keys.
3. The people it answers: every LLDAP account but the service accounts,
   cached for openclaw-pre-start.py, which renders one agent per person.
4. Its Forgejo side, when Forgejo runs: a local, restricted bot user, the two
   repositories it pushes to (scripts/openclaw-sync.py), and their branch
   protection.

Restarts the gateway once at the end if any of that changed. Idempotent: the
next start redoes nothing that is already in place.
"""

import hashlib
import hmac
import json
import os
import re
import subprocess
import sys
from datetime import UTC, datetime

import pilib
from pilib import CurlError, die, fix_ownership, get_env_value, log, resolve_data_location_path, safe_chmod

CONTAINER = "pi-openclaw"
FORGEJO = "pi-forgejo"
STATE_DIR = "/home/node/.openclaw"
PLUGIN = "@openclaw/matrix"
BOT_LOCALPART = "assistant"
TUWUNEL = "http://tuwunel:8008"
LLDAP = "http://lldap:17170"
# LLDAP's own groups for bind and password-manager accounts: a service, not a
# person, and nobody the assistant should answer.
SERVICE_GROUPS = {"lldap_strict_readonly", "lldap_password_manager"}
MEMORY_REPO = "assistant-memory"
KNOWLEDGE_REPO = "knowledge"
PROVISIONING_TOKEN = "assistant-provisioning"
# The shared-secret registration MAC covers the account's admin flag, spelled
# as one of two fixed words (Synapse's protocol, which Tuwunel implements).
REGISTER_AS_USER = b"notadmin"
# The image's `node` user, which the state volume's files belong to.
CONTAINER_UID = 1000

# Every generation of the plugin's install: a reinstall writes a sibling
# `openclaw-matrix-<hash>__openclaw-generation__<id>` before retiring the old
# one, so a glob can match two directories at once.
PLUGIN_GLOB = f"{STATE_DIR}/npm/projects/openclaw-matrix-*/node_modules/@openclaw/matrix"

# Prints the version of each generation that also has its native crypto
# binding. $1 is the version a pass is after, used by the install below.
COMPLETE_GENERATIONS = """
    for dir in """ + PLUGIN_GLOB + """; do
        [ -f "$dir/package.json" ] || continue
        ls "$dir"/node_modules/@matrix-org/matrix-sdk-crypto-nodejs/*.node >/dev/null 2>&1 || continue
        node -p "require(process.argv[1]).version" "$dir/package.json"
    done
"""
INSTALL = """
    set -e
    mkdir -p /tmp/install
    node openclaw.mjs plugins install "@openclaw/matrix@$1" --pin --force
    for dir in """ + PLUGIN_GLOB + """; do
        [ "$(node -p "require(process.argv[1]).version" "$dir/package.json")" = "$1" ] || continue
        (cd "$dir/node_modules/@matrix-org/matrix-sdk-crypto-nodejs" && node download-lib.js)
    done
"""


def docker(*args, input_text=None, env=None, timeout=600):
    return subprocess.run(
        ["docker", *args],
        input=input_text,
        capture_output=True,
        text=True,
        timeout=timeout,
        env=env,
        check=False,
    )


def inspect(container, fmt):
    return docker("inspect", "--format", fmt, container).stdout.strip()


def data_dir():
    return resolve_data_location_path() / "openclaw"


def matrix_password():
    path = pilib.PROJECT_DIR / "config" / "openclaw" / "openclaw.env"
    value = pilib.read_env_value_from_file(path, "OPENCLAW_MATRIX_PASSWORD")
    if not value:
        die(f"no OPENCLAW_MATRIX_PASSWORD in {path}; openclaw-pre-start.py has not run")
    return value


# --- 1. The Matrix plugin ---


def one_shot(image, volume, script, version, *network):
    """A throwaway container of the gateway's own image on its state volume,
    so it works whether the gateway is running or stopped."""
    return docker(
        "run", "--rm", *network, "--user", f"{CONTAINER_UID}:{CONTAINER_UID}",
        "-v", f"{volume}:{STATE_DIR}",
        "--tmpfs", f"/home/node/.cache:uid={CONTAINER_UID},gid={CONTAINER_UID}",
        "-e", f"OPENCLAW_STATE_DIR={STATE_DIR}", "-e", "OPENCLAW_CONFIG_PATH=/tmp/install/openclaw.json",
        "--entrypoint", "sh", image, "-c", script, "sh", version,
    )  # fmt: skip


def plugin_in_place(image, volume, version):
    proc = one_shot(image, volume, COMPLETE_GENERATIONS, version, "--network", "none")
    return version in proc.stdout.split()


def ensure_plugin():
    image = inspect(CONTAINER, "{{.Config.Image}}")
    version_label = '{{index .Config.Labels "org.opencontainers.image.version"}}'
    version = docker("image", "inspect", "--format", version_label, image).stdout.strip()
    volume = inspect(CONTAINER, '{{range .Mounts}}{{if eq .Destination "' + STATE_DIR + '"}}{{.Name}}{{end}}{{end}}')
    if not version or not volume:
        die(f"cannot read the image version or the state volume of {CONTAINER}")

    if plugin_in_place(image, volume, version):
        return False

    log(f"Installing {PLUGIN}@{version} into {volume}")
    # Stopped first: two OpenClaw processes on one state database contend for
    # its leases, and the running gateway logged ownership failures until it
    # was restarted (measured). main() starts it again.
    docker("stop", CONTAINER, timeout=180)
    # The default bridge, for npm and GitHub: this container is the one that
    # may reach out, and it lives for this install only. A throwaway config
    # path, because the volume's openclaw.json is the root-owned mountpoint the
    # gateway's read-only bind leaves there - and the state dir spelled out,
    # because OpenClaw otherwise derives it from the config path and installs
    # into /tmp (measured).
    proc = one_shot(image, volume, INSTALL, version)
    if proc.returncode != 0:
        docker("start", CONTAINER)
        die(f"plugin install failed: {proc.stderr.strip()[-400:]}")
    if not plugin_in_place(image, volume, version):
        docker("start", CONTAINER)
        die(f"{PLUGIN}@{version} is still not in place after the install")
    log(f"Installed {PLUGIN}@{version} and its native crypto binding")
    return True


# --- 2. The bot's Matrix account ---


def matrix_login_works(user_id, password):
    body = {"type": "m.login.password", "identifier": {"type": "m.id.user", "user": user_id}, "password": password}
    try:
        login = pilib.docker_curl_json(
            "-H", "Content-Type: application/json", f"{TUWUNEL}/_matrix/client/v3/login", body=json.dumps(body)
        )
    except CurlError:
        return False
    # The check itself created a device; leave none behind.
    try:
        pilib.docker_curl(
            "-X", "POST", "-H", f"Authorization: Bearer {login['access_token']}", f"{TUWUNEL}/_matrix/client/v3/logout"
        )
    except CurlError:
        log("WARNING: could not log the account check out; a stale device is left on the bot")
    return True


def ensure_bot_account(server_name, password):
    marker = data_dir() / "matrix-account"
    user_id = f"@{BOT_LOCALPART}:{server_name}"
    if marker.is_file() and marker.read_text(encoding="utf-8").strip() == user_id:
        return False

    secret_file = resolve_data_location_path() / "tuwunel-secrets" / "registration_shared_secret"
    try:
        shared_secret = secret_file.read_text(encoding="utf-8").strip()
    except OSError:
        die(f"{secret_file} is missing: tuwunel-pre-start.sh has not run")

    created = False
    try:
        nonce = pilib.docker_curl_json(f"{TUWUNEL}/_synapse/admin/v1/register")["nonce"]
        mac = hmac.new(
            shared_secret.encode(),
            b"\x00".join([nonce.encode(), BOT_LOCALPART.encode(), password.encode(), REGISTER_AS_USER]),
            hashlib.sha1,
        ).hexdigest()
        body = {
            "nonce": nonce,
            "username": BOT_LOCALPART,
            "displayname": "Assistant",
            "password": password,
            "admin": False,
            "mac": mac,
        }
        pilib.docker_curl_json(
            "-H", "Content-Type: application/json", f"{TUWUNEL}/_synapse/admin/v1/register", body=json.dumps(body)
        )
        created = True
    except CurlError:
        # A 400 M_USER_IN_USE on any run after the first. Only a login tells
        # whether that existing account is ours.
        if not matrix_login_works(user_id, password):
            die(
                f"{user_id} exists but does not accept OPENCLAW_MATRIX_PASSWORD from "
                "config/openclaw/openclaw.env; see docs/AI.md (Operating it)"
            )

    pilib.write_file_atomic(marker, user_id + "\n")
    fix_ownership(marker)
    log(f"{'Created' if created else 'Found'} the Matrix account {user_id}")
    return created


def ensure_room_key_backup():
    """Server-side room-key backup for the bot's device: what lets a crypto
    store lost to an unclean shutdown (upstream issue #158784) be restored
    rather than leave every encrypted DM unreadable. Output discarded: the
    bootstrap can print the recovery key, which then only lives in the state
    volume - and in Backrest's snapshots of it."""
    openclaw = ["exec", CONTAINER, "node", "openclaw.mjs", "matrix", "verify"]
    status = docker(*openclaw, "status", timeout=180).stdout
    if "Backup: missing" not in status:
        return
    if docker(*openclaw, "bootstrap", timeout=300).returncode != 0:
        log("WARNING: could not create the bot's room-key backup; run `openclaw matrix verify bootstrap` by hand")
        return
    log("Created the bot's server-side room-key backup")


# --- 3. The people it answers ---


def agent_id(uid):
    """An OpenClaw agent id: ^[a-z0-9_][a-z0-9_-]{0,63}$."""
    return re.sub(r"[^a-z0-9_-]", "_", uid.lower())[:64]


def lldap_people():
    admin = get_env_value("ADMIN_USER")
    password = get_env_value("PASSWORD")
    if not admin or not password:
        die("ADMIN_USER and PASSWORD must be set to read the people list from LLDAP")
    token = pilib.docker_curl_json(
        "-H", "Content-Type: application/json", f"{LLDAP}/auth/simple/login",
        body=json.dumps({"username": admin, "password": password}),
    )["token"]  # fmt: skip
    query = {"query": "{ users { id displayName groups { displayName } } }"}
    users = pilib.docker_curl_json(
        "-H", "Content-Type: application/json", "-H", f"Authorization: Bearer {token}",
        f"{LLDAP}/api/graphql", body=json.dumps(query),
    )["data"]["users"]  # fmt: skip

    people = []
    for user in users:
        if {group["displayName"] for group in user["groups"]} & SERVICE_GROUPS:
            continue
        uid = user["id"].lower()
        people.append({"id": uid, "agent": agent_id(uid), "name": user["displayName"] or uid})
    return sorted(people, key=lambda person: person["id"])


def sync_people():
    people_file = data_dir() / "people.json"
    try:
        people = lldap_people()
    except CurlError as exc:
        log(f"WARNING: LLDAP did not answer ({exc}); keeping the cached people list")
        return False
    try:
        cached = json.loads(people_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        cached = None
    if cached == people:
        return False

    pilib.write_file_atomic(people_file, json.dumps(people, indent=2) + "\n")
    fix_ownership(people_file)
    proc = subprocess.run(
        [sys.executable, str(pilib.SCRIPT_DIR / "openclaw-pre-start.py")], capture_output=True, text=True, check=False
    )
    if proc.returncode != 0:
        die(f"openclaw-pre-start.py failed re-rendering the config: {proc.stderr.strip()[-400:]}")
    log(f"The assistant now answers {len(people)} people")
    return True


# --- 4. Forgejo ---


def forgejo_admin(*args):
    # As `git`: as root the CLI writes files under /data the server cannot read.
    return docker("exec", "-u", "git", FORGEJO, "forgejo", "admin", *args)


def forgejo_usernames(*flags):
    proc = forgejo_admin("user", "list", *flags)
    if proc.returncode != 0:
        die(f"forgejo admin user list failed: {proc.stderr.strip()}")
    # Space-padded columns here (`auth list` pads with tabs instead); a
    # username has no whitespace, so the second field is the username.
    return {line.split()[1].lower() for line in proc.stdout.splitlines()[1:] if len(line.split()) > 1}


def forgejo_owner(users):
    """Who owns the two repositories. ADMIN_USER is LLDAP's directory admin,
    which is not necessarily anyone's day-to-day account, so failing that the
    one Forgejo administrator - accounts come from LLDAP through SSO, and the
    LLDAP `admin` group is what makes one. Ambiguous with several: say so."""
    admin_user = (get_env_value("ADMIN_USER") or "").lower()
    if admin_user in users:
        return admin_user
    admins = forgejo_usernames("--admin") - {BOT_LOCALPART}
    if len(admins) == 1:
        return admins.pop()
    if not admins:
        log("Forgejo has no administrator yet; sign in to it once, and the next start provisions the repositories")
    else:
        log(f"Forgejo has {len(admins)} administrators and none is {admin_user}; not guessing who owns the repos")
    return ""


def forgejo_api(token, method, path, body=None):
    """One call from inside Forgejo, as (status, parsed body). The token reaches
    curl by variable name (`docker exec -e NAME`), never through the host's
    argv, and the status rides on the last line of the output."""
    script = (
        'curl -sS -w "\\n%{http_code}" -H "Authorization: token $FJ_TOKEN" '
        '-H "Content-Type: application/json" -X "$1" "http://localhost:3000/api/v1$2"'
        + (" --data @-" if body is not None else "")
    )
    proc = docker(
        "exec", "-i", "-e", "FJ_TOKEN", FORGEJO, "sh", "-c", script, "sh", method, path,
        input_text=json.dumps(body) if body is not None else "",
        env={**os.environ, "FJ_TOKEN": token},
    )  # fmt: skip
    payload, _, status = proc.stdout.rpartition("\n")
    try:
        parsed = json.loads(payload) if payload.strip() else None
    except json.JSONDecodeError:
        parsed = None
    return int(status.strip() or 0), parsed


def drop_provisioning_token(owner):
    """Forgejo has no CLI to delete a token and its API only deletes one under
    basic auth, which an SSO account does not have - so the row goes the way
    AGENTS.md allows when there is no API: through the database."""
    sql = (
        "DELETE FROM access_token WHERE name = :'token_name' "
        'AND uid = (SELECT id FROM "user" WHERE lower_name = lower(:\'owner\'));\n'
    )
    proc = subprocess.run(
        ["docker", "compose", "exec", "-T", "postgres", "psql", "-q", "-v", "ON_ERROR_STOP=1",
         "-v", f"owner={owner}", "-v", f"token_name={PROVISIONING_TOKEN}", "-U", "postgres", "-d", "forgejo"],
        input=sql, cwd=str(pilib.PROJECT_DIR), capture_output=True, text=True, check=False,
    )  # fmt: skip
    if proc.returncode != 0:
        log(f"WARNING: could not delete {owner}'s {PROVISIONING_TOKEN} token; revoke it in Forgejo's settings")


def provision_repositories(owner, bot):
    drop_provisioning_token(owner)
    proc = forgejo_admin(
        "user", "generate-access-token", "--username", owner, "--token-name", PROVISIONING_TOKEN,
        "--scopes", "write:repository,write:user", "--raw",
    )  # fmt: skip
    token = proc.stdout.strip()
    if proc.returncode != 0 or not token:
        die(f"could not mint a provisioning token for {owner}: {proc.stderr.strip()}")
    try:
        descriptions = {
            MEMORY_REPO: "The family assistant's memory: one branch per person, pushed by openclaw-sync",
            KNOWLEDGE_REPO: "The family's curated knowledge base: changes arrive as pull requests",
        }
        for repo, description in descriptions.items():
            if forgejo_api(token, "GET", f"/repos/{owner}/{repo}")[0] == 404:
                repository = {"name": repo, "private": True, "auto_init": True, "default_branch": "main"}
                status, _ = forgejo_api(token, "POST", "/user/repos", {**repository, "description": description})
                if status != 201:
                    die(f"creating {owner}/{repo} answered {status}")
                log(f"Created {owner}/{repo}")
            collaborator = f"/repos/{owner}/{repo}/collaborators/{bot}"
            if forgejo_api(token, "PUT", collaborator, {"permission": "write"})[0] != 204:
                die(f"adding {bot} to {owner}/{repo} failed")

        # The memory: every branch, pushed by the bot and the owner only, and
        # never rewritten - a force-push is how an agent's history would vanish.
        # The knowledge base: main takes the owner's pushes and reviewed pull
        # requests, which is all the bot can open (an AGit push to refs/for/main).
        protections = {
            MEMORY_REPO: {"rule_name": "*", "enable_push": True, "enable_push_whitelist": True,
                          "push_whitelist_usernames": [owner, bot], "enable_force_push": False},
            KNOWLEDGE_REPO: {"rule_name": "main", "enable_push": True, "enable_push_whitelist": True,
                             "push_whitelist_usernames": [owner], "enable_force_push": False,
                             "required_approvals": 1, "block_on_rejected_reviews": True},
        }  # fmt: skip
        for repo, rule in protections.items():
            status, existing = forgejo_api(token, "GET", f"/repos/{owner}/{repo}/branch_protections")
            if status != 200:
                die(f"reading {owner}/{repo}'s branch protection answered {status}")
            if any(item.get("rule_name") == rule["rule_name"] for item in existing or []):
                continue
            status, _ = forgejo_api(token, "POST", f"/repos/{owner}/{repo}/branch_protections", rule)
            if status != 201:
                die(f"protecting {owner}/{repo} answered {status}")
            log(f"Protected {owner}/{repo} ({rule['rule_name']})")
    finally:
        drop_provisioning_token(owner)


def ensure_forgejo(host_name):
    if not pilib.container_is_running(FORGEJO):
        log("Forgejo is not running; the assistant's memory stays in its volume until it is")
        return
    users = forgejo_usernames()
    owner = forgejo_owner(users)
    if not owner:
        return

    if BOT_LOCALPART not in users:
        proc = forgejo_admin(
            "user", "create", "--username", BOT_LOCALPART, "--email", f"{BOT_LOCALPART}@{host_name}",
            "--random-password", "--must-change-password=false", "--restricted",
        )  # fmt: skip
        # stdout carries the generated password, which nothing needs: the bot
        # only ever authenticates with the token below.
        if proc.returncode != 0:
            die(f"could not create the Forgejo user {BOT_LOCALPART}: {proc.stderr.strip()}")
        log(f"Created the restricted Forgejo user {BOT_LOCALPART}")

    marker = data_dir() / "forgejo-provisioned"
    if not (marker.is_file() and marker.read_text(encoding="utf-8").strip() == owner):
        provision_repositories(owner, BOT_LOCALPART)
        pilib.write_file_atomic(marker, owner + "\n")
        fix_ownership(marker)

    token_file = data_dir() / "secrets" / "forgejo_token"
    if not token_file.is_file() or not token_file.read_text(encoding="utf-8").strip():
        # A fresh name each time: a lost file leaves its token behind, and the
        # CLI refuses a name that is already taken.
        name = f"openclaw-sync-{datetime.now(UTC):%Y%m%d%H%M%S}"
        proc = forgejo_admin(
            "user", "generate-access-token", "--username", BOT_LOCALPART, "--token-name", name,
            "--scopes", "write:repository", "--raw",
        )  # fmt: skip
        token = proc.stdout.strip()
        if proc.returncode != 0 or not token:
            die(f"could not mint the sync token: {proc.stderr.strip()}")
        pilib.write_file_atomic(token_file, token)
        safe_chmod(0o600, token_file)
        fix_ownership(token_file)
        try:
            os.chown(token_file, CONTAINER_UID, CONTAINER_UID)
        except OSError:
            log(f"WARNING: could not chown {token_file} to {CONTAINER_UID}; openclaw-sync cannot read it")
        log("Minted the Forgejo token openclaw-sync pushes with")


def main():
    if not pilib.wait_for_container(CONTAINER):
        die(f"{CONTAINER} is not running")
    host_name = get_env_value("HOST_NAME") or "pi.lan"
    if not pilib.wait_for_health("pi-tuwunel"):
        die("Tuwunel is not healthy, so the bot account cannot be checked")

    # A fresh start after an install already loads the plugin; only what
    # changes after it calls for the restart at the end.
    if ensure_plugin() and docker("start", CONTAINER).returncode != 0:
        die(f"could not start {CONTAINER} after the plugin install")
    restart = ensure_bot_account(f"chat.{host_name}", matrix_password())
    restart = sync_people() or restart
    ensure_forgejo(host_name)
    if not restart:
        # Against the running, logged-in device - which a restart pending
        # above would only interrupt; the next start does it instead.
        ensure_room_key_backup()

    if restart:
        log(f"Restarting {CONTAINER} to apply the changes")
        if docker("restart", CONTAINER, timeout=240).returncode != 0:
            die(f"could not restart {CONTAINER}")


if __name__ == "__main__":
    main()
