# Reaching the cluster without opening a port

SSH to the four k3s nodes through Cloudflare Tunnel, so that CI can apply
Terraform and `kubectl` works from anywhere — without port 22 being open to the
internet, and without `admin_cidrs` needing to know your home address.

**What this replaces.** Today the firewall admits `74.68.92.85/32` and nothing
else. That breaks whenever your residential IP rotates, and it is why a GitHub
runner cannot install k3s on a new node. Both problems have the same cause: an
inbound rule that has to name every machine allowed to connect.

**How a tunnel avoids it.** `cloudflared` runs on each node and dials *out* to
Cloudflare. Nothing ever dials in. Port 22 can be closed to the entire internet —
your own address included — and connections still work, because they arrive
through a connection the node itself opened.

```
node: cloudflared  ──outbound──>  Cloudflare edge
                                        ▲
your laptop / CI runner  ───────────────┘
        authenticating with an Access policy
```

**Cost:** free. Zero Trust's free plan covers 50 *users* — human identities that
authenticate, held until removed. CI uses a service token, not a human identity.
At one person and one pipeline this limit is not a constraint you will approach.

**Effort:** two to three hours, and one non-obvious Terraform change (step 7).

---

## Before you start

You need:

- A domain on Cloudflare — `zemingzhang.com` already is.
- Root SSH to the four nodes, which you have today. **Keep that working until
  the very last step.** Do not close port 22 until the tunnel is proven.

Node public IPs, for reference:

| Node | Role | IP |
|---|---|---|
| `trading-platform-2` | intake | 135.181.99.122 |
| `trading-platform-3` | data | 2.29.30.231 |
| `trading-platform-4` | stream | 62.238.111.151 |
| `trading-platform-5` | observability | 89.167.107.183 |

---

## 1 — Turn on Zero Trust

Cloudflare dashboard → **Zero Trust** in the sidebar.

First time through it asks you to pick a team name. This becomes
`<team>.cloudflareaccess.com` and appears in URLs later — pick something you are
happy to keep, e.g. `zemingzhang`.

Then choose the **Free** plan. It asks for a payment method to complete signup
and does not charge within the free tier.

---

## 2 — Create one tunnel per node

**One tunnel per node, not one tunnel for all four.** A tunnel is a credential
for a specific `cloudflared` process. Sharing one across four machines means any
compromised node can impersonate the others, and revoking it locks out all four.

For each of the four nodes:

**Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared**

Name it after the node: `tsp-intake`, `tsp-data`, `tsp-stream`,
`tsp-observability`.

Cloudflare then shows an install command containing a long token. **Copy the
whole command** — you will paste it on the node in the next step. Do not put the
token in a chat window or a shell script; it grants the right to serve that
tunnel.

---

## 3 — Install `cloudflared` on each node

SSH in the normal way, one node at a time:

```bash
ssh -i ~/.ssh/hetzner root@135.181.99.122
```

Add Cloudflare's apt repository rather than downloading a `.deb` directly, so the
package gets security updates like everything else:

```bash
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
  | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
```

```bash
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
  | tee /etc/apt/sources.list.d/cloudflared.list
```

```bash
apt-get update && apt-get install -y cloudflared
```

Now paste the install command Cloudflare gave you for **this** node. It looks
like:

```
cloudflared service install eyJhIjoiXXXXX...
```

That registers it as a systemd service. Check it:

```bash
systemctl status cloudflared --no-pager
```

You want `active (running)`. Back in the dashboard the tunnel should flip to
**HEALTHY** within about thirty seconds.

**Memory check:**

```bash
systemctl show cloudflared -p MemoryCurrent
```

Expect roughly 30-60 MB. If it is far more, understand why before installing it
on the other three.

