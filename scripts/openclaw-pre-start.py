#!/usr/bin/env python3
"""Pre-start for OpenClaw, the family assistant: its secrets and its whole config.

OpenClaw reads one JSON config, mounted read-only (OPENCLAW_CONFIG_READONLY in
compose), so everything the gateway does is decided here and nothing a model
says can change it. The policy below is the security boundary of this service:
OpenClaw's sandbox needs a container-engine socket or an SSH target, so instead
the agent is given no tool that executes, browses or fetches, and the container
no route out (compose.yaml, the `assistant` network).

One agent per person. The upstream trust model treats everyone allowed to DM a
gateway as able to steer it, and a shared agent injects the same MEMORY.md into
every DM session - measured: one person's notes were in another's context. So
each LLDAP account gets an agent of its own, with its own workspace, bound to
that person's Matrix ID, and `ownership: explicit` makes anything unbound fail
closed rather than land on a default agent.

The people list is not read here: at pre-start LLDAP is not running yet. It is
cached in DATA_LOCATION/openclaw/people.json by scripts/openclaw-bootstrap.py,
which re-runs this and restarts the gateway when the list changes. Before the
first bootstrap the list is empty, and the bot answers nobody.

A pre-start hook (scripts/run-hooks.sh), after agentgateway-pre-start.sh, which
generates the key this hands over. Idempotent.
"""

import json
import os
import secrets

from pilib import die, fix_ownership, get_env_value, log, resolve_data_location_path, safe_chmod, write_file_atomic

# The image runs as `node`, and OpenClaw's file secret provider refuses a file
# another uid owns - the same pin agentgateway-pre-start.sh makes for its data.
CONTAINER_UID = 1000
CONTAINER_GID = 1000

STATE_DIR = "/home/node/.openclaw"
SECRETS_IN_CONTAINER = "/run/secrets/openclaw.json"
BOT_LOCALPART = "assistant"


def secret_ref(pointer):
    return {"source": "file", "provider": "pi", "id": pointer}


