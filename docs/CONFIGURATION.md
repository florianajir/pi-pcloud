# Configuration

Everything is configured through `.env` at the root of the repository. Copy `.env.dist`, fill it in, and apply with `make restart`.

```bash
cp .env.dist .env
make check-env        # validates the required variables
make restart
```

> **Value syntax.** Do not use `$` or ` #` (whitespace + hash) in a value, do not end a value with `\`, do not quote values, and do not leave leading or trailing whitespace.
> Docker Compose interpolates `$VAR` inside `.env` (so `Sup3r$ecret!` reaches the services as `Sup3r!`, with only a warning in the logs), escapes the newline after a trailing backslash, truncates unquoted values at inline comments, strips surrounding quotes and trims edge whitespace — while the bootstrap scripts read `.env` verbatim, so any of those makes the two sides disagree. A backslash *inside* a value is fine.
> `make check-env` refuses such values, using the same `scripts/lib.sh` rule the installer applies at its prompts.

## Required variables

| Variable | Description | Example |
|----------|-------------|---------|
| `HOST_NAME` | Your domain name | `pi.example.com` |
| `TIMEZONE` | Server timezone | `Europe/Paris` |
| `ADMIN_USER` | Stack-wide admin username | `admin` |
| `PASSWORD` | LLDAP admin & Authelia password | `MySecurePassword123!` |
| `EMAIL` | Admin email & sender address | `admin@example.com` |
| `HOST_LAN_IP` | The Pi's static LAN IP — local DNS records point here | `192.168.1.30` |
| `CLOUDFLARE_DNS_API_TOKEN` | Cloudflare API token, `Zone → DNS → Edit` on your domain | *(dashboard)* |
| `CLOUDFLARE_ZONE_ID` | Your domain's zone ID | *(dashboard)* |

`make print-required-vars` prints this list as the Makefile actually enforces it.

**Generating the Cloudflare token:** dashboard → **API Tokens** → Create token → Permissions `Zone → DNS → Edit`, Zone resources `Include → your domain`.

## Optional variables

### General

| Variable | Default | Description |
|----------|---------|-------------|
| `DEFAULT_LANGUAGE` | `en-US` | Stack-wide language (BCP 47) — Open WebUI interface, Piper voice, suggestion tiles. See [Local AI](AI.md#language) |
| `DATA_LOCATION` | `./data` | Where persistent data lives — point it at your SSD |
| `NEXTCLOUD_DEFAULT_PHONE_REGION` | `FR` | ISO country code Nextcloud assumes for phone numbers without a prefix |
| `NEXTCLOUD_MAINTENANCE_WINDOW_START` | `2` | UTC hour at which Nextcloud runs its heavy background jobs |
| `COMPOSE_PROFILES` | `all` | Which optional services run — see [below](#choosing-which-services-run) |

### Host swap

| Variable | Default | Description |
|----------|---------|-------------|
| `SWAP_SIZE_MB` | `8192` | Size of `/var/swap`, applied by `make install` via `scripts/configure-swap.sh` |

Change the size here rather than in `/etc/dphys-swapfile`: `/sbin/dphys-swapfile` clamps
`CONF_SWAPSIZE` to its own `CONF_MAXSWAP=2048` default, so raising only the first does
nothing. The script raises both.

The default is 8192 rather than Raspberry Pi OS's 2048 because the model services load
their weights, go idle and have their cold pages evicted — which is what swap is for —
and need room left for the next spike. The `memswap_limit` ceilings in `compose/*.yaml`
are sized against this number — see
[Architecture](ARCHITECTURE.md#rationing-cpu-and-memory).

Resizing means `swapoff`, which pages everything in swap back into RAM at once.
The script only restarts `dphys-swapfile` when available RAM covers the
swapped-out set with 20% headroom, and otherwise leaves the new size to take
effect on the next reboot. It never fails the install.

`make install` also enables **zswap**, a compressed cache in RAM in front of the file,
so most of this size is only reached under real pressure — see
[Architecture](ARCHITECTURE.md#swap-and-zswap-in-front-of-it).

### Network

Defaults suit a `192.168.1.0/24` LAN. The installer auto-detects all of these except the two IPv6 entries, owned by a systemd timer and an explicit opt-in.

| Variable | Default | Notes |
|----------|---------|-------|
| `HOST_LAN_PARENT` | `eth0` | Network interface (`ip link` to find it). Must be wired — macvlan cannot use Wi-Fi |
| `HOST_LAN_SUBNET` | `192.168.1.0/24` | Your home network CIDR |
| `HOST_LAN_GATEWAY` | `192.168.1.1` | Your router's IP |
| `PIHOLE_IP` | `192.168.1.250` | Pi-hole's own LAN address — in the subnet, outside the DHCP range |
| `STREMIO_IP` | `192.168.1.251` | Only for the `stremio-lan` profile — Stremio's own LAN address, so it can discover cast renderers. Same constraints as `PIHOLE_IP`. The installer derives it from the detected subnet on a `/24`; on any other subnet it warns and you set it by hand. If it falls outside `HOST_LAN_SUBNET`, `stremio-lan-pre-start.sh` refuses the start and names the fix |
| `PIHOLE_DNS_UPSTREAMS` | `172.30.53.53#5335;1.1.1.1;9.9.9.9` | Semicolon-separated. dnsmasq load-balances across all of them rather than treating the first as primary, so the public resolvers do see a share of normal traffic — leave only the Unbound entry to stop that. See [Networking](NETWORKING.md#the-dns-pipeline) |
| `ALLOW_IP_RANGES` | `127.0.0.1/32,192.168.1.0/24,100.64.0.0/10,172.30.0.0/16,::1/128,fd7a:115c:a1e0::/48` | Comma-separated CIDRs allowed to reach the services, both families |
| `HOST_LAN_SUBNET6` | *(empty)* | Appended to `ALLOW_IP_RANGES`: the IPv6 prefix your ISP delegates to the LAN. No fixed default is possible, so `pi-pcloud-wan-allowlist.timer` reads it off `HOST_LAN_PARENT` and keeps it current — leave it to the timer. Empty means no IPv6 client is allowlisted. See [Networking](NETWORKING.md#ipv6) |
| `IPV6_PUBLIC_RECORDS` | *(empty)* | Any non-empty value publishes AAAA records for `<HOST_NAME>` and `*.<HOST_NAME>` — Compose can only test for emptiness, so `0` and `false` enable it too; use `1`, and empty to disable. Set it **after** allowing inbound `443/tcp` to the Pi in your router's IPv6 firewall — a firewall rule, not a port forward. Empty leaves public DNS as A records only, IPv6 still working from the LAN |
| `WAN_HAIRPIN_IP` | *(empty)* | Appended to `ALLOW_IP_RANGES`. IPv4 only — an IPv6 client is never hairpinned. Set it to your line's public address as a `/32` if your router hairpins — see [Networking](NETWORKING.md#routers-that-cannot-set-the-dhcp-dns-option). Maintained by `pi-pcloud-wan-allowlist.timer` once set, so leave it to the timer rather than editing it back |

`ALLOW_IP_RANGES` drives Traefik's `lan` middleware — see [Security](SECURITY.md#per-service-protection). In order: localhost, your home LAN (**adjust to your network**), the Tailscale allocation and the Docker internal networks, then localhost and the tailnet's IPv6 prefix (`fd7a:115c:a1e0::/48`); `HOST_LAN_SUBNET6` carries the IPv6 LAN. The Docker networks have no IPv6 entry on purpose: the only IPv6 source that could appear from inside is the bridge gateway, which is what `docker-proxy` substitutes when the IPv6 DNAT is missing — allowlisting it would turn that failure into an open door.

qBittorrent's `WebUI\AuthSubnetWhitelist` takes the list only when its config file is created, so it ignores later edits — harmless, since qBittorrent is reached through Traefik.

### S3 storage

Used by Backrest (backups), Beszel (snapshots and file uploads) and optionally Nextcloud external storage. Works with AWS S3, Scaleway, DigitalOcean Spaces and friends. **Set all five or leave all five empty** — a partial configuration errors.

| Variable | Example |
|----------|---------|
| `S3_ENDPOINT` | `https://s3.fr-par.scw.cloud` |
| `S3_BUCKET` | `my-pi-pcloud-backup` |
| `S3_REGION` | `fr-par` |
| `S3_ACCESS_KEY_ID` | *(from provider)* |
| `S3_SECRET_ACCESS_KEY` | *(from provider)* |

### Backrest (restic backups)

| Variable | Default | Notes |
|----------|---------|-------|
| `BACKREST_S3_URI` | `s3:${S3_ENDPOINT}/${S3_BUCKET}/restic` | Set explicitly for non-S3 storage |
| `BACKREST_S3_REPO_PASSWORD` | — | Repository encryption key. 32+ random characters. **Keep a copy off this machine** — see [Backups](BACKUP.md#the-env-file-twice) |
| `BACKREST_LOCAL_REPO_PASSWORD` | *(generated)* | Encryption key for the `usb` repository, which holds the `.env` history on the data disk. Left unset, `backrest-pre-start.sh` generates one into `${DATA_LOCATION}/backrest/repos/env-repo-password` so the disk can restore itself — see [Backups](BACKUP.md#the-env-file-twice) |
| `BACKREST_AUTH_USER` | — | **Not a knob**: `compose/compose-monitoring.yaml` pins the Backrest UI/API login to `${ADMIN_USER}`, so a `BACKREST_AUTH_USER` line in `.env` does nothing. Its password is not set here either — see below |
| `NEXTCLOUD_SQL_BACKUP_KEEP` | `7` in `.env.dist`, `30` if the line is absent | Nextcloud SQL dumps retained in `data/nextcloud-config/backups`, separate from the full backups |

Without complete S3 credentials Backrest still starts, but its `s3` repository is unusable — the pre-start script warns and the nightly plan has nowhere to write. The `usb` repository is unaffected — it is local and needs no S3 credentials — but it only covers `.env`. For a local-only setup, add a second repository under `/repos` (bind-mounted from `${DATA_LOCATION}/backrest/repos`, where `/repos/env` is already taken) in the Backrest UI. See [Backup strategy](BACKUP.md#what-is-backed-up).

**Restrict the S3 key.** Credentials that can delete objects, on a bucket without versioning or object lock, let anything that reads them destroy every snapshot. Give the backup key a bucket policy without `s3:DeleteObject` and keep a second, privileged key for the weekly prune — on Scaleway, for example:

```json
{
  "Version": "2023-04-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"SCW": "user_id:<backup-key-owner>"},
    "Action": ["s3:ListBucket", "s3:GetObject", "s3:PutObject"],
    "Resource": ["<bucket>", "<bucket>/*"]
  }]
}
```

Prune needs `DeleteObject`, so with this in place the weekly prune fails until it runs under the privileged key. The trade-off is deliberate: unused data accumulates instead of the repository being deletable by anything that reaches Backrest on port 9898.

### Beszel

| Variable | Default | Notes |
|----------|---------|-------|
| `BESZEL_S3_FORCE_PATH_STYLE` | `true` | Needed by most non-AWS providers |
| `BESZEL_BACKUP_CRON` | `0 3 * * *` | PocketBase snapshot schedule (`minute hour day month weekday`) |
| `BESZEL_BACKUP_MAX_KEEP` | `7` | Snapshots retained |
| `BESZEL_TEMP_ALERT_VALUE` | `70` | Temperature alert threshold, °C |
| `BESZEL_TEMP_ALERT_MIN` | `5` | Minutes over the threshold before alerting |
| `BESZEL_TEMP_ALERT_OVERWRITE` | `false` | Set to `true` to let the bootstrap overwrite alerts you edited in the Beszel UI |

`BESZEL_BACKUP_CRON` is the switch: leave it empty and PocketBase's built-in backups stay off entirely. The CPU (90%), memory (90%) and disk (85%) alerts are constants in `scripts/beszel-agent-bootstrap.py`, not variables — see [Monitoring](MONITORING.md#beszel--the-hardware).

### Email

| Variable | Default | Notes |
|----------|---------|-------|
| `SMTP_HOST` | `localhost` | Leave empty or `localhost` to disable email entirely |
| `SMTP_PORT` | `587` | 587 = STARTTLS, 465 = SSL, 25 = plain |
| `SMTP_USERNAME` | *(empty)* | Often your email address |
| `SMTP_PASSWORD` | *(empty)* | Use an app-specific password where the provider requires one |
| `SMTP_SECURE` | `tls` | Nextcloud only |
| `SMTP_AUTHTYPE` | `LOGIN` | Nextcloud only |
| `SMTP_ENCRYPTION` | `STARTTLS` | Authelia and LLDAP |
| `SMTP_SSL` | `false` | n8n only |
| `MAIL_FROM_ADDRESS` | `nextcloud` | Nextcloud sender local part; the domain is always `HOST_NAME` |

Which services read these, and which need setting up in their own UI: [Email & Notifications](EMAIL.md).

### Download VPN (Gluetun)

qBittorrent, Kapowarr and Stremio run inside Gluetun's network namespace, so all their traffic exits through the VPN tunnel. Gluetun's credentials live in **their own file**, not `.env`:

```bash
cp config/gluetun/gluetun.env.dist config/gluetun/gluetun.env
chmod 600 config/gluetun/gluetun.env
```

| Variable | Example |
|----------|---------|
| `VPN_SERVICE_PROVIDER` | `mullvad`, `nordvpn`, `protonvpn`, `custom` |
| `VPN_TYPE` | `wireguard` or `openvpn` |
| `WIREGUARD_PRIVATE_KEY` / `WIREGUARD_ADDRESSES` | *(from provider)* — `10.x.x.x/32` |
| `OPENVPN_USER` / `OPENVPN_PASSWORD` | *(from provider)* |
| `SERVER_COUNTRIES` | `Netherlands` |
| `FIREWALL_VPN_INPUT_PORTS` | `6881` — improves peer reachability |

The file is optional: without it Gluetun starts with no tunnel and traffic takes the host's default route. `chmod 600` because `cp` keeps the world-readable mode of the tracked `.dist` — this is the only secret file you create by hand; scripts generate the others as 0600.

qBittorrent's credentials (`ADMIN_USER` / `PASSWORD`) are applied on first start by `scripts/qbittorrent-bootstrap.sh`. The config template pre-authorises localhost and `ALLOW_IP_RANGES` so the bootstrap can call the API unauthenticated; it is idempotent on later restarts.

### Audiobook metadata (Hardcover)

| Variable | Description | Example |
|----------|-------------|---------|
| `HARDCOVER_API_KEY` | Hardcover personal access token, from [hardcover.app/account/api](https://hardcover.app/account/api) | `hc_pat_…` |

Optional, and only Shelfmark reads it. Hardcover is the one metadata provider wired here
that carries audiobook editions; without it, audiobook searches fall back to Open Library,
a *book* catalogue, and come back with paper metadata or nothing.

Set it and `scripts/shelfmark-settings-bootstrap.sh` enables Hardcover and makes it the
**default** audiobook provider on the next `make update`; each user can still pick another.
Remove it and the next run releases that selection back to the book provider. The key
already stored in Shelfmark stays — a key pasted by hand looks the same — so clear it under
**Settings → Hardcover** if you want it gone.

The key goes into Shelfmark's `plugins/hardcover.json` rather than its environment, so
`docker inspect` never prints it — the same rule as the OIDC client secrets.

## Auto-generated secrets

These need no configuration, must not be edited by hand, and have no effect if set in `.env`:

- **`BACKREST_AUTH_PASSWORD`** — the Backrest UI/API password. `scripts/backrest-pre-start.sh` generates it into `config/backrest/backrest.env`, loaded as an `env_file`, and the image entrypoint hashes it into `config.json` on every start; Backrest refuses to start with no login at all. Read it with `grep BACKREST_AUTH_PASSWORD config/backrest/backrest.env`. Rotate it with `make rotate-secret TARGET=backrest-auth`, which also updates Homepage's copy in `config/homepage/secrets/backrest_password` — without that, the Homepage widget answers `401 Unauthorized`.
- **`N8N_RUNNERS_AUTH_TOKEN`** — `scripts/n8n-pre-start.sh` generates it into `config/n8n/n8n.env`, loaded by both `n8n` and `n8n-runners`. Rotate it with `make rotate-secret TARGET=n8n-runner`.

Most of the rest are generated on first start, mode `600`, under `${DATA_LOCATION}/authelia-config/secrets/` — by `scripts/authelia-pre-start.sh`, plus the Vaultwarden `/admin` token from `scripts/vaultwarden-pre-start.sh`; `scripts/headscale-init.sh` generates `config/headplane/headscale_api_key`. Full inventory: [Security → Secrets](SECURITY.md#secrets).

## Choosing which services run

Every optional service in `compose/*.yaml` carries a [Compose profile](https://docs.docker.com/compose/how-tos/profiles/) named after itself (plus a catch-all `all`). `COMPOSE_PROFILES` selects them:

```env
COMPOSE_PROFILES=all                                          # everything (the default)
COMPOSE_PROFILES=immich-server,nextcloud,stremio,llama-cpp    # a selection
COMPOSE_PROFILES=                                             # core services only
```

**Core services always run** (they carry no profile): `traefik`, `authelia`, `lldap`, `postgres`, `redis`, `pihole`, `unbound`, `headscale`, `tailscale`, `ntfy`, `backrest`, `ddns-updater`, `homepage`. Pi-hole and Unbound stay core because subdomain resolution depends on the Pi-hole wildcard record; Headscale and Tailscale stay core because they provide remote access to everything else.

**Optional services:** `beszel`, `beszel-agent`, `uptime-kuma`, `dockhand`, `n8n`, `n8n-runners`, `headplane`, `immich-server`, `immich-machine-learning`, `nextcloud`, `gluetun`, `qbittorrent`, `stremio`, `stremio-lan`, `aiostreams`, `aiometadata`, `stremthru`, `prowlarr`, `kapowarr`, `flaresolverr`, `kavita`, `shelfmark`, `audiobookshelf`, `freshrss`, `searxng`, `trilium`, `changedetection`, `forgejo`, `tuwunel`, `element`, `vaultwarden`, `llama-cpp`, `piper`, `parakeet`, `system-tools`, `open-webui`, `agentgateway`, `openclaw`, `prometheus`, `grafana`.

`stremio` and `stremio-lan` are the same server in two networking modes and are **mutually exclusive** — they share one data volume and the same Traefik host rules. `stremio` is the default (VPN); pick `stremio-lan` only to cast to a DLNA/UPnP renderer, and read the trade-off in [Networking → Casting](NETWORKING.md#casting-to-a-dlna-renderer) first. `stremio-lan` is not part of `all`.

`make config` unticks one box when you tick the other, `make enable` refuses and names the service to disable first, and `stack-up.sh` refuses an `.env` that lists both. Switching modes is therefore two steps:

```bash
make disable stremio
make enable stremio-lan
```

**Some services pull in their dependencies** — the dependency carries the dependent's profile too, so enabling one starts both:

| Enabling | Also starts |
|----------|-------------|
| `qbittorrent`, `stremio` or `kapowarr` | `gluetun` (their VPN network namespace) |
| `stremio-lan` | nothing — it is deliberately off the VPN |
| `n8n-runners` | `n8n` |
| `beszel-agent` | `beszel` |
| `prowlarr` | `flaresolverr` |
| `open-webui` | `agentgateway` (it reaches the models through the gateway, not `llama-cpp` directly) and `searxng` (its web search) |
| `openclaw` | `tuwunel`, `element`, `agentgateway` and `searxng` — the [assistant](AI.md#the-family-assistant-openclaw) is a bot on that homeserver that thinks through the gateway and searches through SearXNG. Forgejo is optional: without it, the assistant's memory stays in its own volume |
| `tuwunel` | `element` |

Disabling `searxng` has one consequence outside its own service: Homepage's search box and
quick-launch bar submit to `search.<HOST_NAME>` in the browser, and start answering 404. Set
`provider: duckduckgo` in `config/homepage/widgets.yaml` and `settings.yaml` to put them back
on a hosted engine.

### Managing the selection

```bash
make config              # interactive checklist — the comfortable path
make services            # list each optional service and whether it is enabled
make enable stremio      # add to COMPOSE_PROFILES and start it (plus dependencies)
make disable stremio     # remove from COMPOSE_PROFILES and stop it
```

`make config` opens a terminal picker; on confirm it rewrites `COMPOSE_PROFILES` and starts or stops whatever changed. Services are listed under the section they belong to, and one that is pointless on its own is indented under its parent:

```
Choose which services run — applying starts and stops containers now
36/37 enabled · Traefik, Authelia, Pi-hole, Headscale, Postgres … always run
RAM ceilings 35.6G of 15.6G · 2.3x — overcommitted, as designed
measured here 8.6G held, 22.6G at their peaks · 5 never run here
── Download ──────────────────────────────────────────────────────────────
 [x] prowlarr              173M/512M  Torrent search aggregator
 [x]   flaresolverr        382M/768M  Cloudflare challenge solver for Prowlarr
 [x] qbittorrent            72M/512M  Torrent client (VPN protected)
── Video ─────────────────────────────────────────────────────────────────
 [x] stremio                    1.0G  Movie and TV streaming (VPN protected)
 [x]   aiostreams          190M/768M  Stream aggregator and filtering for Stremio
```

Ticking propagates transitively along both relations — the dependencies in the table above and the companion indent — so the screen always shows a set the stack can run: unticking `gluetun` unticks `qbittorrent`, `kapowarr`, `stremio` and, through `stremio`, `aiostreams`. The footer names whatever moved.

**The pair beside each service is what it holds here over what it may take.** The right-hand number is its `mem_limit` from `compose/*.yaml`; the left-hand one is what `scripts/ram-usage.sh` last measured it holding on *this* host, missing for a service the host has never run. The third header line totals the ceilings of the ticked services plus the always-on ones the screen does not list; the fourth totals the measured side and counts the services it has no reading for.

A service is coloured red when it is worth a quarter of the host's RAM and amber past a tenth — graded on its measured peak once there is one, on its ceiling until then.

`make services`, `make enable` and `make disable` print the same totals, which is the only place a host without `python3` sees them:

```
🧠 RAM 8.5G held by 46 containers · 7.2G free of 15.6G · swap 5.3G of 8.0G
   ceilings 33.9G for this selection — 2.2x the host, overcommitted by design
```

The first line is measured and answers *can I afford this*; the second is the picker's ceiling total. With nothing running to measure — a fresh install, a stopped stack — only the second line is printed, with a warning past 2.5×. `make enable` and `make disable` add what the change itself costs or frees:

```
✅ kavita disabled
   - kavita                     1.0G ceiling · 329M measured here
```

**Ceilings are not usage.** The stack is overcommitted on purpose ([Rationing CPU and memory](ARCHITECTURE.md#rationing-cpu-and-memory)): a limit is what a service may take when it misbehaves, not what it holds. So the header is green when the selection fits even if every service peaked at once, amber for the ordinary overcommitted stack, and red past 2.5×. It is a hint for choosing between services, not a verdict — what decides is which services peak together. Once a service has run, `make doctor` reports which ceilings are binding and which were never approached ([Monitoring](MONITORING.md#ceilings-and-what-psi-cannot-see)).

**The measured numbers** live in `.ram-observed` beside `.env` — gitignored, specific to this machine, and refreshed by every `make services`, `make enable`, `make disable` and `make doctor`, since a container's cgroup readings die with it. Peaks are kept as a maximum across restarts, readings survive a service being disabled, and a container less than an hour old can seed a row but never overwrite one. Deleting the file is harmless: the screen falls back to ceilings until the next command refills it.

The layout is read from `compose/*.yaml` — `homepage.group` for the section, `homepage.description` for the text, `pi-pcloud.companion-of` for the indent, `profiles:` for the dependencies, `mem_limit` for the ceilings — so the picker cannot drift from the stack. It is `scripts/services-picker.py`, standard-library `curses` only; on a host without `python3`, use `make enable` / `make disable`. All three targets wrap `scripts/services.sh`, which writes `.env` and runs the hooks.

**Enabling runs the service's init hooks** — `scripts/<service>-pre-start.sh` before the start, `scripts/<service>-bootstrap.sh` / `-oidc-bootstrap.sh` after — plus four hooks of always-on services that cover the new one: `authelia-pre-start.sh` (its OIDC client secret), `postgres-bootstrap.sh` (its role and database, which `init-databases.sh` only creates on a fresh cluster), `homepage-widgets-bootstrap.sh` (its widget key) and `uptime-kuma-bootstrap.sh` (its monitor). Disabling runs the last two as well, so the monitor is paused rather than alerting on a removed container. These are the scripts the systemd unit runs, so no `make restart` is needed.

The hooks — and only they — run through `sudo`, because what they write under `DATA_LOCATION` belongs to the root-run unit. A failing hook stops the start and restores the previous `COMPOSE_PROFILES` line, so a service that never started is not left marked as enabled.

> An `.env` with no `COMPOSE_PROFILES` line runs everything under systemd, whose unit defaults the variable to `all` — but manual `docker compose` invocations get no default, so keep the line.

## Changing passwords

**The admin password (`PASSWORD`) after a leak** — set the new value in `.env`, then:

```bash
make rotate-password         # LLDAP admin account + Authelia's bind secret
make rotate-password-full    # the above, plus every Postgres role and every service using PASSWORD
```

Editing `.env` alone is **not enough**: LLDAP does not reset an existing admin's password to match the env var on startup. `make rotate-password` performs the actual LDAP password-modify operation and updates Authelia's `ldap_password` secret — and since everything logs in through Authelia SSO, that is the credential a leaked `PASSWORD` actually exposes.

`rotate-password-full` additionally covers Nextcloud, Vaultwarden, Pi-hole, qBittorrent, Prowlarr, Kapowarr, Beszel, ntfy and Dockhand, in an order that matters — the header of `scripts/rotate-password.sh` explains it. Done by hand out of order, it breaks things.

A Postgres role and the connection string in its container's environment must move together. A role rotated without its container being recreated keeps working on the established connection, then fails at the *next* recreate — an unrelated reboot or image bump much later. `rotate-password-full` does both; do not rotate roles by hand.

**A regular user** resets their own password from the Authelia portal (**Account → Change password**) or has it reset from the LLDAP admin UI.

**Authelia's own secrets** are auto-generated. To regenerate them all, delete `${DATA_LOCATION}/authelia-config/secrets/` and restart — this invalidates every session and everyone must log in again.

## Customising further

A `compose.override.yaml` is not the way to switch services off — `profiles:` lists *merge* across compose files, so an override can only add activation profiles, never remove the built-in ones. Use `make enable` / `make disable`, and verify with `make services`.

Non-secret behaviour lives in `config/<service>/` (Traefik is the exception: it is configured entirely by CLI flags and labels in `compose/compose-core.yaml`). Secrets and anything a script reads belong in `.env`. Either way, apply with `make restart`.

To add a service to the stack, follow the [add-service checklist](../.agents/skills/add-service/SKILL.md) — it covers the Compose profile, Traefik labels, the Authelia OIDC client, shared Postgres/Redis, ntfy, Uptime Kuma, Backrest, Homepage labels and the systemd bootstrap hook.

**Back up what cannot be regenerated** — `.env` and the Authelia secrets — somewhere other than the Pi:

```bash
tar -czf pi-pcloud-config-backup.tar.gz .env config/ data/authelia-config/secrets/
```
