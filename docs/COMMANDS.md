# Commands

Everything is a `make` target run from the project directory. `make install` also puts a **`pi-pcloud` command** on your `PATH`, so the same targets work from anywhere:

```bash
pi-pcloud status             # same as `make status`
pi-pcloud enable stremio     # same as `make enable stremio`
pi-pcloud                    # the command list
```

It is a thin dispatcher onto the Makefile — same output, same exit code, same arguments — so a target added there needs no change here. Both forms take the service name positionally (`s=<service>` still works with `make` for compatibility). Tab completion covers the commands and, after `enable` / `disable`, the service names, in bash and zsh; open a new shell after installing.

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
| `make recovery-kit` | Print the five values that open the off-site backup, as two sheets to store apart — verified against the live repository first ([Monitoring](MONITORING.md#the-off-site-half-needs-a-key-that-is-not-on-this-machine)) |
| `make api-keys` | Print the gateway base URLs and the tokens that open them, to paste into a client on another machine ([Local AI](AI.md#the-key-that-is-not-password)) |
| `make test` | Run the installer, CLI, `check-env`, service-selection, memory-reading, start-sequence and compose-invariant suites (temporary copies only, no host changes) |
| `make lint` | Run every static check CI runs: shell syntax and `shellcheck -s dash` over every tracked shell file, `yamllint`, `ruff`, `hadolint`, `actionlint` and a `gitleaks` history scan. A gate whose tool is missing is reported as skipped; `LINT_STRICT=1` makes a skip fail |

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

Images are refreshed while the stack is still running, so nothing is interrupted until the very end. It pulls only what the current `COMPOSE_PROFILES` selects, rebuilds the images built from `config/*/Dockerfile` against their updated bases, and finishes with `docker image prune -f` — dangling layers only, nothing a container still references. Expect several minutes on a Pi when base images have moved.

**It usually does not restart the stack.** The last step is `docker compose up -d --remove-orphans`, which recreates only the containers whose image or configuration actually changed — a single new image no longer costs a full-stack outage, and services that did not move are never touched. The whole start sequence (the pre-start hooks that render configuration, the `up`, then the bootstraps) lives in `scripts/stack-up.sh`, which is also `pi-pcloud.service`'s `ExecStart`: an update re-runs exactly what boot runs, so the two cannot drift.

**A changed config file recreates only the services that read it.** `up -d` compares a container's image and spec, not the *contents* of the files bind-mounted into it, so a rewritten `unbound.conf` would sit on disk unread. `scripts/changed-services.sh` names the services a pull obliges the update to recreate, and `make update` does exactly those with `up -d --no-deps --force-recreate --wait` (the `--wait` is what keeps the success line honest: the recreate happens after the start sequence's own health wait, so without it an update whose whole point was a new config would print ✅ over a container still crash-looping on it). It needs no table to do it: `config/<service>/` and `scripts/<service>-*.sh` already name their owner, and `tests/compose-invariants.py` fails the build on a file that stops following the convention. `scripts/` counts as config because the generated files (headscale, backrest, headplane, authelia) are gitignored — a pull that re-renders one shows up only as a change to the `*-pre-start.sh` that writes it. (Editing a config by hand is still `make restart`; the update has no way to see it.)

What the convention cannot express is a container that reads *another* service's file, and `changed-services.sh` carries one short list for it — `ALSO_RECREATE`. Two shapes, both silent if missed: an `env_file` written by one hook and mounted by others (`ntfy.env` reaches backrest and Uptime Kuma, and `env_file` values are frozen at container creation, so only a recreate picks up a new token), and a shared network namespace (qBittorrent, Stremio and Kapowarr run inside gluetun's, which Docker resolves to a container id at create time — recreating gluetun alone would leave all three running, healthy-looking and with no network at all).

Two cases still take the whole stack down:

- **A change no single service owns** — `scripts/lib.sh`, `run-hooks.sh`, `stack-up.sh` and the like can alter any rendered config, and the path alone cannot say which. Host-side tooling (`lint.sh`, the `rotate-*` scripts, `pg-major-upgrade.sh`) is explicitly exempt: it is listed in `changed-services.sh` as reaching no running container. Anything the convention does not cover answers "everything", because a config nothing recreates is a config nothing reads.
- **A systemd unit changed** — `make install-system` copies it and reloads the definition, but never restarts the unit, so a new `ExecStartPre` or `Environment=` would sit loaded and unapplied until the next reboot.
- **A network or volume definition moved** — an upstream subnet or driver option. `up -d` refuses outright there; `stack-up.sh` recognises the error, takes the stack down once and brings it back, rather than aborting with the new images already pulled.

`make restart` is still there to force a full restart at any time.

**It waits, and says what did not come up.** After the `up`, `stack-up.sh` polls `compose ps -a` until every container is running-and-healthy, or 300 s pass, and then names the ones that are not (`-a`, because a bare `compose ps` lists only what is running — a container that started and died would not be reported at all). A container already reported as `exited` is named straight away rather than polled: Docker takes a crashing container through `restarting`, so one sitting in `exited` has been stopped by hand or given up on, and waiting it out would add the full 300 s to every boot and every update for as long as a single service is down. It is a warning, never a failure: `compose up --wait` would have been the short way to write it, but that exits non-zero on a slow healthcheck, and under systemd a failed `ExecStart` is followed by `ExecStop` — `docker compose down`. One flaky service would take the whole stack down at boot.

**Nothing here is atomic.** `git pull` runs first, and a failure in any later step leaves the checkout on the new commit with the images pulled and the host files applied. There is no rollback; what there is, is the way back printed on failure — `git reset --hard <the previous commit> && make update`.

It also re-runs `install-system`, because a pull can change files this repository copies **outside** itself: the systemd units, the sysctl drop-in, the swap size, the kernel command line, the shell completions. Those copies would otherwise sit stale until the next `make install`. And it validates `.env` against the required-variable list *first*, so a variable added upstream is caught before anything is applied rather than after.

The `pi-pcloud` command needs no refresh — it is a symlink into the checkout.

### `make update-images`, the light one

`make update` minus everything that needs the repository to have moved: no `git pull`, no host files, no watcher restart. It validates `.env`, pulls and rebuilds the images, applies them in place, prunes. Use it when only the pinned images are stale — after Dependabot has been merged upstream but you have no local code change to pick up — and `make update` after a code change.

Both end on the same in-place apply, so both leave the stack in the state the repository describes.

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
