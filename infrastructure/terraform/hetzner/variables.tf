variable "hcloud_token" {
  description = "Hetzner Cloud API token, Read & Write. Never commit this."
  type        = string
  sensitive   = true
}

variable "cluster_name" {
  description = "Prefixes the network, firewall and volume. Not the servers -- those are named already."
  type        = string
  default     = "tsp-k3s"
}

# ------------------------------------------------------------------ topology
#
# These are LOOKUP keys, not specifications. The machines exist; changing a name
# here points Terraform at a different existing server, it does not rename or
# rebuild anything. A name with no matching server fails the plan, which is the
# harmless failure.

variable "server_name" {
  description = <<-EOT
    Hetzner name of the machine that will run the k3s control plane.

    It gets ~1.5 GB of overhead against a 4 GB box, leaving 2.5 GB for pods --
    enough for the light intake tier (ingress, Redis, the data pipeline,
    Grafana) and nothing heavier. Do not put a database here.
  EOT
  type        = string
  default     = "trading-platform-2"
}

variable "agent_roles" {
  description = <<-EOT
    Existing Hetzner server name -> the role it plays and the private address it
    holds.

    `role` becomes the `tsp.role` node label, which is what every nodeSelector in
    stack 2 targets, so "TimescaleDB goes on the data node" is written once,
    here.

    `host` is the last octet of its address on 10.0.1.0/24, and it is stated
    explicitly rather than derived from position for a reason worth knowing.

      An earlier version assigned .11 upward in sorted name order. Adding a node
      called "trading-platform" -- which sorts *before* "trading-platform-3" --
      shifted every existing agent down one address. Because the address is
      baked into each node's k3s service file, that showed up in the plan as
      "reinstall k3s on all three running nodes" to add one. Explicit addresses
      make adding a node touch exactly one node.

    Agents carry no control plane, so overhead is ~1.0 GB and a 4 GB box leaves
    ~2.4 GB for pods. That is the ceiling on any single pod in this cluster -- a
    pod cannot span machines, so anything larger never schedules. It is why
    TimescaleDB is tuned down rather than left at its 4 GB default.

    Exactly one entry must have the role "data"; the volume attaches there.
  EOT
  type = map(object({
    role = string
    host = number
  }))
  default = {
    "trading-platform-3" = { role = "data", host = 11 }
    "trading-platform-4" = { role = "stream", host = 12 }
    "trading-platform-5" = { role = "observability", host = 13 }
  }

  validation {
    condition     = length([for n, a in var.agent_roles : n if a.role == "data"]) == 1
    error_message = "Exactly one agent must have the role \"data\"; the persistent volume attaches to it."
  }

  validation {
    condition = length(distinct([for a in var.agent_roles : a.host])) == length(var.agent_roles)
    # Two agents on one address is a cluster that half works: they join, then
    # fight over the address, and the symptom is nodes flapping NotReady.
    error_message = "Each agent needs a distinct host octet."
  }

  validation {
    condition     = alltrue([for a in var.agent_roles : a.host > 10 && a.host < 255])
    error_message = "host must be 11-254; .1 is the gateway and .10 is the control plane."
  }
}

variable "server_role" {
  description = "Node label applied to the control-plane machine."
  type        = string
  default     = "intake"
}

variable "network_zone" {
  description = "Must match the region the servers are in: eu-central for fsn1/nbg1/hel1, us-east for ash."
  type        = string
  default     = "eu-central"
}

# ------------------------------------------------------------------- access

variable "admin_cidrs" {
  description = <<-EOT
    Who may reach SSH and the Kubernetes API. Your home address as a /32.

    Left as 0.0.0.0/0 this publishes a Kubernetes API server to the internet,
    which is scanned continuously. Find yours with `curl ifconfig.me`.

    Two things that will bite you. A residential IP changes -- when kubectl
    starts timing out, check here before you check the cluster. And the firewall
    attaches to machines you may already be inside: get this wrong and you lock
    yourself out of all of them at once. The console's web terminal is the way
    back in.
  EOT
  type        = list(string)
}

variable "ssh_private_key_path" {
  description = <<-EOT
    Private key Terraform uses to SSH in and install k3s. The public half is
    already on the machines.

    Terraform reads this file at plan time, so the key must exist wherever
    Terraform runs -- including a CI runner, where it comes from a secret rather
    than from disk. That is the main cost of installing via provisioner: the
    thing that applies your infrastructure now also holds root on every node.
  EOT
  type        = string
  default     = "~/.ssh/hetzner"
}

variable "public_tcp_ports" {
  description = "Ports open to the world. Empty until something is actually being served -- add [\"80\", \"443\"] at the ingress phase."
  type        = list(string)
  default     = []
}

variable "data_volume_gb" {
  description = "Persistent volume attached to the data node, for TimescaleDB. 0 to skip. Survives the machine; a boot disk does not."
  type        = number
  default     = 0
}

# ------------------------------------------------------- kubelet reservations
#
# k3s reserves nothing by default. Left alone, the kubelet will place pods into
# memory the operating system and control plane need, and the first time a
# machine is genuinely full the kernel picks what dies by OOM score -- which can
# be the kubelet itself. That is the difference between one pod restarting and
# the whole node going NotReady and shedding everything on it.
#
# On a 4 GB box these are a third of the machine and you will feel them. That is
# the correct signal that the box is small, not a reason to lower them.

variable "kube_reserved_memory" {
  description = "Memory held back on the SERVER for k3s itself: API server, scheduler, controller-manager, datastore, kubelet, containerd."
  type        = string
  default     = "1Gi"
}

variable "kube_reserved_cpu" {
  description = "CPU held back on the server. The control plane starves quietly under load, and the symptom is a cluster that cannot report its own problem."
  type        = string
  default     = "500m"
}

variable "agent_kube_reserved_memory" {
  description = "Memory held back on an AGENT -- kubelet and containerd only, with no control plane to feed. Roughly half the server figure."
  type        = string
  default     = "512Mi"
}

variable "agent_kube_reserved_cpu" {
  description = "CPU held back on an agent."
  type        = string
  default     = "250m"
}

variable "system_reserved_memory" {
  description = "Memory held back for the OS -- sshd, journald, the kernel slab. Small, but the thing you need working when everything else is not."
  type        = string
  default     = "512Mi"
}

variable "system_reserved_cpu" {
  description = "CPU held back for the OS."
  type        = string
  default     = "250m"
}

variable "eviction_threshold" {
  description = "Free memory below which the kubelet starts evicting pods on purpose. A margin, so eviction is a decision the kubelet makes rather than one the OOM killer makes for it."
  type        = string
  default     = "300Mi"
}
