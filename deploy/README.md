# Hetzner Cloud — Deployment Guide

Hosts all 3 backend environments (prod/stg/dev) + Caddy reverse proxy on a single Hetzner Cloud VM. ~$4/month (€3.79) for a CAX11: 2 ARM vCPU, 4 GB RAM, 40 GB SSD, 20 TB bandwidth.

This setup is **provider-agnostic** — the same docker-compose, Caddyfile, and GitHub Actions workflows work on any Ubuntu 22.04 VM (DigitalOcean, Linode, Oracle, etc.). Just change the SSH host secret.

## Architecture

```
GitHub push (main / staging / deployment)
    │
    ▼
GitHub Actions:
  1. Build Docker image (linux/arm64 — Hetzner CAX is ARM)
  2. Push to ghcr.io/zmz-commits/trading-strategy-backend:{prod|stg|dev}
  3. SSH to VM, docker compose pull + up -d
    │
    ▼
Hetzner CAX11 VM (Ubuntu 22.04, ARM):
  Caddy (auto-HTTPS) ─┬─ api.zemingzhang.com      → backend-prod:8000
                      ├─ api-stg.zemingzhang.com  → backend-stg:8000
                      └─ api-dev.zemingzhang.com  → backend-dev:8000
```

---

## Manual Setup (do this once)

### 1. Sign up for Hetzner Cloud

1. Go to <https://www.hetzner.com/cloud>
2. Click **Sign up** (top right)
3. Verify email + add payment method (~€10 minimum top-up; you'll burn through it slowly)
4. Once logged in, click **+ New project** → name it `trading-platform`

### 2. Add your SSH key

1. Project → **Security → SSH Keys → Add SSH key**
2. Paste your **public** key (`~/.ssh/id_rsa.pub` or similar). If you don't have one:
   ```powershell
   ssh-keygen -t ed25519 -f $HOME\.ssh\hetzner
   # leave passphrase empty
   # public key is at $HOME\.ssh\hetzner.pub
   Get-Content $HOME\.ssh\hetzner.pub
   ```
3. Name it `my-laptop` or similar → **Add SSH Key**

### 3. Create the CAX11 server

1. **Servers → Add Server**
2. **Location**: pick the closest to you (Ashburn VA for US East, Hillsboro OR for US West, Falkenstein/Nuremberg/Helsinki for Europe)
3. **Image**: Ubuntu 22.04
4. **Type**: **Shared vCPU → ARM (Ampere) → CAX11** (2 vCPU, 4 GB RAM, €3.79/mo)
5. **Networking**: leave defaults (Public IPv4 + IPv6 enabled)
6. **SSH keys**: select the key you added
7. **Volumes / Firewall / Backups**: skip for now
8. **Name**: `trading-platform`
9. Click **Create & Buy now**

VM is ready in ~30 seconds. Note the **public IP** shown on the server page.

### 4. SSH in and run the bootstrap script

```powershell
# From your laptop (Windows PowerShell)
ssh -i $HOME\.ssh\hetzner root@<vm-public-ip>

# Once on the VM, run:
curl -fsSL https://raw.githubusercontent.com/zmz-commits/trading-strategy-platform/main/deploy/bootstrap.sh | bash
```

The script:
- Installs Docker + docker-compose
- Creates a non-root `deploy` user (copies your SSH key over)
- Configures UFW firewall (SSH/80/443)
- Creates `/data/{prod,stg,dev}` directories
- Clones this repo to `/opt/trading-platform`

After it finishes, **log out** and SSH back in as the `deploy` user:
```powershell
ssh -i $HOME\.ssh\hetzner deploy@<vm-public-ip>
```

### 5. Create a GitHub Personal Access Token (PAT) for ghcr.io

1. GitHub → **Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate new token**
2. Scope: `read:packages` (minimum)
3. Copy the token

On the VM (as `deploy` user):
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
| `SSH_HOST` | VM public IP |
| `SSH_KEY` | Contents of your private SSH key (`$HOME\.ssh\hetzner`) |

### 8. Trigger the first deploy

```bash
cd F:\Projects\trading-strategy-backend
git commit --allow-empty -m "ci: trigger first Hetzner deploy"
git push origin main
git push origin staging
git push origin deployment
```

GitHub Actions will:
1. Build the Docker image (linux/arm64)
2. Push to ghcr.io
3. SSH into the VM
4. `docker compose pull && docker compose up -d` for the right service

Caddy will automatically request HTTPS certs from Let's Encrypt on the first request to each subdomain.

### 9. Update Cloudflare Pages frontend API URLs

In `trading-strategy-ui` repo → GitHub secrets:

| Secret | Value |
|---|---|
| `VITE_API_BASE_URL_PROD` | `https://api.zemingzhang.com` |
| `VITE_API_BASE_URL_STAGING` | `https://api-stg.zemingzhang.com` |
| `VITE_API_BASE_URL_DEV` | `https://api-dev.zemingzhang.com` |

Then push to redeploy each branch:
```bash
cd F:\Projects\trading-strategy-ui
git commit --allow-empty -m "ci: switch to Hetzner backend URLs"
git push origin main
git push origin staging
git push origin deployment
```

---

## Common Operations

```bash
# SSH to VM
ssh -i ~/.ssh/hetzner deploy@<vm-ip>

# View running containers
cd /opt/trading-platform/deploy
docker compose ps

# View logs
docker compose logs -f backend-prod
docker compose logs -f caddy

# Restart a service
docker compose restart backend-prod

# Pull latest image manually
docker compose pull backend-prod && docker compose up -d backend-prod

# Update Caddyfile and reload
nano /opt/trading-platform/deploy/Caddyfile
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

## Troubleshooting

- **Caddy can't get certs**: DNS must be "DNS only" in Cloudflare (gray cloud), not proxied
- **Container won't start**: Check `docker compose logs <service>`
- **High memory usage**: CAX11 has 4 GB RAM — should be plenty for 3 backends. Run `free -m` to check
- **Deploy fails on SSH**: Verify `SSH_HOST` and `SSH_KEY` secrets, ensure key has no passphrase
- **ghcr.io pull fails**: PAT must have `read:packages` scope, re-run `docker login ghcr.io`

## Monthly Cost

- **Hetzner CAX11**: €3.79/month (~$4)
- **Cloudflare Pages**: $0
- **Cloudflare DNS**: $0
- **Domain (zemingzhang.com)**: ~$10/year
- **GitHub Container Registry**: $0 (private packages free under 500 MB/month)
- **Total**: **~€3.79/month + $10/year domain**
