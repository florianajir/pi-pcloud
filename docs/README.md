# Documentation

## Getting started

| | |
|---|---|
| **[Installation](INSTALLATION.md)** | Prerequisites, the guided installer, manual install, first login |
| **[Configuration](CONFIGURATION.md)** | Every `.env` variable, choosing which services run, rotating passwords |
| **[Commands](COMMANDS.md)** | The `pi-pcloud` command and every `make` target |

## How it works

| | |
|---|---|
| **[Architecture](ARCHITECTURE.md)** | What each service is for, how they are isolated, where the data lives |
| **[Security](SECURITY.md)** | Login flows, OIDC clients, per-service protection, secrets, sessions |
| **[Networking](NETWORKING.md)** | The DNS pipeline, Docker networks, exposed ports, Cloudflare records |

## Using it

| | |
|---|---|
| **[VPN](TAILSCALE.md)** | Connecting devices, exit node, MagicDNS, managing nodes |
| **[Monitoring](MONITORING.md)** | Beszel, Uptime Kuma, Prometheus, ntfy topics and alerts |
| **[Backups & restore](BACKUP.md)** | What a snapshot holds, the recovery kit, rebuilding on new hardware |
| **[Email](EMAIL.md)** | SMTP setup and which service sends what |
| **[Local AI](AI.md)** | The model, the gateway, the family assistant, speech in and out, the host-status tool |
| **[Postgres upgrades](POSTGRES-UPGRADE.md)** | Moving the shared cluster to a new major: the cutover, verification, rollback |

## When something breaks

**[Troubleshooting](TROUBLESHOOTING.md)** — startup, access, DNS, VPN, email, monitoring and AI, in one place.

---

Contributing to the project itself? See [CONTRIBUTING.md](../CONTRIBUTING.md) and [AGENTS.md](../AGENTS.md). Reporting a vulnerability? See the [security policy](../.github/SECURITY.md).
