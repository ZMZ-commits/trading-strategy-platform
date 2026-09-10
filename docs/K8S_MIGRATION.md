# Migrating to Kubernetes

Moving the nine services currently running under `deploy/docker-compose.yml` on
a Hetzner VM into a k3s cluster provisioned by Terraform, deployed by GitHub
Actions.

**This moves production.** `api.zemingzhang.com` and the two other environments
are served by the thing being replaced. The plan below is built around never
having a moment where the old system is gone and the new one is not yet proven.

---

## Before anything: back up the workspace volume

The `workspace` volume holds **eleven authored strategies, eight of which exist
nowhere else** — not in git, not on a laptop. It is mounted by five containers
and it is the single highest-value thing on that machine.

```bash
ssh <vm> 'docker run --rm -v workspace:/w -v /tmp:/out alpine \
  tar czf /out/workspace-backup.tgz -C /w .'
scp <vm>:/tmp/workspace-backup.tgz .
```

Do this first, verify the tarball opens, and keep it off the server. Every other
step in this document is reversible; losing that volume is not.

---

## What is being moved

| Service | Image | Notes |
|---|---|---|
| `redis` | `redis:7-alpine` | Tick fan-out and price cache |
| `pipeline` | `…/trading-strategy-data-pipeline:latest` | Holds the single Alpaca socket |
| `backend-prod` | `…/trading-strategy-backend:prod` | |
| `backend-stg` | `…/trading-strategy-backend:stg` | |
| `backend-dev` | `…/trading-strategy-backend:dev` | |
| `caddy` | `caddy:2` | TLS + routing for six hostnames |
| `code-server` | **built on the VM** | The one image with no registry copy |
| `sandbox` | `…/trading-strategy-sandbox:prod` | Runs user code |

### Volumes, and which are shared

| Volume | Written by | Read by | Risk |
|---|---|---|---|
| `workspace` | code-server | sandbox (ro), all 3 backends | **Five pods, one volume** |
| `coder_home` | code-server | — | Settings, extensions, Claude login |
| `dataset_{prod,stg,dev}` | one backend each | — | Straightforward |
| `/data/{prod,stg,dev}` | one backend each | — | Host bind mounts, not named volumes |
| `caddy_data`, `caddy_config` | caddy | — | Disappears with Caddy |

**`workspace` is the hard one.** Five pods mount it, and k3s's default
`local-path` storage is ReadWriteOnce — one node at a time. On a single-node
cluster that is fine because every pod lands on the same node. It stops being
fine the day a second node exists, and it will fail in a way that looks like a
scheduling problem rather than a storage one.

### Secrets

`ALPACA_API_KEY`, `ALPACA_SECRET_KEY`, `CODE_SERVER_PASSWORD` — today they live
in `deploy/.env` on the VM. They become Kubernetes Secrets, created once by hand
rather than committed anywhere.

---

## Phases

Each phase leaves a working system. Stop at the end of any of them.

### 1 — Cluster exists ✅ done

Four cx23 machines, none of them the one running production:

| Node | `tsp.role` | Private IP | Allocatable |
|---|---|---|---|
| `trading-platform-2` | `intake` | 10.0.1.10 | 1.9 GB |
| `trading-platform-3` | `data` | 10.0.1.11 | 2.4 GB |
| `trading-platform-4` | `stream` | 10.0.1.12 | 2.4 GB |
| `trading-platform-5` | `observability` | 10.0.1.13 | 2.4 GB |

One k3s server and three agents — **not** a quorum control plane. Three servers
running embedded etcd costs ~2 GB per node, which on 4 GB machines is half the
box spent on surviving the loss of a box. Revisit when the nodes are bigger.

`terraform apply` does all of it: attaches the private network, applies the
firewall, and installs k3s over SSH with the right label and kubelet
reservations. Adding a node is one line in `agent_roles`.

