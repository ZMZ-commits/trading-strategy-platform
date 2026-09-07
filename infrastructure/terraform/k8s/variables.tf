variable "kubeconfig" {
  description = "Path to the kubeconfig stack 1 produced. Gitignored."
  type        = string
  default     = "./kubeconfig.yaml"
}

variable "namespace" {
  type    = string
  default = "kafka"
}

variable "strimzi_version" {
  description = "Pinned, not left floating: an operator that upgrades itself on a re-apply can roll your brokers without being asked."
  type        = string
  default     = "0.45.0"
}

variable "kafka_version" {
  type    = string
  default = "3.9.0"
}

variable "kafka_name" {
  type    = string
  default = "tsp"
}

variable "external_node_port" {
  description = "NodePort for producers outside the cluster. Must be in 30000-32767 and open in the stack-1 firewall."
  type        = number
  default     = 30092
}

variable "broker_storage" {
  description = "Per-broker disk. Ticks for eight symbols are small; this is mostly headroom."
  type        = string
  default     = "10Gi"
}

variable "topic_partitions" {
  description = <<-EOT
    Ordering is guaranteed per partition, and the producer keys on symbol, so
    every symbol keeps its own order. More partitions than consumers is fine;
    fewer means idle consumers. Raising this later is easy, lowering it is not.
  EOT
  type    = number
  default = 6
}

variable "retention_days" {
  description = "How far back the bot can replay. Disk is the only cost."
  type        = number
  default     = 7
}
