# Troubleshooting

Start here:

```bash
make doctor     # anything outside its threshold: disk, RAM, swap, temperature, load, containers, restarts, backups
make status     # systemd unit state for the stack and the log watcher
make logs       # follow everything
```

`make doctor` asks the `system-tools` container for the same reading the AI assistant's `anomalies` topic returns, so the terminal and the chat cannot disagree.

## Startup

**The stack won't come up.** `make logs`, then look for the usual three:

| Symptom | Cause |
|---------|-------|
| Port binding errors | Something else already holds `80`, `443` or `53` — often `systemd-resolved` on 53 |
| Permission denied under `data/` | `${DATA_LOCATION}` is not writable by the containers' UID |
| Traefik logs ACME failures | The Cloudflare token lacks `Zone → DNS → Edit`, or the zone ID is wrong |

**A service depends on one that never became healthy.** `docker compose ps` shows which. Compose `depends_on: service_healthy` means one failing healthcheck can hold back a whole branch of the stack — check the dependency's own logs first, not the service that appears stuck.

## Access

**A service returns 403.** The `lan` middleware refused your source IP. Either you are reaching it from outside your LAN and tailnet, or the request hairpinned through your router and arrived with the WAN address. Check `ALLOW_IP_RANGES` in `.env` against the network you are actually on, and read the `"ClientHost"` of the rejected request in `docker logs pi-traefik` — it names the address that was refused. If that is your public address the request hairpinned, and `WAN_HAIRPIN_IP` is the fix; if the timer that maintains it is meant to be doing that for you, check it ran:

```sh
systemctl status pi-pcloud-wan-allowlist.timer
sudo ./scripts/wan-allowlist-sync.sh   # runs the same check now; silent means nothing to change
```

