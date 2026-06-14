# Trading Strategy Platform

## 🟢 START HERE (AI session bootstrap)

**Before doing any work, every session:**
1. Read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — the overall system, diagram, deploy topology, and cross-repo state.
2. Read [`docs/AI_ONBOARDING.md`](docs/AI_ONBOARDING.md) — the read-order, the "find the newest branch" one-liner, and the doc-maintenance routine.
3. For any repo you'll touch, read its `AI_CONTEXT.md` (backend / engine / data-pipeline / ui each have one).
4. **Recompute the newest branch per repo from live git** — do not assume `main` is latest; `staging`/`dev` may be ahead (see `AI_ONBOARDING.md` §2).
5. When you finish work that changed code, **update the affected `AI_CONTEXT.md` and `docs/` per the maintenance routine** so the next session starts current.

## Branching Strategy

This repository follows a **3-tier** branching model with three permanent long-lived branches.

```
[feature/*]  ──>  [dev]  ──>  [staging]  ──>  [main]
```

### Branches

| Branch | Purpose | Base | Protected |
|--------|---------|------|-----------|
| `main` | Production. Never push directly. | — | Yes — cannot be deleted or pushed to |
| `staging` | Pre-production. Never push directly. | `main` | Yes — cannot be deleted or pushed to |
| `dev` | Development integration. Never push directly. | `staging` | Yes — cannot be deleted or pushed to |
| `feature/*` | All dev work. Short-lived. Deleted after merge. | `dev` | No |

### Rules

1. **`main` is production** — only `staging` can PR into it. No direct pushes ever.
2. **`staging` is pre-production** — only `dev` can PR into it. No direct pushes ever.
3. **`dev` is the dev integration branch** — only `feature/*` branches can PR into it. No direct pushes ever.
4. **Feature branches** — always branched from `dev`. Named `feature/<short-description>`. PR back into `dev` when done, then **deleted**.
5. **`main`, `staging`, and `dev` are permanent** — they must always exist and must never be deleted or force-pushed.

### Workflow

```
main (prod)
  └── staging (pre-prod)     ← branched from main
        └── dev (dev)        ← branched from staging
              ├── feature/my-feature  ← branched from dev
              ├── feature/another     ← branched from dev
              └── ...
```

**Merge flow:**
```
feature/* → dev → staging → main
```

### Deployed environments

`dev`, `staging`, and `main` are the **long-lived branches deployed to the cloud**
— each push to one auto-deploys its environment via GitHub Actions. `feature/*`
branches are **never deployed**; they are tested **locally via Docker** before the
PR into `dev`.

| Branch | Environment | Deploy target | UI | API |
|--------|-------------|---------------|-----|-----|
| `feature/*` | Local only | **Docker on dev machine** (`docker compose up`) — no cloud deploy | `localhost:5173` | `localhost:8000` |
| `dev` | Dev (cloud) | Auto-deploy on push | `trading-dev.zemingzhang.com` | `api-dev.zemingzhang.com` |
| `staging` | Staging (cloud) | Auto-deploy on push | `trading-stg.zemingzhang.com` | `api-stg.zemingzhang.com` |
| `main` | Production (cloud) | Auto-deploy on push | `trading.zemingzhang.com` | `api.zemingzhang.com` |

**Local Docker test (feature branches):** from the platform repo, `docker compose
up` (root `docker-compose.yml`) builds backend + UI from the sibling working trees
so you can validate a feature before opening the PR into `dev`. CI deploy
workflows trigger **only** on `dev`/`staging`/`main`, so feature pushes never
touch the cloud.

### Quick-start for a new feature

```bash
# 1. Make sure your local dev branch is up to date
git checkout dev
git pull origin dev

# 2. Branch off dev
git checkout -b feature/my-feature

# 3. Do your work, then test it LOCALLY via Docker (no cloud deploy for features)
docker compose up --build       # backend → :8000, UI → :5173

# 4. Push the feature branch
git push -u origin feature/my-feature

# 5. Open a PR: feature/my-feature → dev   (merging here auto-deploys the dev cloud env)
# 6. After dev verification, open a PR: dev → staging
# 7. After sign-off, open a PR: staging → main  (production)
# 8. Delete the feature branch after merge
```

### For AI agents (Claude Code)

- **Never push directly to `main`, `staging`, or `dev`.**
- **Never delete `main`, `staging`, or `dev`.**
- All development work goes on a `feature/*` branch cut from `dev`.
- PRs always flow: `feature/*` → `dev` → `staging` → `main`.
- Feature branches are deleted after merge.
- When creating a new repository under this project, apply the same structure: `main`, `staging`, `dev`, `feature/*`.
