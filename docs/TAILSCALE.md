# Tailscale & Headscale VPN Setup

This stack includes Headscale, a self-hosted Tailscale control plane. It creates a private WireGuard VPN mesh for secure remote access to your services.

## What is Headscale?

Headscale is an open-source implementation of the Tailscale control plane:

- **Replaces** Tailscale's cloud-based coordination server
- **Keeps your VPN private** — You control the server
- **No account required** — Users authenticate via Authelia SSO
- **Same client apps** — Use official Tailscale client on Linux, macOS, Windows, iOS, Android
- **MagicDNS** — Automatic DNS for internal services

## Architecture

```mermaid
flowchart TB
    subgraph VPN["Headscale VPN Network"]
        Client1["Laptop\n(100.64.x.1)"]
        Client2["Phone\n(100.64.x.2)"]
        Client3["Pi\n(100.64.x.100)"]
        Pi_Direct["Pi direct IP\n(192.168.1.100)"]
    end

    Headscale["Headscale\nControl plane"]
    Headplane["Headplane\nWeb admin UI"]

    Client1 <-->|WireGuard| Client2
    Client2 <-->|WireGuard| Client3
    Client3 <-->|WireGuard| Client1
    Pi_Direct ↔ Headscale
    Headplane -->|manage| Headscale
```

**Benefits:**
- **Encrypted** — WireGuard tunnel (256-bit elliptic curve)
- **Mesh** — All devices can reach each other, not just Pi
- **NAT traversal** — Works through firewalls, mobile networks
- **Zero-trust** — Only authenticated devices can connect
- **Split DNS** — Local services resolve correctly on VPN

## Quick Start

### 1. Install Tailscale on Client Device

**Linux:**
```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

**macOS:**
```bash
brew install tailscale
```

**Windows:**
Download from https://tailscale.com/download

**Mobile:** App Store or Google Play

### 2. Join Your Headscale Network

Run tailscale up and note the registration URL:

```bash
tailscale up --login-server https://headscale.<YOUR_DOMAIN>:443
```

This outputs a registration URL. Copy it.

### 3. Approve Node on Pi

Run on your Raspberry Pi:

```bash
make headscale-register <registration_url>
```

Or manually:

```bash
docker compose exec headscale \
  headscale nodes register --user <username> --key <auth_key>
```

Your device is now on the VPN!

## Connecting Devices

### Step-by-Step

1. **On your device**, run:
   ```bash
   tailscale up --login-server https://headscale.<YOUR_DOMAIN>:443
   ```

2. **Copy the registration URL** shown in terminal output

3. **On the Pi**, run:
   ```bash
   make headscale-register <paste-url-here>
   ```

4. **Device connects to VPN** — You'll get an IP like `100.64.x.x`

### Authorization Keys (Alternative)

For automated registration (useful for scripts, mobile apps):

1. **Generate auth key:**
   ```bash
   docker compose exec headscale \
     headscale preauthkeys create --user <username> --reusable
   ```

2. **Copy the key**

3. **Use on device:**
   ```bash
   tailscale up --login-server https://headscale.<YOUR_DOMAIN>:443 --authkey <key>
   ```

## Headplane Web UI

Access Headscale administration via Headplane:

**URL:** `https://headplane.<YOUR_DOMAIN>`

**Login:** Use your LLDAP credentials (Authelia SSO)

**Requires:**
- `admin` group + 2FA (stricter policy than other services)
- LAN IP or VPN connection (IP allowlist)

**What you can do:**
- View connected nodes (devices)
- Create/revoke auth keys
- Manage users and networks
- View route information
- Monitor node health

## MagicDNS

Headscale automatically pushes DNS configuration to all connected clients:

### Configuration

**Pi-hole as DNS:**
- All VPN clients use Pi-hole for DNS
- Queries go through WireGuard tunnel (encrypted)
- Ad blocking works on all devices (home LAN + VPN)

**Split DNS:**
- Local domain (`pi.ajir.dev`) resolves to internal IPs
- External domains (`google.com`) resolve normally
- Example:
  ```
  nextcloud.pi.ajir.dev → 172.30.11.4 (internal)
  google.com → 8.8.8.8 (external)
  ```

### Verify MagicDNS

On a VPN client, check DNS settings:

**Linux/Mac:**
```bash
cat /etc/resolv.conf                    # Should list Pi-hole IP
# or
systemd-resolve --status                # Shows DNS per interface
```

**Windows:**
```powershell
Get-DnsClientServerAddress              # Check DNS servers
ipconfig /all                           # Detailed info
```

**Mobile:**
- Settings → Network → Wi-Fi/VPN → DNS settings
- Or Tailscale app → System DNS (if enabled)

### Disable MagicDNS (if needed)

On client device:

```bash
tailscale set --accept-dns=false
```

Then manually set Pi-hole as DNS if desired.

## VPN Access to Services

Once connected to Headscale, access services via internal IP or hostname:

```
From phone/laptop on VPN:

https://nextcloud.pi.ajir.dev          # Uses split DNS
https://immich.pi.ajir.dev
https://auth.pi.ajir.dev

Or by IP:
https://172.30.11.4                    # Nextcloud container IP
https://172.30.11.5                    # Immich container IP
```

**Why does this work?**
1. Headscale adds your device to the VPN mesh
2. Your device gets IP `100.64.x.x` (Tailscale namespace)
3. You can reach internal IPs that are also on Headscale
4. Split DNS resolves `pi.ajir.dev` to internal IPs over the tunnel

