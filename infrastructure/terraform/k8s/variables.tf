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
  type        = number
  default     = 6
}

variable "retention_days" {
  description = "How far back the bot can replay. Disk is the only cost."
  type        = number
  default     = 7
}

variable "broker_count" {
  description = <<-EOT
    One broker per node, up to three.

    Not a throughput setting -- a single broker handles well over 100,000
    messages a second and this feed peaks in the hundreds. It is about not
    putting a single point of failure inside a cluster bought for redundancy:
    three nodes and one broker means a node loss stops ingestion anyway.

    Three is the ceiling worth paying for. More brokers than nodes just stacks
    two on one machine, which is two lost together.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.broker_count >= 1 && var.broker_count <= 5
    error_message = "broker_count must be between 1 and 5, and should not exceed the node count."
  }
}