**This does not reduce pod capacity.** `cloudflared` is a systemd service outside
Kubernetes, and `allocatable` is arithmetic rather than measurement -- capacity
minus the reservation flags, fixed regardless of what else runs. The node
currently uses ~600 MB of the 1324 MB reserved for the kubelet and the OS, so
cloudflared takes 50 MB of roughly 700 MB of existing slack. Allocatable stays at
2490 MB either way.

Repeat for all four nodes, each with its own tunnel token.

---

## 4 — Route a hostname to SSH on each node

Back in the dashboard, for each tunnel:

**Tunnel → Configure → Public Hostname → Add a public hostname**

| Field | Value |
|---|---|
| Subdomain | `intake-ssh` (then `data-ssh`, `stream-ssh`, `obs-ssh`) |
| Domain | `zemingzhang.com` |
| Type | **SSH** |
| URL | `localhost:22` |

`localhost:22` is from the node's point of view — `cloudflared` is already on the
machine, so it connects to its own sshd. Nothing about this is reachable from
outside except through the tunnel.

Cloudflare creates the DNS record for you. **That record is proxied and resolves
to Cloudflare, not to your server** — the node's real address never appears in
DNS.

---

## 5 — Protect it with an Access policy

Without this, anyone who guesses the hostname reaches your SSH port. The tunnel
moves where the door is; Access is the lock.

**Zero Trust → Access → Applications → Add an application → Self-hosted**

| Field | Value |
|---|---|
| Application name | `tsp-cluster-ssh` |
| Session duration | 24 hours |
| Subdomain | `*-ssh` (wildcard, covers all four) |
| Domain | `zemingzhang.com` |

Then add **two** policies:

**Policy 1 — you**

| | |
|---|---|
| Name | `operator` |
| Action | Allow |
| Include | Emails → `zhang.zeming.zz@gmail.com` |

**Policy 2 — CI**

| | |
|---|---|
| Name | `ci` |
| Action | **Service Auth** (not Allow) |
| Include | Service Token → the one created in the next step |

**`Service Auth` rather than `Allow` matters.** `Allow` expects a browser login;
a headless runner has no browser and the request would be redirected to a login
page it cannot complete.

---

## 6 — Create the CI service token

**Zero Trust → Access → Service Auth → Service Tokens → Create Service Token**

Name it `github-actions-terraform`. Duration: 1 year.

You get a **Client ID** and a **Client Secret**. **The secret is shown once.**

Put them straight into GitHub — never through a terminal or a file:

```powershell
gh secret set CF_ACCESS_CLIENT_ID --repo ZMZ-commits/trading-strategy-platform
```

```powershell
gh secret set CF_ACCESS_CLIENT_SECRET --repo ZMZ-commits/trading-strategy-platform
```

Then go back to Policy 2 above and select this token in the Include rule.

---

## 7 — Test from your laptop, before changing anything

Install `cloudflared` locally:

```powershell
winget install --id Cloudflare.cloudflared -e
```

Open a new terminal, then add this to `C:\Users\zemin\.ssh\config`:

```
Host *-ssh.zemingzhang.com
  ProxyCommand cloudflared access ssh --hostname %h
  User root
  IdentityFile ~/.ssh/hetzner
```

And connect:

```bash
ssh intake-ssh.zemingzhang.com
```

A browser opens for the Access login the first time. After that the session is
cached for 24 hours.

**Stop here if this does not work.** Everything downstream assumes it does, and
you still have port 22 open as a fallback — which is exactly why the firewall
change is the last step and not the first.

---

## 8 — The Terraform change

This is the part that is not obvious from Cloudflare's docs.

**Terraform's `connection` block has no `ProxyCommand`.** It supports
`bastion_host`, which is a different thing. So Terraform cannot dial a tunnel
directly.

The way through: `cloudflared access tcp` opens a plain local TCP port that
forwards through the tunnel, and Terraform connects to *that*.

```bash
cloudflared access tcp --hostname intake-ssh.zemingzhang.com --url 127.0.0.1:2210
```

Terraform then connects to `127.0.0.1:2210` and reaches the node's sshd.

