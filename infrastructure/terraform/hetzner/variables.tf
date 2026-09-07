variable "hcloud_token" {
  description = "Hetzner Cloud API token, Read & Write. Never commit this."
  type        = string
  sensitive   = true
}

variable "cluster_name" {
  description = "Names the server, network and firewall."
  type        = string
  default     = "tsp-k3s"
}

variable "server_type" {
  description = <<-EOT
    k3s needs roughly 1 GB before anything runs, Kafka wants another 1 GB, and
    Strimzi's operator a few hundred MB. 8 GB leaves room to be wrong about
    that; 4 GB does not.
  EOT
  type        = string
  default     = "cx32"
}

variable "location" {
  description = "hel1 (Helsinki), fsn1/nbg1 (Germany), ash/hil (US)."
  type        = string
  default     = "hel1"
}

variable "network_zone" {
  description = "Must match the region of `location`: eu-central for fsn1/nbg1/hel1, us-east for ash."
  type        = string
  default     = "eu-central"
}

variable "ssh_public_key" {
  description = "Contents of your public key, e.g. file(\"~/.ssh/id_ed25519.pub\")."
  type        = string
}

variable "admin_cidrs" {
  description = <<-EOT
    Who may reach SSH and the Kubernetes API. Your home address as a /32.

    Left as 0.0.0.0/0 this publishes a Kubernetes API server to the internet,
    which is scanned continuously. Find yours with `curl ifconfig.me`, and
    remember a residential IP changes -- if kubectl suddenly times out, this is
    the first thing to check, not the cluster.
  EOT
  type        = list(string)
}

variable "public_tcp_ports" {
  description = "Ports open to the world. Empty until something is actually being served."
  type        = list(string)
  default     = []
}

variable "data_volume_gb" {
  description = "Persistent volume for Kafka logs. 0 to skip. Survives server replacement."
  type        = number
  default     = 0
}
