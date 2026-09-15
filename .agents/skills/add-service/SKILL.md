---
name: add-service
description: Vet a candidate upstream project (still maintained, arm64, resource footprint, open-source alternatives) and add it to the pi-pcloud docker compose stack, wiring the standard integrations (Traefik, Authelia OIDC, Postgres, Redis, ntfy, Uptime Kuma, Backrest, Homepage, systemd bootstrap). Use whenever a new container is added to compose/, or when auditing an existing service for missing integrations.
---

# Adding a service to the stack

Step 0 comes first and is never skipped. After it, copy the closest existing
service in `compose/` as a template, then work through every integration below
and skip only the ones that genuinely do not apply. Say explicitly which ones you
skipped and why.

## 0. Vet the candidate first

Before writing a line of compose, answer these four, with evidence, in your
response. A "no" is a reason to stop and come back to the user, not something to
work around quietly.

**Is the project alive?** Read the upstream repo, not the Docker Hub page: date
of the latest release, commits over the last six months, whether issues get
answered. Red flags are an archived or read-only repo, no tagged release in over
a year (which also means step 1 has no stable tag to pin), a lone maintainer with
no merged outside contributions, and an open unpatched advisory. Check the
licence in the same pass — source-available (BUSL, SSPL, Elastic) is not open
source and can be relicensed out from under a self-hoster.

**Does it run on arm64?** `docker buildx imagetools inspect <image>:<tag>` must
list `linux/arm64`. Necessary, not sufficient: multi-arch images regularly ship
x86-64 helpers inside — Kapowarr's bundled `rar`, the browsers a scraper drives.
If the service shells out to a bundled binary, downloads a platform-specific
plugin at runtime, or wants a GPU, verify that path specifically. Never paper
over a gap with `platform: linux/amd64`; qemu emulation on this Pi is slow enough
to be useless.

**What does it cost to run?** The host is a 16 GB Pi 5 already running ~46
containers with ~9 GB in use, so a newcomer competes for what is left. Start the
image once and read `docker stats` at idle and under one realistic action, then
set `mem_limit` from that with headroom — most services here live in 128m–512m.
Anything above ~1 GB idle, or that keeps a core busy on a background job, needs a
stated reason it is worth the slot. Things to spot before measuring: a JVM or
Electron runtime, a bundled Elasticsearch/Mongo/Chromium, its own Postgres or
Redis where steps 4 and 5 would share ours, and a model download on first boot.

**Is an open-source competitor a better fit?** Name at least one and say why this
one wins, on the axes that decide it here: arm64 support, idle footprint, OIDC
(no SSO means one more password — see step 3), reuse of the shared Postgres and
Redis, and whether it duplicates something the stack already runs. Favour a
project the stack already depends on over a new one. If the alternative wins,
propose it instead of implementing this one.

Put the verdict in the PR body. It is what gets re-read the day the service is
replaced, and it is the only place these trade-offs are recorded.

## 1. Compose basics

- if the service builds from a Dockerfile rather than pulling an image, add its
  directory to the `docker` update in `.github/dependabot.yml`. Nothing else
  reminds you, and without it the base image is never bumped;
  `tests/compose-invariants.py` fails the build until you do.
- put it in the `compose/compose-<domain>.yaml` it belongs to — `core`, `identity`,
  `network`, `cloud`, `media`, `knowledge`, `ai`, `monitoring`. The root
  `compose.yaml` declares no service; it holds `include:`, the networks, the
  volumes and the canonical `x-` tier anchors, and a new *network* or *volume*
  goes there, not in the domain file. A new domain file needs an `include:`
  entry carrying both `project_directory: .` and `env_file: /dev/null`, and the
  `compose-` prefix is mandatory: Dependabot's fetcher never opens a basename
  without it, so a `core.yaml` silently stops every image-bump PR.

