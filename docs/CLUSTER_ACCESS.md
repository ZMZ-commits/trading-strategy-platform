# Reaching the cluster without opening a port

Give GitHub Actions and your laptop network access to the four k3s nodes, so CI
can run `terraform apply` end to end — including the changes that install k3s —
and `kubectl` works from anywhere. Port 22 never opens.

## The problem this solves

```
firewall:  :22 and :6443 from 74.68.92.85/32    ← your house, and nothing else
```

Two consequences. A GitHub runner is a throwaway VM on an Azure address, so CI
cannot SSH to a node — which is why `terraform-apply.yml` currently refuses any
plan that would install k3s. And when your residential IP rotates, `kubectl`
stops working until you notice and edit `admin_cidrs`.

Both have the same cause: an inbound rule that must name every machine allowed
to connect.

## Why not just open the firewall for CI

Two ways were considered and rejected.

**Allow-listing GitHub's runner addresses.** Measured: `api.github.com/meta`
publishes **6,980 ranges** for `actions`. A Hetzner firewall holds 50 rules ×
100 source IPs. It does not fit — and the first entry, `4.148.0.0/16`, is 65,536
Azure addresses shared with every other Azure customer.

**Opening :22 for the duration of a run**, then closing it. This works, and it
has a correct state and a failure state: a hard-killed job leaves the rule
behind, and nobody notices a stale firewall rule. It also admits a recycled
Azure address that is not yours.

Tailscale has no failure state of that shape, because **no inbound rule is ever
written**.

## How it works

Nothing dials in. Both ends dial *out*, and outbound is always allowed:

```
  node:   tailscaled  ──── outbound :443 ────>  Tailscale coordination
  runner: tailscaled  ──── outbound :443 ────>  Tailscale coordination
                            (keys exchanged)
              └──── direct WireGuard tunnel ────┘
```

Traffic then reaches a node on its **private** interface (`10.0.1.x`), and
Hetzner cloud firewalls filter only the *public* interface. The firewall stays
fully armed and simply never sees this traffic.

**One node runs it, not four.** A subnet router advertises `10.0.1.0/24`, so
everything on the tailnet reaches all four nodes at the private addresses
Terraform already computes.

**Cost:** free (Personal: 3 users, 100 devices — you will use about four).
~50 MB on one node, which comes out of already-reserved slack and does not
change `allocatable`. About an hour.

---

## Which node runs it

`trading-platform-2` — the intake / control-plane node, `10.0.1.10`.

It has the least free memory of the four (983 MB used vs ~585 MB) but 2.8 GB
still available, so that is not the deciding factor. It is the node you reach for
first when something is wrong, and keeping management concerns on the management
node is easier to reason about than spreading them.

**The trade: it is a single point of access.** If that node is down, nothing on
the tailnet reaches the cluster — including the other three nodes, which are
fine. Adding a second subnet router later fixes it (Tailscale handles failover
between routers advertising the same range) for another 50 MB. Worth doing once
this is proven; not worth complicating the first setup.

---

## 1 — Create the tailnet

Sign up at <https://login.tailscale.com>. Use the Google account you already
sign in with, so there is one identity rather than another password.

Your tailnet gets a name like `tail1a2b3c.ts.net`. Note it — later steps use it.

No payment method required.

---

## 2 — OAuth client, not an auth key

An auth key lives **at most 90 days**, so pasting one in is scheduling a chore.
An **OAuth client secret does not expire** and can mint keys on demand, so
Terraform generates a fresh one on every apply and there is nothing to rotate.

The same client serves CI in step 6, so this is one credential doing two jobs.

Admin console -> **Settings -> OAuth clients -> Generate OAuth client**

| Field | Value |
|---|---|
| Description | `terraform` |
| Scopes | `auth_keys` -- **Write** |
| Tags | `tag:router`, `tag:ci` |

The secret is shown once. Into `terraform.tfvars`, which is gitignored:

```hcl
tailscale_oauth_client_id = "k123ABC..."
tailscale_oauth_secret    = "tskey-client-..."
```

### The expiry that actually matters

There are two, and the one people worry about is not the dangerous one.

| | Default | What happens |
|---|---|---|
| Auth key | 90 days | nothing -- an expired key does **not** de-authorize a node that already enrolled |
| **Node key** | **180 days** | **the router drops off the tailnet**, and the cluster becomes unreachable |

So after the first apply: admin console -> **Machines** -> the router -> **...** ->
**Disable key expiry**. Tailscale recommends this for trusted servers and subnet
routers, and it is the expiry that would take your access away one quiet night
six months from now.

---

## 3 — Let Terraform install it

Terraform already has SSH to the nodes, so it installs Tailscale the same way it
installed k3s. Nothing to do by hand on the machine.

```bash
cd infrastructure/terraform/hetzner
terraform plan -out=tfplan
```

**Read the plan before applying.** It must be exactly:

```
Plan: 1 to add, 0 to change, 0 to destroy.
  # terraform_data.tailscale_router[0] will be created
```

**If any `terraform_data.k3s_*` appears, stop.** That would reinstall k3s on
running nodes, and it means something upstream of the connection block changed.

```bash
terraform apply tfplan
```

The provisioner installs Tailscale, enables IP forwarding, and brings up the
subnet router advertising `10.0.1.0/24`.

