# Security policy

## Reporting a vulnerability

Report it privately through
[GitHub security advisories](https://github.com/florianajir/pi-pcloud/security/advisories/new),
never in a public issue, pull request or discussion.

Include what you found, how to reproduce it, and the commit you were on
(`git rev-parse --short HEAD` in your clone). Replace your domain with
`<HOST_NAME>` and remove addresses, tokens and passwords from anything you attach.

The project is maintained by one person on a best-effort basis. You will get an
answer in the advisory thread, and credit in the fix unless you prefer not to.

## Supported versions

Only `main`. There are no maintained release branches: `make update` brings an
install to the latest `main`, and the monthly releases are dated changelogs, not
versions to pin.

## Scope

In scope: everything this repository ships — the Compose files, Traefik routers
and middlewares, the Authelia and OIDC configuration, the installer and the
scripts, and the default exposure they produce.

Out of scope:

- Vulnerabilities in an upstream image (Nextcloud, Immich, Vaultwarden, …).
  Report them to that project; the stack picks up the fix through its daily
  image updates.
- The trade-offs listed under
  [Accepted risks](../docs/SECURITY.md#accepted-risks), unless you found a way
  to make one worse than described there.

How the stack is secured — login flows, per-service protection, secrets — is
described in [docs/SECURITY.md](../docs/SECURITY.md).
