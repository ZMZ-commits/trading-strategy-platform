# Trading Strategy Platform

Infrastructure and deployment hub for the trading strategy application. The
four sub-repos are cloned as siblings of this one, not vendored into it --
`docker-compose.yml` builds from `../trading-strategy-backend` and
`../trading-strategy-ui`.

## Live environments

| Environment | App | API | Branch |
|---|---|---|---|
| **Production** | https://trading.zemingzhang.com | https://api.zemingzhang.com | `main` |
| Staging | https://trading-stg.zemingzhang.com | https://api-stg.zemingzhang.com | `staging` |
| Dev | https://trading-dev.zemingzhang.com | https://api-dev.zemingzhang.com | `dev` |

Each long-lived branch auto-deploys its own environment on push. `feature/*`
branches are never deployed — test those locally with `docker compose up`.

## Design doc

**[Trading Platform Blueprint](https://trading.zemingzhang.com/design-doc)** — the
architecture, the design principles, and an honest account of what is built
against what is still on paper.

It covers the machine-by-machine system design at service granularity, tenancy,
the data pipeline and watermark model, the observability stack, capacity and
cost. Every component carries a badge saying whether it exists today, needs
changing, or has not been started.

The same page is reachable from inside the app: the book icon in the left rail,
below VS Code. It is served by the front end itself, so it deploys and versions
with the UI rather than living somewhere separate.


### Repositories

- [trading-strategy-platform](https://github.com/ZMZ-commits/trading-strategy-platform) — infrastructure, deployment, cross-repo docs
- [trading-strategy-ui](https://github.com/ZMZ-commits/trading-strategy-ui) — React front end
- [trading-strategy-backend](https://github.com/ZMZ-commits/trading-strategy-backend) — FastAPI service
- [trading-strategy-engine](https://github.com/ZMZ-commits/trading-strategy-engine) — strategy SDK and sandbox worker
- [trading-strategy-data-pipeline](https://github.com/ZMZ-commits/trading-strategy-data-pipeline) — market data ingestion

## Repository Map

| Package | Repo | Description |
|---------|------|-------------|
| [trading-strategy-ui](../trading-strategy-ui) | [trading-strategy-ui](https://github.com/zmz-commits/trading-strategy-ui) | React + Vite dashboard |
| [trading-strategy-backend](../trading-strategy-backend) | [trading-strategy-backend](https://github.com/zmz-commits/trading-strategy-backend) | FastAPI hub (stocks, strategies, execution) |
| [trading-strategy-engine](../trading-strategy-engine) | [trading-strategy-engine](https://github.com/zmz-commits/trading-strategy-engine) | Python strategy runner (imported by backend) |
| [trading-strategy-data-pipeline](../trading-strategy-data-pipeline) | [trading-strategy-data-pipeline](https://github.com/zmz-commits/trading-strategy-data-pipeline) | Data ingestion pipeline |

## First-Time Setup

The five repositories are peers, cloned side by side. This one holds the
infrastructure and the compose files; it does not vendor the others.

```bash
mkdir Projects && cd Projects
for r in platform ui backend engine data-pipeline; do
  git clone https://github.com/zmz-commits/trading-strategy-$r.git 2>/dev/null     || git clone https://github.com/zmz-commits/trading-strategy-platform.git
done
```

`docker-compose.yml` here builds from `../trading-strategy-backend` and
`../trading-strategy-ui`, so the sibling layout is what makes a local run work:

```bash
cd trading-strategy-platform
docker compose up --build     # backend :8000, UI :5173
```

> Submodules under `packages/` used to mirror the sub-repos. Nothing built from
> them — the compose file always used the siblings — and their branch pin had
> gone stale, so they were removed rather than left as a second, wrong copy.

## Branching Model

All repos follow the same 4-tier model:

```
feature/* → deployment → staging → main
```

Active development branch: `dev`

## Infrastructure

Terraform lives in `infrastructure/terraform/`, split into two stacks that are
applied in order:

- `hetzner/` — provisions the server, network and firewall, and installs k3s
- `k8s/` — installs Strimzi and Kafka into the cluster the first stack built

They are separate because the Helm provider needs a kubeconfig that does not
exist until the cluster does. One combined apply fails at plan time.

## Local Dev (all services)

```bash
docker compose up
# frontend → http://localhost:5173
# backend  → http://localhost:8000
```
