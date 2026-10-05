#!/usr/bin/env python3
"""Post-start for OpenClaw: everything that needs the stack answering.

1. The Matrix and SearXNG plugins, at exactly the image's version. Neither is
   in the image, and the image's own entrypoint would fetch and refresh them
   from npm on every start (compose/compose-ai.yaml explains why that
   entrypoint is bypassed). Installed here instead, into the state volume, by a
   throwaway container of the same image - the only moment anything of this
   service reaches the internet. The native crypto binding the Matrix plugin
   uses for encrypted attachments is fetched in the same pass, since the
   gateway has no egress to fetch it at runtime.
2. The bot's Matrix account, @assistant, created through Tuwunel's
   shared-secret endpoint (scripts/tuwunel-pre-start.sh) - registration stays
   off for everyone else - and a server-side backup of its room keys.
3. The people it answers: every LLDAP account but the service accounts,
   cached for openclaw-pre-start.py, which renders one agent per person.
4. The family room: one encrypted room, created by the bot, where a shared
   family agent answers whoever mentions it; every person is invited once
   their Matrix account exists.
5. The household rules (config/openclaw/household/AGENTS.md): a read-only copy
   in every workspace, which the gateway injects into each agent's prompt; and
   every agent's memory index, rebuilt when its scope changed.
6. Its Forgejo side, when Forgejo runs: a local, restricted bot user, the two
   repositories it pushes to (scripts/openclaw-sync.py), and their branch
   protection.
7. Its Nextcloud side, when Nextcloud runs: an app password per person, which
   the nextcloud plugin (config/openclaw/plugins/nextcloud) acts with.

Restarts the gateway once if the account, the people or the family room
changed. Idempotent: the next start redoes nothing that is already in place.
"""

import hashlib
import hmac
import json
import os
import re
import subprocess
import sys
from datetime import UTC, datetime
from urllib.parse import quote

import pilib
from pilib import CurlError, die, fix_ownership, get_env_value, log, resolve_data_location_path, safe_chmod

CONTAINER = "pi-openclaw"
FORGEJO = "pi-forgejo"
STATE_DIR = "/home/node/.openclaw"
MATRIX_PLUGIN = "@openclaw/matrix"
SEARXNG_PLUGIN = "@openclaw/searxng-plugin"
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

# Every generation of a plugin's install: a reinstall writes a sibling
# `openclaw-matrix-<hash>__openclaw-generation__<id>` before retiring the old
# one, so a glob can match two directories at once.
MATRIX_GLOB = f"{STATE_DIR}/npm/projects/openclaw-matrix-*/node_modules/{MATRIX_PLUGIN}"
SEARXNG_GLOB = f"{STATE_DIR}/npm/projects/openclaw-searxng-plugin-*/node_modules/{SEARXNG_PLUGIN}"

