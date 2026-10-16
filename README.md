<div align="center">

<img src="docs/assets/banner.png" alt="pi-pcloud — your cloud, your data, your control" width="820">

**Your own private cloud, on a Raspberry Pi.**
Photos, files, passwords, VPN, ad-blocking DNS, backups and monitoring — one command, no subscription, your data on your own hardware.

[![CI](https://github.com/florianajir/pi-pcloud/actions/workflows/ci.yml/badge.svg)](https://github.com/florianajir/pi-pcloud/actions/workflows/ci.yml)
[![CodeQL](https://github.com/florianajir/pi-pcloud/actions/workflows/codeql.yml/badge.svg)](https://github.com/florianajir/pi-pcloud/actions/workflows/codeql.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Dependabot](https://badgen.net/badge/icon/dependabot?icon=dependabot&label)](https://github.com/florianajir/pi-pcloud/actions/workflows/dependabot/dependabot-updates)

[Quick start](#quick-start) · [What you get](#what-you-get) · [Documentation](docs/README.md)

</div>

---

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/florianajir/pi-pcloud/main/install.sh | sh
```

The installer checks prerequisites, clones the repo, asks only for what it cannot detect (domain, Cloudflare token, admin password), lets you pick which services to run, and deploys. Expect 5–10 minutes on a Pi 5.

Then open `https://lldap.<HOST_NAME>` to create your users, and `https://auth.<HOST_NAME>` to log in.

Prefer doing it by hand? See the [Installation guide](docs/INSTALLATION.md).

## What you get

- **One login for everything.** Authelia SSO + LLDAP directory, with 2FA on the admin surfaces. Services speak OIDC where they can, forward-auth where they can't.
- **Real HTTPS, everywhere.** Traefik terminates TLS with wildcard Let's Encrypt certificates issued over the Cloudflare DNS challenge, so nothing but `443` (TCP, plus UDP for HTTP/3) ever has to reach the internet.
- **Private DNS.** Pi-hole filters ads and trackers for your whole LAN; Unbound resolves recursively from the root servers, so most queries reach no DNS provider.
- **Reachable from anywhere, exposed to no one.** Headscale runs your own Tailscale control plane; everything but the login portal is restricted to your LAN and your tailnet.
- **Backups you can restore.** Backrest (restic) snapshots app data and databases nightly, encrypted and deduplicated, to any S3-compatible bucket.
- **Alerts on your phone.** Beszel watches the hardware, Uptime Kuma watches the services *through* Traefik, Prometheus records what they were doing at the time, and everything pushes to ntfy — split into muteable topics.
- **A local AI assistant.** Open WebUI on top of llama.cpp, with speech in and out, running entirely on the Pi's CPU. It can even report the machine's own health. Agentgateway puts one OpenAI-compatible endpoint with virtual keys in front of it, so your editor and your scripts reach the same models — and the same gateway federates MCP tool servers.

### Why not something else?

| | pi-pcloud | Manual install | Umbrel / CasaOS |
|---|---|---|---|
| Setup effort | one command | days of glue work | one command |
| HTTPS + SSO + DNS pre-wired | ✅ | ❌ | partial |
| Plain Docker Compose you can read | ✅ | ✅ | ❌ app store |
| Reproducible from Git, scriptable | ✅ | depends | ❌ |

## The stack

| Category | Services |
|----------|----------|
| **Cloud & storage** | Nextcloud, Immich, Vaultwarden, Forgejo, n8n, ntfy |
| **Communication** | Matrix chat: Tuwunel (homeserver) + Element Web, with a family assistant (OpenClaw, on a cloud model) as `@assistant`, in DMs and a family room |
| **Network & access** | Traefik, Authelia, LLDAP, Headscale + Headplane, Tailscale |
| **DNS & filtering** | Pi-hole, Unbound |
| **Download & media** | qBittorrent, Prowlarr, Kapowarr, Shelfmark, Kavita, Audiobookshelf, FreshRSS, Stremio, AIOStreams + AIOMetadata, StremThru, FlareSolverr, Gluetun |
| **Notes & knowledge** | Trilium, changedetection.io |
| **Search** | SearXNG |
| **AI** | Open WebUI, Agentgateway, llama.cpp, Piper (TTS), Parakeet (STT), system-tools |
| **Monitoring & backup** | Beszel, Uptime Kuma, Prometheus + Grafana, Homepage, Backrest, Dockhand |
| **Infrastructure** | PostgreSQL, Redis (Valkey), ddns-updater |

You don't have to run all of it. Core infrastructure always starts; every other service is toggled per-install with `make enable` / `make disable`, or the `make config` checklist — see [Choosing which services run](docs/CONFIGURATION.md#choosing-which-services-run).

## Requirements

| | |
|---|---|
| **Hardware** | Raspberry Pi 5, 8 GB RAM minimum — 16 GB recommended for the full stack |
| **Storage** | NVMe SSD HAT recommended (MicroSD degrades fast under continuous I/O) |
| **Domain** | A domain on Cloudflare (free tier) + an API token with `Zone → DNS → Edit` |
| **Software** | Docker and the Compose plugin — the installer offers to add them |
| **Router** | Forward `443/tcp`. Optionally `443/udp` for HTTP/3, and `41641/udp` + `3478/udp` for direct VPN links. For IPv6, allow inbound `443/tcp` (and `443/udp`) to the Pi in the IPv6 firewall — there is nothing to forward |
| **Off-site backup** | An S3-compatible bucket (optional but recommended) |

## What leaves your network

Your files, photos, passwords and chat stay on the Pi. These are the exceptions:

| What | Goes to | When |
|------|---------|------|
| DNS records for your domain, and the certificate challenge | Cloudflare (DNS only, never proxied) and Let's Encrypt | Always |
| A share of DNS queries | Cloudflare and Quad9, as Pi-hole's fallback upstreams — remove them in `PIHOLE_DNS_UPSTREAMS` ([why](docs/NETWORKING.md#the-dns-pipeline)) | By default |
| VPN traffic between two devices that cannot connect directly | Tailscale's public DERP relays, end-to-end encrypted | When a direct link fails |
| Backups | Your S3 bucket, encrypted by restic before upload | If configured |
| Messages, photos and documents sent to `@assistant` | Google Gemini, then OpenRouter once the free quota is spent ([details](docs/AI.md#the-family-assistant-openclaw)) | If `openclaw` runs |
| Requests your own clients send to the gateway's `/groq/v1` and `/openrouter/v1` routes | Groq, OpenRouter | If you use them |
| Web searches from the chat or the dashboard | The public engines SearXNG queries, from the Pi's address | If `searxng` runs |
| Torrent and indexer traffic | Your VPN provider, through Gluetun | If a download service runs |
| Stream lookups from Stremio | Your debrid service and the add-ons AIOStreams queries | If `aiostreams` runs |

Open WebUI's chat, speech-to-text and text-to-speech run on the Pi and send nothing out.

## Scope

pi-pcloud is one person's home setup, published. It targets a Raspberry Pi 5 on Raspberry Pi OS; other hardware may work but is not tested. There are no versioned installs: the installer clones `main`, `make update` follows it, and the monthly [releases](https://github.com/florianajir/pi-pcloud/releases) are dated changelogs to read before updating.

The download services (qBittorrent, Prowlarr, Kapowarr, Shelfmark, Stremio and its add-ons) are general-purpose tools, and Prowlarr starts with no indexer. Which sources you add, and what you download, is your responsibility under the law where you live.

## Everyday use

`make install` puts a `pi-pcloud` command on your `PATH`, so these work from any directory (`pi-pcloud status` = `make status`).

| Task | Command |
|------|---------|
| Start / stop | `make start` / `make stop` |
| Follow logs | `make logs` |
| Health at a glance | `make status`, `make doctor` |
| Turn a service on/off | `make enable <service>` / `make disable <service>` |
| Update code and images | `make update` |
| Update the images only | `make update-images` |

Full list: [Commands reference](docs/COMMANDS.md).

## Documentation

Everything lives in **[docs/](docs/README.md)** — start there. The pages people open first:

[Installation](docs/INSTALLATION.md) · [Configuration](docs/CONFIGURATION.md) · [Commands](docs/COMMANDS.md) · [Backups & restore](docs/BACKUP.md) · [Security](docs/SECURITY.md) · [Troubleshooting](docs/TROUBLESHOOTING.md)

## Contributing

Issues and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow and [AGENTS.md](AGENTS.md) for the conventions this repository holds itself to. Found a vulnerability? Follow the [security policy](.github/SECURITY.md) instead of opening an issue.

## License

[MIT](LICENSE) © Florian Ajir
