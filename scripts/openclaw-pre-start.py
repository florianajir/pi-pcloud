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

Plus one shared agent for the family room openclaw-bootstrap.py creates: what
is said there is shared by nature, so its workspace is the family's memory. It
answers only when mentioned, and only the people in LLDAP.

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
# The image's `node` user.
CONTAINER_UID = 1000
# config/openclaw/plugins, and the app passwords openclaw-bootstrap.py mints
# for it, as compose/compose-ai.yaml mounts them.
HOUSEHOLD_PLUGINS = "/opt/household-plugins"
NEXTCLOUD_TOKENS = "/run/nextcloud-tokens"
# The family room's agent and the room openclaw-bootstrap.py created for it.
FAMILY_AGENT = "family"
FAMILY_ROOM_FILE = "family-room.json"
FAMILY_WORKSPACE = f"{STATE_DIR}/workspaces/{FAMILY_AGENT}"
# A message that starts with the bot's name wakes it, besides Element's
# mention pill: OpenClaw would otherwise derive a pattern from the agent's
# name and wake on the word anywhere in a sentence.
FAMILY_MENTION_PATTERNS = [r"^\s*@?assistant\b"]
# Unmentioned room messages kept in memory and handed over with the next
# mention, so "what do you think?" has something to refer to. No request of
# its own; lost on restart.
ROOM_HISTORY_LIMIT = 20
FAMILY_ROOM_PROMPT = (
    "This is the family's shared room. Several family members write here, and each message says who "
    "sent it: answer that person, by name. Everything said here is seen by every member of the room. "
    "Your workspace is the family's shared memory. Keep lasting facts about the family - who is who, "
    "birthdays, preferences, decisions - in USER.md, not MEMORY.md: in this room USER.md is part of your "
    "context and MEMORY.md is not. Other notes go in memory/. Before answering about something said or "
    "decided earlier, search your memory. You never see anyone's private "
    "conversations with their own assistant, so never claim to know what someone said elsewhere. "
    "Keep replies short: this is a group chat."
)

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


def read_family_room(data_dir):
    try:
        return json.loads((data_dir / FAMILY_ROOM_FILE).read_text(encoding="utf-8")).get("room_id", "")
    except (OSError, json.JSONDecodeError, AttributeError):
        return ""