# Prints "<package> <version>" for each complete generation; a Matrix one is
# complete only with its native crypto binding.
COMPLETE_GENERATIONS = f"""
    for dir in {MATRIX_GLOB}; do
        [ -f "$dir/package.json" ] || continue
        ls "$dir"/node_modules/@matrix-org/matrix-sdk-crypto-nodejs/*.node >/dev/null 2>&1 || continue
        echo "{MATRIX_PLUGIN} $(node -p "require(process.argv[1]).version" "$dir/package.json")"
    done
    for dir in {SEARXNG_GLOB}; do
        [ -f "$dir/package.json" ] || continue
        echo "{SEARXNG_PLUGIN} $(node -p "require(process.argv[1]).version" "$dir/package.json")"
    done
"""
# $1 is the version, the rest the packages to install at it.
INSTALL = f"""
    set -e
    mkdir -p /tmp/install
    version="$1"
    shift
    for package in "$@"; do
        node openclaw.mjs plugins install "$package@$version" --pin --force
    done
    case " $* " in
        *" {MATRIX_PLUGIN} "*)
            for dir in {MATRIX_GLOB}; do
                [ "$(node -p "require(process.argv[1]).version" "$dir/package.json")" = "$version" ] || continue
                (cd "$dir/node_modules/@matrix-org/matrix-sdk-crypto-nodejs" && node download-lib.js)
            done
            ;;
    esac
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


# --- 1. The plugins ---


def one_shot(image, volume, script, args, network=()):
    """A throwaway container of the gateway's own image on its state volume,
    so it works whether the gateway is running or stopped."""
    return docker(
        "run", "--rm", *network, "--user", f"{CONTAINER_UID}:{CONTAINER_UID}",
        "-v", f"{volume}:{STATE_DIR}",
        "--tmpfs", f"/home/node/.cache:uid={CONTAINER_UID},gid={CONTAINER_UID}",
        "-e", f"OPENCLAW_STATE_DIR={STATE_DIR}", "-e", "OPENCLAW_CONFIG_PATH=/tmp/install/openclaw.json",
        "--entrypoint", "sh", image, "-c", script, "sh", *args,
    )  # fmt: skip


def missing_plugins(image, volume, version):
    proc = one_shot(image, volume, COMPLETE_GENERATIONS, [], ("--network", "none"))
    complete = set(proc.stdout.splitlines())
    return [plugin for plugin in (MATRIX_PLUGIN, SEARXNG_PLUGIN) if f"{plugin} {version}" not in complete]


def gateway_image_and_volume():
    image = inspect(CONTAINER, "{{.Config.Image}}")
    volume = inspect(CONTAINER, '{{range .Mounts}}{{if eq .Destination "' + STATE_DIR + '"}}{{.Name}}{{end}}{{end}}')
    if not image or not volume:
        die(f"cannot read the image or the state volume of {CONTAINER}")
    return image, volume


def ensure_plugins():
    image, volume = gateway_image_and_volume()
    version_label = '{{index .Config.Labels "org.opencontainers.image.version"}}'
    version = docker("image", "inspect", "--format", version_label, image).stdout.strip()
    if not version:
        die(f"cannot read the version of {image}")

    missing = missing_plugins(image, volume, version)
    if not missing:
        return False

    wanted = ", ".join(f"{plugin}@{version}" for plugin in missing)
    log(f"Installing {wanted} into {volume}")
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
    proc = one_shot(image, volume, INSTALL, [version, *missing])
    if proc.returncode != 0:
        docker("start", CONTAINER)
        die(f"plugin install failed: {proc.stderr.strip()[-400:]}")
    still_missing = missing_plugins(image, volume, version)
    if still_missing:
        docker("start", CONTAINER)
        die(f"{', '.join(still_missing)} still not in place at {version} after the install")
    log(f"Installed {wanted}")
    return True


# --- 2. The bot's Matrix account ---


def matrix_api(token, method, path, body=None):
    """One client-server call as the bot, as (status, parsed body). curl takes
    its options as a config on stdin, so the access token is in no argv on the
    host's process table."""

    def quoted(value):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

    config = [
        f"url = {quoted(TUWUNEL + path)}",
        f"request = {quoted(method)}",
        f"header = {quoted('Authorization: Bearer ' + token)}",
        'header = "Content-Type: application/json"',
    ]
    if body is not None:
        config.append(f"data-binary = {quoted(json.dumps(body))}")
    try:
        proc = docker(
            "run", "--rm", "-i", "--network", pilib.DOCKER_CURL_NETWORK, pilib.CURL_IMAGE,
            "-sS", *pilib.CURL_TIMEOUTS, "-w", "\\n%{http_code}", "--config", "-",
            input_text="\n".join(config) + "\n", timeout=60,
        )  # fmt: skip
    except subprocess.TimeoutExpired:
        return 0, {}
    payload, _, status = proc.stdout.rpartition("\n")
    try:
        parsed = json.loads(payload) if payload.strip() else {}
    except json.JSONDecodeError:
        parsed = {}
    status = status.strip()
    return (int(status) if status.isdigit() else 0), parsed


