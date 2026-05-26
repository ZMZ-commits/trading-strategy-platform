# Trading Strategy Platform

Monorepo hub for the trading strategy application. Source code lives in four sub-repos, each wired in as a git submodule under `packages/`.

## Repository Map

| Package | Repo | Description |
|---------|------|-------------|
| `packages/trading-strategy-ui` | [trading-strategy-ui](https://github.com/zmz-commits/trading-strategy-ui) | React + Vite dashboard |
| `packages/trading-strategy-backend` | [trading-strategy-backend](https://github.com/zmz-commits/trading-strategy-backend) | FastAPI hub (stocks, strategies, execution) |
| `packages/trading-strategy-engine` | [trading-strategy-engine](https://github.com/zmz-commits/trading-strategy-engine) | Python strategy runner (imported by backend) |
| `packages/trading-strategy-data-pipeline` | [trading-strategy-data-pipeline](https://github.com/zmz-commits/trading-strategy-data-pipeline) | Data ingestion pipeline |

## First-Time Setup

```bash
# Clone the platform with all submodules in one shot
git clone --recurse-submodules -b claude/serene-euler-Gq1ma \
  https://github.com/zmz-commits/trading-strategy-platform.git

# OR — if you already cloned without --recurse-submodules:
bash scripts/setup-submodules.sh
```

## Keeping Submodules Up to Date

```bash
# Pull the latest from every sub-repo
bash scripts/update-submodules.sh
```

## Branching Model

All repos follow the same 4-tier model:

```
feature/* → deployment → staging → main
```

Active development branch: `claude/serene-euler-Gq1ma`

## Infrastructure

Terraform configs for AWS (EC2 + ECR + S3 + CloudFront) live in `infrastructure/terraform/`. See `DEPLOY_AWS.md` for the full deploy guide.

## Local Dev (all services)

```bash
docker compose up
# frontend → http://localhost:5173
# backend  → http://localhost:8000
```