- `<<: *service-defaults` (journald logging + `restart: unless-stopped`)
- pinned image tag — look up the newest **stable** release upstream before writing it
  (`docker buildx imagetools inspect <image>:latest`, the registry's tag list, or the
  project's GitHub releases page); never `latest`, never a tag guessed from another
  service. Skip rc/beta/nightly tags unless the feature we need only exists there, and
  say so if you do. Add a digest for anything security-sensitive.
- `container_name: pi-<service>`
- anything the service reads from the host goes in `config/<service>/`, and any
  script of its own is `scripts/<service>-*.sh` — that naming is what tells
  `make update` to recreate this container alone instead of the whole stack
  (step 10)
- `expose`, not `ports` — everything reaches the LAN through Traefik
- healthcheck built on an `x-healthcheck-*` anchor; check which tools the image
  actually ships first (curl/wget/bash/nc/python3 vary widely, and `CMD-SHELL`
  runs `/bin/sh`, so `/dev/tcp` needs `["CMD", "bash", "-c", ...]`)
- `deploy: *cpu-request-*`, `mem_limit`, `oom_score_adj` — the Pi has limited RAM
- state under `${DATA_LOCATION:-./data}/<service>`
- `depends_on` with `condition: service_healthy` only against services that
  really do declare a healthcheck

## 2. Traefik

Pick `<sub>` by who calls it: a service the household uses gets a **function**
name (`ai`, `vault`, `audiobooks`, `uptime`), an admin-only or infrastructure one
gets the **product** name (`traefik`, `backrest`, `lldap`, `beszel`). Single label
only - the certificate is `*.${HOST_NAME}`, so `a.b.${HOST_NAME}` needs its own
SANs entry. **`chat.` is reserved** for a future human-to-human messaging service;
do not spend it on anything else (see docs/AI.md).

Join `frontend` and add:

```yaml
- "traefik.enable=true"
- "traefik.docker.network=frontend"
- "traefik.http.routers.<svc>.rule=Host(`<sub>.${HOST_NAME:-pi.lan}`)"
- "traefik.http.routers.<svc>.entrypoints=websecure"
- "traefik.http.routers.<svc>.middlewares=lan@docker,authelia@docker"
- "traefik.http.routers.<svc>.tls=true"
- "traefik.http.services.<svc>.loadbalancer.server.port=<port>"
```

Services with their own account system (Immich, Kavita) use `lan@docker` alone —
do not stack forward-auth on top.

`tls=true` is not optional: `websecure` sets `http.tls.certresolver=cloudflare`,
which Traefik applies only to routers declaring no TLS config of their own. Omit
the label and the router inherits the resolver and orders a certificate for its
own domain instead of being served from the stack's wildcard.
`tests/compose-invariants.py` fails the build if a public router has no `tls`.

## 3. OIDC (Authelia)

If the service speaks OIDC/OAuth, wire it: see the "Adding OIDC (Authelia SSO) to a
service" section in `AGENTS.md`. If it does not, keep `authelia@docker` forward-auth
as the access control.

## 4. Postgres

Prefer the shared `postgres` over a per-service database container: add the database
to `config/postgres/init-databases.sh` (idempotent `SELECT 'CREATE DATABASE ...'`
pattern), join the matching internal network, and depend on `postgres` being healthy.

## 5. Redis

Reuse the shared `redis` (valkey) for cache/sessions instead of a new container.
Point the service at host `redis` and make sure both containers share an internal
network — add it to `redis`'s `networks` list if none matches.

## 6. ntfy

For services that can push notifications:

```yaml
networks: [..., ntfy]
env_file:
  - path: ./config/ntfy/ntfy.env
    required: false
extra_hosts:
  - "ntfy.${HOST_NAME:-pi.lan}:172.30.11.1"
```

Send to the topic matching the alert class (monitoring / downloads / security).

## 7. Uptime Kuma

Add the container name to the right group in `GROUPS` in
`scripts/uptime-kuma-bootstrap.py`; the group decides the alert tier and interval.

## 8. Backrest

If the service holds state worth keeping, mount its data read-only into backrest as
`/userdata/<service>` in `compose/compose-monitoring.yaml`. Databases are dumped
instead, via a `db-backup.sh` hook in `config/backrest/config.json.template`. Add
large regenerable data (thumbnails, transcodes, model caches) to the plan `excludes`.

## 9. Homepage

Add `homepage.group` / `name` / `icon` / `href` / `description` labels, plus a
`homepage.widget.*` block when a widget exists for the service — API keys are wired
by `scripts/homepage-widgets-bootstrap.sh`.

`homepage.group` doubles as the section the service is listed under in
`make config`, and `homepage.description` is the line shown beside it there. If
the service is pointless on its own (an addon, a worker, a sidecar), also add
`pi-pcloud.companion-of=<service>` so the picker nests it under the one it
belongs to and toggles the two together — and still give it a description: a
`homepage.*` label without `homepage.group` is discovered but never rendered,
so it stays off the dashboard.

## 10. First-run setup

Do it in `scripts/<service>-bootstrap.sh` (or `-pre-start.sh`), sourcing
`scripts/lib.sh`, idempotent and safe on a fresh install, wired into the
`PRE_START_HOOKS` / `POST_START_HOOKS` list of `scripts/run-hooks.sh` as
`<service>:<script>.sh` (the prefix gates it on `COMPOSE_PROFILES`). That one
list is what both the systemd unit and `make update` run.

The `<service>-` prefix is not cosmetic: `scripts/changed-services.sh` reads it
to decide which containers `make update` has to recreate when a pull rewrites
the script. Same for the config tree — call it `config/<service>/`. A file
matching neither is answered with "recreate everything", a full-stack down/up on
every update that touches it, and `tests/compose-invariants.py` fails the build
rather than let that ship.
No extra container just to run a script, and no new `.env` keys — reuse
`ADMIN_USER` / `PASSWORD` and the per-service config files.

If all the hook does is put one or more generated secrets in an env file, do not
write it — call lib.sh `ensure_env_secrets <file> <KEY>...`. It keeps values that
are already there, mints only the missing ones, repairs the directory a bind
mount leaves behind, writes 0600 and hands the file back to the project owner.
See `scripts/n8n-pre-start.sh` for the whole shape.

Anything the hook generates on the host has to end with lib.sh `fix_ownership`:
the unit runs it as root, and a root-owned `0600` file is one the next non-root
`make update` cannot read and `docker compose up` cannot load as an `env_file`.
`tests/stack-up-test.sh` enforces it.

## 11. Docs

Every place a service is enumerated, in the same change — these tables are where
past services silently fell out of the docs:

- `README.md` — Stack Overview table
- `docs/ARCHITECTURE.md` — Service Roles table
- `docs/SECURITY.md` — Per-Service Protection table (matching the *actual* Traefik
  middlewares), and the OIDC client + secrets lists if step 3 added a client
- `docs/MONITORING.md` — monitor group table if step 7 changed `GROUPS`
- The topical page (`NETWORKING.md`, `EMAIL.md`, …) if the service touches DNS,
  ports, mail or VPN

State the URL, auth path and any deliberate exception (e.g. "no forward-auth
because clients are programmatic") — the *why* is what the compose file can't say.

## 12. Verify

`docker compose config -q`, then bring the service up and check it actually reaches
healthy and answers through Traefik before declaring it done.