def matrix_login(user_id, password, device_name):
    body = {
        "type": "m.login.password",
        "identifier": {"type": "m.id.user", "user": user_id},
        "password": password,
        "initial_device_display_name": device_name,
    }
    try:
        login = pilib.docker_curl_json(
            "-H", "Content-Type: application/json", f"{TUWUNEL}/_matrix/client/v3/login", body=json.dumps(body)
        )
    except CurlError:
        return ""
    return login.get("access_token", "")


def matrix_logout(token):
    """Every login here creates a device; leave none behind."""
    if matrix_api(token, "POST", "/_matrix/client/v3/logout", {})[0] != 200:
        log("WARNING: could not log a bootstrap session out; a stale device is left on the bot")


def matrix_login_works(user_id, password):
    token = matrix_login(user_id, password, "openclaw-bootstrap check")
    if not token:
        return False
    matrix_logout(token)
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
    query = {"query": "{ users { id email displayName groups { displayName } } }"}
    users = pilib.docker_curl_json(
        "-H", "Content-Type: application/json", "-H", f"Authorization: Bearer {token}",
        f"{LLDAP}/api/graphql", body=json.dumps(query),
    )["data"]["users"]  # fmt: skip

    people = []
    agents = {FAMILY_AGENT}
    for user in sorted(users, key=lambda user: user["id"].lower()):
        if {group["displayName"] for group in user["groups"]} & SERVICE_GROUPS:
            continue
        uid = user["id"].lower()
        agent = agent_id(uid)
        # Two uids reduced to one agent id (jean.dupont, jean_dupont) would
        # share a workspace and its MEMORY.md: the leak per-person agents close.
        # The family room's agent holds one id of its own.
        if agent in agents:
            log(f"WARNING: {uid} reduces to the agent id {agent}, already taken; the assistant will not answer it")
            continue
        agents.add(agent)
        # The email is the Nextcloud account id: user_oidc maps uid to email.
        people.append({"id": uid, "agent": agent, "name": user["displayName"] or uid, "email": user.get("email") or ""})
    return people


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
    render_config()
    log(f"The assistant now answers {len(people)} people")
    return True


