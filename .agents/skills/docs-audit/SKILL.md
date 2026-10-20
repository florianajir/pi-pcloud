---
name: docs-audit
description: Audit README.md, AGENTS.md and docs/ against the actual stack configuration, fixing factual drift and removing generic filler. Use for periodic documentation sweeps, after large refactors, or when docs are suspected stale.
---

# Documentation audit

Verify every factual claim in the docs against the files below, fix what is wrong,
and cut what is not useful. Never trust a doc's claim because it sounds plausible —
the drift that survives is exactly the plausible kind.

## Ground truth per doc

Read the source, then the doc — not the other way around.

| Doc | Verify against |
|-----|---------------|
| `README.md` | `compose/*.yaml` service list, `Makefile` targets |
| `docs/README.md` | the set of files actually in `docs/` |
| `docs/COMMANDS.md` | `Makefile` (targets, args, what each recipe actually runs), `scripts/update.sh`, `scripts/install-system.sh` |
| `docs/ARCHITECTURE.md` | `compose/*.yaml` (services) and `compose.yaml` (networks, volumes vs bind mounts), `${DATA_LOCATION}` layout |
| `docs/INSTALLATION.md` | `.env.dist`, `Makefile` `REQUIRED_ENV_VARS` + `install` recipe, first-run bootstrap scripts |
| `docs/CONFIGURATION.md` | `.env.dist`, compose `environment:` defaults (`${VAR:-default}`), the scripts a variable claims to drive |
| `docs/AI.md` | `llama-cpp`/`piper`/`parakeet`/`system-tools`/`open-webui` compose stanzas, `config/system-tools/app.py`, `config/piper/Dockerfile`, `scripts/open-webui-bootstrap.sh`, `scripts/llama-cpp-pre-start.sh` |
| `docs/TROUBLESHOOTING.md` | the command in each block actually runs as written, against the container/host it names |
| `docs/SECURITY.md` | Traefik labels in `compose/*.yaml` (middlewares per router, headers values), `config/authelia/configuration.yml.template` (access_control, session, OIDC clients), `scripts/authelia-pre-start.sh` (secrets) |
| `docs/NETWORKING.md` | compose `networks:` (subnets, static IPs, internal flags), published `ports:`, Pi-hole/Unbound config, `config/headscale/config.yaml` DNS block |
| `docs/MONITORING.md` | `scripts/uptime-kuma-bootstrap.py` (GROUPS), `scripts/beszel-agent-bootstrap.py` (thresholds), `scripts/ntfy-pre-start.sh` (topics, accounts), `scripts/authelia-ntfy-watch.sh` |
| `docs/BACKUP.md` | `config/backrest/config.json.template` (schedule, retention, hooks, excludes), the `backrest` volumes in `compose/compose-monitoring.yaml` (what is in a snapshot, the restore mapping), `scripts/db-backup.sh`, `scripts/sqlite-backup.sh`, `scripts/recovery-kit.sh` |
| `docs/EMAIL.md` | compose SMTP env per service, `config/authelia/configuration.yml.template` notifier block |
| `docs/TAILSCALE.md` | `config/headscale/config.yaml`, tailscale service `TS_EXTRA_ARGS`, `Makefile` headscale targets, `scripts/headscale-init.sh` |
| systemd claims anywhere | `config/systemd/system/pi-pcloud.service`, and `scripts/stack-up.sh` for which scripts run, pre vs post |

`config/headscale/config.yaml`, `config/ntfy/ntfy.env` and `config/beszel-agent/agent.env`
are **generated/live files that may contain secrets** — read them for structure only and
never quote keys, secrets or tokens into a doc.

## Checks that have caught real drift

- **Enumerations complete**: every compose service appears in README's stack table,
  ARCHITECTURE's roles table, and SECURITY's per-service table; every
  `client_id` in the Authelia template appears in SECURITY's OIDC table with its
  real scopes and `authorization_policy`.
- **No invented values**: every IP, subnet, port, path, volume name, group name and
  timeout in a doc must exist in a config file. Grep the doc's literals against the
  repo; a value with no source is a fabrication to delete or fix.
- **Variable tables match `.env.dist`** plus compose `${VAR:-default}` fallbacks —
  both directions: no documented variable that nothing reads, no required variable
  missing from the docs (`Makefile` `REQUIRED_ENV_VARS` is the "required" list).
- **Commands run as written**: middleware lists, `make` targets, `docker compose exec`
  invocations (does that binary/script exist *in that container*, or on the host?).
- **Version-sensitive claims** ("X doesn't support Y") get re-checked against the
  pinned image version — upstream moves.
- **Anchors and cross-links resolve** after edits — `make lint` runs
  `tests/docs-invariants.py`, which also checks the `docs/<PAGE>.md#anchor` hints
  scripts print.
- **No real domain or personal data** — `<HOST_NAME>` placeholders only.
- **"What leaves your network" is complete**: every service that sends user data to
  a third party (an API key in `.env.dist`, an external hostname in `config/`) has a
  row in README's table.
- **`.github/SECURITY.md` stays the disclosure policy** (how to report, supported
  versions, scope) and `docs/SECURITY.md` the design; GitHub shows the first one.

## What to remove

Two opposite failures, both noise for someone running the stack.

Generic filler that documents the internet instead of this stack: best-practice
listicles, per-provider recipes, OS-by-OS install walkthroughs, tutorial content for
upstream tools, diagrams restating a two-line fact.

The maintainer's lab notebook: project history ("used to", "renamed from", "Fixed —"),
incident narratives and ISO dates, household anecdotes and personal devices,
third-party quotas, prices and "observed at vX.Y" notes, the protocol behind a
measurement, upstream source-code internals the reader cannot act on, and any named
tracker, shadow library or torrent-scraper add-on. Rewrite it as the current fact,
in the present tense.

Keep what only this repo can provide: non-obvious decisions and deliberate security
exceptions, in one to three sentences each, and the numbers an operator plans or
operates with (footprint, durations, thresholds and their rationale). The full rule
is in AGENTS.md.

## Reporting

Summarize per file: what was factually wrong (with the correct value and its source),
and what was removed as filler. Distinguish verified-wrong from unverifiable; do not
"fix" a claim you could not check against a source.
