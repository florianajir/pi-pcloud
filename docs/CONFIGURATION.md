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

**Two settings are needed, and raising only the obvious one does nothing.**
`/etc/dphys-swapfile` holds `CONF_SWAPSIZE`, but `/sbin/dphys-swapfile` carries
its own `CONF_MAXSWAP=2048` and clamps the request down to it — "restricting to
config limit" — so the script sets both.

**Why 8192 and not the 2048 Raspberry Pi OS ships.** A full swap file is not a
fault on this box; the model services load their weights, go idle, and have
their cold pages evicted exactly once, which is what swap is *for*. But
`parakeet`, `llama-cpp`, `open-webui` and `immich-machine-learning` filled a
4096 MB file to 99.99% between them, and a swap file with 360 kB free has no
room for the next spike. The `memswap_limit` ceilings in `compose.yaml` are
sized against this number — see
[Architecture](ARCHITECTURE.md#rationing-cpu-and-memory).

Resizing means `swapoff`, which pages everything in swap back into RAM at once.
The script only restarts `dphys-swapfile` when available RAM covers the
swapped-out set with 20% headroom, and otherwise leaves the new size to take
effect on the next reboot. It never fails the install.

The file is not the whole story: `make install` also enables **zswap**, a
compressed cache in RAM in front of it, so most of this size is only reached
under real pressure — see
[Architecture](ARCHITECTURE.md#swap-and-zswap-in-front-of-it).

### Network

Defaults suit a `192.168.1.0/24` LAN. The installer auto-detects all of these except the two IPv6 entries, owned by a systemd timer and an explicit opt-in.

| Variable | Default | Notes |
|----------|---------|-------|
| `HOST_LAN_PARENT` | `eth0` | Network interface (`ip link` to find it). Must be wired — macvlan cannot use Wi-Fi |
| `HOST_LAN_SUBNET` | `192.168.1.0/24` | Your home network CIDR |
| `HOST_LAN_GATEWAY` | `192.168.1.1` | Your router's IP |
| `PIHOLE_IP` | `192.168.1.250` | Pi-hole's own LAN address — in the subnet, outside the DHCP range |
| `STREMIO_IP` | `192.168.1.251` | Only for the `stremio-lan` profile — Stremio's own LAN address, so it can discover cast renderers. Same constraints as `PIHOLE_IP`. The installer derives it from the detected subnet on a `/24`; on any other subnet it warns and you set it by hand. An `.env` from before this variable existed has no line for it — `stremio-lan-pre-start.sh` refuses the start and names the fix rather than letting Compose fail with "Invalid address" |
| `PIHOLE_DNS_UPSTREAMS` | `172.30.53.53#5335;1.1.1.1;9.9.9.9` | Semicolon-separated. dnsmasq load-balances across all of them rather than treating the first as primary, so the public resolvers do see a share of normal traffic — leave only the Unbound entry to stop that. See [Networking](NETWORKING.md#the-dns-pipeline) |
| `ALLOW_IP_RANGES` | `127.0.0.1/32,192.168.1.0/24,100.64.0.0/10,172.30.0.0/16,::1/128,fd7a:115c:a1e0::/48` | Comma-separated CIDRs allowed to reach the services, both families |
| `HOST_LAN_SUBNET6` | *(empty)* | Appended to `ALLOW_IP_RANGES`: the IPv6 prefix your ISP delegates to the LAN. No fixed default is possible, so `pi-pcloud-wan-allowlist.timer` reads it off `HOST_LAN_PARENT` and keeps it current — leave it to the timer. Empty means no IPv6 client is allowlisted. See [Networking](NETWORKING.md#ipv6) |
| `IPV6_PUBLIC_RECORDS` | *(empty)* | Any non-empty value publishes AAAA records for `<HOST_NAME>` and `*.<HOST_NAME>` — Compose can only test for emptiness, so `0` and `false` enable it too; use `1`, and empty to disable. Set it **after** allowing inbound `443/tcp` to the Pi in your router's IPv6 firewall — a firewall rule, not a port forward. Empty leaves public DNS as A records only, IPv6 still working from the LAN |
| `WAN_HAIRPIN_IP` | *(empty)* | Appended to `ALLOW_IP_RANGES`. IPv4 only — an IPv6 client is never hairpinned. Set it to your line's public address as a `/32` if your router hairpins — see [Networking](NETWORKING.md#routers-that-cannot-set-the-dhcp-dns-option). Maintained by `pi-pcloud-wan-allowlist.timer` once set, so leave it to the timer rather than editing it back |

`ALLOW_IP_RANGES` in order: localhost, your home LAN (**adjust to your network**), the Tailscale allocation, and the Docker internal networks — then the same four for IPv6, except the LAN, which `HOST_LAN_SUBNET6` carries instead. `fd7a:115c:a1e0::/48` is the tailnet's IPv6 prefix. The Docker networks have no IPv6 counterpart on purpose: only Traefik has an IPv6 address and it never calls itself, so the one source that could come from `ingress6` is its gateway — which is what `docker-proxy` substitutes when the IPv6 DNAT is missing, and allowlisting it would turn that failure into an open door. It drives Traefik's `lan` middleware — see [Security](SECURITY.md#per-service-protection).

Three services read it, and one does not pick up a later edit: qBittorrent's `WebUI\AuthSubnetWhitelist` is written only when its config file is created. Harmless — it is reached through Traefik, which has the current list.

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
| `BACKREST_S3_REPO_PASSWORD` | — | Repository encryption key. 32+ random characters. **Keep a copy off this machine** — see [Monitoring](MONITORING.md#the-env-file-twice) |
| `BACKREST_LOCAL_REPO_PASSWORD` | *(generated)* | Encryption key for the `usb` repository, which holds the `.env` history on the data disk. Left unset, `backrest-pre-start.sh` generates one into `${DATA_LOCATION}/backrest/repos/env-repo-password` so the disk can restore itself — see [Monitoring](MONITORING.md#the-env-file-twice) |
| `BACKREST_AUTH_USER` | — | **Not a knob**: `compose.yaml` pins the Backrest UI/API login to `${ADMIN_USER}`, so a `BACKREST_AUTH_USER` line in `.env` does nothing. Its password is not set here either — see below |
| `NEXTCLOUD_SQL_BACKUP_KEEP` | `7` in `.env.dist`, `30` if the line is absent | Nextcloud SQL dumps retained in `data/nextcloud-config/backups`, separate from the full backups |

Without complete S3 credentials Backrest still starts, but its `s3` repository is unusable — the pre-start script warns and the nightly plan has nowhere to write. The `usb` repository is unaffected — it is local and needs no S3 credentials — but it only covers `.env`. For a local-only setup, add a second repository under `/repos` (bind-mounted from `${DATA_LOCATION}/backrest/repos`, where `/repos/env` is already taken) in the Backrest UI. See [Backup strategy](MONITORING.md#backup-strategy).

**Restrict the S3 key.** The credentials Backrest holds can delete objects, and the bucket has no versioning or object lock, so anything that reads them can destroy every snapshot. In the Scaleway console, give the backup key a bucket policy without `s3:DeleteObject` and keep a second, privileged key for the weekly prune:

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

Prune needs `DeleteObject`, so with this in place the Sunday prune fails until it runs under the privileged key. The trade-off is deliberate: unused data accumulates instead of the repository being deletable by anything that reaches port 9898.

### Beszel

| Variable | Default | Notes |
|----------|---------|-------|
| `BESZEL_S3_FORCE_PATH_STYLE` | `true` | Needed by most non-AWS providers |
| `BESZEL_BACKUP_CRON` | `0 3 * * *` | PocketBase snapshot schedule (`minute hour day month weekday`) |
| `BESZEL_BACKUP_MAX_KEEP` | `7` | Snapshots retained |
| `BESZEL_TEMP_ALERT_VALUE` | `70` | Temperature alert threshold, °C |
| `BESZEL_TEMP_ALERT_MIN` | `5` | Minutes over the threshold before alerting |
| `BESZEL_TEMP_ALERT_OVERWRITE` | `false` | Set to `true` to let the bootstrap overwrite alerts you edited in the Beszel UI |

`BESZEL_BACKUP_CRON` is the switch: leave it empty and PocketBase's built-in backups stay off entirely. The CPU (90%), memory (90%) and disk (85%) alerts are constants in `scripts/beszel-agent-bootstrap.sh`, not variables — see [Monitoring](MONITORING.md#beszel--the-hardware).

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

The file is optional: without it Gluetun starts with no tunnel and traffic takes the host's default route. `chmod 600` because `cp` copies the mode of `.dist`, which is tracked in Git and therefore world-readable — every other secret file in this repo is generated 0600 by a script (`lib.sh`'s `write_secret_file`), and this is the only one you create by hand.

qBittorrent's credentials (`ADMIN_USER` / `PASSWORD`) are applied on first start by `scripts/qbittorrent-bootstrap.sh`. The config template pre-authorises localhost and `ALLOW_IP_RANGES` so the bootstrap can call the API unauthenticated; it is idempotent on later restarts.

### Audiobook metadata (Hardcover)

| Variable | Description | Example |
|----------|-------------|---------|
| `HARDCOVER_API_KEY` | Hardcover personal access token, from [hardcover.app/account/api](https://hardcover.app/account/api) | `hc_pat_…` |

Optional, and only Shelfmark reads it. Without it, audiobook searches fall back to the
book metadata provider — Open Library, a *book* catalogue with essentially no audio
edition data, so audiobook results come back with paper metadata or nothing. Hardcover
is the one provider wired here that carries audiobook editions.

Set it and `scripts/shelfmark-settings-bootstrap.sh` enables Hardcover and makes it the
**default** audiobook provider on the next `make update`. Remove it and the next run
releases that selection back to the book provider — leaving Hardcover selected with a key
nobody supplies any more would point every audiobook search at a provider that can only
fail. The key already stored in Shelfmark is deliberately left in place, since one pasted
into **Settings → Hardcover** by hand is indistinguishable from one the bootstrap wrote;
clear it there if you want it gone.

Two deliberate details. The key is written into Shelfmark's `plugins/hardcover.json`
rather than its environment, so `docker inspect` never prints it — the same rule as the
OIDC client secrets. And the provider choice is written as a config-file default rather
than an environment variable, because Shelfmark's environment values *always* win over
per-account settings (`core/config.py`): putting it there would freeze every user's
audiobook provider instead of moving the default they can still change.

## Auto-generated secrets

`BACKREST_AUTH_PASSWORD` is deliberately absent from this table: setting it in `.env` has no effect. `scripts/backrest-pre-start.sh` generates it into `config/backrest/backrest.env`, which the service loads as an `env_file`, and the image entrypoint hashes it into `config.json` on every start. Read it with `grep BACKREST_AUTH_PASSWORD config/backrest/backrest.env`; rotate it by deleting the line, then running `sudo sh scripts/backrest-pre-start.sh`, `docker compose up -d backrest` and `sudo sh scripts/homepage-widgets-bootstrap.sh` — that last step is not optional: Homepage authenticates to Backrest with its own copy at `config/homepage/secrets/backrest_password`, and without the sync its widget answers `401 Unauthorized`. The bootstrap restarts Homepage itself when the value changed. Backrest refuses to start if it ends up with no login at all.

`N8N_RUNNERS_AUTH_TOKEN` is absent for the same reason, and setting it in `.env` has no effect either: `scripts/n8n-pre-start.sh` generates it into `config/n8n/n8n.env`, which both `n8n` and `n8n-runners` load as an `env_file`. It used to be a hard-coded default in `compose.yaml`, shared by every install — see [Security → Secrets](SECURITY.md#secrets). Rotate it by deleting the file and running `docker compose up -d n8n n8n-runners`; `env_file` values are frozen at container creation, so `restart` keeps the old one.

These need no configuration and must not be edited by hand. `scripts/authelia-pre-start.sh` generates most of them on first start with mode `600` under `${DATA_LOCATION}/authelia-config/secrets/`, joined there by `scripts/vaultwarden-pre-start.sh` for the Vaultwarden `/admin` token; `scripts/headscale-init.sh` generates `config/headplane/headscale_api_key`. Full inventory: [Security → Secrets](SECURITY.md#secrets).

## Choosing which services run

Every optional service in `compose.yaml` carries a [Compose profile](https://docs.docker.com/compose/how-tos/profiles/) named after itself (plus a catch-all `all`). `COMPOSE_PROFILES` selects them:

```env
COMPOSE_PROFILES=all                                          # everything (the default)
COMPOSE_PROFILES=immich-server,nextcloud,stremio,llama-cpp    # a selection
COMPOSE_PROFILES=                                             # core services only
```

**Core services always run** (they carry no profile): `traefik`, `authelia`, `lldap`, `postgres`, `redis`, `pihole`, `unbound`, `headscale`, `tailscale`, `ntfy`, `backrest`, `ddns-updater`, `homepage`. Pi-hole and Unbound stay core because subdomain resolution depends on the Pi-hole wildcard record; Headscale and Tailscale stay core because they provide remote access to everything else.

**Optional services:** `beszel`, `beszel-agent`, `uptime-kuma`, `dockhand`, `n8n`, `n8n-runners`, `headplane`, `immich-server`, `immich-machine-learning`, `nextcloud`, `gluetun`, `qbittorrent`, `stremio`, `stremio-lan`, `comet`, `prowlarr`, `kapowarr`, `flaresolverr`, `kavita`, `shelfmark`, `audiobookshelf`, `freshrss`, `trilium`, `vaultwarden`, `llama-cpp`, `piper`, `parakeet`, `system-tools`, `open-webui`, `agentgateway`.

`stremio` and `stremio-lan` are the same server in two networking modes and are **mutually exclusive** — they share one data volume and the same Traefik host rules. `stremio` is the default (VPN); pick `stremio-lan` only to cast to a DLNA/UPnP renderer, and read the trade-off in [Networking → Casting](NETWORKING.md#casting-to-a-dlna-renderer) first. `stremio-lan` is not part of `all`.

The exclusion is declared once, as `pi-pcloud.conflicts-with` on `stremio-lan` in `compose.yaml`, and enforced everywhere a selection is made: `make config` unticks one box when you tick the other, `make enable` refuses and names the service to disable first, and `stack-up.sh` refuses a hand-edited `.env` before anything starts. Switching modes is therefore two steps:

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
| `open-webui` | `agentgateway` (it reaches the models through the gateway, not `llama-cpp` directly) |

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
26/27 enabled · Traefik, Authelia, Pi-hole, Headscale, Postgres … always run
── Download ──────────────────────────────────────────────────────────────
 [x] prowlarr                   Indexer manager
 [x]   flaresolverr             Cloudflare challenge solver for Prowlarr
 [x] qbittorrent                Torrent client (VPN protected)
── Video ─────────────────────────────────────────────────────────────────
 [x] stremio                    Streaming server (VPN protected)
 [x]   comet                    Stremio debrid addon
```

Ticking propagates along both dependency relations — the hard ones in the table above, and the companion indent — transitively, so the screen always shows a set the stack can actually run: unticking `gluetun` unticks `qbittorrent`, `kapowarr`, `stremio` and — through `stremio` — `comet`. The footer names whatever moved.

The whole layout is read out of `compose.yaml` (`homepage.group` for the section, `homepage.description` for the text, `pi-pcloud.companion-of` for the indent, `profiles:` for the hard dependencies), so the picker cannot drift from the stack. It is `scripts/services-picker.py`, standard-library `curses` only — nothing to install on Raspberry Pi OS, and on a host without `python3` you simply use `make enable` / `make disable` instead. All three targets wrap `scripts/services.sh`, which is what actually writes `.env` and runs the hooks.

Enabling also runs the service's init hooks — `scripts/<service>-pre-start.sh` before the start, `scripts/<service>-bootstrap.sh` / `-oidc-bootstrap.sh` after — the same scripts the systemd unit runs. So no `make restart` is needed: the stack is immediately consistent, and the unit reads the same `.env` at next boot.

> **Upgrading an older install:** an `.env` with no `COMPOSE_PROFILES` line keeps running everything, because the systemd unit defaults the variable to `all`. Manual `docker compose` invocations do not get that default, so add `COMPOSE_PROFILES=all` to your `.env`.

## Changing passwords

**The admin password (`PASSWORD`) after a leak** — set the new value in `.env`, then:

```bash
make rotate-password         # LLDAP admin account + Authelia's bind secret
make rotate-password-full    # the above, plus every Postgres role and every service using PASSWORD
```

Editing `.env` alone is **not enough**: LLDAP does not reset an existing admin's password to match the env var on startup. `make rotate-password` performs the actual LDAP password-modify operation and updates Authelia's `ldap_password` secret — and since everything logs in through Authelia SSO, that is the credential a leaked `PASSWORD` actually exposes.

`rotate-password-full` additionally covers Nextcloud, Vaultwarden, Pi-hole, qBittorrent, Prowlarr, Kapowarr, Beszel, ntfy and Dockhand. See the header comment of `scripts/rotate-password.sh` for the ordering constraints it handles (Nextcloud's `config.php` dbpassword, Authelia's `db_password` secret versus its `AUTHELIA_DB_PASSWORD` env var); doing these by hand out of order breaks things.

Every service holding a Postgres role must be rotated *and* recreated together, since the role password and the connection string in the container's environment have to move as one. A role that is rotated without its container being recreated does not fail immediately — the running container keeps its established connection — it fails at the *next* recreate, which may be an unrelated reboot or image bump long afterwards. `vaultwarden` was missing from both lists until it was added; if you add another Postgres-backed service, wire it into `rotate_postgres_roles()`, give it a `*_ROLE_OK` gate, and add it to Backrest's gate, which needs every role it dumps.

**A regular user** resets their own password from the Authelia portal (**Account → Change password**) or has it reset from the LLDAP admin UI.

**Authelia's own secrets** are auto-generated. To regenerate them all, delete `${DATA_LOCATION}/authelia-config/secrets/` and restart — this invalidates every session and everyone must log in again.

## Customising further

A `compose.override.yaml` is not the way to switch services off — `profiles:` lists *merge* across compose files, so an override can only add activation profiles, never remove the built-in ones. Use `make enable` / `make disable`, and verify with `make services`.

Non-secret behaviour lives in `config/<service>/` (Traefik is the exception: it is configured entirely by CLI flags and labels in `compose.yaml`). Secrets and anything a script reads belong in `.env`. Either way, apply with `make restart`.

To add a service to the stack, follow the [add-service checklist](../.agents/skills/add-service/SKILL.md) — it covers the Compose profile, Traefik labels, the Authelia OIDC client, shared Postgres/Redis, ntfy, Uptime Kuma, Backrest, Homepage labels and the systemd bootstrap hook.

**Back up what cannot be regenerated** — `.env` and the Authelia secrets — somewhere other than the Pi:

```bash
tar -czf pi-pcloud-config-backup.tar.gz .env config/ data/authelia-config/secrets/
```
