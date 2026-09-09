---
name: add-service
description: Add a new service to the pi-pcloud docker compose stack, wiring the standard integrations (Traefik, Authelia OIDC, Postgres, Redis, ntfy, Uptime Kuma, Backrest, Homepage, systemd bootstrap). Use whenever a new container is added to compose.yaml, or when auditing an existing service for missing integrations.
---

# Adding a service to the stack

Copy the closest existing service in `compose.yaml` as a template, then work through
every integration below and skip only the ones that genuinely do not apply. Say
explicitly which ones you skipped and why.

## 1. Compose basics

- `<<: *service-defaults` (journald logging + `restart: unless-stopped`)
- pinned image tag — look up the newest **stable** release upstream before writing it
  (`docker buildx imagetools inspect <image>:latest`, the registry's tag list, or the
  project's GitHub releases page); never `latest`, never a tag guessed from another
  service. Skip rc/beta/nightly tags unless the feature we need only exists there, and
  say so if you do. Add a digest for anything security-sensitive.
- `container_name: pi-<service>`
- `expose`, not `ports` — everything reaches the LAN through Traefik
- healthcheck built on an `x-healthcheck-*` anchor; check which tools the image
  actually ships first (curl/wget/bash/nc/python3 vary widely, and `CMD-SHELL`
  runs `/bin/sh`, so `/dev/tcp` needs `["CMD", "bash", "-c", ...]`)
- `deploy: *cpu-request-*`, `mem_limit`, `oom_score_adj` — the Pi has limited RAM
- state under `${DATA_LOCATION:-./data}/<service>`
- `depends_on` with `condition: service_healthy` only against services that
  really do declare a healthcheck

## 2. Traefik

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
`/userdata/<service>` in `compose.yaml`. Databases are dumped instead, via a
`db-backup.sh` hook in `config/backrest/config.json.template`. Add large regenerable
data (thumbnails, transcodes, model caches) to the plan `excludes`.

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
`PRE_START_HOOKS` / `POST_START_HOOKS` list of `scripts/stack-up.sh` as
`<service>:<script>.sh` (the prefix gates it on `COMPOSE_PROFILES`). That one
list is what both the systemd unit and `make update` run.
No extra container just to run a script, and no new `.env` keys — reuse
`ADMIN_USER` / `PASSWORD` and the per-service config files.

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
