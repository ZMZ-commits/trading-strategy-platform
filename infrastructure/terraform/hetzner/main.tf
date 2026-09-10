/**
 * Stack 1 of 2 -- the network, and k3s on top of it.
 *
 * The five machines already exist and were bought when cx23 capacity in hel1
 * was briefly available; every type currently reads "not available" in the
 * console, so releasing one may mean not getting it back. Machines that cannot
 * be replaced on demand are not cattle, and Terraform managing them as cattle
 * is how you lose one to a plan you skimmed.
 *
 * So they are read through `data` sources. A data source is a lookup with no
 * destroy verb -- `terraform destroy` will remove the network, the firewall and
 * the volume, and cannot touch a server. That is the safety property, enforced
 * by the tool rather than by remembering.
 *
 * k3s is then installed over SSH by a remote-exec provisioner. cloud-init was
 * never an option here: it runs once, at first boot, on machines that booted
 * weeks ago. The provisioner runs against a machine that is already up, which
 * is the situation we are actually in.
 *
 * Adding a node is therefore: create it in the console, add one line to
 * var.agent_roles, `terraform apply`. Terraform attaches the network, applies
 * the firewall, installs k3s with the right label and reservations, and joins
 * it to the cluster.
 *
 * What provisioners cost, stated plainly: they run at create time only, so
 * Terraform cannot detect that k3s was later uninstalled or hand-edited. They
 * are not a configuration-management system. For a four-node cluster whose
 * nodes are built once, that is an acceptable trade; if this grows to the point
 * where drift matters, the answer is Ansible, not more provisioners.
 *
 * Stack 2 (../k8s) installs Strimzi and Kafka into the resulting cluster.
 */