def agents_for(people, server_name, family_room):
    """One agent and one binding per person, plus the family room's. `id` is
    the LLDAP uid, which is also the Matrix localpart (tuwunel takes
    preferred_username); `agent` is the same name reduced to what an OpenClaw
    agent id accepts."""
    if not people:
        return {}, []
    # Each person's agent may search what the family agent remembers - read
    # only: outside its workspace, where the file tools cannot write. Never
    # the other way round: no DM reaches the family agent.
    family_paths = [f"{FAMILY_WORKSPACE}/{name}" for name in ("MEMORY.md", "USER.md", "memory")]
    family_memory = {"memory": {"search": {"extraPaths": family_paths}}} if family_room else {}
    entries = {
        person["agent"]: {
            "name": person.get("name") or person["id"],
            "workspace": f"{STATE_DIR}/workspaces/{person['agent']}",
            **family_memory,
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
    if family_room:
        entries[FAMILY_AGENT] = {
            "name": "Family",
            "workspace": FAMILY_WORKSPACE,
            "groupChat": {"mentionPatterns": FAMILY_MENTION_PATTERNS},
        }
        bindings.append(
            {
                "type": "route",
                "agentId": FAMILY_AGENT,
                "match": {"channel": "matrix", "peer": {"kind": "channel", "id": family_room}},
            }
        )
    return entries, bindings


def rooms_for(people, server_name, family_room):
    """The family room is the only room answered. Listing its people is what
    lets them run commands there (//new): with no list, anyone in the room
    could talk to the agent and nobody could reset it."""
    if not (family_room and people):
        return {"groupPolicy": "disabled"}
    return {
        "groupPolicy": "allowlist",
        "groups": {
            family_room: {
                "users": [f"@{person['id']}:{server_name}" for person in people],
                # Every accepted room message gets a reply, so without a mention
                # each one would be a model turn and an answer.
                "requireMention": True,
                "systemPrompt": FAMILY_ROOM_PROMPT,
            }
        },
        "historyLimit": ROOM_HISTORY_LIMIT,
    }


def render_config(people, host_name, timezone, family_room):
    server_name = f"chat.{host_name}"
    entries, bindings = agents_for(people, server_name, family_room)
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
                            # Photos and scanned pages go to Gemini as images
                            # (agentgateway translates OpenAI's image_url,
                            # measured); about 1,100 input tokens each.
                            "input": ["text", "image"],
                            "reasoning": False,
                            # Compaction keeps a session under 3/4 of this
                            # (OpenClaw caps its reserve at 25%), which bounds
                            # every request: five at 48k fit Flash-Lite's 250k
                            # tokens a minute. Smaller, and a session measured
                            # at 22k after a few searches would compact - a
                            # request each time - every few turns.
                            "contextWindow": 65536,
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
                # Keyword search, deliberately: the gateway has no route to an
                # embeddings API, and unset means OpenAI - unreachable, so the
                # index stalls on a provider mismatch and stops taking new notes
                # (measured: the family memory never reached a private agent).
                "provider": "none",
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
        # Inbound photos and documents are pruned after a week, so the family's
        # papers do not pile up in the state volume - and in every Backrest
        # snapshot of it. This covers OpenClaw's own copy only; the one it puts
        # in the agent's workspace is pruned by scripts/openclaw-sync.py.
        "attachments": {"ttlHours": 168},
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
                # Registered once the model takes images, and both declare
                # `exclusiveMinimum`, which agentgateway hands to Gemini as is:
                # every request then failed with 400 "Unknown name
                # exclusiveMinimum" (measured). A photo or PDF sent in the
                # conversation is still read without them.
                "view_image",
                "pdf",
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
            # document-extract is what reads a PDF, sent in a chat or through
            # the pdf tool: the extractor lookup is filtered by this list, so
            # without it a PDF reaches the model as an unreadable attachment.
            # nextcloud is this stack's own (config/openclaw/plugins/nextcloud):
            # each person's agent finds, reads and saves files in that person's
            # Nextcloud, with an app password picked by agent id in its code.
            "allow": ["matrix", "memory-core", "searxng", "document-extract", "nextcloud"],
            "load": {"paths": [f"{HOUSEHOLD_PLUGINS}/nextcloud"]},
            "entries": {
                # By container name, on the internal `assistant` network.
                "nextcloud": {
                    "enabled": True,
                    "config": {
                        "baseUrl": "http://nextcloud",
                        "tokenDir": NEXTCLOUD_TOKENS,
                        "accounts": {person["agent"]: person["email"] for person in people if person.get("email")},
                    },
                },
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
                # policies below then drop whatever is not an allowed DM or
                # the family room.
                "autoJoin": "always",
                "joinIntro": False,
                **rooms_for(people, server_name, family_room),
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
    family_room = read_family_room(data_dir)
    rendered = json.dumps(render_config(people, host_name, timezone, family_room), indent=2) + "\n"
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
    ensure_nextcloud_token_dir(data_dir)


def ensure_nextcloud_token_dir(data_dir):
    """Created before compose mounts it - Docker would create a missing source
    as root - and handed to the container's uid after fix_ownership, which
    gives everything here to the project's owner."""
    token_dir = data_dir / "secrets" / "nextcloud"
    token_dir.mkdir(parents=True, exist_ok=True)
    safe_chmod(0o700, token_dir.parent)
    safe_chmod(0o700, token_dir)
    for path in [token_dir, *token_dir.iterdir()]:
        try:
            os.chown(path, CONTAINER_UID, CONTAINER_UID)
        except OSError:
            log(f"WARNING: could not chown {path} to {CONTAINER_UID}; the gateway cannot read it")
            return


if __name__ == "__main__":
    main()
