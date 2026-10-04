#!/usr/bin/env python3
"""Pre-start for OpenClaw, the family assistant: its env_file and its whole config.

OpenClaw reads one JSON config, mounted read-only (OPENCLAW_CONFIG_READONLY in
compose), so everything the gateway does is decided here and nothing a model
says can change it. The policy below is the security boundary of this service:
OpenClaw's sandbox needs a container-engine socket or an SSH target, so instead
the agent is given no tool that executes, browses or fetches, and the container
no route out (compose.yaml, the `assistant` network). Its one window on the web
is web_search through the stack's SearXNG, which returns snippets, not pages.

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
import secrets

from pilib import (
    PROJECT_DIR,
    die,
    fix_ownership,
    get_env_value,
    log,
    read_env_value_from_file,
    resolve_data_location_path,
    safe_chmod,
    write_file_atomic,
)

STATE_DIR = "/home/node/.openclaw"
BOT_LOCALPART = "assistant"

# An env_file, read by the Docker daemon, rather than a mounted secrets file:
# OpenClaw's file provider refuses a file another uid owns, and a hook run by
# anyone but root - CI's runner, a non-root `make update` - cannot chown one to
# the container's uid. Same shape and same trade as agentgateway.env.
ENV_FILE = PROJECT_DIR / "config" / "openclaw" / "openclaw.env"
GATEWAY_TOKEN = "OPENCLAW_GATEWAY_TOKEN"
MATRIX_PASSWORD = "OPENCLAW_MATRIX_PASSWORD"
LLM_KEY = "OPENCLAW_LLM_KEY"


def secret_ref(name):
    return {"source": "env", "provider": "pi", "id": name}


def ensure_env_file():
    """The gateway token and the bot's Matrix password are minted once and kept;
    the LLM key is copied from agentgateway's on every run, so a rotation there
    reaches the assistant at the next `up -d` (env_file values are frozen at
    container creation)."""
    key_file = resolve_data_location_path() / "agentgateway" / "secrets" / "openclaw_llm_key"
    try:
        llm_key = key_file.read_text(encoding="utf-8").strip()
    except OSError:
        die(f"{key_file} is missing: agentgateway-pre-start.sh must run first")
    if not llm_key:
        die(f"{key_file} is empty")

    values = {
        GATEWAY_TOKEN: read_env_value_from_file(ENV_FILE, GATEWAY_TOKEN) or secrets.token_hex(32),
        MATRIX_PASSWORD: read_env_value_from_file(ENV_FILE, MATRIX_PASSWORD) or secrets.token_hex(32),
        LLM_KEY: f"sk-{llm_key}",
    }
    rendered = "".join(f"{name}={value}\n" for name, value in values.items())
    try:
        unchanged = ENV_FILE.read_text(encoding="utf-8") == rendered
    except OSError:
        unchanged = False
    if not unchanged:
        ENV_FILE.parent.mkdir(parents=True, exist_ok=True)
        write_file_atomic(ENV_FILE, rendered)
        log(f"Wrote {ENV_FILE.name}")
    safe_chmod(0o600, ENV_FILE)
    fix_ownership(ENV_FILE)


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
            "auth": {"mode": "token", "token": secret_ref(GATEWAY_TOKEN)},
            "controlUi": {"enabled": False},
            "terminal": {"enabled": False},
        },
        "update": {"checkOnStart": False},
        # An explicit allowlist: the provider resolves these three and no other
        # variable of the container's environment.
        "secrets": {"providers": {"pi": {"source": "env", "allowlist": [GATEWAY_TOKEN, MATRIX_PASSWORD, LLM_KEY]}}},
        "models": {
            "mode": "replace",
            "catalogRefresh": {"enabled": False},
            "providers": {
                "agentgateway": {
                    # A route of its own (config/agentgateway/config.yaml): the
                    # model behind `assistant` is chosen there, not here.
                    "baseUrl": "http://agentgateway:4000/assistant/v1",
                    "api": "openai-completions",
                    "apiKey": secret_ref(LLM_KEY),
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
        # No automatic reset: a conversation goes on until its person starts a
        # new one, and compaction summarises it as it nears the context window.
        # In Element a typed /new is taken for a client command; `//new` sends it.
        "session": {"dmScope": "per-channel-peer"},
        "hooks": {
            "internal": {
                "entries": {
                    # Injects the household rules into every agent's prompt. The
                    # hook only reads inside a workspace, so openclaw-bootstrap.py
                    # puts a read-only copy of config/openclaw/household/AGENTS.md
                    # at this path in each one.
                    "bootstrap-extra-files": {"enabled": True, "paths": [".household/AGENTS.md"]},
                    # On /new, the last exchanges of the conversation it ends go
                    # to a dated note in memory/, so starting over loses nothing
                    # memory_search cannot find again.
                    "session-memory": {"enabled": True},
                },
            }
        },
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
            # Not [], which OpenClaw reads as no allowlist at all - every
            # bundled skill loaded (measured: 13 of them). A name no skill has
            # is how to allow none.
            "allowBundled": ["none"],
            "load": {"extraDirs": ["/opt/household-skills"]},
        },
        "cron": {"enabled": False},
        "browser": {"enabled": False},
        "tools": {
            # The groups that execute, browse, fetch, schedule or reconfigure.
            # What is left is the workspace files, memory, web_search and the
            # reply itself. Not group:web whole: web_fetch reads any URL - a
            # page of untrusted text, and a request that can carry private data
            # out in its query string - where web_search returns titles and
            # snippets from SearXNG, wrapped as untrusted by OpenClaw's core.
            "deny": [
                "group:runtime",
                "group:ui",
                "group:automation",
                "group:nodes",
                "web_fetch",
                "x_search",
                "sessions_spawn",
                "sessions_send",
                # Tools that do nothing here but cost prompt tokens: conversation
                # addresses are scoped to this agent's own DM, spawning is denied
                # above so there are no subagents to wait on, and presence needs
                # Gateway operator access. agents_list would name the other
                # family members' accounts, which this agent has no use for.
                "conversations_list",
                "conversations_send",
                "conversations_turn",
                "subagents",
                "agents_wait",
                "sessions_yield",
                "presence",
                "agents_list",
            ],
            "web": {"search": {"provider": "searxng"}},
            # Both default to true: an instruction planted in a search result
            # could otherwise have one person's agent post into another family
            # member's conversation. Replies stay in the conversation they
            # answer.
            "message": {"crossContext": {"allowWithinProvider": False, "allowAcrossProviders": False}},
            "fs": {"workspaceOnly": True},
            "exec": {"mode": "deny"},
            "elevated": {"enabled": False},
            "sessions": {"visibility": "agent"},
            "agentToAgent": {"enabled": False},
        },
        "plugins": {
            # Fifteen bundled plugins load otherwise. searxng is not in the
            # image: scripts/openclaw-bootstrap.py installs it, as it does matrix.
            "allow": ["matrix", "memory-core", "searxng"],
            "entries": {
                "matrix": {"enabled": True},
                "memory-core": {"config": {"dreaming": {"enabled": False}}},
                # By container name on the internal `ai` network: SearXNG makes
                # the outbound requests, the gateway still has no route out.
                "searxng": {"enabled": True, "config": {"webSearch": {"baseUrl": "http://searxng:8080"}}},
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
                "password": secret_ref(MATRIX_PASSWORD),
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

    ensure_env_file()

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
    # The whole directory, not only the file: the bootstrap writes its markers
    # and the people list here, and a root-run boot would otherwise leave it
    # root-owned for the next non-root run.
    fix_ownership(data_dir)


if __name__ == "__main__":
    main()
