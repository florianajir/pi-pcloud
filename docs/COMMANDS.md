# Commands

Everything is a `make` target run from the project directory. `make install` also puts a **`pi-pcloud` command** on your `PATH`, so the same targets work from anywhere:

```bash
pi-pcloud status             # same as `make status`
pi-pcloud enable stremio     # same as `make enable stremio`
pi-pcloud                    # the command list
```

It is a thin dispatcher onto the Makefile — same output, same exit code, same arguments. Both forms take the service name positionally; `make` also accepts `s=<service>`. Tab completion covers the commands and, after `enable` / `disable`, the service names, in bash and zsh; open a new shell after installing.

The command is a symlink to `scripts/pi-pcloud` inside the checkout, so `git pull` updates it. Point `PI_PCLOUD_DIR` at another checkout to change which one it drives.

## Reference

### Lifecycle

| Command | What it does |
|---------|--------------|
| `make preflight` | Verify Docker, cgroup v2 and dependencies |
| `make install` | Deploy the stack and create the systemd units |
| `make start` / `make stop` / `make restart` | Control the whole stack |
| `make update` | Pull code and images, rebuild, re-apply host files, apply in place |
| `make update-images` | Images only: pull, rebuild, recreate just the containers whose image moved |
| `make install-system` | Re-apply only what lives outside the repo: sysctl, swap size, kernel command line, `/etc/hosts`, systemd units, the `pi-pcloud` command and its completions |
| `make pg-upgrade to=<image>` | Move the shared Postgres cluster to a new major (dump/restore). One step of a procedure — read [Postgres upgrades](POSTGRES-UPGRADE.md) first |
| `make uninstall` | Remove the stack, volumes and units — **destructive** |

### Day to day

