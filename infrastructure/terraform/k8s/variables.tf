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
  description = <<-EOT
    Pinned, not left floating: an operator that upgrades itself on a re-apply
    can roll your brokers without being asked.

    Do not move this BACKWARDS below 0.49 on this cluster. 0.45.0 cannot run
    here at all: it bundles fabric8 6.13.4, which parses the API server's
    /version response strictly, and Kubernetes 1.33 added an `emulationMajor`
    field that it does not know about. The operator won its leader election and
    then died on

      UnrecognizedPropertyException: Unrecognized field "emulationMajor"
      ... Detection of Kubernetes version failed
      ... Unable to start operator for 1 or more namespace

    which looks like a crashloop with no obvious cause until you read far
    enough up the log to see that it had already become leader. These nodes run
    k3s 1.36.
  EOT
  type        = string
  default     = "1.2.0"
}

variable "kafka_version" {
  description = <<-EOT
    Constrained by strimzi_version, not chosen freely. Strimzi 1.2.0 ships
    support for 4.1.0, 4.2.0, 4.2.1, 4.3.0 and 4.3.1 only -- 3.9.0 was dropped,
    so the two variables have to move together.

    Kafka 4.x is KRaft-only, which this cluster already was.
  EOT
  type        = string
  default     = "4.3.1"
}

variable "kafka_name" {
  type    = string
  default = "tsp"
}

variable "external_node_port" {
  description = <<-EOT
    Base NodePort for producers outside the cluster.

    This is the BOOTSTRAP port. Each broker also gets one, at
    external_node_port + 1 + broker_index, because a NodePort listener answers a
    bootstrap request with metadata naming a separate port per broker. So the
    default reserves 30092 for bootstrap and 30093 upward for brokers.

    Every one of them must be open in stack 1's `public_tcp_ports`, or a client
    connects, receives metadata, and then fails against a port nobody opened --
    which reads as a dead broker rather than a firewall rule.

    With the defaults (bootstrap 30092, one broker):

      public_tcp_ports = ["30092", "30093"]

    Must leave room below 32767 for broker_count ports.
  EOT
  type        = number
  default     = 30092

  validation {
    condition     = var.external_node_port >= 30000 && var.external_node_port <= 32700
    error_message = "external_node_port must be in the NodePort range 30000-32700, leaving headroom above it for per-broker ports."
  }
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
    Brokers, one per node carrying var.node_role.

    Defaults to 1 on this cluster, and that is a memory decision rather than a
    throughput one. A Strimzi broker wants ~1.5 GB; the agents here have 2.4 GB
    allocatable each and the cluster has ~9.1 GB in total, most of which is spoken
    for by TimescaleDB and the observability stack. Three brokers would take a
    third of everything to protect a feed that peaks in the hundreds of messages
    a second -- a single broker handles well over 100,000.

    What 1 costs: a node loss stops ingestion, and replication factor 1 means
    the partitions on that machine are gone until it returns. That is the honest
    trade for 4 GB nodes, not something to paper over with a comment.

    Raise it to 3 when there are three nodes with room. Nothing else needs to
    change: replication factor, min.insync.replicas and the per-broker NodePorts
    are all derived from this.

    It must not exceed the number of nodes labelled var.node_role. Set it higher
    and the extra brokers stay Pending -- podAntiAffinity refuses to stack them,
    which is the correct failure.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.broker_count >= 1 && var.broker_count <= 5
    error_message = "broker_count must be between 1 and 5, and must not exceed the number of nodes labelled tsp.role=<node_role>."
  }
}

variable "node_role" {
  description = <<-EOT
    The `tsp.role` node label Kafka is pinned to, via nodeAffinity.

    Stack 1 labels every node with its role, and this is what makes the plan in
    the docs real: without it the scheduler picks by free memory and Kafka lands
    on the database node the first time TimescaleDB happens to be idle.
  EOT
  type        = string
  default     = "stream"
}

# ------------------------------------------------------------------- sizing

variable "broker_memory" {
  description = <<-EOT
    Memory request AND limit for each broker. Equal on purpose: that is what
    makes the pod Guaranteed QoS, so it is evicted last rather than first.

    1500Mi against an agent's ~2490Mi allocatable leaves room for the node's
    own overhead and a little slack. Raising it past ~2000Mi means the broker
    stops fitting and sits Pending -- a pod cannot span machines.
  EOT
  type        = string
  default     = "1500Mi"
}

variable "broker_heap" {
  description = <<-EOT
    JVM heap, roughly half the pod.

    Kafka's throughput comes from the OS page cache rather than its heap, so a
    bigger heap starves the thing doing the work. The remainder of the pod's
    memory is not waste -- it is where the data actually flows.
  EOT
  type        = string
  default     = "768m"
}

variable "broker_cpu_request" {
  description = "CPU the scheduler reserves. These are 2-vCPU boxes, so this is a real fraction of one."
  type        = string
  default     = "200m"
}

variable "broker_cpu_limit" {
  description = <<-EOT
    CPU ceiling. Higher than the request so the broker can burst during a
    backlog -- CPU is compressible, so exceeding the request throttles rather
    than kills, unlike memory.
  EOT
  type        = string
  default     = "1"
}