def read_people():
    try:
        return json.loads((data_dir() / "people.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []


def render_config():
    proc = subprocess.run(
        [sys.executable, str(pilib.SCRIPT_DIR / "openclaw-pre-start.py")], capture_output=True, text=True, check=False
    )
    if proc.returncode != 0:
        die(f"openclaw-pre-start.py failed re-rendering the config: {proc.stderr.strip()[-400:]}")


# --- 4. The family room ---

# The one room the assistant answers in, as an agent of its own whose workspace
# is the family's shared memory; openclaw-pre-start.py binds it to the room ID
# recorded here, and openclaw-sync.py pushes it like a person's.
FAMILY_AGENT = "family"
FAMILY_ROOM_FILE = "family-room.json"
FAMILY_ROOM_NAME = "Family"
FAMILY_ROOM_TOPIC = (
    "The family's room. Mention @Assistant to ask it something; what it learns here, it remembers for everyone."
)


def family_room_state():
    try:
        return json.loads((data_dir() / FAMILY_ROOM_FILE).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def save_family_room_state(state):
    path = data_dir() / FAMILY_ROOM_FILE
    pilib.write_file_atomic(path, json.dumps(state, indent=2) + "\n")
    fix_ownership(path)


def matrix_account_exists(user_id):
    """A Matrix account is created at its owner's first SSO sign-in, so an
    LLDAP account may have none yet - and an invite to it would fail."""
    try:
        pilib.docker_curl_json(f"{TUWUNEL}/_matrix/client/v3/profile/{quote(user_id, safe='')}")
    except CurlError:
        return False
    return True


def create_family_room(token, invitees):
    """Room version 11, not Tuwunel's default 12: from 12 on, the creator - the
    bot - holds unlimited power that nobody can take back. Everyone who joins
    is an administrator (users_default), and inviting takes no rank."""
    status, created = matrix_api(token, "POST", "/_matrix/client/v3/createRoom", {
        "room_version": "11",
        "preset": "private_chat",
        "name": FAMILY_ROOM_NAME,
        "topic": FAMILY_ROOM_TOPIC,
        "initial_state": [
            {"type": "m.room.encryption", "state_key": "", "content": {"algorithm": "m.megolm.v1.aes-sha2"}}
        ],
        "power_level_content_override": {"users_default": 100, "invite": 0},
        "invite": invitees,
    })  # fmt: skip
    if status != 200 or not created.get("room_id"):
        log(f"WARNING: creating the family room answered {status} {created.get('errcode', '')}")
        return ""
    return created["room_id"]


def demote_bot(token, room_id, bot_id):
    """The bot down to an ordinary member who may still pin. The plugin hands
    the agent a delete action, which at 100 would redact anyone's message; a
    room's creator can lower its own rank, and nobody else can lower it."""
    path = f"/_matrix/client/v3/rooms/{quote(room_id, safe='')}/state/m.room.power_levels"
    status, levels = matrix_api(token, "GET", path)
    if status != 200:
        return False
    levels.setdefault("users", {})[bot_id] = 0
    levels.setdefault("events", {})["m.room.pinned_events"] = 0
    return matrix_api(token, "PUT", path, levels)[0] == 200


def invite(token, room_id, user_id):
    """Invites anyone who never had a membership in the room: someone who left
    stays out until a member invites them back."""
    room = f"/_matrix/client/v3/rooms/{quote(room_id, safe='')}"
    if matrix_api(token, "GET", f"{room}/state/m.room.member/{quote(user_id, safe='')}")[0] == 200:
        return True
    return matrix_api(token, "POST", f"{room}/invite", {"user_id": user_id})[0] == 200


def ensure_family_room(server_name, password, people):
    """Creates the room once and invites each person whose Matrix account
    exists. Signs in only when there is something to do. Returns whether the
    room was just created, which the gateway needs a restart to bind."""
    if not people:
        return False
    state = family_room_state()
    invited = set(state.get("invited", []))
    pending = [
        user_id
        for user_id in (f"@{person['id']}:{server_name}" for person in people)
        if user_id not in invited and matrix_account_exists(user_id)
    ]
    if state.get("room_id") and state.get("bot_demoted") and not pending:
        return False

    bot_id = f"@{BOT_LOCALPART}:{server_name}"
    token = matrix_login(bot_id, password, "openclaw-bootstrap")
    if not token:
        log("WARNING: the bot could not sign in to set up the family room; the next start retries")
        return False
    created = False
    try:
        if not state.get("room_id"):
            room_id = create_family_room(token, pending)
            if not room_id:
                return False
            # Saved before anything else can fail: one room, ever.
            state = {"room_id": room_id, "invited": sorted(pending), "bot_demoted": False}
            save_family_room_state(state)
            created = True
            log(f"Created the family room {room_id}, inviting {len(pending)} people")
            pending = []
        if not state.get("bot_demoted"):
            state["bot_demoted"] = demote_bot(token, state["room_id"], bot_id)
            if not state["bot_demoted"]:
                log("WARNING: could not lower the bot's rank in the family room; the next start retries")
        for user_id in pending:
            if invite(token, state["room_id"], user_id):
                invited.add(user_id)
                log(f"Invited {user_id} to the family room")
            else:
                log(f"WARNING: could not invite {user_id} to the family room; the next start retries")
        state["invited"] = sorted(invited | set(state.get("invited", [])))
        save_family_room_state(state)
    finally:
        matrix_logout(token)
    if created:
        render_config()
    return created


# --- 5. The household rules ---

# config/openclaw/household/AGENTS.md, copied into every workspace at this path,
# which openclaw-pre-start.py names to the bootstrap-extra-files hook: the hook
# injects only files inside the workspace. A dot-directory, because the copy
# takes its directory over as root, and `household/` is a name an agent could
# pick for its own notes; openclaw-sync.py keeps it out of the memory branches.
HOUSEHOLD_RULES = pilib.PROJECT_DIR / "config" / "openclaw" / "household" / "AGENTS.md"
HOUSEHOLD_RULES_DIR = ".household"
HOUSEHOLD_RULES_PATH = f"{HOUSEHOLD_RULES_DIR}/AGENTS.md"

# As root, so the agent - which runs as node - can read the copy but neither
# edit nor delete it. Missing directories, workspaces/ included, are created as
# node first: root-owned, OpenClaw could not seed a workspace in them. Prints
# the agents whose copy changed; sha256sum because the image has no cmp.
PLACE_RULES = f"""
    set -e
    [ -d "{STATE_DIR}/workspaces" ] || install -d -o {CONTAINER_UID} -g {CONTAINER_UID} -m 0755 "{STATE_DIR}/workspaces"
    for agent in "$@"; do
        workspace="{STATE_DIR}/workspaces/$agent"
        [ -d "$workspace" ] || install -d -o {CONTAINER_UID} -g {CONTAINER_UID} -m 0755 "$workspace"
        install -d -o 0 -g 0 -m 0755 "$workspace/{HOUSEHOLD_RULES_DIR}"
        copy="$workspace/{HOUSEHOLD_RULES_PATH}"
        if [ -f "$copy" ] && [ "$(sha256sum < "$copy")" = "$(sha256sum < /tmp/rules)" ]; then
            continue
        fi
        install -o 0 -g 0 -m 0444 /tmp/rules "$copy"
        echo "$agent"
    done
"""


def ensure_household_rules():
    agents = [person["agent"] for person in read_people()]
    if family_room_state().get("room_id"):
        agents.append(FAMILY_AGENT)
    if not agents:
        return
    image, volume = gateway_image_and_volume()
    proc = docker(
        "run", "--rm", "--network", "none", "--user", "0:0",
        "-v", f"{volume}:{STATE_DIR}", "-v", f"{HOUSEHOLD_RULES}:/tmp/rules:ro",
        "--entrypoint", "sh", image, "-c", PLACE_RULES, "sh", *agents,
    )  # fmt: skip
    if proc.returncode != 0:
        die(f"could not place the household rules: {proc.stderr.strip()[-400:]}")
    changed = proc.stdout.split()
    if changed:
        log(f"Household rules placed in {len(changed)} workspace(s)")


def ensure_memory_indexes():
    """OpenClaw leaves a memory index whose scope changed - the family room's
    paths added to every agent, a provider switched - serving stale results,
    and waits for this command, because a rebuild may call an embeddings API.
    Search is keyword-only here (openclaw-pre-start.py), so it costs nothing,
    and it does nothing when every index is current."""
    proc = docker("exec", CONTAINER, "node", "openclaw.mjs", "memory", "status", "--index", "--json", timeout=600)
    if proc.returncode != 0:
        log("WARNING: could not bring the memory indexes up to date; run `openclaw memory status --index` by hand")


# --- 6. Forgejo ---


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
    the shell by variable name (`docker exec -e NAME`) and curl through a
    here-document on fd 3 - in curl's own argv it would be on the host's
    process table too - and the status rides on the last line of the output."""
    script = (
        'curl -sS -w "\\n%{http_code}" -H @/dev/fd/3 '
        '-H "Content-Type: application/json" -X "$1" "http://localhost:3000/api/v1$2"'
        + (" --data @-" if body is not None else "")
        + " 3<<EOF\nAuthorization: token $FJ_TOKEN\nEOF\n"
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
        token_file.parent.mkdir(parents=True, exist_ok=True)
        safe_chmod(0o700, token_file.parent)
        pilib.write_file_atomic(token_file, token)
        safe_chmod(0o600, token_file)
        fix_ownership(token_file.parent)
        try:
            os.chown(token_file, CONTAINER_UID, CONTAINER_UID)
        except OSError:
            log(f"WARNING: could not chown {token_file} to {CONTAINER_UID}; openclaw-sync cannot read it")
        log("Minted the Forgejo token openclaw-sync pushes with")


# --- 7. Nextcloud ---

NEXTCLOUD = "pi-nextcloud"
# What the person sees in Nextcloud's security settings, where they can revoke it.
NEXTCLOUD_TOKEN_NAME = "Family assistant (OpenClaw)"
APP_PASSWORD = re.compile(r"^[A-Za-z0-9-]{20,}$")


def mint_app_password(account):
    proc = docker("exec", NEXTCLOUD, "php", "occ", "user:auth-tokens:add", "--name", NEXTCLOUD_TOKEN_NAME, account)
    lines = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    if proc.returncode != 0 or not lines or not APP_PASSWORD.match(lines[-1]):
        return ""
    return lines[-1]


def has_app_password(token_file):
    """The directory belongs to the gateway's uid, mode 0700: a non-root run
    by another user cannot look inside, and could not write a new one either."""
    try:
        return bool(token_file.read_text(encoding="utf-8").strip())
    except FileNotFoundError:
        return False
    except PermissionError:
        return True


def ensure_nextcloud_app_passwords(people):
    """One app password per person, minted as that person by occ, so the
    plugin acts with exactly their rights and nobody else's. A person whose
    Nextcloud account does not exist yet - it is created at their first sign-in
    - gets one at the first start after that. A lost file means a new password;
    the old one stays listed in their settings until they revoke it."""
    if not pilib.container_is_running(NEXTCLOUD):
        return
    token_dir = data_dir() / "secrets" / "nextcloud"
    for person in people:
        account = person.get("email")
        token_file = token_dir / person["agent"]
        if not account or has_app_password(token_file):
            continue
        if docker("exec", NEXTCLOUD, "php", "occ", "user:info", account).returncode != 0:
            continue
        secret = mint_app_password(account)
        if not secret:
            log(f"WARNING: could not mint {person['agent']}'s Nextcloud app password")
            continue
        pilib.write_file_atomic(token_file, secret)
        safe_chmod(0o600, token_file)
        try:
            os.chown(token_file, CONTAINER_UID, CONTAINER_UID)
        except OSError:
            log(f"WARNING: could not chown {token_file} to {CONTAINER_UID}; the gateway cannot read it")
        log(f"Minted {person['agent']}'s Nextcloud app password")


def main():
    if not pilib.wait_for_container(CONTAINER):
        die(f"{CONTAINER} is not running")
    host_name = get_env_value("HOST_NAME") or "pi.lan"
    if not pilib.wait_for_health("pi-tuwunel"):
        die("Tuwunel is not healthy, so the bot account cannot be checked")

    # A fresh start after an install already loads the plugin; only what
    # changes after it calls for a restart.
    if ensure_plugins():
        if docker("start", CONTAINER).returncode != 0:
            die(f"could not start {CONTAINER} after the plugin install")
        # An image bump reinstalls the plugins without asking for a restart,
        # and the CLI steps below fail against a gateway still starting.
        if not pilib.wait_for_health(CONTAINER):
            die(f"{CONTAINER} did not come back healthy after the plugin install")
    server_name = f"chat.{host_name}"
    password = matrix_password()
    restart = ensure_bot_account(server_name, password)
    restart = sync_people() or restart
    restart = ensure_family_room(server_name, password, read_people()) or restart
    # Before anything that can die: the next run finds people.json and the
    # family room already current, and would never ask for this restart again.
    if restart:
        log(f"Restarting {CONTAINER} to apply the changes")
        if docker("restart", CONTAINER, timeout=240).returncode != 0:
            die(f"could not restart {CONTAINER}")
        # The CLI steps below exec into it, and failed against a gateway still
        # starting (measured: the memory index step).
        if not pilib.wait_for_health(CONTAINER):
            die(f"{CONTAINER} did not come back healthy after the restart")
    ensure_household_rules()
    ensure_memory_indexes()
    ensure_forgejo(host_name)
    ensure_nextcloud_app_passwords(read_people())
    if not restart:
        # Needs the device logged in, which a restart just undid; the next
        # start does it instead.
        ensure_room_key_backup()


if __name__ == "__main__":
    main()
