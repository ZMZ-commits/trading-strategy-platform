/**
 * Stack 1 of 2 -- the machine and the cluster.
 *
 * This stack knows nothing about Kafka. It provisions a Hetzner server, locks
 * it down, and installs k3s via cloud-init. What runs *inside* the cluster is
 * stack 2 (../k8s), and the split is not tidiness: the Helm provider needs a
 * kubeconfig, which does not exist until this stack has finished. Put both in
 * one apply and Terraform tries to configure Helm at plan time, against a
 * cluster that is not there yet, and fails in a way that reads like a provider
 * bug rather than an ordering problem.
 *
 * Deliberately separate from ../aws, which targets ECR/EC2/CloudFront and
 * provisions nothing this project currently runs.
 */

terraform {
  required_version = ">= 1.5"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.48"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
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

# The Kubernetes API and SSH are reachable only from the addresses you name.
# A k3s API server open to the internet is a credential-stuffing target, and
# the default deny here is the difference between a lab and an incident.
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

resource "hcloud_ssh_key" "deployer" {
  name       = "${var.cluster_name}-deployer"
  public_key = var.ssh_public_key
}

# ------------------------------------------------------------------- server

resource "hcloud_server" "k3s" {
  name        = var.cluster_name
  image       = "ubuntu-24.04"
  server_type = var.server_type
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.deployer.id]
  firewall_ids = [hcloud_firewall.cluster.id]

  network {
    network_id = hcloud_network.main.id
    ip         = "10.0.1.10"
  }

  # k3s is installed by cloud-init rather than a provisioner: a provisioner ties
  # the apply to an SSH connection that may not be ready, and re-runs on
  # replacement in ways that are hard to reason about. cloud-init runs once, on
  # the machine, and its log survives for you to read.
  user_data = <<-EOT
    #cloud-config
    package_update: true
    packages:
      - curl
    runcmd:
      # --disable traefik: we terminate TLS ourselves and a second ingress
      #   controller fighting for :80 is a confusing first failure.
      # --tls-san: the cert must cover the public IP, or kubectl from your
      #   laptop rejects the connection it just made.
      # --write-kubeconfig-mode 644: readable so the file can be fetched
      #   without sudo. Acceptable because the firewall already restricts who
      #   can reach the API at all.
      - |
        curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 644 --tls-san $(curl -s ifconfig.me)" sh -
      - until kubectl get nodes 2>/dev/null; do sleep 3; done
      - touch /var/lib/cloud/k3s-ready
  EOT

  labels = {
    project = "trading-platform"
    role    = "k3s"
  }
}

# Anything that must survive lives here, not on the server's boot disk.
#
# The distinction matters more than it sounds. Terraform destroys a server not
# only on `terraform destroy` but whenever an immutable attribute changes --
# edit `image` or `location` and the plan says "replace", which means destroy.
# The boot disk goes with it. This volume does not: it detaches, waits, and
# reattaches to the new machine.
#
# Treat the server as disposable and the volume as the thing you are protecting.
resource "hcloud_volume" "data" {
  count     = var.data_volume_gb > 0 ? 1 : 0
  name      = "${var.cluster_name}-data"
  size      = var.data_volume_gb
  server_id = hcloud_server.k3s.id
  automount = true
  format    = "ext4"

  # No delete_protection and no prevent_destroy, deliberately: the volume is
  # empty and a locked resource in a cluster you are still learning to build is
  # an obstacle, not a safeguard. The reviewer gate on the apply job is the
  # protection for now.
  #
  # Two things to know about relying on that:
  #
  #   - It only covers CI. A `terraform destroy` from a laptop never meets a
  #     reviewer.
  #   - Turn both flags back on the day this volume holds something you would
  #     miss. That day arrives quietly, usually the first time a bot writes a
  #     trade record here.
  #
  # The planned next layer is a snapshot taken by CI immediately before apply,
  # tagged with the commit, so a bad plan is recoverable rather than merely
  # visible.
}
