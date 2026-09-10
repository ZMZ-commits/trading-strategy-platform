/**
 * Stack 2 of 2 -- what runs inside the cluster.
 *
 * Reads the kubeconfig stack 1 produced. Installs the Strimzi operator with
 * Helm, then asks it for a Kafka.
 *
 * Why an operator rather than a Kafka Helm chart directly: Kafka is stateful
 * and its awkward moments are all operational -- rolling a broker without
 * losing a partition leader, growing storage, rotating certs. Strimzi encodes
 * those as controller logic. A plain chart gives you the pods and leaves the
 * hard parts to you at the exact moment you are least able to think.
 */

terraform {
  required_version = ">= 1.5"
  required_providers {
    helm       = { source = "hashicorp/helm", version = "~> 2.13" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    kubectl    = { source = "gavinbunney/kubectl", version = "~> 1.14" }
  }
}

# All three read the same file. It is written by stack 1 and gitignored; if it
# is missing, run the fetch_kubeconfig command that stack 1 outputs.
provider "helm" {
  kubernetes { config_path = var.kubeconfig }
}

provider "kubernetes" {
  config_path = var.kubeconfig
}

provider "kubectl" {
  config_path      = var.kubeconfig
  load_config_file = true
}

resource "kubernetes_namespace" "kafka" {
  metadata {
    name = var.namespace
  }
}

# ------------------------------------------------------------------ operator

resource "helm_release" "strimzi" {
  name       = "strimzi"
  repository = "https://strimzi.io/charts/"
  chart      = "strimzi-kafka-operator"
  version    = var.strimzi_version
  namespace  = kubernetes_namespace.kafka.metadata[0].name

  # The operator must be running before a Kafka resource means anything --
  # without it the CRD is unrecognised and the apply fails on the next resource
  # rather than here, which is a confusing place to learn it.
  wait          = true
  wait_for_jobs = true
  timeout       = 600
}

# --------------------------------------------------------------------- kafka

# Applied as raw YAML rather than a typed resource: Kafka is a CRD, and the
# Kubernetes provider cannot plan against a schema that did not exist when the
# plan was made. kubectl_manifest defers that to apply time, which is the only
# order that works on a first run.
resource "kubectl_manifest" "kafka" {
  depends_on = [helm_release.strimzi]

  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1beta2"
    kind       = "Kafka"
    metadata = {
      name      = var.kafka_name
      namespace = kubernetes_namespace.kafka.metadata[0].name
      annotations = {
        # KRaft: no ZooKeeper. One less stateful thing to operate, and the
        # only mode Strimzi carries forward.
        "strimzi.io/node-pools" = "enabled"
        "strimzi.io/kraft"      = "enabled"
      }
    }
    spec = {
      kafka = {
        version = var.kafka_version
        listeners = [
          {
            name = "plain"
            port = 9092
            type = "internal"
            tls  = false
          },
          {
            # Reachable from outside the cluster, so the scraper on your other
            # box (and your laptop) can produce without being in the cluster.
            name = "external"
            port = 9094
            type = "nodeport"
            tls  = false
            configuration = {
              bootstrap = { nodePort = var.external_node_port }
            }
          },
        ]
        config = {
          # Every partition on all three brokers, and a write is only
          # acknowledged once two of them hold it. That is what survives losing
          # a node: the third broker is missing, two still have the data, and
          # producers carry on.
          #
          # min.insync.replicas of 2 rather than 3 is the whole point. At 3 a
          # single broker restart -- an upgrade, a reschedule -- stops writes
          # dead, because the cluster cannot satisfy its own durability rule.
          # At 2 it tolerates one absence and still refuses to accept a write
          # that only one broker has seen.
          "offsets.topic.replication.factor"         = var.broker_count
          "transaction.state.log.replication.factor" = var.broker_count
          "transaction.state.log.min.isr"            = var.broker_count > 1 ? 2 : 1
          "default.replication.factor"               = var.broker_count
          "min.insync.replicas"                      = var.broker_count > 1 ? 2 : 1
        }
      }
      entityOperator = { topicOperator = {}, userOperator = {} }
    }
  })
}

resource "kubectl_manifest" "node_pool" {
  depends_on = [helm_release.strimzi]

  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1beta2"
    kind       = "KafkaNodePool"
    metadata = {
      name      = "dual-role"
      namespace = kubernetes_namespace.kafka.metadata[0].name
      labels    = { "strimzi.io/cluster" = var.kafka_name }
    }
    spec = {
      replicas = var.broker_count
      roles    = ["controller", "broker"]

      # One broker per node. Three brokers sharing a machine is three brokers
      # lost at once, which is the failure this whole arrangement exists to
      # survive -- and Strimzi will happily stack them without being told not to.
      template = {
        pod = {
          affinity = {
            podAntiAffinity = {
              requiredDuringSchedulingIgnoredDuringExecution = [{
                labelSelector = {
                  matchExpressions = [{
                    key      = "strimzi.io/name"
                    operator = "In"
                    values   = ["${var.kafka_name}-kafka"]
                  }]
                }
                topologyKey = "kubernetes.io/hostname"
              }]
            }
          }
        }
      }
      storage = {
        type = "jbod"
        volumes = [{
          id   = 0
          type = "persistent-claim"
          size = var.broker_storage
          # Kafka's whole point is that messages survive a restart. An
          # ephemeral volume gives you a queue that forgets, which is the one
          # thing you already had in Redis.
          deleteClaim = false
        }]
      }
    }
  })
}

# --------------------------------------------------------------------- topic

resource "kubectl_manifest" "trades_topic" {
  depends_on = [kubectl_manifest.kafka]

  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1beta2"
    kind       = "KafkaTopic"
    metadata = {
      name      = "market.trades"
      namespace = kubernetes_namespace.kafka.metadata[0].name
      labels    = { "strimzi.io/cluster" = var.kafka_name }
    }
    spec = {
      # Partitioned so per-symbol ordering holds: a producer keying on the
      # symbol always lands the same symbol on the same partition, and a bar
      # built from out-of-order ticks has the wrong high and low.
      partitions = var.topic_partitions
      # Every partition on every broker. Replicas cannot exceed brokers, and a
      # topic replicated once on a three-broker cluster is a topic that dies
      # with one machine, on a cluster built so that it would not.
      replicas = var.broker_count
      config = {
        "retention.ms"     = var.retention_days * 24 * 60 * 60 * 1000
        "cleanup.policy"   = "delete"
        "compression.type" = "producer"
      }
    }
  })
}
