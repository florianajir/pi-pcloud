# VPN (Tailscale + Headscale)

Headscale is a self-hosted Tailscale control plane. You get the official Tailscale clients on every platform and a private WireGuard mesh, but the coordination stays on your Pi instead of Tailscale's cloud — and logins are federated to Authelia, so joining the VPN means signing in with your LLDAP account.

| Component | Where | Access |
|-----------|-------|--------|
| **headscale** | `https://headscale.<HOST_NAME>` | Public by necessity — clients must reach it from anywhere. Runs an embedded DERP relay (STUN on `3478/udp`), which relays only for enrolled nodes (`derp.server.verify_clients`) |
| **headplane** | `https://headscale.<HOST_NAME>/admin` | Admin web UI — LAN-only, `admin` group, 2FA. Bare `https://headscale.<HOST_NAME>/` redirects here |
| **tailscale** | The Pi's own node, on the host network | WireGuard on `41641/udp` |

The Pi's node starts with `--advertise-exit-node --advertise-routes=${HOST_LAN_SUBNET} --ssh`, so exit-node use, LAN access and Tailscale SSH need nothing extra on the Pi — only per-client enabling. `scripts/headscale-init.sh` runs on stack start: it creates the Headscale user, registers the Pi with a short-lived preauth key tagged `tag:router`, and provisions Headplane's API key. The policy's `autoApprovers` approve that tag's LAN and exit routes.

## Connecting a device

1. Install the official client — [tailscale.com/download](https://tailscale.com/download), or on Linux `curl -fsSL https://tailscale.com/install.sh | sh`.

2. Point it at your own control plane:

   ```bash
   tailscale up --login-server https://headscale.<HOST_NAME>
   ```

3. Open the URL it prints. It leads to Authelia — sign in with your LLDAP account and the device is registered. On mobile, set the login server in the Tailscale app's account settings and log in the same way.

If the browser flow isn't practical, register the node key on the Pi instead:

```bash
make headscale-register <key-from-the-url>
```

### Headless devices

For anything that can't open a browser:

```bash
docker compose exec headscale headscale preauthkeys create --user <user-id> --reusable
tailscale up --login-server https://headscale.<HOST_NAME> --authkey <key>
```

Revoke reusable keys if they leak — they allow registration with no interactive login at all.

## What you get on the VPN

- **Every service, by name, with valid TLS.** `https://nextcloud.<HOST_NAME>` works from a hotel Wi-Fi exactly as it does at home.
- **Ad blocking everywhere.** All DNS goes to `100.64.0.1` — the Pi's tailnet IP — through the tunnel, so Pi-hole filters the device wherever it is. The client must accept DNS for this (`tailscale up --accept-dns=true`, or "Use Tailscale DNS" in the app — the default).
- **MagicDNS names** under `tailnet.<HOST_NAME>`.
- **The Pi as an exit node or LAN gateway.** It already advertises both and the policy approves them; per client:

  ```bash
  tailscale set --exit-node <pi-tailnet-ip>   # route ALL traffic through home
  tailscale set --accept-routes=true          # or just reach the home LAN
  ```

Details of the DNS side: [Networking → DNS on the VPN](NETWORKING.md#dns-on-the-vpn).

### The IPv6 half of the exit node

`tailscaled` advertises `0.0.0.0/0` **and** `::/0`, but in this setup it installs its netfilter chains (`ts-input`, `ts-forward`, `ts-postrouting`) for IPv4 only. Nothing complains — `tailscale status` looks right and a client using the exit node reaches every IPv4 site — but IPv6-capable sites stall, because the client's packets leave the uplink with their `fd7a:115c:a1e0::/48` source and are dropped upstream.

`scripts/tailscale-post-start.sh` (a post-start hook, so it runs on every boot and every `make update`) mirrors the four IPv4 rules into the same backend `tailscaled` chose (`-legacy` or `-nft`), with the address family translated and the WireGuard port read off the IPv4 rule. It compares before it writes, so a run that finds the chains in step changes nothing. To check:

```bash
sudo ip6tables-legacy -t filter -S ts-forward   # should mirror the -S of the v4 chain
sudo ip6tables-legacy -t nat    -S ts-postrouting
```

The mirror is a hardcoded copy of the IPv4 rules, so a `tailscaled` that starts managing IPv6 itself would be overwritten rather than left alone: re-check the script whenever the `tailscale/tailscale` image is bumped.

## Managing users and devices

Headplane at `https://headscale.<HOST_NAME>/admin` covers day-to-day work: viewing nodes, expiring keys, approving routes. The CLI equivalents:

```bash
docker compose exec headscale headscale users list
docker compose exec headscale headscale nodes list
docker compose exec headscale headscale nodes delete --identifier <node_id>
make headscale-reset       # wipe ALL nodes, preauth keys and IP allocations — destructive
```

ACLs use Headscale's HuJSON policy format, loaded from `config/headscale/policy.hujson` (`policy.mode: file`). That file is rendered from `config/headscale/policy.hujson.template` by `scripts/headscale-pre-start.sh` on every start, so edits to it are overwritten: restrict traffic between devices in the template, then run `make update`. The shipped policy accepts all traffic. Syntax: the [Headscale docs](https://headscale.net/).

---

Device won't register, or services unreachable from the VPN? See [Troubleshooting → VPN](TROUBLESHOOTING.md#vpn).