terraform {
  required_version = ">= 1.5"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.48"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

# ------------------------------------------------------------- the machines

# Read, never created. If one of these names is wrong the plan fails with "no
# server found", which is the correct and harmless failure -- far better than
# Terraform deciding the server is missing and offering to build it.
data "hcloud_server" "server" {
  name = var.server_name
}

data "hcloud_server" "agent" {
  for_each = var.agent_roles
  name     = each.key
}

locals {
  agent_names = keys(var.agent_roles)

  # Addresses are stated in var.agent_roles, not derived from position. Deriving
  # them meant a new node whose name sorted early renumbered every existing one,
  # and since the address is baked into each node's k3s service file, adding one
  # node planned a reinstall of all of them.
  server_private_ip = "10.0.1.10"
  agent_private_ips = {
    for name, a in var.agent_roles : name => "10.0.1.${a.host}"
  }

  all_server_ids = concat(
    [data.hcloud_server.server.id],
    [for s in data.hcloud_server.agent : s.id],
  )
}

# ---------------------------------------------------------------- networking

resource "hcloud_network" "main" {
  name     = "${var.cluster_name}-net"
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "main" {
  network_id   = hcloud_network.main.id
  type         = "cloud"
  network_zone = var.network_zone
  ip_range     = "10.0.1.0/24"
}

# Attaching the network is a separate resource precisely because the servers are
# data sources -- there is no inline `network` block to put it in. This is the
# better shape anyway: detaching a network is reversible, replacing a server is
# not.
resource "hcloud_server_network" "server" {
  server_id  = data.hcloud_server.server.id
  network_id = hcloud_network.main.id
  ip         = local.server_private_ip

  depends_on = [hcloud_network_subnet.main]
}

resource "hcloud_server_network" "agent" {
  for_each = data.hcloud_server.agent

  server_id  = each.value.id
  network_id = hcloud_network.main.id
  ip         = local.agent_private_ips[each.key]

  depends_on = [hcloud_network_subnet.main]
}

# ------------------------------------------------------------------ firewall

# SSH and the Kubernetes API are reachable only from the addresses you name.
#
# Cluster traffic -- the datastore, flannel, kubelet -- is NOT listed here,
# deliberately: it rides the private network above, and Hetzner cloud firewalls
# filter only the public interface. That is the whole point of attaching the
# subnet rather than letting nodes find each other over the internet.
resource "hcloud_firewall" "cluster" {
  name = "${var.cluster_name}-fw"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = var.admin_cidrs
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = var.admin_cidrs
  }

  dynamic "rule" {
    for_each = var.public_tcp_ports
    content {
      direction  = "in"
      protocol   = "tcp"
      port       = rule.value
      source_ips = ["0.0.0.0/0", "::/0"]
    }
  }
}

# Applied to servers Terraform does not own, so this is an attachment rather
# than a `firewall_ids` argument on the server itself.
#
# This takes effect immediately on machines you may already be sshed into. If
# admin_cidrs is wrong you lock yourself out of all of them at once -- the
# console web terminal is the way back in, and it is worth knowing where that
# button is before running the apply rather than after.
resource "hcloud_firewall_attachment" "cluster" {
  firewall_id = hcloud_firewall.cluster.id
  server_ids  = local.all_server_ids
}

# ----------------------------------------------------------------- the token

# The shared secret an agent presents to join.
#
# Generated here rather than read off the server after the fact, which is what
# makes adding a node a single `terraform apply`: both halves of the join
# already know the secret, so nothing has to be copied by hand between machines.
#
# It lands in terraform.tfstate in plaintext -- every provider secret does.
# That is why state is gitignored, and why it belongs in a remote backend with
# encryption at rest before CI ever runs an apply.
resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

# ----------------------------------------------------------- k3s: the flags

locals {
  reserve_server = join(" ", [
    "--kubelet-arg=kube-reserved=cpu=${var.kube_reserved_cpu},memory=${var.kube_reserved_memory}",
    "--kubelet-arg=system-reserved=cpu=${var.system_reserved_cpu},memory=${var.system_reserved_memory}",
    "--kubelet-arg=eviction-hard=memory.available<${var.eviction_threshold}",
  ])

  reserve_agent = join(" ", [
    "--kubelet-arg=kube-reserved=cpu=${var.agent_kube_reserved_cpu},memory=${var.agent_kube_reserved_memory}",
    "--kubelet-arg=system-reserved=cpu=${var.system_reserved_cpu},memory=${var.system_reserved_memory}",
    "--kubelet-arg=eviction-hard=memory.available<${var.eviction_threshold}",
  ])

  # --disable traefik: we terminate TLS ourselves, and a second ingress
  #   controller fighting for :80 is a confusing first failure.
  # --node-ip: pins the cluster to the private network. Without it k3s picks the
  #   public address and flannel encapsulates node traffic across the internet.
  # --tls-san: the certificate must cover both addresses, or kubectl from your
  #   laptop rejects the connection it just made.
  # --write-kubeconfig-mode 644: readable without sudo, acceptable only because
  #   the firewall already restricts who can reach the API at all.
  # --node-label: what every nodeSelector in stack 2 targets.
  install_server = join(" ", compact([
    "curl -sfL https://get.k3s.io |",
    "K3S_TOKEN='${random_password.k3s_token.result}'",
    "INSTALL_K3S_EXEC=\"server",
    "--disable traefik",
    "--write-kubeconfig-mode 644",
    "--node-ip ${local.server_private_ip}",
    "--node-external-ip ${data.hcloud_server.server.ipv4_address}",
    "--tls-san ${data.hcloud_server.server.ipv4_address}",
    "--tls-san ${local.server_private_ip}",
    "--node-label tsp.role=${var.server_role}",
    local.reserve_server,
    "\" sh -",
  ]))

  install_agent = {
    for name, a in var.agent_roles : name => join(" ", compact([
      "curl -sfL https://get.k3s.io |",
      "K3S_URL=https://${local.server_private_ip}:6443",
      "K3S_TOKEN='${random_password.k3s_token.result}'",
      "INSTALL_K3S_EXEC=\"agent",
      "--node-ip ${local.agent_private_ips[name]}",
      "--node-external-ip ${data.hcloud_server.agent[name].ipv4_address}",
      "--node-label tsp.role=${a.role}",
      local.reserve_agent,
      "\" sh -",
    ]))
  }
}

# --------------------------------------------------------- k3s: control plane

# terraform_data rather than null_resource: same behaviour, no extra provider.
#
# triggers_replace decides when this re-runs. The install command is in there,
# so changing a reservation or a label reinstalls k3s with the new flags on the
# next apply rather than drifting silently from the config that claims to
# describe it.
resource "terraform_data" "k3s_server" {
  triggers_replace = {
    node_id = data.hcloud_server.server.id
    command = local.install_server
  }

  connection {
    type        = "ssh"
    host        = data.hcloud_server.server.ipv4_address
    user        = "root"
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "3m"
  }

  provisioner "remote-exec" {
    inline = [
      # The private NIC must be up first. k3s binding --node-ip to an address
      # the kernel does not hold yet fails in a way that reads like a k3s bug.
      "until ip -4 addr show | grep -q '${local.server_private_ip}'; do sleep 3; done",
      local.install_server,
      # Do not report success until the API actually answers. Without this the
      # agents below start joining a control plane that is still starting.
      "until k3s kubectl get nodes >/dev/null 2>&1; do sleep 3; done",
      "echo 'k3s server ready'",
    ]
  }

  depends_on = [
    hcloud_server_network.server,
    hcloud_firewall_attachment.cluster,
  ]
}

# ---------------------------------------------------------------- k3s: agents

# One per entry in var.agent_roles. Adding a node is one line in that map.
resource "terraform_data" "k3s_agent" {
  for_each = var.agent_roles

  triggers_replace = {
    node_id = data.hcloud_server.agent[each.key].id
    command = local.install_agent[each.key]
  }

  connection {
    type        = "ssh"
    host        = data.hcloud_server.agent[each.key].ipv4_address
    user        = "root"
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "3m"
  }

  provisioner "remote-exec" {
    inline = [
      "until ip -4 addr show | grep -q '${local.agent_private_ips[each.key]}'; do sleep 3; done",
      local.install_agent[each.key],
      "echo 'k3s agent joined: ${each.value.role}'",
    ]
  }

  # Ordering is not cosmetic: the agent installer does not retry a refused
  # connection, it exits, and you find out later from a node that never showed.
  depends_on = [
    terraform_data.k3s_server,
    hcloud_server_network.agent,
  ]
}

# -------------------------------------------------------------------- volume

# Anything that must survive lives here, not on a boot disk. A boot disk goes
# with the machine; this detaches, waits, and reattaches to whatever replaces it.
#
# Attached to the data node, because without Longhorn storage is node-local and
# the database is the thing worth protecting.
resource "hcloud_volume" "data" {
  count     = var.data_volume_gb > 0 ? 1 : 0
  name      = "${var.cluster_name}-data"
  size      = var.data_volume_gb
  server_id = data.hcloud_server.agent[one([for n, a in var.agent_roles : n if a.role == "data"])].id
  automount = true
  format    = "ext4"

  # Unlike the servers, this IS owned by Terraform and therefore destroyable.
  # It is empty today, so no lock. Turn on delete_protection here and
  # prevent_destroy in a lifecycle block the day it holds something you would
  # miss -- which arrives quietly, usually the first time a bot writes a trade
  # record into it.
}
