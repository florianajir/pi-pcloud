# Backups & restore

Backrest (restic) snapshots the stack's state every night to an S3 bucket, encrypted
and deduplicated, and keeps a second, local copy of `.env` on the data disk. This page
covers what is in a snapshot, how the pieces that cannot be copied file by file are
handled, and how to rebuild the whole stack on new hardware.

## What is backed up

Two plans, both defined in `config/backrest/config.json.template`. `s3-backup` carries
everything off-site; `usb-env` is a small local one covering `.env` alone, described
under [The `.env` file, twice](#the-env-file-twice).

| | `s3-backup` |
|---|---|
| **Runs** | Nightly at 04:00 |
| **Backs up** | `/userdata/` — Immich, Nextcloud (data, config, themes), LLDAP, Vaultwarden, Uptime Kuma, Authelia config and secrets, Beszel, Open WebUI, Headscale (node keys, ACLs), Headplane, n8n, ntfy ACLs, Kavita, Pi-hole, Traefik's ACME certificates, qBittorrent, Prowlarr, Kapowarr, Shelfmark, Audiobookshelf, FreshRSS, Trilium, changedetection.io (watch list, settings and history), Forgejo (bare repositories and LFS objects — a branch pushed only to this forge exists nowhere else), Agentgateway, AIOStreams, AIOMetadata, Tuwunel (uploads and the RocksDB backup described below), OpenClaw (workspaces, sessions and the Matrix crypto state its device needs to stay trusted) |
| **Excludes** | Caches, previews, thumbnails and model caches; logs and their rotations; every SQLite `-wal`/`-shm`; Pi-hole's query log, list cache and `gravity.db`; Forgejo's indexes, queues, sessions and generated archives; Trilium's own rotating copies; OpenClaw's installed plugin, sync git directories and knowledge-base export — all regenerable, or replaced by a consistent copy (below). `/userdata/tuwunel-backups/**` is re-included after the `*.log` exclusion, because its RocksDB write-ahead logs carry that extension |
| **Databases** | Dumped or copied by pre-snapshot hooks — see [Databases](#databases) |
| **Retention** | 7 daily, 4 weekly, 4 monthly |
| **Maintenance** | Prune Sundays at 03:00 (25% unused); monthly integrity check that also re-reads 5% of the pack data; stale locks released before every run |
| **Destination** | Your S3 bucket, restic-encrypted and deduplicated |
| **On failure** | Pushes to the ntfy `monitoring` topic |

The full list of what goes in is the `backrest` service's volumes in
`compose/compose-monitoring.yaml`: each one mounted under `/userdata/` is in the snapshot.

**Not backed up:** the media libraries and downloads (`download/`, `comics/`, `manga/`
under `DATA_LOCATION`), the Postgres cluster's files (the dumps replace them), and the
volumes that only hold caches or re-downloadable data — model weights, Prometheus and
Grafana, Redis, the search and streaming caches, Tuwunel's live database (its own backup
is taken instead) and the Pi's own Tailscale node state.

Configure the plans with the `S3_*` and `BACKREST_*` variables — see
[Configuration](CONFIGURATION.md#backrest-restic-backups).

### Beszel PocketBase snapshots

A second, independent layer for the monitoring history alone: SQLite snapshots on
`BESZEL_BACKUP_CRON` (default 03:00), keeping `BESZEL_BACKUP_MAX_KEEP` (default 7),
restorable from the Beszel admin UI.

## Databases

### PostgreSQL dumps

`scripts/db-backup.sh` runs as a pre-snapshot hook and writes a plain-SQL `pg_dump` of
each database — `nextcloud` and `vaultwarden` (fatal on error), `authelia`, `lldap`,
`open-webui`, `immich`, `freshrss`, `forgejo` — as `<service>-sqlbkp_<timestamp>.bak`:

| Database | Dumps under `DATA_LOCATION` |
|----------|-----------------------------|
| `nextcloud` | `nextcloud-config/backups/` (keeps `NEXTCLOUD_SQL_BACKUP_KEEP`) |
| `authelia` | `authelia-config/backups/` |
| `immich`, `lldap`, `open-webui`, `vaultwarden`, `freshrss`, `forgejo` | `<name>/backups/` |

Seven are kept per database unless stated. They sit on the data disk as well as in the
snapshot, so a lost root disk does not take them.

Restore a dump **as the `postgres` superuser**: `config/postgres/init-databases.sh`
grants each schema's default privileges as `postgres`, so a service role replaying its
own dump is refused on the `ALTER DEFAULT PRIVILEGES` lines. Use the `psql` inside the
postgres container (or the Backrest one, which `config/backrest/Dockerfile` pins to the
server major): the dumps open with a `\restrict` line that only `psql` 17.6 and newer
understands.

### Consistent copies of the live SQLite databases

The plan mounts each service's data read-only, so restic would otherwise read a `.db`
and its `-wal` at different instants and store a pair that disagrees.
`scripts/sqlite-backup.sh` runs as a pre-snapshot hook and writes a `sqlite3 .backup` of
each one into `/userdata/sqlite-backups/` (`DATA_LOCATION/backrest/sqlite` on the host),
named after the service — `DATABASES` at the top of that script is the list. **That copy
is the one to restore from.** The main `.db` files stay in the snapshot as a fallback for
a night the hook fails: read without its WAL, a main file is an older state, not a torn one.

Pi-hole's `gravity.db` is excluded outright: almost all of it is block lists that
`pihole -g` re-downloads, so the hook dumps only the configuration tables to
`sqlite-backups/pihole-gravity-config.sql`. Restore it with
`sqlite3 gravity.db < pihole-gravity-config.sql`, then `pihole -g`.

### Tuwunel's RocksDB

restic reading a live RocksDB file by file would capture SST files a compaction is
deleting, and that does not restore as a database. Tuwunel takes the backup itself:
`tuwunel-backup.timer`, installed by `make install-system`, sends `SIGUSR2` to
`pi-tuwunel` at 03:45, and `TUWUNEL_ADMIN_SIGNAL_EXECUTE` turns that into
`server backup-database` — a RocksDB backup into the `tuwunel_backups` volume, keeping
two. The 04:00 snapshot takes that volume and `tuwunel_media` (the uploads); the live
`tuwunel_data` is not mounted into Backrest. The timer skips itself when the `tuwunel`
profile is off.

To restore, stop the server and run the binary once with `--restore-backup` against the
same volumes:

```bash
docker compose stop tuwunel
docker compose run --rm --no-deps tuwunel --restore-backup --maintenance --execute "server shutdown"
docker compose up -d tuwunel
```

`--restore-backup=<id>` picks another backup than the newest (`!admin server list-backups`
in the admin room lists them). Restore replaces the files in `tuwunel_data`, so keep a
copy of that volume if the one you are replacing may still be wanted.

## Three eyes on the same question

Backups fail in two different ways, and one of them is silent:

- **Backrest → ntfy** pushes when a run *fails*.
- **Uptime Kuma `backup freshness`** alerts when a run never *started*.
- **`make doctor`** (and the `backups` chat topic) reads Backrest's operation log on demand.

## The `.env` file, twice

`scripts/backrest-env-snapshot.sh` copies `.env` to `/userdata/pi-web-env/.env` as a
pre-snapshot hook. A copy, not a bind mount: mounting a single file pins its inode, and
`services.sh` and `rotate-password.sh` replace `.env` rather than rewrite it.

That copy goes into **two** repositories, because one of them cannot restore itself:

| | `s3` | `usb` |
|---|---|---|
| Plan | `s3-backup`, 04:00 | `usb-env`, 02:00 |
| Contents | the whole `/userdata/` tree | `/userdata/pi-web-env` only |
| Where | off-site S3 bucket | `${DATA_LOCATION}/backrest/repos/env` — the data disk |
| Retention | 7 daily / 4 weekly / 4 monthly | 30 daily / 12 weekly / 12 monthly |
| Password | `BACKREST_S3_REPO_PASSWORD`, **inside the `.env` it backs up** | `repos/env-repo-password`, next to the repository |

The `s3` repository survives losing the house but cannot hand `.env` back on its own:
its password lives inside the file you would be restoring. The `usb` repository covers
the likelier failure — the root filesystem is gone, the data disk is fine — by keeping
its password in cleartext on the same disk, in `env-repo-password` and again in the
human-readable `env-RESTORE.txt`. That is deliberate: the disk already holds every
service's live data and a cleartext `.env` under `backrest/env-snapshot/`, so a password
kept elsewhere would buy no secrecy and make the repository unreadable in the one case
it exists for. Set `BACKREST_LOCAL_REPO_PASSWORD` in `.env` to choose otherwise.

`scripts/backrest-pre-start.sh` (re)writes both files and adds the repository and its
plan to an existing `config.json` if they are missing. The `usb-env` plan treats a failed
`.env` copy as fatal, unlike `s3-backup`: a plan whose only content is one file must alert
rather than record yesterday's copy as today's.

### The recovery kit

Losing both the Pi and the data disk leaves only `s3`, and opening it takes five values
that live on the root filesystem: the repository URI, the region, both S3 keys and the
repository password. Without them the bucket is unreadable ciphertext. They are five
values rather than the whole `.env` because `.env` is *inside* the repository they open
— and they change almost never, so they can live on paper.

```bash
make recovery-kit
```

It reads them from `config/backrest/config.json` — the file Backrest feeds to restic —
and prints nothing until it has opened the live repository with them from a throwaway
container. Output goes to a `mktemp` file, never to stdout, so a terminal transcript
never carries the values. The sheets also carry the restore commands used below.

You get two sheets to store in **two different places**: sheet A the S3 access, sheet B
the repository password. Neither reads the backup alone, but sheet A *can delete* it if
the key may delete objects and the bucket has no versioning — the split protects
confidentiality, not availability. Never store them in Vaultwarden, which is itself
restored *from* this repository. The pairing code changes on every run, so after a
rotation reprint and replace **both** halves.

## The API holds the keys

Backrest's API returns the restic repository password and the S3 keys to any
*authenticated* caller, so that login is worth exactly as much as the archive.

The image entrypoint (`config/backrest/auth-entrypoint.sh`) turns `BACKREST_AUTH_USER` /
`BACKREST_AUTH_PASSWORD` into a bcrypt user in `config.json` on every start. The password
is **not** `PASSWORD`: `scripts/backrest-pre-start.sh` generates a dedicated one into
`config/backrest/backrest.env`, because several containers carry `PASSWORD` in their
environment and a leak from any of them would otherwise reach every snapshot. Homepage's
widget reads a copy from `config/homepage/secrets/backrest_password`. If the credential is
missing and `config.json` defines no login, the entrypoint **refuses to start** rather
than come up unprotected.

`pi-backrest` is also off `frontend`, on the dedicated `backup` network that only Traefik
and Homepage join — see [Networking](NETWORKING.md#network-isolation).

Whoever holds the S3 key can delete every snapshot unless the key is restricted or the
bucket versioned — see [Configuration](CONFIGURATION.md#backrest-restic-backups).

## Restoring on new hardware

This procedure follows from what the snapshot contains. Rehearse it on spare hardware
before you need it: a backup you have never restored is a hypothesis.

| You lost | You still have | Where things come from |
|----------|----------------|------------------------|
| The root disk | The data disk (`DATA_LOCATION` on a separate disk) | `.env` from the data disk; bind-mounted data is already in place; Postgres from the dumps on the data disk; named volumes from S3 |
| Everything | The S3 bucket and the recovery kit | All of it from S3 |

With the default `DATA_LOCATION=./data`, the data lives on the root disk and only the
second row applies.

### 1. Reinstall the host

Raspberry Pi OS, Docker and the Compose plugin (the installer offers them), and restic
(`sudo apt-get install -y restic`). If the data disk survived, mount it where it was.

### 2. Get `.env` back

From the data disk:

```bash
export RESTIC_PASSWORD="$(cat <DATA_LOCATION>/backrest/repos/env-repo-password)"
restic -r <DATA_LOCATION>/backrest/repos/env restore latest --target /tmp/env-restore
# the file lands at /tmp/env-restore/userdata/pi-web-env/.env
```

From S3: export the values on the recovery-kit sheets as they print them, then
`restic restore latest --target /tmp/r --include /userdata/pi-web-env`. The file lands at
`/tmp/r/userdata/pi-web-env/.env`.

### 3. Clone the repository

Clone into a directory with the same name as before — `pi-pcloud` with the installer's
defaults — because Compose prefixes every named volume with it, and copy `.env` in. If
the Pi's LAN address or network changed, update `HOST_LAN_*` and `PIHOLE_IP` now.

### 4. Restore the files (S3 only)

Skip this step if the data disk survived. Otherwise restore the latest snapshot as root,
so ownership comes back with the files:

```bash
sudo -E restic restore latest --target /mnt/restore
```

`/mnt/restore/userdata/<name>` goes back to `<DATA_LOCATION>/<name>`, with these
exceptions:

| In the snapshot | On the host |
|-----------------|-------------|
| `nextcloud-data` | `<DATA_LOCATION>/nextcloud` |
| `kapowarr-db` | `<DATA_LOCATION>/kapowarr/db` |
| `traefik-letsencrypt` | `<DATA_LOCATION>/traefik/letsencrypt` |
| `audiobookshelf` | `<DATA_LOCATION>/audiobookshelf/config` |
| `pi-web-env`, `sqlite-backups` | not restored as such — they are the sources for `.env` and the SQLite copies |
| `beszel`, `open-webui-data`, `headscale`, `headplane`, `n8n`, `ntfy`, `kavita`, `pihole`, `tuwunel-media`, `tuwunel-backups`, `openclaw`, `aiostreams`, `aiometadata` | named volumes — step 7 |

The `backrest` service's volumes in `compose/compose-monitoring.yaml` are the
authoritative mapping. Copy with numeric ids, so a uid that means something else on the
new host is not rewritten:

```bash
sudo rsync -a --numeric-ids /mnt/restore/userdata/immich/ <DATA_LOCATION>/immich/
```

### 5. Restore the databases

Start Postgres alone. On an empty data directory it creates one empty database and role
per service (`config/postgres/init-databases.sh`), with the password from the restored
`.env`:

```bash
docker compose up -d postgres
```

Then replay the newest dump of each database into it, before any service starts and
runs its own migrations on the empty schema:

```bash
docker compose exec -T postgres psql -U postgres -d immich \
  < <DATA_LOCATION>/immich/backups/immich-sqlbkp_<timestamp>.bak
```

Repeat for `nextcloud`, `authelia`, `lldap`, `open-webui`, `vaultwarden`, `freshrss` and
`forgejo`, from the directories in [PostgreSQL dumps](#postgresql-dumps).

### 6. Install

```bash
make install
```

The hooks find the restored state rather than an empty one. Files they generate under
`config/` (such as `config/backrest/backrest.env`) are not in the snapshot; they are
created again here.

### 7. Put back the volume-held state

For each named volume in the table above, stop the service that owns it, copy the
restored directory in, and start it again. Find the volume's full name with
`docker volume ls`; it is `<directory>_<volume>`:

```bash
docker compose stop headscale
docker run --rm --entrypoint cp \
  -v <directory>_headscale_data:/dst -v /mnt/restore/userdata/headscale:/src:ro \
  pi-backrest:local -a /src/. /dst/
docker compose start headscale
```

For a service whose consistent SQLite copy exists, replace its `.db` with the copy from
`sqlite-backups/` while it is stopped. Restore Tuwunel with the
[command above](#tuwunels-rocksdb) once both of its volumes are back, and Pi-hole's lists
with `pihole-gravity-config.sql`.

### 8. Check

`make doctor` reports anything out of place, including any secret that no longer agrees
with its consumers. Then sign in through Authelia, open each service, and run
`make smoke`.