Which means `main.tf` needs the connection host and port to be configurable
rather than hardcoded to the public IP. Roughly:

```hcl
variable "connect_via" {
  description = "public = SSH straight to the node. tunnel = via local cloudflared forwards."
  type        = string
  default     = "public"
}

locals {
  agent_ssh = {
    for name, a in var.agent_roles : name => var.connect_via == "tunnel"
      ? { host = "127.0.0.1", port = 2210 + a.host }
      : { host = data.hcloud_server.agent[name].ipv4_address, port = 22 }
  }
}
```

and each `connection` block using `local.agent_ssh[each.key].host` / `.port`.

**Do not do this by hand while reading a guide.** Tell me when steps 1–7 work and
I will make the change properly, with the plan verified to be a no-op against the
running cluster first — the connection block feeds `triggers_replace`, and
getting it wrong plans a k3s reinstall on all four nodes.

---

## 9 — The workflow change

In `terraform-apply.yml`, before the Terraform steps:

```yaml
- name: Open tunnel forwards
  env:
    TUNNEL_SERVICE_TOKEN_ID: ${{ secrets.CF_ACCESS_CLIENT_ID }}
    TUNNEL_SERVICE_TOKEN_SECRET: ${{ secrets.CF_ACCESS_CLIENT_SECRET }}
  run: |
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
      | sudo tee /etc/apt/sources.list.d/cloudflared.list
    sudo apt-get update -qq && sudo apt-get install -y cloudflared

    for pair in "intake-ssh:2210" "data-ssh:2211" "stream-ssh:2212" "obs-ssh:2213"; do
      host="${pair%%:*}"; port="${pair##*:}"
      cloudflared access tcp --hostname "$host.zemingzhang.com" --url "127.0.0.1:$port" &
    done

    # Wait for the forwards rather than sleeping and hoping.
    for port in 2210 2211 2212 2213; do
      for i in $(seq 30); do
        if timeout 1 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/$port" 2>/dev/null; then break; fi
        [ "$i" = 30 ] && { echo "::error::tunnel forward on $port never opened"; exit 1; }
        sleep 1
      done
    done
```

and `TF_VAR_connect_via: tunnel` in the job env.

The `Refuse changes that need SSH` guard then comes **out** — that guard exists
only because CI could not reach the nodes. Once it can, it is blocking work it no
longer needs to block.

---

## 10 — Close port 22, last

Only after steps 1–9 are working end to end.

In `infrastructure/terraform/hetzner/terraform.tfvars`:

```hcl
admin_cidrs = []
```

Then `terraform plan` — confirm the only change is firewall rules losing their
source, and nothing touches `terraform_data`. Then apply.

**Know your way back in before you do this.** Hetzner's console has a web
terminal per server (Server → Console) that works regardless of the firewall. If
the tunnel and the firewall are both broken at once, that is the only door left.

**Keep `6443` reachable or you lose `kubectl`.** The API server port is governed
by the same `admin_cidrs`. Either give the API its own tunnel hostname first, or
leave 6443 admitting your address while 22 closes — it is worth doing one at a
time rather than discovering both broke together.

---

## What you end up with

| Before | After |
|---|---|
| Port 22 open to `74.68.92.85/32` | Port 22 open to nobody |
| Home IP rotates → `kubectl` hangs | Home IP is irrelevant |
| CI cannot add a node | CI can add a node |
| Access controlled by an IP allowlist | Access controlled by identity |

## What it costs

**`cloudflared` runs on every node.** Another process to keep updated and debug
when it misbehaves. The resource cost is close to nothing — ~70 MB of disk
against 34 GB free, and RAM that comes out of already-reserved slack rather than
out of pod capacity — so the real cost is operational, not capacity.

**Cloudflare becomes load-bearing.** If Zero Trust has an outage and port 22 is
closed, your way in is the Hetzner web console. That is a genuine dependency, not
a footnote, and it is the reason step 10 is last and reversible.
