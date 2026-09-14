# Homepage widget secrets

Each file in `secrets/` is a single-line secret read by the Homepage container
(via `{{HOMEPAGE_FILE_x}}` in `compose/monitoring.yaml`) to authenticate a
service widget on the dashboard. That whole directory is gitignored - nothing
in it is committed.

This page sits beside the directory rather than inside it on purpose: the
repository denies every read under a `secrets/` path, documentation included,
so a README in there is one no tool can lint, audit or fix.

Every widget secret lives here. Homepage has no `env_file`: one mechanism, one
place to look.

| File                | Service   | How it gets there |
|---------------------|-----------|--------------------|
| `prowlarr_api_key`  | Prowlarr  | `scripts/homepage-widgets-bootstrap.sh` reads it from Prowlarr's own `config.xml` |
| `headscale_api_key` | Headscale | same script, creates a dedicated `headscale apikeys create` token |
| `headscale_node_id` | Headscale | same script, looks up the `tailscale` client's node ID |
| `kavita_api_key`    | Kavita    | same script, reads an admin key from `kavita.db` - Kavita refuses password logins while OIDC is enforced, so a key is the only way in |
| `audiobookshelf_api_key` | Audiobookshelf | same script, logs in as the root account and mints a `homepage` API key - Audiobookshelf shows a key's value once, at creation, so this file is the only copy |
| `backrest_password` | Backrest  | same script, copies the per-service password out of `config/backrest/backrest.env` - `scripts/rotate-secret.sh` keeps the two in step |
| `immich_api_key`    | Immich    | **you paste it**: Immich > Account Settings > API Keys, permission `server.statistics` |

Everything except Immich regenerates on every stack boot - idempotent, only
rewritten when the value actually changed, and Homepage is restarted only then.

**Adding a new secret here needs `make update`, not just the bootstrap.** The
script ends with `docker restart pi-homepage`, which is enough for a changed
*file* but not for the new `HOMEPAGE_FILE_*` variable in
`compose/monitoring.yaml` that points at it: environment is fixed when a
container is created, so a restart
keeps the old set, `{{HOMEPAGE_FILE_...}}` never resolves and the widget shows
a bare "API Error". `make update` runs `compose up -d`, which recreates the
container first.

Immich is the exception, and not for lack of trying: its admin password is set
at signup and is not derivable from `.env`, and `api_key.key` is stored hashed,
so neither its API nor its database can hand a key back. The bootstrap creates
the file empty so the path always resolves; until you fill it, the Immich card
is a plain link with a small error icon, which breaks nothing else.