**The reservations matter more than they look.** k3s sets none by default, so a
full node lets the OOM killer choose its victim by score — which can be the
kubelet, taking the node `NotReady` and evicting everything on it. Reserved, the
worst case is a pod restarting.

**Budget honestly: ~1.5 GB per node.** These boxes report 3814 MB, not 4096, so
the cluster has **~9.1 GB allocatable in total** — not the ~14.5 GB a
back-of-envelope "4 × 4 GB minus overhead" suggests. Every placement decision
downstream is against 9.1 GB.

*Done when:* `kubectl get nodes -L tsp.role` shows four Ready nodes from your
laptop, and `kubectl describe node | grep -A6 Allocatable` shows capacity minus
the reservation rather than the full machine.

### 2 — Remote state

State moves off your laptop into Terraform Cloud or a Hetzner bucket, with
locking.

**Nothing about CI works until this is done.** GitHub Actions has no laptop; a
runner starting from empty state builds a second server.

*Done when:* two `terraform plan` runs from different machines agree.

### 3 — The stateless services

`redis`, `sandbox`, and the three backends as Deployments and Services. No
ingress yet, no data — reach them with `kubectl port-forward`.

*Done when:* a port-forwarded backend answers `/strategies`.

### 4 — Storage, and the data

PersistentVolumeClaims, then restore the workspace tarball into the new
`workspace` PVC. Copy `/data/{env}` and the dataset volumes across.

*Done when:* a port-forwarded backend lists **all eleven** strategies.

### 5 — Ingress and TLS

`ingress-nginx` plus `cert-manager` replacing Caddy. Six hostnames, Let's
Encrypt.

**Use the staging ACME issuer first.** Let's Encrypt rate-limits certificate
requests per domain per week, and a misconfigured issuer burns that quota on
certificates you throw away — leaving you unable to get a real one until the
window rolls.

*Done when:* the new cluster serves all six hostnames on a test DNS name.

### 6 — code-server gets a registry image

It is built on the VM today. **Kubernetes cannot build images**, so this must
move to CI: build `deploy/Dockerfile.codeserver`, push to
`ghcr.io/zmz-commits/trading-code-server`, pull like everything else.

*Done when:* the image exists in ghcr and the compose pulls it instead of
building it. Worth doing even if the migration stalls — it removes a build
toolchain from a production box.

### 7 — Parallel run

Both systems live. Point a spare hostname at the cluster and use it for a few
days. **Do not cut DNS yet.**

*Done when:* the cluster has served real traffic for long enough that you would
be surprised by a new failure.

### 8 — Cutover

Move DNS. Keep the VM running, untouched, for a week.

*Done when:* the old machine has been idle and unmissed for seven days.

### 9 — Remove the old

Delete `deploy/docker-compose.yml`, `redeploy.sh`, `bootstrap.sh`. Not before.

---

## CI/CD, once phase 2 is done

Two workflows per stack, because plan and apply carry opposite risk:

| Trigger | Job |
|---|---|
| PR touching `infrastructure/**` | `terraform plan`, posted as a PR comment. Safe, automatic. |
| Merge to `dev` / `staging` / `main` | `terraform apply`, gated on a GitHub Environment with a **required reviewer** |

The reviewer gate is the only protection against a bad merge, since
`prevent_destroy` and `delete_protection` were deliberately left off. It covers
CI only — a `terraform destroy` from a laptop never meets a reviewer.

---

## What this buys, honestly

At the end you have **the same system, running somewhere else**, plus:

- reproducible infrastructure — the server can be rebuilt from `terraform apply`
  rather than from a shell script someone hopes is still accurate
- a deploy that does not depend on SSH
- somewhere for Kafka, Strimzi and the rest of the streaming work to live

It does not make the platform faster, cheaper or more reliable on its own. A
single-node cluster has exactly the same failure domain as the single VM it
replaces. **Redundancy needs three nodes**, and that is a separate decision with
a separate bill.

Worth being clear about that before spending several days on it.