**IP forwarding is why this is worth automating.** A subnet router forwards
packets between interfaces and Linux drops them silently unless told otherwise —
the symptom is "Tailscale connected, `10.0.1.11` times out", which reads as a
Tailscale problem and is not. Doing it by hand is one `sysctl` file to forget.

The route also self-approves, because the ACL in step 5 lists it under
`autoApprovers`. Without that you would approve it in the console every time the
node is rebuilt.

---

## 4 — Your laptop

```powershell
winget install --id tailscale.tailscale -e
```

Sign in with the same account. Then, from a new terminal:

```bash
ssh -i ~/.ssh/hetzner root@10.0.1.11
```

**That is the checkpoint.** A private address, from your laptop, over the
internet, with the firewall still admitting only your house. If this works,
everything downstream will.

If it hangs: check step 3, then `ip_forward` on the router.

Note this is a **split** VPN. Only `100.64.0.0/10` and `10.0.1.0/24` route
through Tailscale; your normal browsing is untouched, so you can leave it on
permanently.

---

## 5 — Lock down the ACL

**Paste this before step 3 if you want the route to self-approve on the first
apply** — otherwise approve it once in the console (Machines → the node → Edit
route settings) and this ACL keeps it approved from then on.

The default tailnet policy is allow-everything. Fine for one laptop, not fine
once a CI token exists — a compromised workflow should reach ports 22 and 6443
on four machines, not your whole tailnet.

Admin console → **Access Controls**:

```json
{
  "tagOwners": {
    "tag:ci": ["autogroup:admin"]
  },
  "autoApprovers": {
    "routes": {
      "10.0.1.0/24": ["autogroup:admin"]
    }
  },
  "acls": [
    {
      "action": "accept",
      "src":    ["autogroup:member"],
      "dst":    ["*:*"]
    },
    {
      "action": "accept",
      "src":    ["tag:ci"],
      "dst":    ["10.0.1.0/24:22,6443"]
    }
  ]
}
```

`autoApprovers` means a replacement subnet router is approved automatically —
otherwise rebuilding that node silently loses cluster access until someone
remembers step 3.

---

## 6 — OAuth client for CI

An OAuth client rather than a plain auth key, because it issues **ephemeral**
nodes that are removed when the job ends. A static key accumulates one dead —
but still authorized — peer per workflow run, forever.

Admin console → **Settings → OAuth clients → Generate OAuth client**

| Field | Value |
|---|---|
| Description | `github-actions` |
| Scopes | `auth_keys` — **Write** |
| Tags | `tag:ci` |

You get a client ID and secret. **The secret is shown once.** Straight into
GitHub, not through a terminal:

```powershell
gh secret set TS_OAUTH_CLIENT_ID --repo ZMZ-commits/trading-strategy-platform
```

```powershell
gh secret set TS_OAUTH_SECRET --repo ZMZ-commits/trading-strategy-platform
```

---

## 7 — The Terraform change

Two lines, and I will make them — but here is what changes and why it needs care.

The `connection` block currently targets each node's public IP. Over the tailnet
it should target the private address Terraform already computes:

```hcl
host = var.connect_via == "tailnet"
  ? local.agent_private_ips[each.key]                 # 10.0.1.11
  : data.hcloud_server.agent[each.key].ipv4_address
```

**The care:** the connection block feeds `triggers_replace`. Change it carelessly
and the plan reinstalls k3s on all four running nodes. The change must be
verified as a no-op against the live cluster before it is applied — `terraform
plan` reporting `0 to change` is the only acceptable result.

---

## 8 — The workflow change

```yaml
      - name: Join the tailnet
        uses: tailscale/github-action@v3
        with:
          oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
          tags: tag:ci
          args: --accept-routes
```

**`--accept-routes` is not optional.** Without it the runner joins the tailnet
and ignores the advertised subnet, so `10.0.1.11` is unreachable — the same
symptom as steps 2 and 3, from a third cause.

Then `TF_VAR_connect_via: tailnet` in the job env, and the `Does this plan need
SSH` guard comes out. It exists only because CI could not reach the nodes; once
it can, it blocks work it no longer needs to block.

---

## 9 — Close port 22, last

Only after a CI run has actually installed something over the tailnet.

```hcl
admin_cidrs = []
```

`terraform plan` first, and confirm the only change is the firewall rules losing
their source — nothing touching `terraform_data`.

**Know the way back before you do this.** Hetzner's console has a per-server web
terminal (Server → Console) that works regardless of the firewall. If the subnet
router and the firewall are both broken at once, that is the only door left.

**Do 22 and 6443 separately**, not in one apply. Closing both and discovering the
tailnet is misconfigured means losing SSH and `kubectl` in the same minute, with
no way to tell which change caused it.

---

## What you end up with

| Before | After |
|---|---|
| `:22` open to `74.68.92.85/32` | `:22` open to nobody |
| Home IP rotates → `kubectl` hangs | Home IP is irrelevant |
| CI refuses plans that install k3s | CI runs them |
| 6,980 Azure ranges would be needed | none |

## What it costs

**A single point of access** until a second subnet router exists. If
`trading-platform-2` is down, the tailnet reaches nothing — including three
healthy nodes.

**A third party in the access path.** Tailscale's coordination server
distributes keys. Traffic is end-to-end encrypted and does not flow through
them, but they control who can join. Same class of dependency as Cloudflare,
smaller surface.

**One more service to keep patched**, on one machine.
