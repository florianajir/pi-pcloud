# Local AI

Open WebUI at `https://ai.<HOST_NAME>` is a full chat assistant running entirely on the Pi's CPU: text, images and audio in, speech out, plus a tool that lets the model report the machine's own health.

The two hostnames say who they are for: `ai.` is the human UI, `llm.` is the gateway clients POST to. `llm.` used to be `agent.`, a synonym of `ai.` for the opposite kind of caller - a person on one, a client library on the other. The old name is gone with no redirect, so a stale bookmark gets Traefik's 404; only admins ever typed it.

`chat.<HOST_NAME>` is **reserved and deliberately unused**: it is the name a
human-to-human messaging service should get, and for everyone outside this
repository "chat" means talking to people, not to a model. Nothing here may
claim it.

| Piece | Role | Network |
|-------|------|---------|
| `open-webui` | Chat frontend, OIDC-authenticated | `frontend`, `ai` |
| `agentgateway` | LLM and MCP gateway: one OpenAI-compatible endpoint, one MCP endpoint, virtual keys | `frontend`, `ai` |
| `llama-cpp` | Inference server (OpenAI-compatible API) | `ai` |
| `piper` | Text-to-speech | `ai` |
| `parakeet` | Speech-to-text | `ai` |
| `system-tools` | OpenAPI tool server answering questions about the host | `ai`, `frontend` |

Everything without `frontend` sits on the internal `ai` network with no route to the internet.

Chat traffic runs `open-webui → agentgateway → llama-cpp`. `piper` and `parakeet` are called directly:
they are not chat completions, and the gateway would only add a hop.

## The model

