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
4. **Asks which services to run**, using the same picker as `make config` — everything pre-selected, grouped into sections, linked services toggling together, each with the memory ceiling it may claim and a running total for the host. Core infrastructure always runs, and the choice can be changed any time. See [Choosing which services run](CONFIGURATION.md#choosing-which-services-run).
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
- Create an **`admin` group** and add your admin accounts to it. It gates the admin tools — Traefik, Pi-hole, Backrest, LLDAP, Dockhand, Headplane — behind 2FA, and it is also what makes an account a **Nextcloud server administrator** and an **Immich administrator**. Regular users need no group at all.
- Leave the built-in `lldap_*` groups to the accounts that administer the directory itself. They are filtered out of the `groups` claim, and `lldap_strict_readonly` grants read access to every user record — nobody needs it to change their own password, which goes through the reset mail.

### 2. Log in through the SSO portal

Visit `https://auth.<HOST_NAME>` and sign in with an LLDAP account. Admin users are prompted to enrol TOTP or a WebAuthn key on first access to a protected admin tool.

### 3. Open your services

Everything is wired to SSO already — just visit it and you'll be redirected to the portal:

`https://nextcloud.<HOST_NAME>` · `https://immich.<HOST_NAME>` · `https://vault.<HOST_NAME>` · `https://ai.<HOST_NAME>` · `https://llm.<HOST_NAME>/ui` · `https://beszel.<HOST_NAME>` · `https://uptime.<HOST_NAME>` · `https://n8n.<HOST_NAME>` · `https://dockhand.<HOST_NAME>` · `https://chat.<HOST_NAME>`

`https://homepage.<HOST_NAME>` is a dashboard listing all of them, with live widgets. The full list with its protection model is in [Security](SECURITY.md#per-service-protection).

### 4. Kavita — one manual step

`scripts/kavita-oidc-bootstrap.sh` configures Kavita's SSO, but Kavita's settings API needs an admin account and a fresh install has none:

1. Visit `https://kavita.<HOST_NAME>` and create the **admin account** by normal registration.
2. Re-run `make update` (or wait for the next start). The hook fills in Authority, Client ID and Secret, turns on **Auto-Provision**, and sets the role settings described below.
3. Optionally, once an SSO login works, turn on **Disable password authentication** in **Settings → OpenID Connect**. The hook leaves it to you because, set automatically, it can lock you out of a fresh install whose SSO is not working yet.

**Leave role sync off.** With it on, Kavita takes every permission from the `groups` claim at each login and refuses any account whose claim contains neither `Login` nor `Admin` — here, everyone outside the `admin` group. With it off, new SSO accounts get `Login`, `Change Password`, `Bookmark` and `Download` from **Default roles**, and you promote an admin in **Settings → Users**. Group-driven roles need LLDAP groups named after Kavita's roles (`Login`, `Admin`, `library-<Name>`) behind a **Roles prefix**, *and* the `groups` scope added to both the Authelia client and Kavita's **Custom scopes** — on one side only, every login fails with `invalid_scope`.

Settings persist in the `kavita_config` volume. Once the admin exists, the same run also provisions:

- **Libraries** — `scripts/kavita-library-bootstrap.sh` creates **Comics**, **Manga** and **Books** with the right type and folders, repairs them if they drift, and adds every library to the OIDC default set so auto-provisioned accounts see it.
- **The Homepage widget** — `scripts/homepage-widgets-bootstrap.sh` publishes a Kavita API key for it, since Kavita refuses password logins while OIDC is enforced.

Both skip with a warning until the admin account exists.

> Kavita's email settings only power local-account flows (invites, setup links, password resets) that SSO bypasses, so they are usually unnecessary. To set them anyway, fill **Settings → Email** with your `SMTP_*` values from `.env`.

### 5. Shelfmark — pick your sources

Authentication needs nothing: `scripts/shelfmark-settings-bootstrap.sh` writes the Authelia
client into Shelfmark's `plugins/security.json`, password login is off, and every Authelia
user is auto-provisioned on first sign-in (as admin if they are in the `admin` group).
The Prowlarr, qBittorrent, ntfy and SMTP settings are rendered into
`config/shelfmark/shelfmark.env` on every start, so they show as environment-managed and
read-only in the UI. Anything a user should be able to change is seeded as a config-file
default instead, because Shelfmark's environment overrides per-account settings.

Release sources:

- **Prowlarr indexers** — when Prowlarr is enabled, the indexers you add there appear as a
  release source. Nothing else to do.
- **Direct download** is on, seeded with one mirror from
  `scripts/shelfmark-settings-bootstrap.sh`. Mirrors move: the list is **seeded, not
  enforced**, so edit it under **Settings → Mirrors** and the bootstrap leaves your version
  alone. Challenge pages are solved by the browser bundled in the full Shelfmark image
  (`USING_EXTERNAL_BYPASSER=false`), not by the stack's FlareSolverr, which cannot pass
  them — that browser is why the full image is used rather than `-lite`.
- **The other audiobook sources**, IRC included, stay off: each needs a hostname or
  network only you can supply.

A donator key (**Settings → Direct Download**) skips the queue on the slow download
hosts. Without one, a direct download that looks stuck is usually just queued.

For audiobook *metadata*, set `HARDCOVER_API_KEY` in `.env` — see
[Configuration](CONFIGURATION.md#audiobook-metadata-hardcover).

The default search language is seeded from `DEFAULT_LANGUAGE` (`fr-FR` → `fr`) on first
start, and each user can override it under **Settings → Search Mode**. Seeded, not
enforced: changing `DEFAULT_LANGUAGE` later does not overwrite a language already chosen.

### 6. Audiobookshelf — nothing, unless you want a second admin

Fully provisioned by `scripts/audiobookshelf-bootstrap.sh` on the first start: the root
account (`ADMIN_USER` / `PASSWORD` from `.env`), the Authelia client, and an
**Audiobooks** library on `download/audiobooks/` — the folder Shelfmark files into.
Its metadata provider is the Audible storefront matching `DEFAULT_LANGUAGE`
(`fr-FR` → `audible.fr`), since Audible's catalogue is regional. The bootstrap seeds that
value and never rewrites it; change it under **Library → Edit → Metadata provider**.

Worth knowing:

- **Local login is switched off**, so SSO is the only way in — for the web app and for
  the mobile apps, which have their own registered redirect URI. `scripts/rotate-password.sh`
  keeps the root password in step with `.env` only for the recovery path in
  [Troubleshooting](TROUBLESHOOTING.md#books-and-audiobooks).
- **SSO logins are matched to the root account by email.** An LLDAP account whose address
  differs from `EMAIL` gets a second, plain-user account instead.
- **The bootstrap keeps its own API key**, at
  `${DATA_LOCATION}/audiobookshelf/config/pi-web-api-key`, listed in the app as
  `pi-web-bootstrap`. With local logins off it is the only credential any script has —
  do not revoke it under **Settings → API Keys**. Backrest snapshots it with the rest of
  the config directory, and Troubleshooting has the way back in if every copy is gone.

### 7. Chat — sign in yourself first

The first account to sign in to `https://chat.<HOST_NAME>` becomes the Matrix server's
admin (Tuwunel's `grant_admin_to_first_user`) and is joined to its admin room, where
`!admin` commands run. So sign in before anyone else does, with your own LLDAP account.

- **Accounts are created on the first SSO sign-in**, named after the LLDAP uid
  (`@alice:chat.<HOST_NAME>`). That suffix is the server name, and it is permanent: a
  database created under one `HOST_NAME` cannot move to another.
- **On a phone, use Element X** and type `chat.<HOST_NAME>` as the server. It signs in
  through Tuwunel's own OAuth server, which hands over to Authelia. Like every LAN-only
  service here, it only connects over the LAN or the tailnet.
- **Nobody outside this server can join a room or message one** — federation is off.

## Next steps

- **[Connect your devices to the VPN](TAILSCALE.md)** — one command per device.
- **[Set up off-site backups](CONFIGURATION.md#backrest-restic-backups)** — S3 credentials plus a repository password.
- **[Configure SMTP](EMAIL.md)** — password resets and alert emails.
- **[Subscribe to the ntfy topics](MONITORING.md#ntfy-topics)** — alerts on your phone.
- Something not working? **[Troubleshooting](TROUBLESHOOTING.md)**.
