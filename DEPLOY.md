# Deploying to Render

## One-time setup

### 1. Deploy the backend

1. Go to [render.com](https://render.com) → **New** → **Web Service**
2. Connect the `zmz-commits/trading-strategy-backend` repo
3. Select branch: `claude/serene-euler-Gq1ma`
4. Runtime: **Docker**
5. Set environment variables:
   | Key | Value |
   |-----|-------|
   | `CORS_ORIGINS` | *(leave blank for now — fill in after frontend deploys)* |
   | `STORE_ROOT` | `/tmp/trading-strategies` |
6. Click **Deploy**. Note your backend URL: `https://trading-strategy-backend.onrender.com`

> **Persistence note:** The free tier uses ephemeral storage — data resets on redeploy.
> Upgrade to Starter ($7/mo) and add a **Disk** (mount at `/data`, set `STORE_ROOT=/data/trading-strategies`) for persistence.

---

### 2. Deploy the frontend

1. Go to Render → **New** → **Static Site**
2. Connect the `zmz-commits/trading-strategy-ui` repo
3. Select branch: `claude/serene-euler-Gq1ma`
4. Build command: `npm install && npm run build`
5. Publish directory: `dist`
6. Set environment variables:
   | Key | Value |
   |-----|-------|
   | `VITE_API_BASE_URL` | `https://trading-strategy-backend.onrender.com` |
7. Click **Deploy**. Note your frontend URL: `https://trading-strategy-ui.onrender.com`

---

### 3. Wire up CORS

1. Go back to your **backend** service on Render
2. Set `CORS_ORIGINS` = `https://trading-strategy-ui.onrender.com`
3. Click **Save** → backend redeploys automatically

---

## Local Docker testing

```bash
# Clone all repos into the same parent directory
git clone https://github.com/zmz-commits/trading-strategy-backend
git clone https://github.com/zmz-commits/trading-strategy-ui
git clone https://github.com/zmz-commits/trading-strategy-platform

# Checkout the feature branch in each
for repo in trading-strategy-backend trading-strategy-ui trading-strategy-platform; do
  cd $repo && git checkout claude/serene-euler-Gq1ma && cd ..
done

# Build and run
cd trading-strategy-platform
docker-compose up --build

# Open http://localhost:5173
```

## Free tier limits (Render)

| Resource | Free tier |
|----------|-----------|
| Backend (web service) | 512 MB RAM, spins down after 15 min inactivity |
| Frontend (static site) | Unlimited, CDN-served |
| Storage | Ephemeral (upgrade for persistence) |
| Custom domains | Supported on all tiers |

For 50–100 active users, upgrade the backend to **Starter ($7/mo)** to avoid spin-down and add persistent disk.
