# Email & Notifications

Push notifications are the primary channel in this stack — see [ntfy topics](MONITORING.md#ntfy-topics). Email is for the things that must reach a person who isn't looking at their phone: password resets, identity verification, sharing notifications and emergency vault access.

One set of SMTP credentials in `.env` serves every service that can read them. The variables are listed in [Configuration → Email](CONFIGURATION.md#email); apply changes with `make restart`.

**Two things that catch people out:**

- Gmail, Office 365 and most large providers refuse your account password — generate an **app password** and use that.
- Nextcloud's sender domain is always `HOST_NAME`, so the address is `${MAIL_FROM_ADDRESS}@${HOST_NAME}`. Vaultwarden pins `SMTP_SECURITY=starttls` in `compose.yaml`; change it to `force_tls` there if you move to port 465.

**To run without email:** leave `SMTP_HOST` empty or set to `localhost`. The stack starts normally — Authelia has `disable_startup_check` enabled — and delivery simply fails silently.

## Who sends what

Configured automatically from `.env`:

| Service | Sends |
|---------|-------|
| **Authelia** | 2FA enrolment, password reset, identity verification |
| **Nextcloud** | Share notifications, activity digests, password resets |
| **LLDAP** | Self-service password reset links |
| **Vaultwarden** | Invitations, and the whole emergency-access flow (invite, grant, takeover notice). Emergency access is useless without working SMTP — and since `SSO_ONLY` is on, the trusted contact also needs an LLDAP account. See [Security](SECURITY.md#vaultwarden) |
| **n8n** | Workflow **Send Email** nodes and error notifications (`N8N_SMTP_*`) |
| **ntfy** | Email delivery for topics, when a subscriber asks for it |
| **Beszel** | Alert emails, configured through its API by `scripts/beszel-agent-bootstrap.py` |

Configured in their own UI — they don't read `.env`:

| Service | Where | Needed? |
|---------|-------|---------|
| **Immich** | Admin → Settings → Notification settings | Optional; reuse the same `SMTP_*` values |
| **Uptime Kuma** | Settings → Notifications → SMTP | Optional — its ntfy notifications are already bootstrapped, so email is a second channel |
| **Kavita** | Settings → Email | Usually unnecessary with SSO — see [Installation](INSTALLATION.md#4-kavita--one-manual-step) |
| **Dockhand** | — | Nothing to do: alerts go to ntfy via `scripts/dockhand-oidc-bootstrap.sh` |

## Testing it

- **Authelia** — `https://auth.<HOST_NAME>` → Settings → add or verify an email, or reset a password.
- **Nextcloud** — Administration → Basic settings → Send test email.
- **Beszel / Uptime Kuma** — trigger a test notification from their settings.

```bash
docker compose logs authelia | grep -i -E 'smtp|mail'
docker compose logs nextcloud | grep -i mail
```

Delivery failing? See [Troubleshooting → Email](TROUBLESHOOTING.md#email).
