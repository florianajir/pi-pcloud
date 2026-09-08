# Installation

## Before you start

- A **Raspberry Pi 5** (8 GB minimum, 16 GB recommended) running Raspberry Pi OS, ideally booting from an NVMe SSD.
- A **domain on Cloudflare** (free tier) and an API token with `Zone → DNS → Edit` on it — dashboard → **API Tokens** → Create token.
- **Docker and the Compose plugin.** The installer offers to install them if missing.
- Your router forwarding **`443/tcp`** to the Pi. Optionally `41641/udp` and `3478/udp` for direct VPN links.
- **For IPv6, a firewall rule rather than a forward** — nothing is translated. Allow inbound `443/tcp` (and `443/udp`) to the Pi in your router's IPv6 firewall, then set `IPV6_PUBLIC_RECORDS=1`. Optional; IPv6 works from the LAN either way. Do not open the Pi wholesale — see [Networking → IPv6](NETWORKING.md#ipv6).

## Guided install

```bash
curl -fsSL https://raw.githubusercontent.com/florianajir/pi-pcloud/main/install.sh | sh
```

The installer:

1. **Checks prerequisites** — `git`, `make`, Docker, the Compose plugin; offers to install what's missing via `apt-get` / [get.docker.com](https://get.docker.com). A fresh Docker install requires logging out and re-running, since the `docker` group only takes effect at next login.
2. **Clones the repository** into `~/pi-pcloud` (`/opt/pi-pcloud` when run as root). Override with `PI_PCLOUD_DIR=/path`, or run it from inside an existing clone to reuse that checkout — it is fast-forwarded in place.
3. **Builds `.env`** from `.env.dist`, prompting only for what it cannot work out: domain, email, admin user, Cloudflare token and zone. Timezone and the whole network layout are auto-detected, and `PASSWORD` can be generated for you.
4. **Asks which services to run**, using the same picker as `make config` — everything pre-selected, grouped into sections, linked services toggling together. Core infrastructure always runs, and the choice can be changed any time. See [Choosing which services run](CONFIGURATION.md#choosing-which-services-run).
5. **Runs `make preflight`, then `make install`.**

Prompts use `whiptail` dialogs when available (it ships with Raspberry Pi OS) and fall back to plain terminal prompts otherwise, with identical behaviour. A host without `python3` skips step 4 and keeps every service enabled.

### What it detects, and when it asks anyway

The network layout is resolved before the first prompt, because macvlan gives Pi-hole its own LAN address and is picky about its parent:

| Situation | What happens |
|-----------|--------------|
| Parent interface is Wi-Fi, or a VPN tunnel owns the default route | Asks for confirmation — macvlan needs a wired parent |
| Subnet is not a `/24` | Asks for `PIHOLE_IP` explicitly |
| Something already answers a ping at the chosen Pi-hole address | Skips it and picks another |
| Layout cannot be determined at all | Asks before falling back to the `192.168.1.0/24` placeholders from `.env.dist` |

The fallback is all-or-nothing, so a half-detected layout is never mixed with placeholders. The installer stops if that confirmation is refused, and an unattended run also stops on an auto-detected Wi-Fi or tunnel parent — export `HOST_LAN_PARENT` to override, since nobody is there to read the warning.

### Re-running and unattended installs

It is safe to re-run: an existing clone is fast-forwarded, and an existing `.env` is never modified. `.env` only appears once fully configured, so an interrupted run restarts cleanly.

Any prompt can be pre-answered by exporting the variable first — `HOST_NAME`, `EMAIL`, `ADMIN_USER`, `PASSWORD`, `TIMEZONE`, `HOST_LAN_IP`, `CLOUDFLARE_DNS_API_TOKEN`, `CLOUDFLARE_ZONE_ID`. Exported network values (`HOST_LAN_PARENT`, `HOST_LAN_SUBNET`, `HOST_LAN_GATEWAY`, `PIHOLE_IP`, `ALLOW_IP_RANGES`) override auto-detection, and an exported `COMPOSE_PROFILES` skips the service picker — without it, a non-interactive run enables everything.

That makes fully unattended installs possible from a non-interactive shell:

```bash
export HOST_NAME=pi.example.com EMAIL=admin@example.com ADMIN_USER=admin PASSWORD='…'
export CLOUDFLARE_DNS_API_TOKEN='…' CLOUDFLARE_ZONE_ID='…'
export COMPOSE_PROFILES=nextcloud,immich-server,immich-machine-learning
curl -fsSL https://raw.githubusercontent.com/florianajir/pi-pcloud/main/install.sh | sh
```

They need passwordless sudo (the Raspberry Pi OS default), since `make install` applies sysctl, `/etc/hosts` and systemd changes.

Values must satisfy the [`.env` value syntax rule](CONFIGURATION.md) — the installer and `make check-env` both enforce it through `scripts/lib.sh`, so a prompt and a later check can never disagree.

Optional settings (SMTP, S3 backups, `DEFAULT_LANGUAGE`) are left empty; fill them in `.env` later.

## Manual install

```bash
git clone https://github.com/florianajir/pi-pcloud.git
cd pi-pcloud
cp .env.dist .env       # fill in the required variables
make preflight          # Docker, Compose, cgroup v2, required commands
make install            # systemd units, secrets, containers, databases
make logs               # first startup takes 2–5 minutes
```

The variables you must set are listed in [Configuration → Required variables](CONFIGURATION.md#required-variables); `make check-env` validates them.

## First login

### 1. Create your users in LLDAP

Visit `https://lldap.<HOST_NAME>` and log in as `admin` with your `PASSWORD`.

- Create users under **Admin → Users**.
- Create an **`admin` group** and add your admin accounts to it. It gates the admin tools — Traefik, Pi-hole, Backrest, LLDAP, Dockhand, Headplane — behind 2FA. Regular users need no group at all.

### 2. Log in through the SSO portal

Visit `https://auth.<HOST_NAME>` and sign in with an LLDAP account. Admin users are prompted to enrol TOTP or a WebAuthn key on first access to a protected admin tool.

### 3. Open your services

Everything is wired to SSO already — just visit it and you'll be redirected to the portal:

`https://nextcloud.<HOST_NAME>` · `https://immich.<HOST_NAME>` · `https://vault.<HOST_NAME>` · `https://ai.<HOST_NAME>` · `https://beszel.<HOST_NAME>` · `https://uptime.<HOST_NAME>` · `https://n8n.<HOST_NAME>` · `https://dockhand.<HOST_NAME>`

`https://homepage.<HOST_NAME>` is a dashboard listing all of them, with live widgets. The full list with its protection model is in [Security](SECURITY.md#per-service-protection).

### 4. Kavita — one manual step

Kavita's OIDC connection is provisioned automatically (`scripts/kavita-oidc-bootstrap.sh` writes the client, secret and `appsettings.json`), but its **role mapping and account auto-provisioning live in its own database**, editable only through the UI. Once per fresh install:

1. Visit `https://kavita.<HOST_NAME>` and create the **admin account** by normal registration.
2. **Settings → OpenID Connect** — Authority, Client ID and Secret are already filled in.
3. Enable **Auto-Provision** so Authelia users get a Kavita account on first login.
4. Under **Advanced settings**, set **Roles claim** to `groups`. The default `.../claims/role` is not emitted by Authelia. Leave **Custom scopes** as `groups`.
5. To grant admin via SSO, put the user in an LLDAP group whose name matches a Kavita role (e.g. `Admin`), or set a **Roles prefix** such as `kavita-` and use groups like `kavita-admin`.

These persist in the `kavita_config` volume, and only these steps are manual: they gate everything else, because with **Disable password authentication** on there is no login a script can use until an admin exists.

Once that admin exists, the rest is provisioned on the next `make update`:

- `scripts/kavita-library-bootstrap.sh` creates the **Comics**, **Manga** and **Books** libraries with the right type and folders, repairs them if they drift, and adds every library to the OIDC default set so auto-provisioned accounts can see one added later.
- `scripts/homepage-widgets-bootstrap.sh` publishes a Kavita **API key** for the Homepage widget — the widget cannot use a password, since Kavita refuses password logins while OIDC is enforced.

Both read that key out of `kavita.db` (read-only — never edit it, the schema is not stable across Kavita majors) because `/api/Plugin/authenticate` is the only credential path left, and both skip with a warning until the admin account exists.

> Kavita's email settings have the same problem, but with OIDC + Auto-Provision they are usually unnecessary: they only power local-account flows (invites, setup links, password resets) that SSO bypasses. If you want them anyway, fill **Settings → Email** with your `SMTP_*` values from `.env`.

### 5. Shelfmark — pick your sources

Authentication needs nothing: `scripts/shelfmark-settings-bootstrap.sh` writes the Authelia
client into Shelfmark's `plugins/security.json`, password login is off, and the first
Authelia user to sign in is auto-provisioned (admin if they are in the `admin` group).
Prowlarr, qBittorrent, ntfy and SMTP are rendered into
`config/shelfmark/shelfmark.env` on every start, so those settings show as
environment-managed and read-only in the UI. Only discovered credentials and
service URLs go there: Shelfmark's environment outranks per-account settings as
well as the admin UI, so anything a user is meant to be able to change is
seeded as a plain default instead.

Two release sources are wired up:

- **Prowlarr indexers** work as soon as Prowlarr has some — add French trackers there
  and they appear as a release source. Nothing else to do.
- **Direct Download** (Anna's Archive) is on, seeded with one mirror,
  `https://annas-archive.gl` — upstream's recommendation, and the only candidate that
  was actually serving the site when this was written. Mirrors move; the list is
  **seeded, not enforced**, so edit it freely under **Settings → Mirrors** and the
  bootstrap will leave your version alone. The challenges those mirrors put up are
  solved by the bypasser **bundled in the Shelfmark image** (`USING_EXTERNAL_BYPASSER=false`),
  not by this stack's FlareSolverr: Anna's Archive is behind DDoS-Guard, which
  FlareSolverr reports as solved while handing back the interstitial. That bundled
  browser is the whole reason the full image is used instead of `-lite`.
- **AudiobookBay and IRC** are the other audiobook sources; both need a hostname or a
  network only you can choose.

For audiobook *metadata*, set `HARDCOVER_API_KEY` in `.env` (free, from
[hardcover.app/account/api](https://hardcover.app/account/api)). Without it audiobook
searches fall back to Open Library, which is a book catalogue and carries almost no
audio edition data — see
[Configuration](CONFIGURATION.md#audiobook-metadata-hardcover).

A donator key (**Settings → Direct Download → `AA_DONATOR_KEY`**) removes the wait on
the slow download hosts. Without one, Anna's Archive queues you for a minute or two per
file, so a direct download that looks stuck is usually just queued.

Per-account language: the stack seeds the default from `DEFAULT_LANGUAGE`
(`fr-FR` → `fr`) on first start, and each user can override it for their own
searches. Seeded, not enforced — changing `DEFAULT_LANGUAGE` later will not
overwrite a language you or a user has since chosen; adjust it under
**Settings → Search Mode**.

### 6. Audiobookshelf — nothing, unless you want a second admin

Fully provisioned by `scripts/audiobookshelf-bootstrap.sh` on the first start: the root
account (`ADMIN_USER` / `PASSWORD` from `.env`), the Authelia client, and an
**Audiobooks** library on `download/audiobooks/` — the folder Shelfmark files into.
Its metadata provider is the Audible storefront matching `DEFAULT_LANGUAGE`
(`fr-FR` → `audible.fr`), because the catalogue is regional and a French audiobook is
invisible from `audible.com`. Change it under **Library → Edit → Metadata provider**;
the bootstrap seeds that value and never rewrites it.

Two things worth knowing:

- **Local login is switched off**, so SSO is the only way in — for the web app and for
  the mobile apps, which have their own registered redirect URI. The root account's
  password stays in step with `.env` (`scripts/rotate-password.sh` updates it) purely so
  the recovery path below is real; nothing accepts it while `local` is off.
- **SSO logins are matched to the root account by email.** If the LLDAP account you sign
  in with carries a different address than `EMAIL`, you get a second, plain-user account
  instead — see [Troubleshooting](TROUBLESHOOTING.md#books-and-audiobooks).
- **The bootstrap keeps its own API key**, at
  `${DATA_LOCATION}/audiobookshelf/config/pi-web-api-key`, filed in the app as
  `pi-web-bootstrap`. With local logins off it is the only credential any script has —
  do not revoke it under **Settings → API Keys**. It is inside the directory Backrest
  snapshots, so a restore brings it back; [Troubleshooting](TROUBLESHOOTING.md#books-and-audiobooks)
  has the path back in if both copies are gone.

## Next steps

- **[Connect your devices to the VPN](TAILSCALE.md)** — one command per device.
- **[Set up off-site backups](CONFIGURATION.md#backrest-restic-backups)** — S3 credentials plus a repository password.
- **[Configure SMTP](EMAIL.md)** — password resets and alert emails.
- **[Subscribe to the ntfy topics](MONITORING.md#ntfy-topics)** — alerts on your phone.
- Something not working? **[Troubleshooting](TROUBLESHOOTING.md)**.