`llama-cpp` serves **Gemma 4 E2B** (Google's QAT Q4_0 build — text, image and audio in). There is no Ollama in the stack: llama.cpp is the engine Ollama wraps, and running it directly is faster on ARM CPU and one process instead of two.

Measured on a Raspberry Pi 5 (16 GB, 3 threads pinned to cores 1–3): **~10 tok/s generation, ~40 tok/s prompt processing, ~3.7 GB resident**. A short question answers in about 3 seconds end to end.

### Why the defaults look aggressive

Latency comes from prompt size, not the model. Three defaults exist purely because ~40 tok/s of prompt processing punishes anything verbose:

- **Thinking is off** (`LLAMA_ARG_CHAT_TEMPLATE_KWARGS`). Gemma 4 otherwise spends ~500 tokens reasoning before the first visible word — over a minute of empty chat window for "how are you".
- **One server slot** (`LLAMA_ARG_N_PARALLEL=1`). llama-server defaults to several and runs them concurrently, so two requests each generated at ~5 tok/s instead of one at ~10. Queueing is faster than sharing three threads.
- **Open WebUI's built-in tools are off for this model**, along with title, tag, follow-up and search-query generation. The built-in tools (time, memory, chats, notes, knowledge, channels) inject ~5000 tokens of schemas into every message — roughly three minutes of prompt processing before the model starts. The other four are invisible extra LLM calls per message.

All are re-enablable in **Admin Settings** and in the model's own **Capabilities**.

### Tuning knobs

All `environment:` entries on the `llama-cpp` service:

| Variable | Default here | Notes |
|----------|--------------|-------|
| `LLAMA_ARG_CTX_SIZE` | `16384` | Context window. The model supports 128k; RAM and prompt-processing time do not. |
| `LLAMA_ARG_CHAT_TEMPLATE_KWARGS` | `{"enable_thinking":false}` | Thinking off. Drop the line to restore it — `--reasoning-budget 0` is *not* equivalent: it closes the channel without telling the model, which then reasons in the visible answer. |
| `LLAMA_ARG_N_PARALLEL` | `1` | One server slot; concurrent requests queue instead of splitting the three threads. |
| `LLAMA_ARG_THREADS` | `3` | Matched to `cpuset: "1-3"`, leaving core 0 for Traefik and DNS. A 4th thread measured no faster. |
| `LLAMA_ARG_SPEC_TYPE` | `draft-mtp` | Speculative decoding via Gemma 4's multi-token-prediction head; roughly doubles generation speed. Remove it and `LLAMA_ARG_SPEC_DRAFT_MODEL` to disable. |
| `LLAMA_ARG_MMPROJ` | mmproj file | Vision/audio input. Removing it saves ~1 GB of RAM and re-enables `--cache-reuse`. |

### Where the weights live

`scripts/llama-cpp-pre-start.sh` downloads them into the `llama_models` Docker volume (on the NVMe root, not `DATA_LOCATION`) before the stack starts, because the `ai` network is internal and the container cannot reach HuggingFace itself. It is idempotent — it only re-downloads a file whose size does not match the remote one. To re-check by hand:

```bash
sh scripts/llama-cpp-pre-start.sh
```

### Changing the model

Edit the `DOWNLOADS` list in `config/llama-cpp/fetch-models.sh`, then point `LLAMA_ARG_MODEL` (and `LLAMA_ARG_MMPROJ` / `LLAMA_ARG_SPEC_DRAFT_MODEL`, or drop them) at the new files in `compose.yaml`. Prefer `Q4_0` quantisations: llama.cpp repacks those into the ARM i8mm/dotprod kernels the Pi 5 has. Anything much past ~4B parameters is too slow to chat with on CPU.

## The gateway (Agentgateway)

`https://llm.<HOST_NAME>` is [agentgateway](https://agentgateway.dev), a Rust data plane that serves
three things on one port: an OpenAI-compatible `/v1` in front of `llama-cpp`, an MCP endpoint at `/mcp`
that federates tool servers, and the UI at `/ui` that configures both. It joined the
[Agentic AI Infrastructure Foundation](https://aaif.io/blog/agentgateway-joins-aaif-as-an-open-gateway-for-agentic-ai-infrastructure)
under the Linux Foundation in 2026.

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
capabilities, the API-key policy, the local model and the OIDC policy. `config.storage.mode: hybrid`
sends the *resources* the UI writes — providers, models, virtual models, MCP targets, routes, policies —
to a SQLite database under `${DATA_LOCATION}/agentgateway` instead, where they are merged over that
baseline at read time. In the default `file` mode even those saves would fail against a read-only mount.

The file carries only what has to exist before anyone can log in: `gemma-4-e2b-it` pointed at
`http://llama-cpp:8080/v1`, and the key Open WebUI presents. Its provider is `custom`, not `openAI` —
that one talks to api.openai.com — and `completions` with no `path` resolves to
`<baseUrl>/chat/completions`, which is why the `baseUrl` carries the `/v1` and llama-server's own
`/v1/chat/completions` is what gets called. No `apiKey` on it: llama-server does not check one.

Hybrid does not make the file itself editable, and that is worth knowing before opening the UI: a write to
any top-level section is refused client-side with `File configuration is read-only in hybrid mode`. That
is upstream's design, not a misconfiguration here — the database holds the resources *within* a section,
but only `file` mode lets the UI create the section itself, so the refusal would happen just the same
without the read-only mount. The
welcome wizard's *Enable LLM* and *Enable MCP* chips are exactly such a write, and unlike the Save buttons
elsewhere in the UI they offer neither the diff they tell you to copy nor the `Ctrl`/`Cmd`+`Shift` override
those buttons carry — no HTTP request is even sent, which makes the error look like a broken deployment.
That is why `llm` and `mcp` are declared in the file: the UI reads "enabled" off their presence alone.
Targets and models added afterwards save normally. Do not make the file writable to get the wizard
working — agentgateway expands its `${…}` references at read time, so it would write the resolved OIDC
client secret back in cleartext and drop every comment.

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
| `/mcp` | whatever policy is attached to the target | **nothing by default** |

The gateway runs the OIDC flow itself against the `agentgateway` Authelia client — authorization code
with PKCE, callback `https://llm.<HOST_NAME>/oauth/callback`. A forward-auth in front of it would
intercept that callback, which is why there is none. Its console reconfigures the whole gateway, so it
sits with Dockhand and Headplane rather than with the user-facing services.

**That gates the UI, and only the UI** — which is the split worth keeping: an admin configures the
models, the providers and the credentials through the browser, everyone else consumes with a key. Open
WebUI and any script holding one are untouched by it, and none of them could complete an interactive
login anyway.

The third row is the one to watch. An MCP target you add is served with no policy on it, so attach one —
`jwtAuth`, `apiKey` or `basicAuth` all work there — before pointing anything at `/mcp`.

The MCP Authorization spec's own flow (`mcpAuthentication`) is not wired. As written it expects the
identity provider to support Dynamic Client Registration, and Authelia does not — its discovery document
publishes no `registration_endpoint`. Setting `clientId` and `clientSecret` on the policy short-circuits
registration with a client declared in `config/authelia/configuration.yml.template`, which is the way in
if you want it; every MCP client then shares that one registration.

### The key that is not `PASSWORD`

`scripts/agentgateway-pre-start.sh` generates `${DATA_LOCATION}/agentgateway/secrets/llm_api_key` on
first start, and `rotate-password.sh` deliberately leaves it alone. `llm.<HOST_NAME>` carries no
forward-auth on `/v1` — API clients cannot complete an interactive login — so deriving it from
`PASSWORD` would make a `PASSWORD` leak a free pass to the models. It also has to outlive a rotation:
`OPENAI_API_KEY` is PersistentConfig in Open WebUI, so the value that container starts with is copied
into its database. The gateway's own policy and Open WebUI's entrypoint read the same file, so the
caller and the gateway cannot drift apart.

Open WebUI mounts **that file alone**, not the directory it sits in: `cookie_secret` next to it signs
the admin session cookie, and the chat has no business being able to read it.

There is no salt key to lose sleep over. Provider credentials added through the UI are stored by
agentgateway in the SQLite database, which backrest snapshots whole.

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

### Adding a provider

Anything OpenAI-compatible is a `custom` provider. z.ai's free GLM tier, for example, is a `baseUrl` of
`https://api.z.ai/api/paas/v4` and a `model` of `glm-4.7-flash` — add it under **Models** in the UI and
it lands in SQLite, no file edit and no restart. Pair it with a token rate limit: the free tiers are
quota'd per day, and a runaway agent loop is exactly what exhausts one.

### Two things that will bite you

- **The image is distroless.** It contains `/app/agentgateway`, `ld.so` and a CA bundle — no shell, no
  curl. That is why the service declares no healthcheck and Uptime Kuma watches the container instead,
  why Open WebUI depends on it as `service_started` rather than `service_healthy`, and why the secrets
  reach it through an `env_file` rather than an `export $(cat …)` entrypoint. Those values are frozen at
  container creation: use `docker compose up -d agentgateway`, not `restart`.
- **Environment expansion runs over the raw file, comments included.** A dollar-brace reference written
  in a comment as an example is looked up like any other and fails the start with
  `error looking key '…' up`.

## How Open WebUI is wired

`OPENAI_API_BASE_URL` and friends are Open WebUI *PersistentConfig* variables: they seed the database on first start and are ignored afterwards, so on an instance that already has connections the model simply never shows up in the picker. `scripts/open-webui-bootstrap.sh` (a post-start hook in `scripts/stack-up.sh`) closes that gap.

It appends `http://agentgateway:4000/v1` to the stored connection list when missing, with the gateway's API key, leaves any other connection you configured in the UI alone, and restarts open-webui only when it changed something. It also seeds the low-latency defaults above — once, guarded by a `pi-pcloud.local_ai_defaults` marker row, so anything you change afterwards in Admin Settings stays changed. The same script registers the `system-tools` server (marker `pi-pcloud.system_tools`) and the new-chat suggestions (marker `pi-pcloud.prompt_suggestions`); the markers are independent, so re-seeding one never re-imposes the others.

Everything that writes the model's *workspace row* — turning the built-in tools off (marker `pi-pcloud.local_ai_model_defaults`), attaching the tool server, seeding the suggestions — needs an admin account to own that row, and there is none until the first SSO login. Those steps are therefore skipped, unmarked, on a fresh install, and applied by the next run of the hook. The settings that live in the `config` table alone (connection, low-latency defaults, audio) apply from the first boot. Run it by hand after the first login, or after a database restore:

```bash
sh scripts/open-webui-bootstrap.sh
```

### Who may use it

Authelia already decides who reaches `ai.<HOST_NAME>`, so Open WebUI's own `pending` role — which parks every SSO login behind an admin approval screen — would only mean nobody can use the service until an admin notices. The script sets `ui.default_user_role` to `user` and releases accounts already parked (marker `pi-pcloud.open_access`).

That alone is not enough, because two separate things default to admin-only:

- A model with a workspace row is kept by `get_filtered_models` only for its owner or for someone named in an access grant. The row exists here to turn the built-in tools off and it belongs to the admin, so every other account got an **empty model picker**.
- A tool server whose `config` carries no `access_grants` is private to admins (`has_connection_access`), so a normal user clicking a suggestion would get an invented answer with no tool call.

Both are granted wildcard public read — `('user', '*', 'read')`, the shape the code itself documents as public — by the same marker. They stay visible and revocable in **Admin Settings** and **Workspace → Models**; narrowing either one by hand is never undone. Admin rights still have to be granted deliberately.

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

The same verdict is reachable from a shell with **`make doctor`**, which asks this container for the `anomalies` topic and prints it — the same endpoint, so the terminal and the chat cannot disagree.

### Reporting versus judging

Every topic but one hands the model a measurement and leaves the conclusion to it — and "184.5G free of 468.9G" is a conclusion a 4B model gets wrong often enough to matter, mid-sentence, against a threshold it has to invent. `anomalies` moves that decision into code: it walks disk, memory, swap, temperature, 5-minute load, container health, restart counts and backup age, and returns *only* what is off. When nothing is, it says so in one line, naming what it checked.

The thresholds are at the top of `config/system-tools/app.py`. `DISK_PCT`, `MEMORY_PCT` and `TEMP_C` are deliberately Beszel's own alert values (85% / 90% / 70 °C, see `scripts/beszel-agent-bootstrap.sh`), so anything this topic calls abnormal is something that has already pushed to ntfy — two voices on one number, rather than a chat that disagrees with your phone. `RESTART_LOOP` is 3, which only ever counts restarts *within* one run of the stack, because `docker compose up` zeroes the counter.

**Swap needs two conditions, and that is the interesting one.** It was written first as a plain `SWAP_PCT = 50` and fired on its first run against a box where nothing was wrong: 103 days of uptime, swap 100% full, **7 GB of RAM available, no OOM kill on record, and 0.13 MB/min of actual paging**. `/var/swap` (2 GB at the time, now `SWAP_SIZE_MB`) is on the NVMe, and what filled it was `parakeet` (578 MB), `llama-cpp` (351 MB) and `immich-machine-learning` (158 MB) — services that load a model, go idle, and have their cold pages evicted exactly once. That is what swap is *for*, and the fill level cannot tell it apart from a machine fighting for RAM.

So the finding needed `SWAP_PCT` **and** `RAM_PRESSURE_PCT` (80%) together — two levels, because neither alone tells the idle-model case apart from a machine fighting for RAM. The general lesson stands and is the reason the topic exists at all: **a level is a state, and only some states are faults.**

**`PSI_MEM_FULL_PCT` replaced the pair, because it is the fault rather than a proxy for it.** With `psi=1` on the kernel command line ([Monitoring → Memory pressure](MONITORING.md#memory-pressure-psi)), `/proc/pressure/memory` reports `full avg300`: the share of the last five minutes in which *every* task was stalled waiting on memory. Not a level that might cost something — time the machine provably lost. The threshold is 5%, which is 15 seconds of dead wall clock out of 300 on a box that is otherwise 95% idle. `some` is deliberately unused: it fires whenever any one process is in reclaim, which is a container touching its own `mem_limit` doing exactly what the limit is for.

Swap fill and RAM percentage now come along as *context* in the same finding, never as the trigger. And because the same file exists per cgroup, the finding can name the container doing the stalling — `worst: llama-cpp 8.2%` — which no combination of host-wide levels could ever say. That walk is one read per container, so it only runs once the host is already over the threshold; the fast path stays a single extra `/proc` read.

The two-level heuristic is kept as the fallback for a kernel with no `/proc/pressure`, which includes this one between `make install` and the next reboot. The `memory` topic still reports swap unconditionally, and now the zswap absorption ratio beside it: with a compressed cache in front of the swap file, "swap used" no longer says how much of that cost was paid in disk I/O.

Nothing new is measured for `anomalies` — it reuses the collectors the other topics already call, so the whole pass is one `statvfs` per filesystem, three `/proc` reads, one inspect per container and one SQLite query: **60–80 ms** end to end, against the ~300 ms `cpu` alone spends sleeping between its two `/proc/stat` samples. That sample is the one thing `anomalies` skips: the 5-minute load average already says whether the machine is saturated, sustained.

### Why one operation and not ten

Tool schemas are injected into the prompt of every message. At ~40 tok/s of prompt processing they *are* the latency budget — which is why the built-in tools are off above. This one is 170 tokens (`curl llama-cpp:8080/tokenize` on the payload Open WebUI builds from the spec), which llama-server then caches for the rest of the conversation.

That shape keeps growth cheap, and the difference is measured: the enum has gone 6 → 10 topics for 113 → 170 tokens, about **+14 per topic**, where a single extra *operation* costs **+72** on its own. So a new capability becomes a topic, never a second operation. (`anomalies` came in at +19 — above average, because its clause has to say what a threshold *is* and not merely name a subject.)

Replies are digested for the same reason, and it matters more than the schema does: a reply is re-processed on every later turn. `df -h` alone is ~400 tokens of column padding, so nothing here returns raw command output, and `errors` caps itself at three containers and three lines each.

### Topic selection is testable, so test it

The real ceiling is not tokens, it is whether a 4B model still picks the right topic as the list grows. One prompt per topic, sent to `llama-server` with the schema attached, currently scores **10/10 at ten topics** — no degradation from six.

What breaks is phrasing, not the number of topics. Two reproducible failure modes:

- **The singular** — *"is a container stopped?"* makes the model ask *which* container instead of calling anything. *"are all services running?"* calls `services` every time.
- **Negation** — *"since when is X no longer online?"* makes it answer nothing at all. Stated positively, it calls `devices`.

Re-run the check when adding a topic, and when writing a suggestion tile. One known miss stays: a vague *"is everything okay?"* routes to `overview` rather than `anomalies` — defensible, since `overview` does report the container count, though it would miss a full swap. Widening the `anomalies` description was tried and changed that case not at all, only the token count, so the short clause stayed and the tile names anomalies outright instead.

### What it can reach

- `/` is bind-mounted read-only at `/hostfs`. `/proc` and `/sys` report the host from inside a container anyway, but `statvfs` can only measure a filesystem this process can itself see, which is what `disk` needs.
- The Docker socket is mounted `:ro`, the same way `homepage` mounts it — but be clear about what that buys: `:ro` protects the socket *inode*, not the Docker API, and anything holding an open socket can still `POST /containers/create` and get host root. What actually constrains this server is its own code: it only ever issues `GET`, to two paths, and `services` is the only caller. There is no endpoint that accepts a command, a path or a pattern — the model picks a topic from a closed list and each topic maps to fixed code, so a prompt injection has nothing to steer. The container runs `read_only` with `no-new-privileges`.
- `services`, `restarts` and `errors` filter the container list on `com.docker.compose.project=$COMPOSE_PROJECT` (from `COMPOSE_PROJECT_NAME`, default `pi-web`), so a stray `docker run` left in `Exited` is not reported as something needing attention.
- `errors` reads container logs, which is where "the model picks a topic, not a target" earns its keep: it only ever reads the tail of containers it has *already* found stopped or unhealthy. The model cannot name what gets read.
- `backups` reads Backrest's operation log, `$DATA_LOCATION/backrest/data/oplog.sqlite`, opened `mode=ro`. Its *directory* is bind-mounted at `/run/backrest` rather than reached through `/hostfs`, for two reasons: `DATA_LOCATION` is relative to the project directory by default, and the oplog does not exist until Backrest's first run, so mounting the file would have Docker create a directory in its place. The same reading is served as JSON at `/health/backups` — `ok`, `stale`, `failed`, `unknown`, no status a substring of another — which the Uptime Kuma `backup freshness` monitor matches on ([Monitoring](MONITORING.md#what-is-actually-checked)). That endpoint is kept out of the OpenAPI schema, so it costs no prompt tokens.
- `devices` reads headscale's node API — the tailnet is self-hosted, so there is no Tailscale SaaS call — reusing the API key `homepage`'s headscale widget already holds, mounted read-only at `/run/secrets/headscale_api_key`. Those keys expire, so this topic and the Homepage widget break together. It is the only topic needing the `frontend` network, and it still takes no parameter naming a device: ten devices fit in eleven digested lines, so *"when was the iPad last online?"* is answered by the model reading its own tool result. Past `DEVICE_LINES` devices the offline ones are trimmed oldest-first, and the reply says how many it dropped.

> Two gotchas in `backups`: the status codes come from `proto/v1/operations.proto`, where `WARNING` is declared before `ERROR` but numbered *after* the cancellations (reading declaration order off the binary gets it backwards — `ERROR` is 4); and a WAL database opened read-only can refuse the read if the WAL needs replaying, which surfaces as `backup log unreadable` rather than an error.

There is deliberately **no `network` topic**: routes and link speeds are static configuration, traffic *since boot* is a number nothing can be acted on, and the rate is already graphed by Beszel and the Homepage widget.

### Extending it

- **Another model, same capability:** add `server:pi-system` to its `toolIds` in **Workspace → Models**; the tool server itself is registered once, globally.
- **A new topic:** extend `TOPICS` and the `Topic` literal in `config/system-tools/app.py`.
- **Another drive:** add its mount point to `FILESYSTEMS` in the same file (one that is not mounted is skipped, so a drive that comes and goes is safe to list).

Either way, `docker compose build system-tools` afterwards.

## The new-chat suggestions

Open WebUI's own six suggestions — vocabulary drills, the Roman Empire, options trading — advertise a model this box does not run and never touch the tool, so nobody discovers the assistant can be asked about the machine. `scripts/open-webui-bootstrap.sh` replaces them with nine that each map to a topic, written in the stack's `DEFAULT_LANGUAGE`: free disk space, whether anything is abnormal, general status, CPU temperature and load, uptime, who is online on the tailnet, last night's backup, recent restarts, and the errors of whatever is failing.

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
| `fr_FR-siwis-medium` | French, female — the default |
| `fr_FR-tom-medium` | French, male |
| `fr_FR-upmc-medium` | French, female, different timbre |
| `en_US-lessac-medium` | English, so English text is not read with a French phonemiser |

The default voice is not named on the service — it is matched against `DEFAULT_LANGUAGE`, because open-webui asks for OpenAI's own voice names (`alloy`, `echo`), none of which exist here, so the fallback *is* the voice in practice. Pick a voice per user in **Settings → Audio**; it overrides the default.

To add voices, extend `VOICES` in `config/piper/Dockerfile` (catalogue: [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices)) and rebuild with `docker compose build piper`. To go back to the browser's own voices, set the TTS engine to Web API in Admin Settings — nothing re-imposes Piper.

## Speech-to-text (Parakeet)

The microphone button goes through `parakeet`, built from `config/parakeet/` on top of NVIDIA's [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), run as ONNX via [onnx-asr](https://github.com/istupakov/onnx-asr). As with Piper, upstream publishes no image — and onnx-asr has no HTTP server at all — so the image adds `config/parakeet/openai_api.py`, serving `POST /v1/audio/transcriptions`. The weights are baked into the image, so the container needs no network.

It needs nothing done by hand. A fresh install is configured by the `AUDIO_STT_*` variables on the open-webui service (PersistentConfig, read on an instance's very first start), so `make install` comes up dictating. On an instance whose database already exists those are ignored by design, and `scripts/open-webui-bootstrap.sh` writes the same values once (marker `pi-pcloud.local_stt_defaults`). The setting is global rather than per-account, and the microphone is on for every role by default (`chat.stt` in `user.permissions`).

### Why not Open WebUI's built-in whisper

It runs *inside* the open-webui container, which is capped at 1 GB and already sits near 730 MB, so the only model that fits is the default `base` — and `base` is the reason dictated French comes back wrong. Measured on 113 seconds of read French ([FLEURS](https://huggingface.co/datasets/google/fleurs) `fr_fr`) across this Pi's three AI cores:

| Engine | WER | Speed | Resident |
|--------|-----|-------|----------|
| faster-whisper `base` (Open WebUI's default) | 20.2% | 0.95× realtime | ~630 MB |
| faster-whisper `small` | 12.5% | 1.25× realtime | ~1.0 GB |
| faster-whisper `medium` | 4.9% | 3.99× realtime | ~2.7 GB |
| **Parakeet TDT v3, int8 (in use)** | **8.7%** | **0.17× realtime** | **~1.2 GB** |
| Parakeet TDT v3, fp32 | 4.5% | 0.30× realtime | ~2.3 GB |

Whisper decodes autoregressively — a token at a time, so accuracy is bought with wall-clock. Parakeet is a TDT model whose decoder is a small joint network stepped once per frame, which is why it reaches whisper-`medium` accuracy at a twentieth of the cost. In practice a dictated sentence comes back in well under a second, punctuated and capitalised.

**It has no language setting at all**, and that is the other half of the fix. Parakeet was trained on 25 European languages and picks one acoustically, so dictating in English tomorrow needs no switch flipped — where whisper *auto-detects*, and its failure mode on a short French clip is to decide the audio is English and transliterate it. Open WebUI still sends a `language` field; the facade accepts and ignores it.

### More accuracy, at twice the memory

Rebuild in fp32 — 4.5% WER, still three times faster than realtime, but ~2.3 GB resident and a ~2.5 GB model in the image:

```bash
docker compose build --build-arg PARAKEET_QUANTIZATION= parakeet
```

Then set `PARAKEET_QUANTIZATION=` (empty) on the service in `compose.yaml` so the weights loaded are the weights baked in, and raise `mem_limit` to `3584m`.

### Long recordings are chunked

Long uploads are transcribed in 20-second windows. That is not only about memory — a single 120-second pass took the container past 2 GB and got it killed — but about a cliff in the ONNX export, which stops transcribing part of a long call. Against 57 seconds of continuous French with a 163-word reference:

| Window | Words returned | WER |
|--------|----------------|-----|
| 10 s | 157 | 20.2% |
| **20 s** | **162** | **15.3%** |
| 30 s | 160 | 16.6% |
| 60 s | 75 | 73.0% |

At 60 seconds half the audio simply goes missing, so the window has to stay well under it. Boundaries are then nudged onto the quietest nearby frame rather than falling wherever 20 seconds lands, because a window that opens mid-word is the one that comes back in the wrong language — on a deliberately badly-cut sample that alone took the transcript from 33.7% to 19.5% WER. Dictation reaches none of this: it is one window. Tune with `PARAKEET_CHUNK_SECONDS` if you feed it long recordings.

To go back to Open WebUI's built-in whisper, set the STT engine to Whisper (Local) in **Admin Settings → Audio** — nothing re-imposes Parakeet.

