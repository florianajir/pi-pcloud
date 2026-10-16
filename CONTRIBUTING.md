# Contributing

Thanks for taking the time. Bug reports, service additions and documentation fixes are all welcome.

## Reporting a bug

Open an issue with the bug report form: it asks for the commit, `make services` and `make doctor`. **Never paste your `.env`, tokens or passwords**, and replace your domain with `<HOST_NAME>`.

Found a security issue? Follow the [security policy](.github/SECURITY.md) — privately, never in a public issue.

## Making a change

```bash
git clone https://github.com/florianajir/pi-pcloud.git
cd pi-pcloud
make test          # installer, CLI, check-env, service-selection, start-sequence, compose-invariant and Trilium-API-contract suites
make lint          # every static check CI runs: shell, YAML, Python, Dockerfiles, workflows, secrets, docs
```

Both leave the running stack alone. `tests/trilium-api-contract.sh` is the one suite that starts a container — a throwaway Trilium with no volumes and no published ports — and pulls the pinned image if it is missing; its header explains why it exists. Point it at a candidate before committing a Trilium bump:

```bash
TRILIUM_CONTRACT_IMAGE=ghcr.io/triliumnext/trilium:v0.106.0 sh tests/trilium-api-contract.sh
```

`make lint` runs `scripts/lint.sh`, which CI calls too, so a green run locally means a green run there. A gate whose tool is missing is reported as skipped; CI sets `LINT_STRICT=1`, which makes a skip fail.

`shellcheck` comes from your package manager. `ruff` and `yamllint` are pinned in `requirements-lint.txt`; Raspberry Pi OS (like any PEP 668 distro) refuses to install them system-wide, so use a virtualenv:

```bash
sudo apt-get install -y shellcheck
python3 -m venv .venv-lint && .venv-lint/bin/pip install -r requirements-lint.txt
PATH="$PWD/.venv-lint/bin:$PATH" make lint
```

`hadolint`, `actionlint` and `gitleaks` need nothing installed: `scripts/lint.sh` runs them from pinned images when Docker is available.

Then open a pull request against `main`. CI runs the same gates, validates the Compose file under four profile combinations, runs the test suites, boots the stack, and refuses an added image that publishes no ARM manifest (`tests/image-architectures.py`) — the runners are amd64, so nothing else would notice.

### House rules

These are the ones that get changes sent back. [AGENTS.md](AGENTS.md) has the full set.

- **Everything through Docker Compose.** Change `compose/compose-<domain>.yaml` (services), `compose.yaml` (networks, volumes, the `x-` tier anchors), `config/` or `scripts/` — never the state of a running container. A fresh install must reach the same result.
- **Scripts are POSIX `sh`**, run by dash with `set -eu`. No bashisms: `shellcheck -s dash` in `make lint` reports each one as an `SC3xxx` error.
- **Never source `.env`** — read keys through `scripts/lib.sh` `get_env_value`. Never log a secret.
- **Pin every image version** explicitly, after checking upstream for the newest stable release. No `latest`.
- **Documentation follows the change, in the same commit.** Verify every port, IP, variable and default against the actual file; use `<HOST_NAME>` placeholders, never a real domain.
- **Docs describe the current stack, for the people running it.** No project history, incident stories, dated measurements or provider quotas that will go stale, and no names of torrent trackers or shadow libraries. How a decision was reached belongs in the pull request.
- **Comments explain *why*, not *what*.** Self-explanatory code beats a comment restating it.

### Adding a service

Follow the [add-service checklist](.agents/skills/add-service/SKILL.md): Compose profile, Traefik labels, Authelia OIDC client, shared Postgres/Redis, ntfy, Uptime Kuma, Backrest, Homepage labels and the systemd bootstrap hook.

### Brand assets

`docs/assets/banner.png` (the README header) and `docs/assets/logo.png` (the mark) are the only sources for the project's artwork. Everything in `config/homepage/icons/` is generated from `logo.png` — re-render with `scripts/homepage-favicon.sh` (needs ImageMagick) and commit the result. `logo-mask.svg`, the monochrome silhouette Safari needs, is the one hand-maintained exception.

A re-rendered icon takes effect immediately; a *new* filename needs `docker compose up -d homepage`, because Homepage indexes `public/` only at boot.

### Releases

`.github/workflows/release.yml` tags `main` on the first of each month as `vYYYY.MM.DD`, with notes generated from the merged pull requests, and skips the month if nothing was merged. Run it from the Actions tab for an out-of-cycle release.
