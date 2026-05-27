# Oracle Cloud Always Free — Deployment Guide

Hosts all 3 backend environments (prod/stg/dev) + Caddy reverse proxy on a single Oracle Cloud VM. Free forever, no card charges as long as you stay within Always Free resources.

## Architecture

```
GitHub push (main / staging / deployment)
    │
    ▼
GitHub Actions:
  1. Build Docker image (linux/arm64)
  2. Push to ghcr.io/zmz-commits/trading-strategy-backend:{prod|stg|dev}
  3. SSH to Oracle VM, docker compose pull + up -d
    │
    ▼
Oracle Cloud VM (Ubuntu 22.04, ARM Ampere A1):
  Caddy (auto-HTTPS) ─┬─ api.zemingzhang.com      → backend-prod:8000
                      ├─ api-stg.zemingzhang.com  → backend-stg:8000
                      └─ api-dev.zemingzhang.com  → backend-dev:8000
```

---

## Manual Setup (do this once)

### 1. Sign up for Oracle Cloud Always Free

1. Go to <https://www.oracle.com/cloud/free/>
2. Click **Start for free**
3. Credit card required for verification — **will not be charged** if you stay within Always Free
4. Pick a **home region** — choose one with ARM availability (try **us-ashburn-1**, **us-phoenix-1**, or **ca-toronto-1**)
5. Wait for account provisioning (~30 minutes)

### 2. Create an ARM VM (Ampere A1)

1. Dashboard → **Compute → Instances → Create Instance**
2. **Name**: `trading-platform`
3. **Image**: Canonical Ubuntu 22.04
4. **Shape**: Click *Change shape* → **Ampere → VM.Standard.A1.Flex**
   - **OCPU**: 4 (max free)
   - **Memory**: 24 GB (max free)
5. **Networking**: leave defaults, **Assign a public IPv4 address: Yes**
6. **SSH keys**: Generate a new key pair, **download both private + public keys** — you'll need them
7. Click **Create**

⚠️ **If you get "Out of capacity"**: ARM is in high demand. Try a different region or retry every few hours. If you can't get ARM, fall back to 2× AMD VM.Standard.E2.1.Micro instances (1 CPU, 1GB RAM each) — you'll need to drop one environment.

### 3. Open ports 80 and 443

1. **Instance details → Virtual Cloud Network → Security Lists → Default Security List**
2. **Add Ingress Rules**:
   - Source CIDR: `0.0.0.0/0`, IP Protocol: TCP, Destination Port: `80`
   - Source CIDR: `0.0.0.0/0`, IP Protocol: TCP, Destination Port: `443`

### 4. Run the bootstrap script on the VM

SSH in (use the private key you downloaded):
```bash
ssh -i ~/Downloads/ssh-key.key ubuntu@<your-vm-public-ip>
```

Run:
```bash
curl -fsSL https://raw.githubusercontent.com/zmz-commits/trading-strategy-platform/main/oracle/bootstrap.sh | bash
```

Log out and back in (for docker group to take effect).

### 5. Create a GitHub Personal Access Token (PAT) for ghcr.io

1. GitHub → **Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate new token**
2. Scopes: `read:packages` (minimum)
3. Copy the token

On the VM, log Docker into ghcr.io:
```bash
echo <YOUR_PAT> | docker login ghcr.io -u <YOUR_GITHUB_USERNAME> --password-stdin
```

### 6. Configure DNS in Cloudflare

In Cloudflare dashboard → `zemingzhang.com` → DNS:

| Type | Name | Content | Proxy |
|---|---|---|---|
| A | api | `<vm-public-ip>` | DNS only (gray cloud) |
| A | api-stg | `<vm-public-ip>` | DNS only |
| A | api-dev | `<vm-public-ip>` | DNS only |

⚠️ **Must be "DNS only" (gray cloud)** for Caddy to get Let's Encrypt certificates. You can turn on proxy (orange cloud) later after certs are issued.

### 7. Add GitHub Secrets

In `trading-strategy-backend` repo → **Settings → Secrets → Actions**:

| Secret | Value |
|---|---|
| `ORACLE_HOST` | VM public IP |
| `ORACLE_SSH_KEY` | Contents of the private SSH key file you downloaded |

### 8. Trigger the first deploy

```bash
cd F:\Projects\trading-strategy-backend
git commit --allow-empty -m "ci: trigger first Oracle deploy"
git push origin main
git push origin staging
git push origin deployment
```

GitHub Actions will build, push to ghcr.io, SSH in, and start the containers. Caddy will automatically request HTTPS certs from Let's Encrypt on first request.

### 9. Update Cloudflare Pages frontend API URLs

In `trading-strategy-ui` repo → GitHub secrets:

| Secret | Old (Fly.io) | New (Oracle) |
|---|---|---|
| `VITE_API_BASE_URL_PROD` | `https://trading-strategy-backend-prod.fly.dev` | `https://api.zemingzhang.com` |
| `VITE_API_BASE_URL_STAGING` | `https://trading-strategy-backend-stg.fly.dev` | `https://api-stg.zemingzhang.com` |
| `VITE_API_BASE_URL_DEV` | `https://trading-strategy-backend-dev.fly.dev` | `https://api-dev.zemingzhang.com` |

---

## Common Operations

```bash
# SSH to VM
ssh -i ~/.ssh/oracle ubuntu@<vm-ip>

# View running containers
docker compose ps

# View logs
docker compose logs -f backend-prod
docker compose logs -f caddy

# Restart a service
docker compose restart backend-prod

# Pull latest image manually
docker compose pull backend-prod && docker compose up -d backend-prod

# Update Caddyfile and reload
sudo nano /opt/trading-platform/oracle/Caddyfile
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

## Troubleshooting

- **Caddy can't get certs**: DNS must be "DNS only" in Cloudflare (gray cloud), not proxied
- **Container won't start**: Check `docker compose logs <service>`
- **Out of memory**: ARM VM has 24GB — should be plenty. Run `free -m` to check
- **Deploy fails on SSH**: Verify `ORACLE_HOST` and `ORACLE_SSH_KEY` secrets, ensure key has no passphrase