| Command | What it does |
|---------|--------------|
| `make status` | `systemctl status` for the stack unit and the Authelia log watcher |
| `make logs` | Follow live logs |
| `make doctor` | Report anything outside its threshold: disk, RAM, swap, temperature, load, containers, restarts, backups — then which memory ceilings are actually binding and which were never approached ([Monitoring](MONITORING.md#ceilings-and-what-psi-cannot-see)), then whether each secret still agrees with its consumers |
| `make services` | List optional services, whether each is enabled, what the running containers hold right now, and the RAM ceilings of the selection |
| `make enable <service>` | Enable a service: update `COMPOSE_PROFILES`, start it, run its init hooks — then what it costs: its ceiling, and what it was last measured holding here |
| `make disable <service>` | Disable a service: update `COMPOSE_PROFILES` and stop it — and say what that frees |
| `make config` | Interactive checklist to choose which optional services run |
| `make check-env` | Validate the required `.env` variables |
| `make recovery-kit` | Print the five values that open the off-site backup, as two sheets to store apart — verified against the live repository first ([Backups](BACKUP.md#the-recovery-kit)) |
| `make api-keys` | Print the gateway base URLs and the tokens that open them, to paste into a client on another machine ([Local AI](AI.md#the-key-that-is-not-password)) |
| `make test` | Run the suites in `tests/` against temporary copies and throwaway containers — no change to the host or the running stack |
| `make lint` | Run every static check CI runs: shell syntax and `shellcheck -s dash` over every tracked shell file, `yamllint`, `ruff`, the docs invariants (links, anchors, prose rules), `hadolint`, `actionlint` and a `gitleaks` history scan. A gate whose tool is missing is reported as skipped; `LINT_STRICT=1` makes a skip fail |

### VPN and credentials

| Command | What it does |
|---------|--------------|
| `make headscale-register <key>` | Register a device to the VPN |
| `make headscale-reset` | Reset all VPN nodes — **destructive** |
| `make rotate-password` | Rotate `PASSWORD` after a leak (LLDAP admin + Authelia) |
| `make rotate-password-full` | The same, plus every Postgres role and every other service using `PASSWORD` |
| `make rotate-secret TARGET=<name>` | Rotate one *independent* per-service secret and propagate it to every consumer. `TARGET=` with no value lists them |
| `make check-secrets` | Report which secrets have drifted from their consumers; changes nothing |

## What `make update` actually does

In order: `git pull`, validate `.env` against the required-variable list (so a variable added upstream is caught before anything is applied), pull and rebuild the images, re-apply host files, apply in place, prune.

**Images are refreshed while the stack runs.** It pulls only what `COMPOSE_PROFILES` selects, rebuilds the images built from `config/*/Dockerfile` against their updated bases, and finishes with `docker image prune -f` — dangling layers only. Expect several minutes on a Pi when base images have moved.

**A failed pull is retried twice**, 20 s then 40 s later — in `make update-images` too — since a registry can rate-limit Compose's parallel pulls, and what the failed attempt fetched is already local. A third failure stops the update before anything is rebuilt or applied.

**Host files are re-applied** through `make install-system`, because a pull can change what this repository copies outside itself: the systemd units, the sysctl drop-in, the swap size, the kernel command line, the shell completions. The `pi-pcloud` command needs no refresh — it is a symlink into the checkout.

**It usually does not restart the stack.** The apply step is `scripts/stack-up.sh` — also `pi-pcloud.service`'s `ExecStart`, so an update re-runs exactly what boot runs: the pre-start hooks that render configuration, `docker compose up -d --remove-orphans`, then the bootstraps. `up -d` recreates only the containers whose image or spec changed; the rest are never touched.

**A changed config file recreates the services that read it.** `up -d` does not compare the *contents* of bind-mounted files, so `scripts/changed-services.sh` names the services a pull affects from the paths alone — `config/<service>/` and `scripts/<service>-*.sh` name their owner. `make update` recreates those with `up -d --no-deps --force-recreate`, then waits up to 180 s and warns about any that are not healthy. A container that reads another service's file or network namespace is listed in that script's `ALSO_RECREATE` and recreated along with it — qBittorrent, Stremio and Kapowarr with gluetun, for instance. A config you edit by hand is not seen: run `make restart`.

These cases take the whole stack down:

- **A change no single service owns** — `scripts/lib.sh`, `run-hooks.sh`, `stack-up.sh` and the like can alter any rendered config. Host-side tooling (`lint.sh`, the `rotate-*` scripts, `pg-major-upgrade.sh`) is exempt. Any path the convention does not cover counts as "everything".
- **A systemd unit changed** — `make install-system` reloads the definition but never restarts the unit, so the update restarts the stack.
- **A network or volume definition moved** — `up -d` refuses those; `stack-up.sh` recognises the error, takes the stack down once and brings it back.

`make restart` forces a full restart at any time.

**It waits, and names what did not come up.** After the `up`, `stack-up.sh` polls `compose ps -a` until every container is running and healthy, or 300 s pass, then names the ones that are not; a container already `exited` is named straight away rather than waited for. It is a warning, never a failure: under systemd a failed `ExecStart` is followed by `ExecStop` — `docker compose down` — so one flaky service would take the whole stack down at boot.

**Nothing here is atomic.** A failure after `git pull` leaves the checkout on the new commit, with the images pulled and the host files applied. There is no rollback; the failure message prints the way back — `git reset --hard <the previous commit> && make update`.

### `make update-images`, the light one

`make update` minus everything that needs the repository to have moved: no `git pull`, no host files, no watcher restart. It validates `.env`, pulls and rebuilds the images, applies them in place with the same `stack-up.sh`, and prunes. Use it when only the images are stale, and `make update` after a code change.

## Common workflows

**After editing `.env`:**
```bash
make restart
```

**Toggle optional services** ([details](CONFIGURATION.md#choosing-which-services-run)):
```bash
make services            # what is enabled right now?
make config              # interactive checklist
make enable stremio      # auto-starts gluetun too, runs init hooks
make disable n8n
```

**Read one service's logs:**
```bash
docker compose logs -f traefik      # or authelia, nextcloud, pihole, …
journalctl -t pi-traefik            # same lines, survives container recreation
```

**Add a device to the VPN:**
```bash
tailscale up --login-server https://headscale.<HOST_NAME>
# open the printed URL and sign in via Authelia — or register the key manually:
make headscale-register <key-from-the-url>
```

**Update:**
```bash
make update           # code + images, applied in place
make update-images    # images only, same in-place apply
```
