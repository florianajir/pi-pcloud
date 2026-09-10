# PostgreSQL major upgrades

Seven services share one PostgreSQL cluster: `immich`, `nextcloud`, `authelia`, `lldap`, `open-webui`, `vaultwarden`, `freshrss`. A major version bump therefore moves all seven at once, or none of them.

It is a **dump and restore**, not `pg_upgrade`. The `ghcr.io/immich-app/postgres` image ships exactly one major's binaries and `pg_upgrade` needs both, so it would take a custom image carrying two Postgres builds plus VectorChord. The dump also rebuilds the vchord indexes at the new extension version, which is the rebuild the VectorChord release notes ask for after any vchord change anyway.

`scripts/pg-major-upgrade.sh` does the whole thing, wrapped as `make pg-upgrade`. This page is the procedure around it: what to check first, and what to look at afterwards.

## The one thing that will ruin your day

**Never start the stack on the new compose file before the migration has run.**

The data directory moves with the major (see below), so a `make start` on the new checkout finds nothing at the new path, initialises an empty cluster, and `config/postgres/init-databases.sh` obligingly creates all seven roles and all seven *empty* databases. Every service then connects successfully — to nothing. Nextcloud reports itself uninstalled, Immich starts re-running its migrations, and both begin writing into the empty cluster. The old data is still intact, but you are now merging two divergent clusters instead of doing a migration.

Between checking out the new compose file and finishing `make pg-upgrade`, the only commands that are safe are the ones on this page. Not `make start`, not `make update`, not `make restart`, and not the `pi-pcloud` service starting on its own after a reboot — if the host reboots mid-procedure, run the migration before doing anything else.

## Why the data path changes

From Postgres 18 the upstream image keeps `PGDATA` at `/var/lib/postgresql/<major>/docker` and **refuses to start** with anything mounted at `/var/lib/postgresql/data`. So the mount point became the parent directory and the host path carries the major:

```yaml
# before                                             # after
- ${DATA_LOCATION}/postgres:/var/lib/postgresql/data - ${DATA_LOCATION}/postgres18:/var/lib/postgresql
```

That is not just a compatibility detail — it is the rollback. The old cluster at `${DATA_LOCATION}/postgres` is **never written to** by the upgrade, so reverting two lines in `compose.yaml` puts you back exactly where you started.

## Pre-flight

1. **Confirm the target image supports every service.** Immich is the binding constraint: it declares a `POSTGRES_VERSION_RANGE` and a required vchord range in its release notes, and refuses to start outside them. The others follow the Postgres project's own support window.

2. **Check the vchord upgrade path exists.** The dump's `CREATE EXTENSION` lines carry no version, so the restore installs vchord at the new image's `default_version` directly and no `ALTER EXTENSION` is needed as part of the cutover. Confirm the target ships the extension at all:

   ```sh
   docker run --rm --entrypoint sh <target-image> \
     -c 'cat /usr/share/postgresql/*/extension/vchord.control'
   ```

   `vchord.control` sets `superuser = true`, which is why the `immich` role — deliberately not a superuser — cannot install or update it itself. `scripts/postgres-bootstrap.sh` runs `ALTER EXTENSION ... UPDATE` as `postgres` on every boot, so later vchord bumps *within* a major (where the data directory is reused) are hands-off. Immich's own `pg_dumpall`-based backup is off in `config/immich/config.yaml` for the same reason; leave it off.

3. **Bump the Backrest client in the same change.** `config/backrest/Dockerfile` pins `postgresqlNN-client`, and `scripts/db-backup.sh` dumps through it. A client older than the server refuses to dump at all, so an unbumped Backrest silently stops backing up all seven databases the night after the cutover.

4. **Check free space.** The script wants 3× the cluster size and refuses to start below it: the dumps are roughly one copy and the new cluster another.

5. **Rehearse first.** `scripts/pg-major-upgrade.sh --to <image> --rehearse`, with `ENV_FILE` pointing at a scratch `.env` whose `DATA_LOCATION` is spare disk, runs the entire dump/restore/verify against the live cluster **without stopping anything** — no service, not Postgres itself — and refuses `--apply`. It proves the migration on your real data for the cost of a read.

6. **Take a backup you did not generate for this.** Run the Backrest plan and let its `db-backup.sh` hooks write their per-database dumps, so there is an off-site copy independent of the upgrade's own working files.

## The cutover

Everything below runs from the repository root with the stack **up** — the script dumps from the live cluster, and stops the stack itself when it is ready to.

```sh
# 1. The new compose file, WITHOUT starting anything.
git checkout <branch>

# 2. A globals dump the script does not take: it restores roles from
#    `pg_dumpall --roles-only`, which omits tablespaces and per-database
#    settings. There are none here, which is exactly what this proves.
docker exec pi-postgres pg_dumpall -U postgres --globals-only \
  > ~/pg-globals-$(date +%F).sql

# 3. Record what the cluster looks like now, to compare against afterwards.
docker exec pi-postgres psql -U postgres -Atc \
  "SELECT rolname, rolsuper FROM pg_roles WHERE rolcanlogin ORDER BY rolname;"
docker exec pi-postgres psql -U postgres -Atc 'SHOW server_version;'

# 4. The migration. Takes the image from compose.yaml, so the two cannot drift.
make pg-upgrade to=$(grep -m1 'image: ghcr.io/immich-app/postgres:' compose.yaml | awk '{print $2}')
```

