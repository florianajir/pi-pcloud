# Local AI

Open WebUI at `https://ai.<HOST_NAME>` is a full chat assistant running entirely on the Pi's CPU: text, images and audio in, speech out, plus a tool that lets the model report the machine's own health.

The two hostnames say who they are for: `ai.` is the human UI, `llm.` is the gateway clients POST to.
`chat.<HOST_NAME>` is not the AI's: it is the Matrix chat (Tuwunel + Element, see
[Architecture](ARCHITECTURE.md#what-each-service-is-for)), where the assistant
[below](#the-family-assistant-openclaw) is one more account.

| Piece | Role | Network |
|-------|------|---------|
| `open-webui` | Chat frontend, OIDC-authenticated | `frontend`, `ai` |
| `agentgateway` | LLM and MCP gateway: one OpenAI-compatible endpoint, one MCP endpoint, virtual keys | `frontend`, `ai` |
| `llama-cpp` | Inference server (OpenAI-compatible API) | `ai` |
| `piper` | Text-to-speech | `ai` |
| `parakeet` | Speech-to-text | `ai` |
| `system-tools` | OpenAPI tool server answering questions about the host | `ai`, `frontend` |
| `searxng` | Metasearch engine behind the chat's web search | `ai`, `frontend` |
| `openclaw` | The family assistant, `@assistant` in the Matrix chat — [below](#the-family-assistant-openclaw) | `ai`, `assistant` |

Everything without `frontend` sits on the internal `ai` network with no route to the internet.

Chat traffic runs `open-webui → agentgateway → llama-cpp`. `piper` and `parakeet` are called directly:
they are not chat completions, and the gateway would only add a hop.

## The model

`llama-cpp` serves **Gemma 4 E2B** (Google's QAT Q4_0 build — text, image and audio in). There is no Ollama in the stack: llama.cpp is the engine Ollama wraps, and running it directly is faster on ARM CPU and one process instead of two.

On a Raspberry Pi 5 (16 GB, 3 threads pinned to cores 1–3): **~10 tok/s generation, ~40 tok/s prompt processing, ~3.7 GB resident**. A short question answers in about 3 seconds end to end.

### Why the defaults look aggressive

Latency comes from prompt size, not the model. Three defaults exist purely because ~40 tok/s of prompt processing punishes anything verbose:

- **Thinking is off** (`LLAMA_ARG_CHAT_TEMPLATE_KWARGS`). Gemma 4 otherwise spends ~500 tokens reasoning before the first visible word — over a minute of empty chat window for "how are you".
- **One server slot** (`LLAMA_ARG_N_PARALLEL=1`). llama-server defaults to several and runs them concurrently, so two requests each generate at ~5 tok/s instead of one at ~10. Queueing is faster than sharing three threads.
- **Open WebUI's built-in tools are off for every model, bar web search**, along with title, tag, follow-up and search-query generation. The built-in tools (time, memory, chats, notes, knowledge, channels) inject ~5000 tokens of schemas into every message — roughly three minutes of prompt processing before the model starts. Web search is the exception because the composer's toggle does nothing without it — see [Web search](#web-search-searxng) — and its two schemas are injected only while that toggle is on. The other four are invisible extra LLM calls per message.

All are re-enablable in **Admin Settings** and in the model's own **Capabilities**.

### Tuning knobs

All `environment:` entries on the `llama-cpp` service:

| Variable | Default here | Notes |
|----------|--------------|-------|
| `LLAMA_ARG_CTX_SIZE` | `16384` | Context window. The model supports 128k; RAM and prompt-processing time do not. |
| `LLAMA_ARG_CHAT_TEMPLATE_KWARGS` | `{"enable_thinking":false}` | Thinking off. Drop the line to restore it — `--reasoning-budget 0` is *not* equivalent: it closes the channel without telling the model, which then reasons in the visible answer. |
| `LLAMA_ARG_N_PARALLEL` | `1` | One server slot; concurrent requests queue instead of splitting the three threads. |
| `LLAMA_ARG_THREADS` | `3` | Matched to `cpuset: "1-3"`, leaving core 0 for Traefik and DNS. Generation is memory-bandwidth bound, so a fourth thread is no faster. |
| `LLAMA_ARG_SPEC_TYPE` | `draft-mtp` | Speculative decoding via Gemma 4's multi-token-prediction head; roughly doubles generation speed. Remove it and `LLAMA_ARG_SPEC_DRAFT_MODEL` to disable. |
| `LLAMA_ARG_MMPROJ` | *unset* | Vision/audio input, off because it costs about 1 GB resident for a capability Open WebUI does not offer on this model, and because the multimodal path disables `--cache-reuse`. Point it at `/models/mmproj-gemma-4-E2B-it.gguf` — already in the volume — to turn image input on. |

### Where the weights live

`scripts/llama-cpp-pre-start.sh` downloads them into the `llama_models` Docker volume (a named volume, not under `DATA_LOCATION`) before the stack starts, because the `ai` network is internal and the container cannot reach HuggingFace itself. It is idempotent — it only re-downloads a file whose size does not match the remote one. To re-check by hand:

```bash
sh scripts/llama-cpp-pre-start.sh
```

### Changing the model

Edit the `DOWNLOADS` list in `config/llama-cpp/fetch-models.sh`, then point `LLAMA_ARG_MODEL` (and `LLAMA_ARG_MMPROJ` / `LLAMA_ARG_SPEC_DRAFT_MODEL`, or drop them) at the new files in `compose/compose-ai.yaml`. Prefer `Q4_0` quantisations: llama.cpp repacks those into the ARM i8mm/dotprod kernels the Pi 5 has. Anything much past ~4B parameters is too slow to chat with on CPU.

## The gateway (Agentgateway)

`https://llm.<HOST_NAME>` is [agentgateway](https://agentgateway.dev), a Rust data plane that serves
three things on one port: an OpenAI-compatible `/v1` in front of `llama-cpp`, an MCP endpoint at `/mcp`
that federates tool servers, and the UI at `/ui` that configures both.

It exists so there is exactly one endpoint per protocol in the stack: Open WebUI, your editor, n8n and
any script all call the same `/v1`, one MCP client configuration covers every tool server, and adding a
second model — another local one, or a cloud provider — is a row in its database rather than an
environment change in every client.

What it buys over calling `llama-cpp:8080/v1` directly:

- **Virtual keys.** Each caller gets its own `sk-…`, revocable on its own without touching anyone else's.
- **Token rate limits per key**, which is what keeps a free-tier provider's daily quota intact.
- **One place for provider credentials**, rather than an environment variable in every client.
- **Providers beyond the local one.** Anything OpenAI-compatible is a `custom` provider with a `baseUrl`
  — z.ai, Groq, DeepSeek, OpenRouter, Together — and OpenAI, Anthropic, Gemini, Vertex, Bedrock and
  Azure have native ones.

### Configuration is split in two on purpose

`config/agentgateway/config.yaml` is mounted read-only and is the baseline: the gateway, the three
capabilities, the API-key policies, the local model and the OIDC policy. `config.storage.mode: hybrid`
sends the *resources* the UI writes — providers, models, virtual models, MCP targets, routes, policies —
to a SQLite database under `${DATA_LOCATION}/agentgateway` instead, where they are merged over that
baseline at read time. In the default `file` mode even those saves would fail against a read-only mount.

The `llm:` section carries only what has to exist before anyone can log in: `gemma-4-e2b-it` at
`http://llama-cpp:8080/v1`, as a `custom` (OpenAI-compatible) provider, and the keys its callers
present.

**The UI cannot create a top-level section.** In hybrid mode a write to one is refused client-side with
`File configuration is read-only in hybrid mode` — upstream's design, not a misconfiguration: the
database holds the resources *within* a section, and only `file` mode lets the UI create a section. The
welcome wizard's *Enable LLM* and *Enable MCP* chips are such a write, and send no request at all, so the
error looks like a broken deployment. That is why `llm` and `mcp` are declared in the file: the UI reads
"enabled" off their presence alone. Targets and models added afterwards save normally. Do not make the
file writable to get the wizard working — agentgateway expands its `${…}` references at read time, so it
would write the resolved OIDC client secret back in cleartext and drop every comment.

SQLite rather than the shared Postgres because the same database also takes a row per proxied request,
and every service in the stack waits on that Postgres. `scripts/sqlite-backup.sh` copies it consistently
into the nightly snapshot.

### Three surfaces, three different gates

They share port 4000 and the `llm.<HOST_NAME>` router, and Traefik carries only the LAN allowlist, so
each surface has to gate itself:

| Surface | Gated by | Effect |
|---------|----------|--------|
| `/ui` | `ui.policies.oidc` | Authelia, `admin_only` — the `admin` group with 2FA |
| `/v1` | `llm.policies.apiKey`, `mode: strict` | 401 without a key |
| `/groq/v1`, `/openrouter/v1` | each route's own `policies.apiKey` | 401 without a key |
| `/assistant/v1` | its own `policies.apiKey`, OpenClaw's key alone | 401 for every other key, Open WebUI's included |
| `/mcp` | `mcp.policies.apiKey`, `mode: strict` | 401 without a key — a *different* key from `/v1`'s |

The path routes repeat the `/v1` policy rather than inheriting it: `llm.policies.apiKey` is attached to
the `llm:` section and does not cover a top-level route. Drop that block from a path route and the
provider behind it is reachable with no credential by anything that clears the LAN allowlist.

`/mcp` has its own policy for the same reason, with its own key: whoever holds it reads and writes every
note through the [Trilium target](#trilium-on-both-sides-of-the-gateway), which is not what a `/v1` key
is for. An MCP target added through the UI is served with no policy of its own until one is attached to
it; `jwtAuth` and `basicAuth` work there too.

The gateway runs the OIDC flow itself against the `agentgateway` Authelia client — authorization code
with PKCE, callback `https://llm.<HOST_NAME>/oauth/callback`. A forward-auth in front of it would
intercept that callback, which is why there is none. **That gates the UI, and only the UI** — the split worth keeping: an admin configures models, providers and credentials through
the browser, everyone else consumes with a key, and no API client could complete an interactive login
anyway.

A signed-out visit lands on the gateway's own page, `/ui/login`, whose button starts the Authelia flow;
a request from the console's JavaScript gets a `401` rather than a redirect. Signing out clears the
gateway's session cookie only: the Authelia session survives it, so the next sign-in does not ask for a
password again.

The MCP Authorization spec's own flow (`mcpAuthentication`) is not wired. As written it expects the
identity provider to support Dynamic Client Registration, and Authelia does not — its discovery document
publishes no `registration_endpoint`. Setting `clientId` and `clientSecret` on the policy short-circuits
registration with a client declared in `config/authelia/configuration.yml.template`, which is the way in
if you want it; every MCP client then shares that one registration.

### Trilium, on both sides of the gateway

Trilium is a consumer of the LLM API *and* a target on the MCP one, and neither side is configurable
from the environment: `aiEnabled`, `mcpEnabled` and `llmProviders` are options in Trilium's own
database, writable only through a private endpoint that wants a session cookie **and** a CSRF token. No
script can open such a session once SSO is enrolled ([Security](SECURITY.md#triliums-sso-has-to-be-enrolled-by-hand-once)),
so `scripts/trilium-bootstrap.sh` does it on a fresh install, before enrolment:

1. creates the initial document, without the *Trilium Demo* tree (the built-in help subtree stays), and
   sets the owner password to `${PASSWORD}`, claiming the instance
2. opens a session and reads its CSRF token
3. writes `aiEnabled`, `mcpEnabled` and an `llmProviders` entry pointing at `http://agentgateway:4000/v1`
   with `${TRILIUM_LLM_KEY}` — provider type `openai-compatible`, whose `baseURL` is honoured, rather
   than `openai`, which talks to api.openai.com whatever you set
4. mints an ETAPI token for agentgateway's MCP target

These are private endpoints, not a published API, so an image bump can break them; check a candidate
image with `tests/trilium-api-contract.sh` first, as [CONTRIBUTING](../CONTRIBUTING.md) describes.

Step 4 is the only one that still works after enrolment: that route verifies the password itself
instead of deferring to Authelia.

**On an instance whose password this stack did not set, all of it declines.** The hook is not a repair
tool: it writes nothing it cannot verify, and an owner who chose their own password in the setup wizard
keeps it. Then the manual equivalents are Trilium's *Options → AI* for the provider and the MCP toggle,
and *Options → ETAPI* for the token, which goes in `${DATA_LOCATION}/agentgateway/secrets/trilium_etapi_token`,
beside agentgateway's own keys — `agentgateway-pre-start.sh` reads it from there on the next run.
Not under Trilium's data directory, which that container `chown -R`'s to uid 1000 on every start.

That token expands into the MCP target's `Authorization` header, and it must never be empty: an unset
reference leaves a null where agentgateway wants a string, and it refuses the whole `mcp:` section at
startup — the gateway goes down, not just the target. Hence the `pending-trilium-bootstrap`
placeholder, which Trilium simply answers 401 to. For the same class of reason the section carries
`failureMode: failOpen`: `trilium` is an optional profile, and a target that cannot initialize should
not take `/mcp` down with it.

### The key that is not `PASSWORD`

`scripts/agentgateway-pre-start.sh` generates `${DATA_LOCATION}/agentgateway/secrets/llm_api_key` on
first start, and `rotate-password.sh` deliberately leaves it alone: `/v1` carries no forward-auth, so
deriving it from `PASSWORD` would make a `PASSWORD` leak a free pass to the models. It also has to
outlive a rotation: `OPENAI_API_KEY` is PersistentConfig in Open WebUI, so the value that container
starts with is copied into its database. The gateway's own policy and Open WebUI's entrypoint read the
same file, so the caller and the gateway cannot drift apart.

`agent_api_key` is generated the same way, for tools running on other machines, so revoking one does not
lock the other out; `mcp_api_key` is the `/mcp` key. The stored values carry no prefix — the `sk-`
belongs to the credential:

```bash
make api-keys   # the client tokens, with the base URL each one opens
```

None of them is settable from `.env`, and none can be a key you created in the UI: a route declared in
`config.yaml` cannot reference one held in the database. The UI's own keys still work on `/v1`, the
surface the UI manages. Every gateway secret, and what each one protects, is listed under
[Security](SECURITY.md).

Provider credentials added through the UI are stored by agentgateway in the SQLite database, which
Backrest snapshots whole.

### Calling it from outside

```bash
curl -sS https://llm.<HOST_NAME>/v1/chat/completions \
  -H "Authorization: Bearer sk-<your-key>" \
  -H 'Content-Type: application/json' \
  -d '{"model": "gemma-4-e2b-it", "messages": [{"role": "user", "content": "hello"}]}'
```

`GET /v1/models` lists what the gateway serves, which is what Open WebUI's picker reads. A model
declared `visibility: internal` is reachable only as a virtual model's target and stays out of that
list. The route is LAN-and-tailnet only like everything else, so this works from your devices, not from
the internet.

### Turning the built-in tools off, once, for everything

The built-in tools cost ~5000 prompt tokens per message, so `scripts/open-webui-bootstrap.sh` turns
them off in `models.default_metadata`, which Open WebUI applies to every model that has no workspace row
of its own (a row overrides it). One `config` row therefore covers everything the path routes list, and
keeps covering it as those catalogues change. Being a `config` row it also needs no admin account, so it
applies from the first boot rather than the first SSO login.

What the row holds is not the master switch but a category map, because the master switch takes web
search down with it: `capabilities.builtin_tools` stays `true`, and `meta.builtinTools` —
`BUILTIN_TOOLS_MAP` in the hook — turns off every category except `web_search`. Every category defaults
to on upstream, so the map is a deny list that has to stay complete when a release adds one. Nothing is
injected while the chat's web search toggle is off.

Open WebUI reads **none** of the capability metadata providers publish — no `input_modalities`, no
`supported_features` — so `vision` cannot switch itself on for the models that have it, and a
transcription model is still offered as a chat model.

### Adding a provider

Anything OpenAI-compatible is a `custom` provider: a `baseUrl` and a `model`, added under **Models** in
the UI. It lands in SQLite — no file edit and no restart. Pair a free-tier provider with a token rate
limit: free tiers are quota'd per day, and a runaway agent loop is exactly what exhausts one.

### …and why Groq and OpenRouter are not

They sit on their own paths, `/groq/v1` and `/openrouter/v1`, as top-level `routes:` in `config.yaml`.
The reason is `GET /v1/models`. A provider added through the UI is reached by *model name*, so
`/v1/models` lists only what the gateway already knows: a wildcard entry expands from its built-in model
catalogue, which yields nothing usable for these two. A tool that builds its picker from that endpoint
would see nothing to pick.

A top-level route serves the real catalogue, because `policies.ai.routes` maps a URL suffix to a
handler: `/chat/completions` stays `completions`, so tokenisation and budgets still apply, while
`/models` is `passthrough` and answers with the provider's own list.

The provider keys, `GROQ_API_KEY` and `OPENROUTER_API_KEY`, come from `.env` and stay in the gateway: a
client presents only its gateway key (`make api-keys`). `/openrouter/v1` sends `max_tokens: 8192` when
the caller names none (a caller's own value still wins): OpenRouter otherwise reserves the model's whole
context window against the account's credit, and a credit-limited account refuses that with a 402.

The cost: these routes are invisible to the UI, which lists only `llm.provider` and `llm.model`
resources. A third provider this way is a file edit and a `docker compose up -d agentgateway`, not a
form. Use the UI when you are willing to name the models by hand, a path route when the client needs to
discover them.

### Two things that will bite you

- **The image is distroless.** It contains `/app/agentgateway`, `ld.so` and a CA bundle — no shell, no
  curl. That is why the service declares no healthcheck and Uptime Kuma watches the container instead,
  why Open WebUI depends on it as `service_started` rather than `service_healthy`, and why the secrets
  reach it through an `env_file` rather than an `export $(cat …)` entrypoint. Those values are frozen at
  container creation: use `docker compose up -d agentgateway`, not `restart`.
- **Environment expansion runs over the raw file, comments included.** A dollar-brace reference written
  in a comment as an example is looked up like any other and fails the start with
  `error looking key '…' up`.

## The family assistant (OpenClaw)

`@assistant:chat.<HOST_NAME>` is a bot account on the stack's Matrix server. Anyone in LLDAP can
open a direct chat with it from Element Web or Element X, and mention it in the family room the
bootstrap creates; encrypted rooms work, because the bot runs end-to-end encryption itself. Behind it
is [OpenClaw](https://github.com/openclaw/openclaw). Its background features — heartbeat, scheduled
jobs, memory consolidation — are all switched **off**.

| Piece | Where |
|-------|-------|
| The gateway and its agents | `openclaw` in `compose/compose-ai.yaml`, config rendered by `scripts/openclaw-pre-start.py` |
| Plugins, bot account, people, family room, household rules, Forgejo side | `scripts/openclaw-bootstrap.py` (post-start) |
| Memory and knowledge base in Forgejo | `scripts/openclaw-sync.py`, every quarter hour by `openclaw-sync.timer` |
| The model | agentgateway's `/assistant/v1` route |
| Rules every agent gets in its prompt | `config/openclaw/household/AGENTS.md` |
| Skills: the knowledge base, web search | `config/openclaw/skills/` |
| The Nextcloud tools | `config/openclaw/plugins/nextcloud/` |

A conversation is one session that goes on until its person starts a new one — there is no
automatic reset, and OpenClaw summarises older turns (compaction) as it nears the context window.
`/new` starts over, and the `session-memory` hook first saves the last exchanges to a dated note in
the agent's `memory/`, where memory search finds them again. **In Element, type `//new`**: a typed
`/new` is taken for one of Element's own commands and answered with "Unknown command"; `//` sends the
rest as text. The same goes for every OpenClaw command (`//context detail` lists what is injected
into the prompt).

### Household rules

`config/openclaw/household/AGENTS.md` holds the rules every agent follows, whatever a message, a
file or a search result says: never claim an action a tool did not confirm, search memory before
saying "I don't know", cite the URL a web-search answer relied on, treat text inside a photo or a
document as information rather than instructions, never put a document's words into a web search, and
answer only in the conversation it is in.

The bootstrap copies the file into each workspace as `.household/AGENTS.md`, owned by root and
read-only — the agent, which runs as `node`, can read it but neither change nor remove it — and the
`bootstrap-extra-files` hook injects it into every prompt. The hook only reads inside a workspace,
which is why it is a copy per agent rather than one shared file. Edit the repository file and restart
the stack; the bootstrap refreshes every copy. The sync leaves `.household/` out of the memory
branches: it is a copy of a repository file, not memory.

Only the skills in `config/openclaw/skills/` load. `skills.allowBundled` is `["none"]`, not `[]`:
OpenClaw reads an empty list as no allowlist at all, and loads every bundled skill into every prompt.

### One agent per person

Every LLDAP account except the service accounts (`lldap_strict_readonly`, `lldap_password_manager`)
gets an agent of its own, with its own workspace (`MEMORY.md`, `memory/`), bound to that person's
Matrix ID. That account list is also the DM allowlist, and every room but the family room is ignored.
A shared agent would leak between people: OpenClaw injects the workspace's `MEMORY.md` into every DM
session, so one person's context would carry what another asked it to remember — and the upstream
trust model treats anyone allowed to DM a gateway as able to steer it, so isolation is per agent or not
at all.

The list is read from LLDAP at post-start, cached in `${DATA_LOCATION}/openclaw/people.json`, and the
gateway is restarted when it changes. A new user therefore gets an assistant at the next
`make update` or reboot, not the moment their account exists. An agent id keeps only `a-z`, `0-9`,
`_` and `-`, so two uids that reduce to the same one (`jean.dupont`, `jean_dupont`) would share a
workspace: the second in alphabetical order is left out, with a warning in the bootstrap's log.

### The family room

Next to the DMs, the bootstrap creates one encrypted room, **Family**, bound to an agent of its own
(`family`). What is said in a room is shared by nature, so that agent's workspace is the room's shared
memory, separate from every person's. Members can rename the room; the bootstrap only reads its ID.

- **Created by the bot**, at the first start with a people list, and recorded in
  `${DATA_LOCATION}/openclaw/family-room.json`: the binding needs the literal room ID, an alias does
  not match. Room version 11, not Tuwunel's default 12, where the creator — the bot — would hold
  unlimited power nobody can take back. Everyone who joins is an administrator (`users_default:
  100`), and the bot lowers itself to an ordinary member that may still pin, so the delete action the
  Matrix plugin gives the agent cannot redact another member's message, and the bot cannot rename the
  room.
- **Invites.** A Matrix account only exists after its owner's first SSO sign-in, so each person is
  invited at the first start after that; a member can invite them straight away from Element. Someone
  who leaves is not invited back.
- **Only when mentioned.** OpenClaw answers every room message it accepts, and its Matrix plugin has
  no listening-only mode, so without a mention each message would be a model turn and a reply. A turn
  starts on Element's mention pill (type `@Ass` and pick it), on a message that *starts* with
  "Assistant", and on `@room` — an announcement to everyone wakes it too. A reply to one of its
  messages is not a mention. The last 20 unmentioned messages go along with the next mention
  (`historyLimit`), so "what do you think?" has something to refer to; they cost no request, and are
  kept in memory only, so a restart drops them.
- **Who.** The room's `users` list is the LLDAP accounts, and it is also what lets them run commands
  there (`//new`, `//context detail`): with no list, anyone in the room could talk to the agent and
  nobody could reset it. The room has one session, shared by everyone in it, and anyone listed can
  reset it.
- **Memory.** OpenClaw never injects `MEMORY.md` into a room session, a privacy filter no hook can
  lift. The room's instructions (`systemPrompt` in its `groups` entry, read-only config) have the
  agent keep lasting facts about the household in `USER.md`, which is injected, and other notes in
  `memory/`, which it searches. Its workspace is synced to the `family` branch of `assistant-memory`,
  and its knowledge proposals arrive as pull requests like anyone's.
- **Read by the private agents, never the reverse.** Each person's agent finds what the family agent
  remembers through memory search: `MEMORY.md`, `USER.md` and `memory/` of the family workspace are
  extra paths, outside its own workspace, so it cannot write them. That is a path for planted text: a
  note the family agent wrote from a search result can reach a private agent's context when that
  agent searches. The family agent sees no DM.
- **Tools** are the private agents'. `crossContext` keeps its replies in the room.

### Isolated rather than sandboxed

OpenClaw's own sandbox runs tools in sibling containers through a container-engine socket (Docker,
Podman), or on a separate host over SSH. Neither belongs here, so the boundary is drawn the other way:

- **No tool that executes, browses or fetches.** `tools.deny` removes the runtime, browser,
  automation and node groups, and `web_fetch` and `x_search`; `exec` is `deny`; the file tools are
  confined to the agent's own workspace. What is left is reading and writing its notes, memory
  search, `web_search`, reading its own past sessions, and the reply; photos and PDFs it is sent
  arrive with the message.
- **No tool that reaches another agent.** The other agents belong to other people, so
  `sessions_spawn`, `sessions_send` and `agents_list` are denied, along with tools that do nothing in a
  DM but cost prompt tokens (`conversations_*`, `subagents`, `agents_wait`, `sessions_yield`,
  `presence`). What a generalist assistant uses stays: `skill_workshop` (teach it a procedure, kept as
  a skill), goals, `ask_user`, and its own sessions.
- **No route out.** The container sits on `ai` (agentgateway, SearXNG) and `assistant` (Tuwunel,
  Forgejo, Nextcloud), both internal. A prompt injection has nowhere to send what it finds.
- **Replies stay in their conversation.** `tools.message.crossContext` defaults to letting the
  message tool post into *any* conversation of the same channel; both of its switches are off, so an
  agent cannot write into another person's DM, whatever it was told to.
- **A config the agent cannot change.** The JSON is mounted read-only with `OPENCLAW_CONFIG_READONLY`,
  which closes the "model edits its own config" class of advisory.
- **No inbound surface.** The gateway binds loopback inside its container, behind a token, with the
  Control UI and the terminal off. There is no Traefik router.

The image's own entrypoint is bypassed: it runs `openclaw doctor --fix` before every start, which
refreshes plugins from npm, and which exits 1 against a read-only config. The bootstrap installs the
Matrix and SearXNG plugins instead, pinned to the image's version, from a throwaway container — the
only moment anything of this service reaches the internet — together with the native crypto binding
the Matrix plugin would otherwise download at runtime.

### Web search, and prompt injection

The assistant searches the web through the stack's own SearXNG, with OpenClaw's built-in
`web_search` and its `searxng` provider — not an MCP server. The difference is what reaches the
model, and what can leave:

- **Snippets, not pages.** `web_search` returns a title, a URL and a short snippet per result. Each
  piece is wrapped by OpenClaw's core in an `EXTERNAL_UNTRUSTED_CONTENT` envelope with a random id, so
  a result cannot close the envelope and pass for instructions. `mcp-searxng` also ships
  `web_url_read`, which puts whole pages in the context and fetches any URL — a request that can carry
  private data out in its query string. `web_fetch` stays denied for the same reason.
- **The gateway still has no route out.** SearXNG makes the outbound requests; OpenClaw only reaches
  it on `ai`. A query is the one thing that leaves, and it goes to the search engines SearXNG asks,
  not to whoever wrote a page.

What an instruction planted in a result can still do, since the model will sometimes follow one:
mislead the reply or suggest a link — nothing leaves unless it is clicked, Tuwunel generates no URL
preview with its empty allowlists, and the DMs are encrypted — or write a false note into that one
person's memory. The sync commits every memory change to Forgejo (`assistant-memory`) within a
quarter of an hour, where it is visible and revertible. That is also why dreaming (OpenClaw's memory
consolidation) stays off: it would consolidate such a note into `MEMORY.md`.

### Photos and documents

The model entry accepts images, so a photo sent in a DM or the family room goes to Gemini with the
message: agentgateway translates OpenAI's `image_url` into Gemini's format, at about 1,100 input
tokens per image. A PDF is read by OpenClaw's bundled `document-extract` plugin, which has to be in
`plugins.allow`: the extractor lookup is filtered by that list, so without it a PDF reaches the model
as an unreadable attachment.

- **No extra request for an attached PDF.** Its text is extracted locally and wrapped as untrusted
  content, with OpenClaw's defaults: 20 MB, 20 pages, 60,000 characters. A page with under 200
  characters of text — a scan — is rendered to an image for the model instead. On the Pi a 20-page
  PDF takes about 0.3 s and 120 MiB.
- **`view_image` and `pdf` are denied, by necessity.** OpenClaw registers them once the model takes
  images, to look at an earlier attachment again. Both declare `exclusiveMinimum` in their parameters,
  which agentgateway passes to Gemini as is, and Gemini rejects: with either tool present, every
  request to every agent fails with `400 Invalid JSON payload … Unknown name "exclusiveMinimum"`. The
  cost: OpenClaw drops image data from the history after three turns, and the agent cannot look again.
- **Kept a week, both copies.** OpenClaw keeps each attachment twice: in its media directory, pruned
  by `attachments.ttlHours: 168` (the most it allows), and in the receiving agent's workspace
  (`media/inbound/openclaw-staged-*`), which that setting does not touch and `openclaw-sync.py` prunes
  after a week. Neither copy reaches Forgejo: the sync excludes `media/` from the memory branches.
- **Text in an image is not wrapped.** Search results and extracted PDF text arrive inside the
  untrusted-content envelope; words written in a photo or a screenshot reach the model as part of the
  image. A household rule says such text is information, never instructions, and the boundaries
  above hold whatever the model makes of it: no route out, replies confined to their conversation.

### Nextcloud

Each person's agent can find, read and save files in that person's own Nextcloud, through a plugin
of this stack's own (`config/openclaw/plugins/nextcloud`) with four tools:

| Tool | What it does |
|------|--------------|
| `nextcloud_search` | Files and folders whose path holds every word asked for. Nextcloud matches file names only, not the text inside documents (there is no full-text search app), so each word is searched on its own and the folder path counts too |
| `nextcloud_list` | One folder's content |
| `nextcloud_fetch` | A file's text (PDF, text files) or the image itself, wrapped as untrusted content like a web result, and a copy in the workspace that the message tool can send to the person |
| `nextcloud_save` | A file from the workspace — an attachment as it arrived, or a note the agent wrote — into any folder, creating the missing ones. An existing file is never replaced: the new one gets a number (`Spec (2).pdf`). Nothing is ever deleted, moved or shared. Only a file inside the workspace can be saved, and no tool accepts a Nextcloud path containing `..` |

- **As that person, and only that person.** The bootstrap mints an app password per person with
  `occ user:auth-tokens:add`, named "Family assistant (OpenClaw)": it shows in their Nextcloud
  security settings, where they can revoke it. The plugin picks it by the calling agent's id, in its
  code — never from what the model says — so one person's agent cannot reach another's files. The
  passwords sit in `${DATA_LOCATION}/openclaw/secrets/nextcloud/`, mounted into the gateway outside every
  workspace. A Nextcloud account only exists after its owner's first sign-in; until then that person's
  agent simply has no Nextcloud tool, and gets one at the next start. The family room's agent has none.
- **By name, on `assistant`.** Nextcloud joins that internal network; the gateway still has no route
  out. `http://nextcloud` passes Nextcloud's trusted-domain check because `OVERWRITEHOST` applies to
  every request.
- **What it exposes.** The agent holds a person's whole Nextcloud next to untrusted content — web
  results, the documents themselves, photos. The one way out left is a web search: the query goes to
  the search engines SearXNG asks, so an instruction planted somewhere could have the agent search with
  a document's words. A household rule forbids it; it is a rule, not a guarantee. Writing can at worst
  leave unwanted files, never lose one.
- **Fetched copies** go to `media/nextcloud/` in the workspace: kept out of Forgejo with the rest of
  `media/`, and pruned after a week by `openclaw-sync.py`.
- **Tied to the image.** The plugin imports three modules by absolute path from the OpenClaw image —
  linkedom for WebDAV's XML, OpenClaw's untrusted-content envelope and its PDF extractor. An image bump
  that moves one makes that tool fail with an error, not the gateway; check the plugin after a bump.

### The model behind `assistant`

OpenClaw asks agentgateway for a model called `assistant`, on `/assistant/v1`. That route accepts
OpenClaw's key and no other, and each provider behind it names its own model, so changing the chain
is an edit to that one block of `config/agentgateway/config.yaml` and a `docker compose up -d
agentgateway` — nothing in OpenClaw changes. It is a route rather than an `llm:` virtual model because
every `llm:` model shows up on `/v1/models`, so Open WebUI would offer it to every user.

It serves `gemini-3.5-flash-lite` first, on Gemini's free tier, with `GEMINI_API_KEY` from `.env`.
Whether free-tier prompts may be used to improve Google's products depends on your region; check the
Gemini API terms before relying on it.

- **A turn is not the message.** It is OpenClaw's instructions, the tool schemas and the injected
  workspace files, about 9,900 tokens before anyone has said anything. A provider whose free tier
  caps tokens per minute below that answers the very first request with `413 Request too large`, which
  OpenClaw reports as a context overflow.
- **The `gemini` provider, not `custom` on Google's OpenAI-compatible endpoint.** Gemini 3 refuses the
  second step of a tool loop with `400 Function call is missing a thought_signature` unless the
  signature it attached to the call comes back. The native provider carries it inside the `tool_call`
  id, which OpenClaw echoes back within a turn; through the OpenAI-compatible endpoint it is lost, and
  every tool loop fails on its second step.
- **Flash-Lite, not Flash.** One message costs OpenClaw five to seven requests — its tool loop — so the
  free tier's per-minute and per-day *request* quotas are the limits that matter, which is why the chain
  uses Flash-Lite models rather than Flash. The quotas are per model and per project, listed on AI
  Studio's rate-limit page, and Google changes them.
- **A 64k context window, declared on purpose.** OpenClaw's model entry says `contextWindow: 65536`,
  far below what Flash-Lite takes, because compaction keeps a session under three quarters of it
  (its reserve is capped at 25%), and so it bounds every request: a tool loop at that size stays within
  the free tier's tokens-per-minute quota, where a 128k window would not over a long session — and the
  family room's session is shared and never resets by itself. Smaller is no better: a session reaches
  about 22k tokens after a few searches, so it would compact every few turns, and each compaction is a
  request.

**Failover.** The backend is three priority groups — `gemini-3.5-flash-lite`, `gemini-3.1-flash-lite`,
then `openai/gpt-oss-120b` on OpenRouter. A 429 (quota) or 503 (overload) evicts that group for 10
minutes, and the route's `retry` replays the request on the next one, so the message that runs out a
quota is still answered, and the next one goes straight to the next group.

- An exhausted provider is tried **twice** in that first request before its eviction takes hold —
  hence `attempts: 6`, two per Gemini group plus OpenRouter plus one spare.
- The two Flash-Lite models have separate quotas, and a switch between them mid tool loop is safe,
  since one accepts the other's signature.
- `gpt-oss-120b` accepts Gemini's tool_call ids, in a running loop and in history.

The one gap is the way back: when a Gemini group returns from eviction in the middle of a tool loop that
started on OpenRouter, Gemini refuses the OpenRouter call it finds in the current turn — it carries no
signature — and that one message ends in an error. A quota exhausted for the day cannot cause it: the
returning group answers 429 again before anything is processed.

OpenRouter is paid from the account's credit, and only reached while both Gemini groups are evicted.
Zero Data Retention is not set here: enable it in the OpenRouter account's privacy settings, where it
limits every OpenRouter request, this route's and the `/openrouter/v1` one's, to providers that keep no
prompt. The same `max_tokens: 8192` default as [the `/openrouter/v1` route](#and-why-groq-and-openrouter-are-not)
applies.

### Memory and knowledge in Forgejo

When Forgejo runs, the bootstrap creates a local, *restricted* user `assistant` and two private
repositories owned by the stack owner — `ADMIN_USER` if that account exists in Forgejo, otherwise the
one Forgejo administrator — with the bot as a write collaborator on both and on nothing else:

- **`assistant-memory`**: each person's workspace on its own branch, and the family room agent's on
  `family`, committed and pushed directly.
  Every branch is protected against force-push, so an agent's history cannot be rewritten away.
  Edits the owner makes on a person's branch are merged back at the next sync, and win where both
  sides changed the same lines.
- **`knowledge`**: the curated knowledge base. `main` takes pushes from the owner and nothing else,
  and needs one approval. A read-only export sits beside the workspaces, where every agent's memory
  search indexes it. An agent proposes a change by writing files under `knowledge-proposals/` in its
  workspace; the sync turns that into one pull request per person (an AGit push to `refs/for/main`,
  updated in place while it is open), and empties the folder once the pull request is merged or closed.

All of that is `scripts/openclaw-sync.py`, never the agent: the Forgejo token is mounted into nothing
but the throwaway container the timer starts, its git directories live outside the workspaces, and its
git runs with hooks disabled, so nothing an agent writes is ever executed. Until Forgejo runs, the
memory simply stays in the `openclaw_state` volume, which Backrest snapshots either way.

### Operating it

- **The bot account** is created through Tuwunel's shared-secret endpoint, with the password
  `OPENCLAW_MATRIX_PASSWORD` in `config/openclaw/openclaw.env`. If that file is lost, the account
  still exists but no longer accepts the new password, and the bootstrap stops with a message saying
  so. Reset the password from Tuwunel's admin room (`!admin users reset-password assistant`), put it
  in that variable, and `docker compose up -d openclaw` — an `env_file` is read at container creation.
- **Encryption**: the bootstrap creates a server-side room-key backup for the bot's device the first
  time. A crypto store lost to an unclean shutdown is then restorable with
  `openclaw matrix verify backup restore`, rather than leaving every encrypted DM unreadable.
- **Memory search is keyword-only** (`memory.search.provider: "none"`). Left unset it means OpenAI
  embeddings, which the gateway cannot reach: the index then stalls on a provider mismatch. And
  OpenClaw does not rebuild an index whose scope changed — adding the family room's paths to every
  agent is such a change — it serves stale results until `openclaw memory status --index` runs,
  because a rebuild may call an embeddings API. Keyword-only, a rebuild costs nothing, so the bootstrap
  runs it at every start.
- **The CLI** runs inside the container: `docker exec pi-openclaw node openclaw.mjs channels status`,
  `… agents list`, `… matrix verify status`. Each call is a second Node process in the same cgroup —
  about 400 MiB — which `mem_limit` leaves room for.
- **Upgrades** follow the image: the bootstrap reinstalls the plugins whenever the image's version
  changes, with the gateway stopped during the install, since two OpenClaw processes on one state
  database contend for its leases.

## How Open WebUI is wired

`OPENAI_API_BASE_URL` and friends are Open WebUI *PersistentConfig* variables: they seed the database on first start and are ignored afterwards, so on an instance that already has connections the model simply never shows up in the picker. `scripts/open-webui-bootstrap.sh` (a post-start hook in `scripts/run-hooks.sh`) closes that gap.

It appends `http://agentgateway:4000/v1` to the stored connection list when missing, with the gateway's API key, leaves any other connection you configured in the UI alone, and restarts open-webui only when it changed something.

The two path routes are separate connections, because they are separate base URLs — which is also why nothing on them shows up under `/v1`. The hook adds them the same way, with a `prefix_id` so the picker says which provider a model came from, and with the gateway key rather than `AGENT_API_KEY`: storing the external-client key here would make revoking it 401 the chat as well.

**No `model_ids` filter**, deliberately: naming models there would be the hardcoded list these routes exist to avoid, so Groq's catalogue arrives whole, transcription and speech models included. Filter in **Admin Settings → Connections**; the hook leaves what is set there alone — including a connection switched off there, which it never switches back on. None of these models has a workspace row, and Open WebUI shows such a model to admins only: users see none of OpenRouter's paid catalogue until an admin grants a model in **Admin Settings → Models**.

It also seeds the low-latency defaults above — once, guarded by a `pi-pcloud.local_ai_defaults` marker row, so anything you change afterwards in Admin Settings stays changed. The same script registers the `system-tools` server (marker `pi-pcloud.system_tools`), the web search settings (marker `pi-pcloud.web_search`, see below) and the new-chat suggestions (marker `pi-pcloud.prompt_suggestions`); the markers are independent, so re-seeding one never re-imposes the others.

Everything that writes the model's *workspace row* — attaching the tool server, seeding the suggestions — needs an admin account to own that row, and there is none until the first SSO login. Those steps are therefore skipped, unmarked, on a fresh install, and applied by the next run of the hook. The settings that live in the `config` table alone (connections, low-latency defaults, audio, the global model metadata) apply from the first boot. Run it by hand after the first login, or after a database restore:

```bash
sh scripts/open-webui-bootstrap.sh
```

### Who may use it

Authelia already decides who reaches `ai.<HOST_NAME>`, so Open WebUI's own `pending` role — which parks every SSO login behind an admin approval screen — would only mean nobody can use the service until an admin notices. The script sets `ui.default_user_role` to `user` and releases accounts already parked (marker `pi-pcloud.open_access`).

That alone is not enough, because two separate things default to admin-only:

- A model with a workspace row is shown only to its owner or to someone named in an access grant. The row belongs to the admin, so every other account would get an **empty model picker**.
- A tool server whose `config` carries no `access_grants` is private to admins, so a normal user clicking a suggestion would get an invented answer with no tool call.

Both are granted wildcard public read — `('user', '*', 'read')`, the shape Open WebUI's own code treats as public — by the same marker. They stay visible and revocable in **Admin Settings** and **Workspace → Models**; narrowing either one by hand is never undone. Admin rights still have to be granted deliberately.

## Web search (SearXNG)

The **Web Search** toggle in the chat composer queries `searxng`, the stack's own metasearch
engine, rather than a hosted API. Nothing about a query leaves the network except the query
itself, and it leaves from the Pi rather than from the browser. There is no API key to hold
and nothing to rotate.

`searxng` is not an AI service and is also the Homepage search box — see
[Architecture](ARCHITECTURE.md) — but it ships in the `open-webui` profile as well, because
turning the toggle on with nothing behind it is a silent empty result set.

**The toggle is not self-sufficient**, and this is the part nothing in the UI says. Open WebUI
acts on it in one of two ways: it offers the model the `search_web` and `fetch_url` built-in
tools, which the model then chooses to call, or — only when the model's params carry
`function_calling: legacy` — it runs a RAG search over the results itself. Native function
calling is the default, so with the built-in tools off the toggle reaches neither: the model
answers from memory, no search is made, and there is no error in any log. Hence `web_search`
staying `true` in the category map above. Given the search schema, Gemma 4 E2B does answer with
a `search_web` call.

One setting on the SearXNG side is load-bearing, in `config/searxng/settings.yml`:
`search.formats` must list `json`. Open WebUI's client sends `format=json`, and a SearXNG
that was not told to serve it answers **403 with an HTML error page** — which surfaces in
the chat as a search that returned nothing, with no error anywhere. (`html` alone is the
upstream default.)

`server.limiter` stays `false` there too, but that is already SearXNG's own default, spelled
out rather than changed: the limiter is bot protection for a public instance, and here the
only caller it could ever throttle is Open WebUI itself.

The Open WebUI side is `ENABLE_WEB_SEARCH`, `WEB_SEARCH_ENGINE`, `SEARXNG_QUERY_URL`,
`SEARXNG_LANGUAGE`, `WEB_SEARCH_RESULT_COUNT` and `WEB_SEARCH_CONCURRENT_REQUESTS` on the
`open-webui` service. All six are *PersistentConfig*, so as with the audio settings they only
reach an install that has never started; `scripts/open-webui-bootstrap.sh` carries the same
values into an existing database once, behind the `pi-pcloud.web_search` marker. Change any of
them in **Admin Settings → Web Search** afterwards and the change sticks.

`SEARXNG_QUERY_URL` is `http://searxng:8080/search` with no `?q=<query>`: the client strips a
query string off that URL and builds its own parameters, so the placeholder form seen in most
guides is tolerated rather than used.

The counts are sized for this Pi, not for a workstation. Each of the five results is a page
Open WebUI then fetches and embeds locally, on the same four cores running the model, so
`WEB_SEARCH_CONCURRENT_REQUESTS=2` is a deliberate throttle — the upstream default of `0`
means unlimited. Pages are fetched without a headless browser, so a result that only renders in
JavaScript contributes little.

## Asking the assistant about the server

`system-tools` (built from `config/system-tools/`) is an OpenAPI tool server. Open WebUI discovers tools from an OpenAPI spec and hands them to the model as function definitions, so the model can *measure* the machine it runs on instead of guessing — "how much disk is left?", "is anything down?", "how long has it been up?". It is attached to `gemma-4-e2b-it` in the workspace, so it is live on every chat; untick it under the model in **Workspace → Models** to turn it off.

One operation, `get_system_status(topic)`:

| Topic | Answers with |
|-------|--------------|
| `overview` | One line each of uptime, CPU, RAM, `/`, containers |
| `anomalies` | Only the readings outside their threshold — or that none are |
| `disk` | Free space on `/`, `/mnt/usbdrive` and `/mnt/sdcard` |
| `cpu` | Usage overall and per core, load average, temperature, clock |
| `memory` | RAM, swap, the zswap absorption ratio and memory pressure |
| `uptime` | Uptime, boot time, host clock |
| `services` | Container count, and which ones are not running or not healthy |
| `restarts` | What restarted, how often, and with which exit code |
| `errors` | The last few log lines of whatever is currently failing |
| `backups` | Last backup per plan, whether it worked, when the next one runs |
| `devices` | Tailnet devices, their owner, which are online, when the rest were last seen |

The same verdict is reachable from a shell with **`make doctor`**, which asks this container for the `anomalies` topic and prints it — the same endpoint, so the terminal and the chat cannot disagree. With `system-tools` disabled, `make doctor` skips that block.

### Reporting versus judging

Every topic but one hands the model a measurement and leaves the conclusion to it — and "184.5G free of 468.9G" is a conclusion a 4B model gets wrong often enough to matter, mid-sentence, against a threshold it has to invent. `anomalies` moves that decision into code: it walks disk, memory, swap, temperature, 5-minute load, container health, restart counts and backup age, and returns *only* what is off. When nothing is, it says so in one line, naming what it checked.

The thresholds are at the top of `config/system-tools/app.py`. `DISK_PCT`, `MEMORY_PCT` and `TEMP_C` are deliberately Beszel's own alert values (85% / 90% / 70 °C, see `scripts/beszel-agent-bootstrap.py`), so anything this topic calls abnormal is something that has already pushed to ntfy — two voices on one number, rather than a chat that disagrees with your phone. `RESTART_LOOP` is 3, which only ever counts restarts *within* one run of the stack, because `docker compose up` zeroes the counter.

**Memory is judged on stall time, not on fill levels.** Swap that is merely full is not a fault: a service that loads a model and goes idle — `parakeet`, `llama-cpp`, `immich-machine-learning` — has its cold pages evicted once and never faults them back, which is what swap is *for*, and the fill level cannot tell that apart from a machine fighting for RAM. A level is a state, and only some states are faults.

So the trigger is `PSI_MEM_FULL_PCT`: memory pressure's `full avg300` above 5%, the share of the last five minutes in which *every* task was stalled waiting on memory — time the machine provably lost. [Monitoring → Memory pressure](MONITORING.md#memory-pressure-psi) explains the reading. `some` is deliberately unused: it fires whenever any one process is in reclaim, which is a container touching its own `mem_limit` doing exactly what the limit is for. Swap fill and RAM percentage come along as *context* in the same finding, never as the trigger, and the finding names the container doing the stalling (`worst: llama-cpp 8.2%`).

On a kernel with no `/proc/pressure`, which includes this one between `make install` and the next reboot, it falls back to `SWAP_PCT` (50%) **and** `RAM_PRESSURE_PCT` (80%) together, since neither alone tells the idle-model case apart from real pressure. The `memory` topic still reports swap unconditionally, with the zswap absorption ratio beside it: with a compressed cache in front of the swap file, "swap used" no longer says how much of that cost was paid in disk I/O.

`anomalies` measures nothing new — it reuses the collectors the other topics call — and skips the one slow one, `cpu`'s ~300 ms between two `/proc/stat` samples: the 5-minute load average already says whether the machine is saturated, sustained.

### Why one operation and not ten

Tool schemas are injected into the prompt of every message. At ~40 tok/s of prompt processing they *are* the latency budget — which is why the built-in tools are off above. This one is about 170 tokens, which llama-server then caches for the rest of the conversation.

That shape keeps growth cheap: a topic costs about 14 tokens of schema, a second *operation* about 72 on its own. So a new capability becomes a topic, never a second operation.

Replies are digested for the same reason, and it matters more than the schema does: a reply is re-processed on every later turn. `df -h` alone is ~400 tokens of column padding, so nothing here returns raw command output, and `errors` caps itself at three containers and three lines each.

### Topic selection is testable, so test it

The real ceiling is not tokens, it is whether a 4B model still picks the right topic as the list grows. Test it with one prompt per topic, sent to `llama-server` with the schema attached, and check which topic each call names.

What breaks is phrasing, not the number of topics. Two reproducible failure modes:

- **The singular** — *"is a container stopped?"* makes the model ask *which* container instead of calling anything. *"are all services running?"* calls `services` every time.
- **Negation** — *"since when is X no longer online?"* makes it answer nothing at all. Stated positively, it calls `devices`.

Re-run the check when adding a topic, and when writing a suggestion tile. One known miss: a vague *"is everything okay?"* routes to `overview` rather than `anomalies` — defensible, since `overview` does report the container count — so the suggestion tile names anomalies outright.

### What it can reach

- `/` is bind-mounted read-only at `/hostfs`. `/proc` and `/sys` report the host from inside a container anyway, but `statvfs` can only measure a filesystem this process can itself see, which is what `disk` needs.
- The Docker socket is mounted `:ro`, the same way `homepage` mounts it — but be clear about what that buys: `:ro` protects the socket *inode*, not the Docker API, and anything holding an open socket can still `POST /containers/create` and get host root. What actually constrains this server is its own code: it only ever issues `GET`, to two paths, and `services` is the only caller. There is no endpoint that accepts a command, a path or a pattern — the model picks a topic from a closed list and each topic maps to fixed code, so a prompt injection has nothing to steer. The container runs `read_only` with `no-new-privileges`.
- `services`, `restarts` and `errors` filter the container list on `com.docker.compose.project=$COMPOSE_PROJECT` (from `COMPOSE_PROJECT_NAME`, default `pi-web`), so a stray `docker run` left in `Exited` is not reported as something needing attention.
- `errors` reads container logs, which is where "the model picks a topic, not a target" earns its keep: it only ever reads the tail of containers it has *already* found stopped or unhealthy. The model cannot name what gets read.
- `backups` reads Backrest's operation log, `$DATA_LOCATION/backrest/data/oplog.sqlite`, opened `mode=ro` from its directory, bind-mounted at `/run/backrest` (the file itself does not exist until Backrest's first run). A WAL database opened read-only can refuse the read when the WAL needs replaying, which surfaces as `backup log unreadable` rather than an error. The same reading is served as JSON at `/health/backups` — `ok`, `stale`, `failed`, `unknown`, no status a substring of another — which the Uptime Kuma `backup freshness` monitor matches on ([Monitoring](MONITORING.md#what-is-actually-checked)). That endpoint is kept out of the OpenAPI schema, so it costs no prompt tokens.
- `devices` reads headscale's node API — the tailnet is self-hosted, so there is no Tailscale SaaS call — reusing the API key `homepage`'s headscale widget already holds, mounted read-only at `/run/secrets/headscale_api_key`. Those keys expire, so this topic and the Homepage widget break together. It is the only topic needing the `frontend` network, and it still takes no parameter naming a device: the whole list fits in a digest, so *"when was the tablet last online?"* is answered by the model reading its own tool result. Past `DEVICE_LINES` devices the offline ones are trimmed oldest-first, and the reply says how many it dropped.

There is deliberately **no `network` topic**: routes and link speeds are static configuration, traffic *since boot* is a number nothing can be acted on, and the rate is already graphed by Beszel and the Homepage widget.

### Extending it

- **Another model, same capability:** add `server:pi-system` to its `toolIds` in **Workspace → Models**; the tool server itself is registered once, globally.
- **A new topic:** extend `TOPICS` and the `Topic` literal in `config/system-tools/app.py`.
- **Another drive:** add its mount point to `FILESYSTEMS` in the same file (one that is not mounted is skipped, so a drive that comes and goes is safe to list).

Either way, `docker compose build system-tools` afterwards.

## The new-chat suggestions

Open WebUI's own suggestions are general-knowledge prompts that never touch the tool, so nobody discovers the assistant can be asked about the machine. `scripts/open-webui-bootstrap.sh` replaces them with nine that each map to a topic, written in the stack's `DEFAULT_LANGUAGE`: free disk space, whether anything is abnormal, general status, CPU temperature and load, uptime, who is online on the tailnet, last night's backup, recent restarts, and the errors of whatever is failing.

They go on the model (`suggestion_prompts`) rather than the global `ui.prompt_suggestions`, because the frontend reads `model.info.meta.suggestion_prompts` first — a suggestion that assumes the status tool exists belongs to the model the tool is attached to.

Edit them in **Workspace → Models → gemma-4-e2b-it**, or in the `SUGGESTIONS` heredoc in the script. The `pi-pcloud.prompt_suggestions` marker means a UI edit is never overwritten — but the marker carries a version (`SUGGESTIONS_VERSION`), so changing the tiles in the script means bumping it, which re-seeds once and *does* overwrite a UI edit. Check any new wording against the model first: [a prompt that reads well is not necessarily one it turns into a call](#topic-selection-is-testable-so-test-it).

## Language

One `.env` variable, `DEFAULT_LANGUAGE`, sets the language of everything in the stack that has to choose one, as a BCP 47 tag. It defaults to `en-US`; this is the only place to change it.

| It drives | How |
|-----------|-----|
| Open WebUI's interface | `DEFAULT_LOCALE`, for users who have not picked a language themselves |
| Which Piper voice reads answers aloud | matched against the voices baked into the image |
| The new-chat suggestion tiles | written in that language by `scripts/open-webui-bootstrap.sh` |

`fr-FR` and `en-US` are the two tags with voices shipped. Anything else still works — the interface has its own translations, and Piper picks the closest voice it has (`fr-BE` finds `fr_FR-siwis-medium`; `de-DE` warns in the log and uses English until you add a German voice to `VOICES` in `config/piper/Dockerfile`). To name a voice outright instead of matching the language, set `PIPER_DEFAULT_VOICE` on the service.

Changing it later is one variable and a restart: the seeding markers carry the language, so `pi-pcloud.local_tts_defaults` moves from `2-en-US` to `2-fr-FR` and re-seeds once. A voice you then pick in Admin Settings stays picked.

## Text-to-speech (Piper)

The read-aloud button goes through `piper`, built from `config/piper/` on top of [OHF-Voice/piper1-gpl](https://github.com/OHF-Voice/piper1-gpl). Upstream publishes no image and its HTTP server speaks its own protocol, so the image adds `config/piper/openai_api.py`, a small OpenAI-compatible facade (`/v1/audio/speech`, `/v1/audio/voices`, `/v1/audio/models`) — the shape Open WebUI's "OpenAI" TTS engine calls.

Roughly **five seconds of speech per second of CPU, ~215 MB resident.** Voices are baked into the image:

| Voice | |
|-------|---|
| `fr_FR-siwis-medium` | French, female — the default for French |
| `fr_FR-tom-medium` | French, male |
| `fr_FR-upmc-medium` | French, female, different timbre |
| `en_US-lessac-medium` | English, so English text is not read with a French phonemiser |

The default voice is not named on the service — it is matched against `DEFAULT_LANGUAGE`, because open-webui asks for OpenAI's own voice names (`alloy`, `echo`), none of which exist here, so the fallback *is* the voice in practice. Pick a voice per user in **Settings → Audio**; it overrides the default.

To add voices, extend `VOICES` in `config/piper/Dockerfile` (catalogue: [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices)) and rebuild with `docker compose build piper`. To go back to the browser's own voices, set the TTS engine to Web API in Admin Settings — nothing re-imposes Piper.

## Speech-to-text (Parakeet)

The microphone button goes through `parakeet`, built from `config/parakeet/` on top of NVIDIA's [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), run as ONNX via [onnx-asr](https://github.com/istupakov/onnx-asr). As with Piper, upstream publishes no image — and onnx-asr has no HTTP server at all — so the image adds `config/parakeet/openai_api.py`, serving `POST /v1/audio/transcriptions`. The weights are baked into the image, so the container needs no network.

It needs nothing done by hand. A fresh install is configured by the `AUDIO_STT_*` variables on the open-webui service (PersistentConfig, read on an instance's very first start), so `make install` comes up dictating. On an instance whose database already exists those are ignored by design, and `scripts/open-webui-bootstrap.sh` writes the same values once (marker `pi-pcloud.local_stt_defaults`). The setting is global rather than per-account, and the microphone is on for every role by default (`chat.stt` in `user.permissions`).

### Why not Open WebUI's built-in whisper

It runs *inside* the open-webui container, where torch and the embedding model already hold about 640 MB of the `1536m` limit from boot, so the only model that fits is the default `base` — and `base` is the reason dictated French comes back wrong. On 113 seconds of read French ([FLEURS](https://huggingface.co/datasets/google/fleurs) `fr_fr`), on this Pi's three AI cores:

| Engine | WER | Speed | Resident |
|--------|-----|-------|----------|
| faster-whisper `base` (Open WebUI's default) | 20.2% | 0.95× realtime | ~630 MB |
| faster-whisper `small` | 12.5% | 1.25× realtime | ~1.0 GB |
| faster-whisper `medium` | 4.9% | 3.99× realtime | ~2.7 GB |
| **Parakeet TDT v3, int8 (in use)** | **8.7%** | **0.17× realtime** | **~1.2 GB** |
| Parakeet TDT v3, fp32 | 4.5% | 0.30× realtime | ~2.3 GB |

Parakeet comes close to whisper-`medium` accuracy at a twentieth of the cost: a dictated sentence comes back in well under a second, punctuated and capitalised.

**It has no language setting at all.** Parakeet was trained on 25 European languages and picks one acoustically, so switching the language you dictate in needs no setting — where whisper *auto-detects*, and its failure mode on a short French clip is to decide the audio is English and transliterate it. Open WebUI still sends a `language` field; the facade accepts and ignores it.

### More accuracy, at twice the memory

Rebuild in fp32 — 4.5% WER, still three times faster than realtime, but ~2.3 GB resident and a ~2.5 GB model in the image:

```bash
docker compose build --build-arg PARAKEET_QUANTIZATION= parakeet
```

Then set `PARAKEET_QUANTIZATION=` (empty) on the service in `compose/compose-ai.yaml` so the weights loaded are the weights baked in, and raise `mem_limit` to `3584m`.

### Long recordings are chunked

Long uploads are transcribed in 20-second windows. That is not only about memory — a single 120-second pass takes the container past 2 GB — but about a cliff in the ONNX export, which stops transcribing part of a long call: on continuous French, 20 s windows scored 15.3% WER, 10 s 20.2%, 30 s 16.6%, and at 60 s half the words went missing (73%). Boundaries are nudged onto the quietest nearby frame rather than falling wherever 20 seconds lands, because a window that opens mid-word is the one that comes back in the wrong language. Dictation reaches none of this: it is one window. Tune with `PARAKEET_CHUNK_SECONDS` if you feed it long recordings, keeping it well under 60.

To go back to Open WebUI's built-in whisper, set the STT engine to Whisper (Local) in **Admin Settings → Audio** — nothing re-imposes Parakeet.