def ensure_secrets(data_dir):
    """The gateway token and the bot's Matrix password are minted once and kept;
    the LLM key is copied from agentgateway's on every run, so a rotation there
    reaches the assistant at the next start."""
    secrets_dir = data_dir / "secrets"
    secrets_dir.mkdir(parents=True, exist_ok=True)
    safe_chmod(0o700, secrets_dir)
    secrets_file = secrets_dir / "openclaw.json"
    if secrets_file.is_dir():
        try:
            secrets_file.rmdir()
        except OSError:
            die(f"{secrets_file} is a non-empty directory; remove it by hand")

    current = {}
    if secrets_file.is_file():
        try:
            current = json.loads(secrets_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            die(f"cannot read {secrets_file}: {exc}")

    key_file = resolve_data_location_path() / "agentgateway" / "secrets" / "openclaw_llm_key"
    try:
        llm_key = key_file.read_text(encoding="utf-8").strip()
    except OSError:
        die(f"{key_file} is missing: agentgateway-pre-start.sh must run first")
    if not llm_key:
        die(f"{key_file} is empty")

    wanted = {
        "gatewayToken": current.get("gatewayToken") or secrets.token_hex(32),
        "matrixPassword": current.get("matrixPassword") or secrets.token_hex(32),
        "llmKey": f"sk-{llm_key}",
    }
    if wanted != current:
        write_file_atomic(secrets_file, json.dumps(wanted))
        log("Wrote OpenClaw's secrets")
    safe_chmod(0o600, secrets_file)
    return secrets_dir, secrets_file


def hand_over(data_dir, secrets_paths):
    """Everything to the project owner, so a non-root `make update` and the
    post-start bootstrap can write here - then the secrets to the container's
    uid, the one owner OpenClaw's file provider accepts. Both are 1000 on a
    standard install; where they differ, the container's needs win."""
    fix_ownership(data_dir)
    for path in secrets_paths:
        try:
            os.chown(path, CONTAINER_UID, CONTAINER_GID)
        except OSError:
            log(f"WARNING: could not chown {path} to {CONTAINER_UID}; OpenClaw will refuse its secrets")


def read_people(data_dir):
    path = data_dir / "people.json"
    try:
        people = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return []
    except (OSError, json.JSONDecodeError) as exc:
        die(f"cannot read {path}: {exc}")
    return sorted(people, key=lambda person: person["id"])


def agents_for(people, server_name):
    """One agent and one binding per person. `id` is the LLDAP uid, which is
    also the Matrix localpart (tuwunel takes preferred_username); `agent` is
    the same name reduced to what an OpenClaw agent id accepts."""
    if not people:
        return {}, []
    entries = {
        person["agent"]: {
            "name": person.get("name") or person["id"],
            "workspace": f"{STATE_DIR}/workspaces/{person['agent']}",
        }
        for person in people
    }
    bindings = [
        {
            "type": "route",
            "agentId": person["agent"],
            "match": {"channel": "matrix", "peer": {"kind": "direct", "id": f"@{person['id']}:{server_name}"}},
        }
        for person in people
    ]
    return entries, bindings


def render_config(people, host_name, timezone):
    server_name = f"chat.{host_name}"
    entries, bindings = agents_for(people, server_name)
    agents = {
        "defaults": {
            "model": {"primary": "agentgateway/assistant"},
            # No background work at all to start with: no heartbeat turn, no
            # dreaming consolidation (plugins below), no cron.
            "heartbeat": {"every": "0m"},
            "sandbox": {"mode": "off"},
            "userTimezone": timezone,
        },
    }
    if entries:
        agents["entries"] = entries
        agents["ownership"] = "explicit"

    return {
        "gateway": {
            # Nothing connects to the gateway but the CLI inside the container,
            # so no port is published and no Control UI is served.
            "mode": "local",
            "bind": "loopback",
            "auth": {"mode": "token", "token": secret_ref("/gatewayToken")},
            "controlUi": {"enabled": False},
            "terminal": {"enabled": False},
        },
        "update": {"checkOnStart": False},
        "secrets": {"providers": {"pi": {"source": "file", "path": SECRETS_IN_CONTAINER, "mode": "json"}}},
        "models": {
            "mode": "replace",
            "catalogRefresh": {"enabled": False},
            "providers": {
                "agentgateway": {
                    # A route of its own (config/agentgateway/config.yaml): the
                    # model behind `assistant` is chosen there, not here.
                    "baseUrl": "http://agentgateway:4000/assistant/v1",
                    "api": "openai-completions",
                    "apiKey": secret_ref("/llmKey"),
                    "timeoutSeconds": 300,
                    "models": [
                        {
                            "id": "assistant",
                            "name": "assistant",
                            "input": ["text"],
                            "reasoning": False,
                            "contextWindow": 131072,
                            "maxTokens": 8192,
                        }
                    ],
                }
            },
        },
        "agents": agents,
        **({"bindings": bindings} if bindings else {}),
        "session": {"dmScope": "per-channel-peer"},
        "memory": {
            "search": {
                # Recall across conversations is exactly the cross-person leak
                # the per-person agents exist to prevent.
                "rememberAcrossConversations": False,
                # The curated knowledge base, checked out read-only by
                # scripts/openclaw-sync.py. Outside every workspace, so the
                # file tools (workspaceOnly) cannot write it.
                "extraPaths": [f"{STATE_DIR}/knowledge"],
            }
        },
        "skills": {
            "workshop": {"autonomous": {"mode": "off"}},
            # Only config/openclaw/skills: the bundled ones mostly drive tools
            # this agent does not have, and each one listed costs prompt tokens.
            "allowBundled": [],
            "load": {"extraDirs": ["/opt/household-skills"]},
        },
        "cron": {"enabled": False},
        "browser": {"enabled": False},
        "tools": {
            # The groups that execute, browse, fetch, schedule or reconfigure.
            # What is left is the workspace files, memory and the reply itself.
            "deny": [
                "group:runtime",
                "group:ui",
                "group:automation",
                "group:nodes",
                "group:web",
                "sessions_spawn",
                "sessions_send",
            ],
            "fs": {"workspaceOnly": True},
            "exec": {"mode": "deny"},
            "elevated": {"enabled": False},
            "sessions": {"visibility": "agent"},
            "agentToAgent": {"enabled": False},
        },
        "plugins": {
            # Fifteen bundled plugins load otherwise.
            "allow": ["matrix", "memory-core"],
            "entries": {
                "matrix": {"enabled": True},
                "memory-core": {"config": {"dreaming": {"enabled": False}}},
            },
        },
        "channels": {
            "matrix": {
                "enabled": True,
                # By container name on the internal `assistant` network; the
                # plugin refuses a private address unless told otherwise.
                "homeserver": "http://tuwunel:8008",
                "network": {"dangerouslyAllowPrivateNetwork": True},
                "userId": f"@{BOT_LOCALPART}:{server_name}",
                "password": secret_ref("/matrixPassword"),
                "deviceName": "Assistant",
                "encryption": True,
                # Every invite, because a DM cannot be told from a room at
                # invite time and autoJoinAllowlist takes room IDs only; the
                # policies below then drop whatever is not an allowed DM.
                "autoJoin": "always",
                "joinIntro": False,
                "groupPolicy": "disabled",
                "dm": {
                    "policy": "allowlist",
                    "allowFrom": [f"@{person['id']}:{server_name}" for person in people],
                },
            }
        },
    }


def main():
    host_name = get_env_value("HOST_NAME") or "pi.lan"
    timezone = get_env_value("TIMEZONE") or "Europe/Paris"
    data_dir = resolve_data_location_path() / "openclaw"
    data_dir.mkdir(parents=True, exist_ok=True)

    secrets_paths = ensure_secrets(data_dir)

    people = read_people(data_dir)
    config_file = data_dir / "openclaw.json"
    if config_file.is_dir():
        try:
            config_file.rmdir()
        except OSError:
            die(f"{config_file} is a non-empty directory; remove it by hand")
    rendered = json.dumps(render_config(people, host_name, timezone), indent=2) + "\n"
    try:
        unchanged = config_file.read_text(encoding="utf-8") == rendered
    except OSError:
        unchanged = False
    if not unchanged:
        write_file_atomic(config_file, rendered)
        log(f"Rendered OpenClaw's config for {len(people)} people")
    safe_chmod(0o644, config_file)
    hand_over(data_dir, secrets_paths)


if __name__ == "__main__":
    main()