`make pg-upgrade` then, in order: pulls the target image, **stops only the Postgres-backed services** (immich, nextcloud, authelia, lldap, open-webui, vaultwarden, freshrss, plus backrest so no scheduled dump fires mid-window), dumps roles and all seven databases, counts every row in every table, stops Postgres, starts a throwaway container on the new data directory, restores into it, runs `ANALYZE` per database so the new cluster starts with planner statistics, **re-counts every table and compares the two lists whole**, and refuses to touch `compose.yaml` if they differ at all. On a mismatch it stops with the old cluster untouched and the new one left in place for inspection.

**The DNS/VPN path never stops.** Pi-hole, unbound, headscale and tailscale use no Postgres (headscale is SQLite), so devices on the tailnet keep resolving and routing through the whole cutover. What the window does cost: the stopped services themselves are unreachable, and SSO logins fail while Authelia is down — established Tailscale connections and plain internet access are unaffected. The writers stop *before* the dump on purpose: anything written between the dump and the switch would otherwise be silently absent from the new cluster.

The counts are exact `count(*)`, not `pg_stat_user_tables.n_live_tup`. That estimate is only refreshed on (auto)analyze, and a table too small to trip the autovacuum threshold can carry a number that was never right — on this stack `lldap.groups` reported 0 against 4 real rows. Compared against a freshly restored cluster, whose counts *are* accurate, that reads as data loss on a migration that was perfect.

```sh
# 5. Rebuild Backrest. `up -d` compares image *names*, and pi-backrest:local
#    has not changed name — the pg-NN client inside it would stay at the old
#    major forever.
docker compose build backrest

# 6. Start.
make start
```

### What the restore does not carry over

`pg_dumpall --roles-only` reproduces the source cluster's role attributes faithfully, **including any `SUPERUSER`**. An install predating the current `init-databases.sh` created the `immich` role as a superuser, and `init-databases.sh` cannot correct it: it only ever runs on a fresh `PGDATA`, from `docker-entrypoint-initdb.d`, which a restored cluster never is.

`scripts/postgres-bootstrap.sh` asserts it instead, on every boot, so this is handled — but verify rather than assume:

```sh
docker exec pi-postgres psql -U postgres -Atc \
  "SELECT rolsuper FROM pg_roles WHERE rolname = 'immich';"   # must be f
```

If it reads `t`, the bootstrap hook did not run (check `make logs`) and the fix is one statement:

```sh
docker exec pi-postgres psql -U postgres -c 'ALTER ROLE immich WITH NOSUPERUSER;'
```

The same applies to the extension versions, for a cluster that came from a restore rather than this script:

```sh
docker exec pi-postgres psql -U postgres -d immich -Atc \
  "SELECT name, installed_version, default_version FROM pg_available_extensions
   WHERE installed_version IS NOT NULL AND installed_version IS DISTINCT FROM default_version;"
```

Anything listed means `ALTER EXTENSION <name> UPDATE;` as `postgres`, which is what the bootstrap hook does.

## Post-cutover verification

Do these in order — each one exercises a different failure mode, and the first two gate the rest.

| # | Check | How | What a failure means |
|---|-------|-----|----------------------|
| 1 | Server version and extensions | `docker exec pi-postgres psql -U postgres -Atc 'SHOW server_version;'` | The container came up on the old cluster; check the mount path in `compose.yaml` |
| 2 | Every container healthy | `docker compose ps` — nothing restarting | A service could not authenticate or found an empty schema |
| 3 | **Authelia + lldap login** | Log in at `https://auth.<HOST_NAME>` | Both roles' data restored; do this first, everything else is behind it |
| 4 | **Immich: upload a photo** | Upload from the app or web, then confirm the thumbnail and that search returns it | Write path, and the vchord index — a broken `clip_index` shows up as search returning nothing, not as an error |
| 5 | **Vaultwarden** | Unlock the vault and open one entry | Its diesel migrations ran against restored data |
| 6 | **Nextcloud** | `docker exec pi-nextcloud php occ status` then `docker exec pi-nextcloud php occ db:add-missing-indices` | `installed: true` and no missing indices; a `dbpassword` mismatch shows here first |
| 7 | **Open WebUI** | Load a past conversation, not just the login page | SQLAlchemy reads restored history rather than an empty database |
| 8 | Backups still work | Run the Backrest plan by hand and check all seven `db-backup.sh` hooks succeed | The client/server major mismatch from step 5 of the cutover |
| 9 | Row counts | Already verified by the script; `--keep-dumps` leaves `counts.before`/`counts.after` for a second look | — |

Only once all nine pass:

```sh
# The old cluster is the rollback. Keep it until you are sure — it costs disk,
# not correctness, and there is no way to regenerate it afterwards.
sudo rm -rf ${DATA_LOCATION}/postgres
```

## Rollback

The old cluster was never written to, so this is complete and takes a minute:

```sh
make stop
git checkout main            # or revert the compose.yaml image + volume lines
docker compose build backrest # back to the old client major
make start
```

Anything written to the *new* cluster since the cutover is lost by rolling back — which is the real reason to run the verification list promptly rather than a week later.