## User & Device Management

### Create User

```bash
docker compose exec headscale headscale users create <username>
```

### List Users

```bash
docker compose exec headscale headscale users list
```

### List Devices

```bash
docker compose exec headscale headscale nodes list
```

Example output:
```
ID  Hostname    IP Address       User      Tags  Last Seen      Last Updated
1   laptop      100.64.0.1       john      -     2 mins ago     5 mins ago
2   phone       100.64.0.2       john      -     online         1 min ago
3   pi-server   100.64.0.100     -         -     online         10 secs ago
```

### Approve/Register Node

```bash
docker compose exec headscale \
  headscale nodes register \
  --user <username> \
  --key <nodekey>
```

### Revoke Node

```bash
docker compose exec headscale \
  headscale nodes delete --identifier <node_id>
```

Device will disconnect from VPN.

### Add Tags

Tags group devices and allow fine-grained ACL rules:

```bash
docker compose exec headscale \
  headscale nodes tag --identifier <node_id> --tags tag:work,tag:personal
```

## Access Control (ACLs)

Advanced routing between devices. Edit in Headplane or via CLI.

**Example ACL rules:**

```yaml
# Allow all nodes in same user to reach each other
- action: accept
  src: ["<username>"]
  dst: ["<username>:*"]

# Allow laptop to reach pi
- action: accept
  src: ["tag:personal"]
  dst: ["tag:server:*"]

# Deny everything else
- action: deny
  src: ["*"]
  dst: ["*"]
```

Default policy: **Allow all** (permissive). Add rules to restrict.

## Tailscale Client Settings

### Accept DNS (important!)

Must be enabled for MagicDNS to work:

```bash
tailscale up --accept-dns=true
```

Or in Tailscale app:
- **Settings** → **DNS** → **Use Tailscale DNS**

### Exit Node (optional)

Route all internet traffic through Pi (makes Pi act as VPN server):

**On Pi:**
```bash
docker compose exec tailscale \
  tailscale up --advertise-exit-node
```

**On client:**
```bash
tailscale set --exit-node <pi-ip>
```

**Use case:** Use home network DNS + security from anywhere

### Split Tunneling (optional)

Only route specific traffic through VPN:

```bash
tailscale up --advertise-routes=<HOST_LAN_SUBNET>
```

Then on client:
```bash
tailscale set --accept-routes=true
```

Now can access the home LAN from VPN clients.

## Troubleshooting

### Device won't register

**Check Headscale logs:**
```bash
docker compose logs headscale | tail -30
```

Look for:
- `invalid request` — Malformed registration
- `user not found` — Username doesn't exist
- `device already exists` — Device already registered (revoke first)

**Verify registration URL format:**
```
https://headscale.<YOUR_DOMAIN>:443
```

Should use HTTPS and port 443.

### Can't reach services from VPN

**Check 1: Device IP**
```bash
tailscale ip                            # Should be 100.64.x.x
```

**Check 2: Routes advertised**
```bash
docker compose exec headscale headscale nodes list
```

Check "Routes" column — it should include your LAN subnet (for example `192.168.1.0/24`).

If empty, Headscale wasn't configured to advertise routes. Restart:
```bash
make restart
```

**Check 3: DNS resolution**
```bash
nslookup nextcloud.pi.ajir.dev          # Should resolve
ping 172.30.11.4                        # Direct IP test
```

If DNS fails, check Headscale MagicDNS is enabled and pushing DNS.

**Check 4: Firewall on Pi**
```bash
sudo iptables -L -n                     # Check input rules
```

If strict, may need to allow WireGuard port (typically 51820).

### Connection drops frequently

**Causes:**
- Network instability (WiFi)
- Headscale container restarting
- Port 443 issues

**Fixes:**
- Use wired connection if possible
- Check Headscale logs: `docker compose logs headscale`
- Ensure Pi can reach Cloudflare (for DDoS mitigation)

### Node appears offline but device is connected

Headscale tracks "last seen" based on heartbeat packets. If showing offline:
- Device likely still connected (check on device: `tailscale status`)
- Wait 5 minutes for heartbeat to update
- Or manually refresh in Headplane

## Security Notes

1. **Admin access** — Headplane requires 2FA (stricter policy)
2. **Auth keys** — Reusable keys allow registration without interactive approval; revoke if compromised
3. **Exit node** — Enables all traffic routing through Pi; monitor usage
4. **Split DNS** — Internal DNS is now exposed via VPN; no privacy improvement for home LAN devices (Pi-hole rules still apply)
5. **Updates** — Keep Tailscale client updated on all devices for security patches

## Advanced: Custom Headscale Config

To modify Headscale behavior, edit `config/headscale/config.yaml` and restart:

```bash
# Edit config
nano config/headscale/config.yaml

# Apply changes
make restart
```

Common settings:
- `server.listen_addr` — IP:port Headscale listens on
- `db.datasource` — Database location
- `derp` — DERP servers (relay for NAT traversal)

See [Headscale docs](https://headscale.net/) for all options.

## Next Steps

- Add more devices: Phone, tablet, laptop, other PCs
- Use exit node for home VPN access from anywhere
- Configure ACLs for stricter access control
- Monitor in Headplane dashboard
- Review [Security](SECURITY.md) for VPN + auth architecture