**The browser downloads a 9-byte `Forbidden` file instead of showing the 403.** Same refusal, and the
`autodetect` middleware is not reaching it. Check it is still **last** on the `websecure` entrypoint
chain ([Security](SECURITY.md#the-middleware-chain)) — anywhere else it stops wrapping `lan`.

Traefik's access log records the address it actually saw, which is the one the allowlist judged — read it rather than guessing:

```bash
journalctl -t pi-traefik -n 200 | grep '"DownstreamStatus":403' | tail
```

To confirm the middleware is the culprit rather than the service, compare the two paths — bypassing DNS and the router should succeed where the hostname fails:

```bash
curl -k -o /dev/null -w '%{http_code}\n' -H "Host: vault.<HOST_NAME>" https://127.0.0.1/   # 200 = service is fine
curl -k -o /dev/null -w '%{http_code}\n' https://vault.<HOST_NAME>/                        # 403 = allowlist
```

**IPv4 works and IPv6 gives 403.** The `"ClientHost"` is a global IPv6 address the allowlist does not cover. `HOST_LAN_SUBNET6` admits your LAN's prefix and the same timer maintains it; empty is the normal cause. Compare the two families:

```bash
# --resolve, because Pi-hole answers AAAA for *.<HOST_NAME> with NODATA (below),
# so a plain `curl -6` on a LAN client fails to resolve rather than reporting a status.
PI6=$(ip -6 addr show scope global | awk '/inet6/{print $2}' | cut -d/ -f1 | head -1)   # on the Pi
curl -4 -sk -o /dev/null -w 'v4=%{http_code}\n' --resolve homepage.<HOST_NAME>:443:<HOST_LAN_IP> https://homepage.<HOST_NAME>/
curl -6 -sk -o /dev/null -w 'v6=%{http_code}\n' --resolve "homepage.<HOST_NAME>:443:[$PI6]" https://homepage.<HOST_NAME>/
```

The reverse split — IPv6 timing out from **outside** while IPv4 works — is the router's IPv6 firewall, not the stack: publishing AAAA does not open inbound `443`.

A split verdict means the client resolved the public address instead of the Pi-hole one and hairpinned back with the WAN source. This is stack-wide, not per-service: every router carries `lan`, so check a second hostname before suspecting one container. Browser DNS-over-HTTPS ("Secure DNS") is a common trigger, since it silently bypasses Pi-hole even on the LAN — see [DNS](#dns).

**A service returns a generic 404 from Traefik.** Its router is gone. For qBittorrent, Prowlarr, Kapowarr and Stremio the usual cause is **gluetun being unhealthy** — they share its network namespace, so when it drops, all of their Traefik routes vanish at once rather than erroring individually. `docker compose ps gluetun` and `docker compose logs gluetun`.

**Nextcloud returns 502 right after installing an app from the UI.** Its PHP workers are
segfaulting, so Traefik has no live backend. The signature is in the container log, one line per
dead worker:

```bash
docker logs pi-nextcloud | grep 'Segmentation fault'
```

`docker restart pi-nextcloud` clears it — the state that kills the workers is process-wide, not
something the installed app left on disk. `config/nextcloud/zz-opcache-jit.ini` disables the tracing
JIT that the upstream image enables by default; that is the suspected mechanism rather than a proven
one, since the crash has not been reproduced on demand, but it is the known-fragile piece on aarch64
and Nextcloud loses little without it. If you see a 502 again, first confirm the JIT is still off:

```bash
docker exec pi-nextcloud php -i | grep -E '^opcache.jit(_buffer_size)? =>'   # expect disable / 0
```

Note that `.htaccess` rewrites unknown `.php` paths to `index.php`, so dropping a test script in the
webroot to isolate PHP from Nextcloud's own code does not work — it runs the full bootstrap instead.

**`dig AAAA` returns nothing for a stack hostname on the LAN.** Expected: Pi-hole has an A record for `*.<HOST_NAME>` and dnsmasq answers AAAA for those names with `NODATA-IPv6` rather than forwarding, so LAN clients using it take the IPv4 path deliberately. See [Networking → IPv6](NETWORKING.md#what-stays-ipv4-and-why).

**Nothing resolves from outside.** Check that DNS points at your public IP and that 443 is forwarded:

```bash
nslookup auth.<HOST_NAME>          # should return your public IP, via Cloudflare
docker compose logs traefik | tail -50
```

**Forgot or leaked the admin password.** Set the new `PASSWORD` in `.env` and run `make rotate-password`. Editing `.env` alone does **not** reset the LLDAP admin account — see [Configuration → Changing passwords](CONFIGURATION.md#changing-passwords). Regular users reset their own from the Authelia portal or the LLDAP admin UI.

## DNS

**Queries not resolving.**

```bash
docker compose logs pihole | tail -20
nslookup example.com <PIHOLE_IP>      # from a LAN device
```

If devices aren't using Pi-hole at all, check your router's DHCP DNS option, or set it manually on one device to test.

**Upstream resolution broken.**

```bash
docker compose logs unbound | tail -20
docker compose exec unbound drill @127.0.0.1 -p 5335 cloudflare.com
```

The Uptime Kuma `dns resolution` monitor covers this whole chain continuously — see [Monitoring](MONITORING.md#what-is-actually-checked).

**A link or a redirect leads nowhere.** Sponsored search results, newsletter links and affiliate links route through ad infrastructure, so the block lists catch them and the click dies on a blank page instead of just losing an ad.

To find the real culprit, check the Pi-hole query log for the click — **the blocked domain is often not the one you typed**. A status of *blocked (CNAME)* means an alias is at fault: `g.live.com` was blocked because it points at `g.msn.com`.

Add the domain to the `ALLOW_LISTS` in `scripts/pihole-bootstrap.sh`, not only in the web UI, or the next rebuild loses it.

**High latency.** First queries are slower while Unbound walks the delegation tree; its cache warms quickly. If it stays high, check RAM pressure in Beszel and consider trimming very large blocklists.

## VPN

**A device won't register.** `docker compose logs headscale | tail -30`. The login server must be `https://headscale.<HOST_NAME>` — port 443, valid TLS. A device registered before must be deleted before re-registering.

**Services unreachable from the VPN.** Verify the client got a `100.64.x.x` address (`tailscale ip`) and that DNS is accepted (`tailscale dns status`). Then `nslookup nextcloud.<HOST_NAME>` should return the Pi's LAN IP.

**Connections relay instead of going direct.** Forward `41641/udp` (WireGuard) and `3478/udp` (STUN) on your router. Without them traffic still works, but rides the embedded DERP relay.

**`netcheck.runProbe: named node "999" has no v6 address`, every 5 minutes.** Expected. `999` is Headscale's embedded DERP region, whose `derp.server` block advertises `ipv4` and no `ipv6`, so a client with working IPv6 probes it over IPv6 and finds nothing. Advertising one would mean publishing `[::]:3478`, which Headscale has no IPv6 address to DNAT to — see [Networking → IPv6](NETWORKING.md#what-stays-ipv4-and-why). Relaying is unaffected; the public DERP regions all answer.

**A node shows offline while the device is connected.** "Last seen" lags by design — check `tailscale status` on the device itself before trusting the list.

## Books and audiobooks

**Shelfmark finds nothing on Direct Download.** Check the mirror list first
(**Settings → Mirrors**): the stack seeds one, `https://annas-archive.gl`, and mirror
availability moves. `annas-archive.is` resolves and loads but does not work as a source.
A search that returns empty while the log shows it still running is usually the
challenge solve, not the mirror — a cold one takes a couple of minutes.

**A mirror keeps challenging, or direct downloads fail while search still works.**
Those are the two halves that go through the VPN. Shelfmark's bypasser and its direct
downloads both egress via gluetun's HTTP proxy (`plugins/network.json`,
`http://gluetun.docker:8888`), while the Prowlarr API, the OIDC token exchange and the
metadata providers stay direct — so a gluetun outage costs you direct downloads, not
search or login. Check gluetun first (`docker compose ps gluetun`).

To take direct downloads off the tunnel and accept that they leave on the residential IP
(torrents are unaffected — they go through qBittorrent, which is inside gluetun):
**changing `PROXY_MODE` under Settings → Network does not stick**, because the proxy is
reconciled on every stack start by `scripts/shelfmark-settings-bootstrap.sh`, which owns
that value. Blank `GLUETUN_HTTP_PROXY` at the top of that script, or drop gluetun from
`COMPOSE_PROFILES` — the script then unwinds the setting itself and says so in the start
log. FlareSolverr is not in this path at all: it belongs to Prowlarr, and cannot solve
the DDoS-Guard challenge Anna's Archive puts up, which is why Shelfmark carries its own
browser.

**Books do not appear in Kavita.** Shelfmark files into `download/books/`, which Kavita
scans as its **Books** library; its own in-progress grabs live in `download/shelfmark/`
and are meant to be invisible to Kavita. Check the file actually landed, then trigger a
library scan. Audiobooks go to `download/audiobooks/` and Kavita never reads them —
those are Audiobookshelf's library, and are also browsable through Nextcloud.

**A book sits in `download/books/` and Kavita never shows it.** Two causes, both
silent.

*It is a loose file at the library root.* Kavita takes the series name from the
containing folder and `GetFoldersTillRoot` stops below the scan root, so a file
placed directly in `download/books/` has no folder to name a series after and is
skipped without an error. Give each book its own subfolder. If the file belongs
to a torrent, move it with qBittorrent's `renameFile` API rather than `mv`, so
the torrent follows it instead of breaking.

*The EPUB declares version 3.0 but ships no nav document.* The log says
`Epub3NavException: NAV item not found in EPUB manifest`, followed by `Unable to
parse any meaningful information out of file`. Kavita's parser requires the
EPUB 3 nav document once the package claims 3.0, and some releases only carry the
legacy `toc.ncx` (`<spine toc="ncx">`). Rewriting the OPF's `version="3.0"` to
`version="2.0"` makes the declaration match the TOC the file actually has, and
Kavita then reads it. Repair a *copy* if the file is being seeded — changing the
bytes invalidates the torrent — and keep `mimetype` as the first, uncompressed
zip entry or the result is no longer a valid EPUB.

**Audiobookshelf's page never finishes loading — the spinner turns forever.** Its
assets are 404ing. The image leaves `ROUTER_BASE_PATH` unset, and *unset does not
mean no subfolder*: both the server and the Nuxt client read it as
`?? '/audiobookshelf'`, and the published image has that default **baked into every
asset URL** at build time. Setting the variable to the empty string makes the server
stop serving that prefix while the client keeps asking for it, so every
`/audiobookshelf/_nuxt/*.js` returns 404 and the app never boots. Leave it unset.
Confirm with `docker logs pi-audiobookshelf | head -2`, which prints the effective
value, and compare what the page asks for against what answers:

```bash
curl -sk https://audiobooks.<domain>/ | grep -oE 'src="[^"]*"'
curl -sko /dev/null -w '%{http_code}\n' https://audiobooks.<domain>/audiobookshelf/_nuxt/<file>.js
```

The app is *meant* to live under `/audiobookshelf`; the server rewriting prefix-less
URLs onto it is a convenience on top, which is why the root URL, the healthcheck and
the Homepage widget all work without the prefix. A hand-built
`?callback=…/login` test therefore proves nothing about SSO — the real login page
sends `/audiobookshelf/login`, which passes the check the bare path fails.

**Signing in to Audiobookshelf through SSO lands on a second, non-admin account.** The
root account is created by `scripts/audiobookshelf-bootstrap.sh` and is matched to your
Authelia identity **by email** — so it only links if the LLDAP account you sign in with
carries the same address as `EMAIL` in `.env`. Fix the address on either side and log in
again, or promote the new account from the root one (Settings → Users). Group claims are
deliberately not used: Audiobookshelf reads them as a role and denies anyone whose groups
contain none of `admin`/`user`/`guest`, which in this stack is every regular user.

**Audiobookshelf offers no password field, or `POST /login` answers 500.** Expected:
local logins are disabled once the bootstrap holds an API key, and the `/login` route is
wired to a passport strategy that no longer exists — hence a 500 rather than a 401.
`/status` reports what is actually active, without authenticating:

```bash
docker run --rm --network frontend curlimages/curl:8.12.1 -sS http://pi-audiobookshelf/status | jq .authMethods
```

**Nothing can reach the Audiobookshelf API and SSO is broken too.** The scripts
authenticate with the key at `${DATA_LOCATION}/audiobookshelf/config/pi-web-api-key`,
and with local logins off there is no other credential — `audiobookshelf-bootstrap.sh`
says so and changes nothing rather than guessing. Recover in this order:

1. **The key file is gone but SSO works.** Sign in as the admin, mint a key under
   **Settings → API Keys**, and write it to that path (`chmod 600`). The next bootstrap
   run picks it up. A Backrest restore of `/userdata/audiobookshelf/` also brings it
   back, since the file is inside the snapshotted directory.
2. **The key still works but SSO does not.** Re-enable the password login with it, then
   sign in with `ADMIN_USER` / `PASSWORD` from `.env`:

   ```bash
   KEY=$(cat "$DATA_LOCATION/audiobookshelf/config/pi-web-api-key")
   docker run --rm --network frontend curlimages/curl:8.12.1 -sS \
     -X PATCH -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
     -d '{"authActiveAuthMethods":["local","openid"]}' \
     http://pi-audiobookshelf/api/auth-settings
   ```

   The next bootstrap run turns `local` back off, so fix the OIDC side first.
3. **Both are gone.** `restart pi-audiobookshelf` — on start-up Audiobookshelf drops
   `openid` from the active methods if any of the OIDC settings is *empty*, and then
   falls back to `local`. That is the only automatic way back, and it is why clearing one
   field is enough. Settings that are complete but wrong do not trip it, so the last
   resort is editing `authActiveAuthMethods` in the JSON of the single `server-settings`
   row in `absdatabase.sqlite`'s `settings` table, with the container stopped.

**Shelfmark downloads an audiobook and nothing appears.** `download/audiobooks/` is the
one download folder with no writer inside a container to create it, so on stacks built
before `scripts/audiobookshelf-pre-start.sh` existed the Docker daemon created it as
`root:root` and Shelfmark (uid 1000) could not file anything there. That hook repairs
the ownership, but only when it runs as root — `sudo sh scripts/audiobookshelf-pre-start.sh`
if `make update` ran unprivileged and the start log warned about it.

**One audiobook shows up as dozens of one-track books.** Audiobookshelf calls a book
either a *subfolder* of the library or a *single loose file* at its root. It never
groups root-level files with each other — not even ones sharing an `album` tag — so a
multi-file release dropped flat into `download/audiobooks/` becomes one book per track.
Shelfmark's `FILE_ORGANIZATION_AUDIOBOOK` is now `organize` in `compose.yaml`, which
applies `{Author}/{Title}/{Title}` and produces the folder Audiobookshelf expects; its
default, `rename`, renames single-file grabs and leaves multi-file ones flat, which is
what caused this. To repair an existing one, move the tracks into a subfolder on the
host — `mv` within `download/` preserves the hardlinks, so the torrent keeps seeding —
then rescan and clear the stale entries, which the scan marks missing rather than
deleting:

```sh
KEY=$(cat "$DATA_LOCATION/audiobookshelf/config/pi-web-api-key")
LIB=$(docker run --rm --network frontend curlimages/curl -s -H "Authorization: Bearer $KEY" \
  http://pi-audiobookshelf/audiobookshelf/api/libraries | jq -r '.libraries[0].id')
docker run --rm --network frontend curlimages/curl -s -X POST -H "Authorization: Bearer $KEY" \
  "http://pi-audiobookshelf/audiobookshelf/api/libraries/$LIB/scan?force=1"
docker run --rm --network frontend curlimages/curl -s -X DELETE -H "Authorization: Bearer $KEY" \
  "http://pi-audiobookshelf/audiobookshelf/api/libraries/$LIB/issues"
```

**A torrent added by hand never reaches any reader.** An uncategorised torrent saves to
the `download/` root, which nothing indexes. Pick the category for the destination
instead — `books`, `manga`, `comics` or `audiobooks`; `scripts/qbittorrent-bootstrap.sh`
owns the list and its save paths. The `shelfmark` and `shelfmark-audiobooks` categories
are *not* destinations: they are Shelfmark's staging area, and Shelfmark only
post-processes torrents belonging to one of its own tasks, so a manual add left there
downloads and then sits forever.

**Shelfmark finds no audiobook for a title a tracker definitely carries.** Shelfmark
queries Prowlarr with one category per content type: `[7000]` for anything text, `[3030]`
for an audiobook (`release_sources/prowlarr/source.py`). 7000 is a *parent*, so it
expands over the whole Books range and text searches are broad. 3030 is a leaf, and that
narrowness fails in two independent ways.

*The indexer is never queried.* `_indexer_supports_search_categories` skips any indexer
whose capabilities do not declare the requested id — on this stack 5 of the 12 enabled
ones, including **YggReborn** and **Torrent9**. `PROWLARR_AUTO_EXPAND=true` in
`compose.yaml` covers this: when a query variant returns nothing and no indexer errored,
Shelfmark reruns *that variant* with no category filter, and every indexer is queried.

*The indexer answers, but the release is tagged 7000.* The trap, because auto-expand
cannot help: it only retries a variant that returned **zero** results, and a search that
found ten other editions of the book returned plenty. Category comes from the tracker
section the uploader chose, so an indexer that files most audiobooks under 3030 will
still have some under 7000. Verified on TR4KER —
`Homère.L'Odyssée.2019.FR.AAC.64kbps.M4B-RACHE` is `[7000, 107000]`, and a Prowlarr
search for `Homère L'Odyssée` returns it under `categories=7000` and not at all under
`categories=3030`, while the same indexer serves 3030 for other audiobooks.

Such a release *is* visible in Shelfmark — under an **ebook** search, since 7000 covers
it. But grabbing it there fails at post-processing, and the error is misleading:
`content_type` is derived from the release's own categories
(`_detect_content_type_from_categories`), so 7000 means "book", the `.m4b` is checked
against `SUPPORTED_FORMATS` and rejected with *"Found 1 book(s) but format not supported
(.m4b). Enable in Settings > Formats."* Do **not** take that advice — adding `m4b` to
`SUPPORTED_FORMATS` makes it worse, because `is_audiobook` stays false and the file is
then filed into `download/books/`, Kavita's Book library, which cannot read it.

So for a mis-tagged release there is no Shelfmark route. Use it to confirm the release
exists (search as an ebook), then grab it the manual way below, with the `audiobooks`
category. Two more knobs worth knowing:

- **Manual query** in the search UI — Shelfmark otherwise searches the *metadata
  record's* title and author, so a release named nothing like the Hardcover entry never
  matches. A manual query is passed through, and still honours auto-expand.
- **`PROWLARR_COLLAPSE_DUPLICATES`** (on by default, "Show one row per release")
  collapses several indexer entries for one release into a single row. Turn it off to
  see every entry, which is what surfaces filter-specific ones like freeleech.

**Grabbing from Prowlarr's own UI, for any media type.** It works, but the category is
resolved from the release's newznab id, not from what you know the file to be — Prowlarr
sends `GetCategoryForRelease(release) ?? Settings.Category`, and the default is
`prowlarr`, a folder no reader indexes. On the indexers here 3030, 7000, the Books
subcategories and YggReborn's own 1071xx ids all land somewhere; a bare `3000`, `3010` or
`8000` does not. Two caveats: 7000 is mapped to `books` regardless of what the release
holds, so a Nyaa.si manga or a mis-tagged audiobook arrives in `download/books/`; and an
ambiguous comic goes to `manga`, because outside YggReborn no indexer distinguishes the
two. See ARCHITECTURE.md. Two ways through:

1. **Copy the magnet or .torrent out of Prowlarr and add it in qBittorrent**, choosing
   the category yourself. Deterministic for every media type; this is the reliable one.
2. **Grab in Prowlarr, then fix the category in qBittorrent.** Since
   `category_changed_tmm_enabled` is on (set by `scripts/qbittorrent-bootstrap.sh`), the
   files *move* to the new category's save path — no Set Location needed. Verified: a
   torrent switched from `prowlarr` to `audiobooks` relocated on its own.

   The catch is that relocation needs the torrent in **Automatic Torrent Management**
   mode. Prowlarr's grabs are (`auto_tmm=true`); Shelfmark's are not, because it passes
   an explicit save path on add, which forces Manual mode. Flip one with
   `torrents/setAutoManagement`.

Either way the file arrives as the **raw release tree**, with none of the renaming
Shelfmark's own imports get, so the destination's own parsing rules apply:

| Destination | What the raw tree costs you |
|---|---|
| `audiobooks` | Fine. A multi-file torrent has its own folder, which is exactly one book; a single-file one is a single loose file, also one book. Metadata comes from the audio tags, not the folder. |
| `books` | **A single-file torrent breaks.** A lone `.epub` at the root of `download/books/` has no folder to name a series after and Kavita skips it silently. Put it in a subfolder with qBittorrent's `renameFile` so the torrent follows. |
| `comics`, `manga` | The folder becomes the series name — see the next entry. |

**A hand-grabbed comic lands in Kavita under a scene-release name.** Expected, and
fixable before the scan. The Comics library is the ComicVine type, whose parser takes
the series from the *containing folder* and never from the filename — and
`GetFoldersTillRoot` stops below the scan root, so the deepest folder above the issues
wins. A release tree like `Batman.2016.COMPLETE-SCENE/` becomes a series of that name,
and any extra `Volume 01/` level makes *that* the series instead. Rename the torrent's
folder to `Series (Year)` and the parser reads it correctly; do it through qBittorrent
rather than with `mv`, so the torrent follows the rename and keeps seeding:

```sh
docker exec pi-qbittorrent curl -sS -H "Referer: http://127.0.0.1:8080" \
  --data-urlencode "hash=<hash>" \
  --data-urlencode "oldPath=Batman.2016.COMPLETE-SCENE" \
  --data-urlencode "newPath=Batman (2016)" \
  http://127.0.0.1:8080/api/v2/torrents/renameFolder
```

`newPath` may contain `/` to create nesting, which is also how an audiobook release
folder gets reshaped into the `Author/Title` layout Audiobookshelf wants.

**Nothing downloads and the log mentions the torrent client.** Shelfmark reaches
qBittorrent through gluetun (`http://gluetun:8080`) with `ADMIN_USER`/`PASSWORD`. If
`ADMIN_USER` is under 3 characters, qBittorrent rejected it and kept its own generated
login — `scripts/shelfmark-pre-start.sh` then leaves the client unset on purpose and
says so in the start log.

## Email

| Symptom | Cause |
|---------|-------|
| Connection refused | Wrong host or port, or your ISP blocks outbound 25 — use 587 |
| Authentication failed | Most providers refuse the account password; generate an app password |
| Nothing sent at all | `SMTP_HOST` is empty or `localhost`, which disables delivery by design |

```bash
docker compose logs authelia | grep -i -E 'smtp|mail'
docker compose logs nextcloud | grep -i mail
```

## Monitoring

**Beszel agent not reporting.** `docker compose logs beszel-agent`. The hub reads the agent over the shared `beszel_socket` volume, and the agent reads container stats from the Docker socket. If the hub shows the system offline, restarting `beszel-agent` usually reconnects it.

**ntfy webhook silent.** Check that `config/ntfy/ntfy.env` holds the expected topic, then test directly:

```bash
curl -d "test alert" https://ntfy.<HOST_NAME>/<topic>
```

**Authelia login alerts stopped.**

```bash
sudo systemctl status pi-pcloud-authelia-ntfy.service
sudo journalctl -u pi-pcloud-authelia-ntfy.service -f
```

A `WARNING: NTFY_AUTHELIA_PASSWORD missing` line means `ntfy-pre-start.sh` has not run since the feature was added:

```bash
sh scripts/ntfy-pre-start.sh && docker compose up -d ntfy
```

### Uptime Kuma database keeps growing

The nightly prune catches its own exceptions, so a failure leaves no trace except `data/uptime-kuma/error.log`. A corrupt page anywhere in `heartbeat` makes every run abort with `SQLITE_CORRUPT`, and the file then grows without bound:

```bash
docker exec pi-uptime-kuma grep -c SQLITE_CORRUPT /app/data/error.log
docker exec pi-uptime-kuma sqlite3 /app/data/kuma.db "PRAGMA integrity_check(5);"
```

**Never `VACUUM` a database that fails `integrity_check`** — it rewrites the whole file and can fail halfway. Recover from a copy instead, with a recent sqlite: the 3.40 shipped in the Kuma image aborts `.recover` with `SQL logic error`, while `alpine:latest` carries a working one.

```bash
docker stop pi-uptime-kuma          # clean shutdown, then copy kuma.db aside
docker run --rm -v /path/to/backup:/bk alpine:latest sh -c \
  'apk add --no-cache sqlite && cd /bk && \
   sqlite3 kuma.db ".recover" | sqlite3 kuma-recovered.db && \
   sqlite3 kuma-recovered.db "PRAGMA integrity_check;"'
```

Then prune and `VACUUM` the recovered copy and swap it in — `chown 1000:1000`, and delete the stale `kuma.db-wal` / `kuma.db-shm` alongside the old file.

## Local AI

**The model doesn't appear in the picker.** Either the weights aren't there or the connection was never seeded. Both are idempotent, so just re-run them:

```bash
sh scripts/llama-cpp-pre-start.sh     # re-checks and re-downloads the weights
sh scripts/open-webui-bootstrap.sh    # re-seeds the connection, tools and suggestions
```

On a **fresh install** the steps that write the model's workspace row are skipped until an admin account exists — so run the bootstrap once after your first SSO login. See [Local AI](AI.md#how-open-webui-is-wired).

**Replies take minutes.** Something re-enabled the built-in tools or thinking. Both cost thousands of prompt tokens per message at ~40 tok/s — see [Why the defaults look aggressive](AI.md#why-the-defaults-look-aggressive).

**The assistant answers about the server without calling the tool.** Check the phrasing: singular and negated questions reliably fail to trigger a tool call where the plural, positive form works. See [Topic selection is testable](AI.md#topic-selection-is-testable-so-test-it).
