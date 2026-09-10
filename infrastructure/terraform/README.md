# Terraform

Two stacks, applied in order.

| Stack | Owns | Applied by |
|---|---|---|
| `hetzner/` | private network, firewall, k3s on every node, the data volume | CI, once set up |
| `k8s/` | Strimzi + Kafka inside the cluster | still by hand — see below |

## What a merge can and cannot change

```
Removable by a merge              Not removable, ever
────────────────────              ───────────────────
network, subnet                   the five servers
firewall + attachment
k3s install (terraform_data)
the data volume
everything in k8s/
```

The servers are read through `data` sources. A data source is a lookup with **no
destroy verb** — no plan can produce one that deletes a machine. That is the
safety property, and it is enforced by the tool rather than by remembering.

Delete a `resource` block and CI removes the thing. Delete a `data` block and CI
removes nothing; Terraform just stops knowing the machine exists.

---

## Before CI can run: remote state

**Nothing below works until this is done.** A GitHub runner is destroyed after
every job, so `terraform init` with no backend means every run starts from empty
state. Terraform then sees none of your infrastructure and offers to create a
second copy of all of it.

Your other repo, `zemingzhang1/terraform-infra`, hit exactly this and works
around it by re-importing every resource on every run with `|| true`. That is a
reasonable hack for DNS records. It is not one for a volume with a database on
it: a silently skipped import means Terraform concludes the resource is missing
and creates another.

**Use HCP Terraform's free tier.** It does encrypted state with locking, needs no
infrastructure of its own, and takes about ten minutes.

1. Sign up at <https://app.terraform.io>, create an organisation.
2. Add this to `hetzner/backend.tf`:

   ```hcl
   terraform {
     cloud {
       organization = "<your-org>"
       workspaces { name = "tsp-hetzner" }
     }
   }
   ```

3. Locally: `terraform login`, then `terraform init -migrate-state`. This uploads
   what is currently on your disk and switches over.
4. Set the workspace's execution mode to **Local** — you want HCP for state and
   locking, and GitHub Actions for running. Remote execution would need every
   variable configured there instead, in a second place.
5. Create an API token (HCP → User settings → Tokens) and add it as the
   `TF_API_TOKEN` repository secret.

Two `terraform plan` runs from different machines agreeing is how you know it
took.

**Do not put state in MinIO.** MinIO will run inside the cluster this stack
builds, so Terraform would need the cluster to exist in order to find out whether
the cluster exists.

---

## Repository secrets

Settings → Secrets and variables → Actions.

| Secret | What | Notes |
|---|---|---|
| `HCLOUD_TOKEN` | Hetzner API token, Read & Write | Full control of the account |
| `ADMIN_CIDRS` | JSON list, e.g. `["203.0.113.4/32"]` | Must be a **JSON array**, not a bare IP |
| `CLUSTER_SSH_PRIVATE_KEY` | private half of `~/.ssh/hetzner` | Whole file, including the BEGIN/END lines |
| `TF_API_TOKEN` | HCP Terraform token | Only if using the `cloud` backend above |

`ADMIN_CIDRS` is the one that will catch you out. Terraform reads `TF_VAR_*` for
a `list(string)` as HCL, so `203.0.113.4/32` fails and `["203.0.113.4/32"]`
works. It is also your home IP, which changes — when a plan suddenly wants to
rewrite the firewall, this is why.

### About `CLUSTER_SSH_PRIVATE_KEY`

k3s is installed by a `remote-exec` provisioner, so **the runner needs root SSH
on every node**. That is a real escalation and worth naming: anyone who can
trigger this workflow, or read its secrets, has root on the cluster.

It is the cost of installing via provisioner rather than an image. Accept it
knowingly, keep the key scoped to these machines, and rotate it if a run is ever
compromised.

---

## The reviewer gate

Settings → Environments → New environment → **`terraform-apply`** → Required
reviewers → add yourself.

**Without this step `terraform-apply.yml` applies with no gate**, which is the
exact failure it exists to prevent. The environment name in the workflow is not
enough on its own; the protection rule is configured in GitHub, not in YAML.

This covers CI only. A `terraform destroy` from a laptop never meets a reviewer,
which is why every server also has Hetzner **delete protection** turned on in the
console — that one is enforced by the API and refuses deletion from any source.

---

## Workflows

| File | Trigger | Does |
|---|---|---|
| `terraform-plan.yml` | PR touching `infrastructure/terraform/**` | plan, posted as a PR comment, updated in place on each push |
| `terraform-apply.yml` | push to `dev`/`staging`/`main` | plan then apply, behind the reviewer gate |

The plan comment flags destroys explicitly, because that is the line a reviewer
must not skim.

`terraform-apply.yml` applies a **saved plan file** rather than re-planning. The
world can move between the two, and applying a file guarantees that what ran is
what the reviewer approved.

Neither workflow touches `k8s/` yet. That stack needs a kubeconfig, which means
another secret holding cluster-admin credentials — worth doing deliberately, once
the hetzner stack has run through CI a few times.

---

## Running it by hand

```bash
cd hetzner
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Then fetch cluster credentials and check the result:

```bash
terraform output fetch_kubeconfig   # prints the command; run it
export KUBECONFIG=$PWD/../k8s/kubeconfig.yaml
kubectl get nodes -L tsp.role
```

## Adding a node

1. Create the server in the Hetzner console.
2. Add one line to `agent_roles`, picking the next free `host` octet:

   ```hcl
   "trading-platform-6" = { role = "apps", host = 14 }
   ```

3. `terraform apply`.

Terraform attaches the private network, applies the firewall, installs k3s with
the right label and kubelet reservations, and joins it to the cluster. No SSH.

**Give each node an explicit `host`.** An earlier version derived addresses from
sorted position, and adding a node called `trading-platform` — which sorts before
`trading-platform-3` — renumbered every existing agent. Since the address is
baked into each node's k3s service file, the plan for adding one node was a
reinstall of all of them. Stating the octet keeps an addition to one node.

## What provisioners do not do

They run at **create** time only. If someone uninstalls k3s by hand, Terraform
will not notice: `terraform_data` has no way to inspect the machine.

This is not configuration management, and for four nodes built once that is an
acceptable trade. The `triggers_replace` block does cover the common case — change
a reservation or a label and k3s is reinstalled with the new flags on the next
apply. If drift ever starts mattering, the answer is Ansible, not more
provisioners.
