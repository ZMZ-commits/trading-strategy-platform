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

  # Roll back a failed install instead of leaving one behind. Three dead
  # revisions accumulated during the 0.45 -> 1.2 upgrade, each a release the
  # next run had to reason about. atomic makes a failure leave nothing.
  #
  # cleanup_on_fail covers the resources within a failed upgrade, which atomic
  # alone does not always reclaim.
  atomic          = true
  cleanup_on_fail = true
}

# --------------------------------------------------------------------- kafka

# Applied as raw YAML rather than a typed resource: Kafka is a CRD, and the
# Kubernetes provider cannot plan against a schema that did not exist when the
# plan was made. kubectl_manifest defers that to apply time, which is the only
# order that works on a first run.
#
# apiVersion is v1, not v1beta2. Strimzi 1.x serves exactly one version of each
# of these CRDs and v1beta2 is not it -- the operator asks for
# /apis/kafka.strimzi.io/v1/... and a cluster still holding the 0.45 CRDs
# answers 404, which it reports as a crashloop rather than as a version
# mismatch.
resource "kubectl_manifest" "kafka" {
  depends_on = [helm_release.strimzi]

  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1"
    kind       = "Kafka"
    metadata = {
      name      = var.kafka_name
      namespace = kubernetes_namespace.kafka.metadata[0].name
      # Vestigial as of Strimzi 1.x, kept because they cost nothing and reading
      # their absence as "ZooKeeper" would be worse. KRaft and node pools are
      # both mandatory now -- ZooKeeper was removed outright -- so there is no
      # longer anything to opt into.
      annotations = {
        "strimzi.io/node-pools" = "enabled"
        "strimzi.io/kraft"      = "enabled"
      }
    }
    spec = {
      kafka = {
        version = var.kafka_version

        # Sizing is NOT here. It lives on the KafkaNodePool below.
        #
        # It was here, and Strimzi silently ignored it: with node pools the pool
        # owns the pod spec, so `kubectl get pod tsp-dual-role-0` reported
        # `resources: {}` and `qosClass: BestEffort` while this block sat in the
        # Kafka resource looking authoritative. BestEffort is the worst possible
        # class for the one stateful thing in the cluster -- the kubelet evicts
        # it FIRST under memory pressure.

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
              # Both halves are needed, and only setting the first is a trap.
              #
              # A client bootstraps against the bootstrap port, and Kafka
              # answers with metadata naming the address of every broker that
              # owns a partition. For a NodePort listener Strimzi allocates a
              # SEPARATE NodePort per broker, so a client that bootstraps
              # successfully then tries to connect to a port nobody opened, and
              # the failure looks like the broker is down rather than firewalled.
              #
              # Assigned explicitly rather than left to Strimzi so the numbers
              # are knowable at plan time -- var.public_tcp_ports in stack 1 has
              # to name them, and it cannot name a port chosen at random later.
              bootstrap = { nodePort = var.external_node_port }
              brokers = [
                for i in range(var.broker_count) : {
                  broker   = i
                  nodePort = var.external_node_port + 1 + i
                }
              ]
            }
          },
        ]
        config = {
          # Derived from broker_count, which defaults to 1 on this cluster --
          # see the variable for why. At 1 these all collapse to 1, and a node
          # loss stops ingestion; there is no arrangement of one broker that
          # survives losing the machine it is on.
          #
          # At 3: every partition on all three brokers, and a write is only
          # acknowledged once two of them hold it. That is what survives losing
          # a node -- the third broker is missing, two still have the data, and
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
      # Reconciles the KafkaTopic resource below into an actual topic. Small,
      # stateless, and deliberately unpinned -- it can live on any node with
      # room, unlike the broker whose data ties it to one machine.
      #
      # topicOperator only. The User Operator is deliberately absent: it manages
      # KafkaUser resources, which only mean something when a listener has
      # authentication. Both listeners here are plaintext with none, and no
      # KafkaUser exists, so it started, found nothing to do, and exited 0 --
      # which a pod with restartPolicy Always treats as a crash. It restarted
      # eleven times, the entity-operator Deployment never went Ready, and the
      # whole Kafka resource sat NotReady behind it:
      #
      #   StrimziTimeoutException: Exceeded timeout of 300000ms while waiting
      #   for Deployment resource tsp-entity-operator to be ready
      #
      # The broker was fine throughout. Add this back the day a listener gains
      # authentication and there are users to manage.
      entityOperator = {
        topicOperator = {
          resources = {
            requests = { memory = "256Mi", cpu = "50m" }
            limits   = { memory = "256Mi", cpu = "200m" }
          }
        }
      }
    }
  })
}

resource "kubectl_manifest" "node_pool" {
  depends_on = [helm_release.strimzi]

  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1"
    kind       = "KafkaNodePool"
    metadata = {
      name      = "dual-role"
      namespace = kubernetes_namespace.kafka.metadata[0].name
      labels    = { "strimzi.io/cluster" = var.kafka_name }
    }
    spec = {
      replicas = var.broker_count
      roles    = ["controller", "broker"]

      # requests == limits, which makes the broker Guaranteed QoS: evicted last
      # rather than first. This is the spec Strimzi actually reads for a pooled
      # node -- the identical block on Kafka.spec.kafka was ignored.
      resources = {
        requests = { memory = var.broker_memory, cpu = var.broker_cpu_request }
        limits   = { memory = var.broker_memory, cpu = var.broker_cpu_limit }
      }

      # Heap is deliberately about half the pod. Kafka's throughput comes from
      # the OS page cache, not its heap -- it reads and writes through the
      # filesystem and lets the kernel decide what stays resident, so a large
      # heap starves the thing doing the work. -Xms == -Xmx so the JVM claims
      # it up front rather than growing into a limit and being OOM-killed on
      # the way there.
      jvmOptions = {
        "-Xms" = var.broker_heap
        "-Xmx" = var.broker_heap
      }

      # Two placement rules, doing different jobs.
      #
      # nodeAffinity puts Kafka on the node this cluster set aside for it. The
      # tsp.role labels exist for exactly this -- without it the scheduler picks
      # by free memory, and Kafka lands on the database node the first time
      # TimescaleDB is idle.
      #
      # podAntiAffinity keeps brokers off each other. Three brokers sharing a
      # machine is three brokers lost at once, which is the failure the whole
      # arrangement exists to survive, and Strimzi stacks them happily unless
      # told not to.
      #
      # They constrain each other: broker_count must not exceed the number of
      # nodes carrying var.node_role, or the extras stay Pending forever with
      # "didn't match pod anti-affinity rules". That is the correct failure --
      # loud, and not a silently unsafe placement.
      template = {
        pod = {
          affinity = {
            nodeAffinity = {
              requiredDuringSchedulingIgnoredDuringExecution = {
                nodeSelectorTerms = [{
                  matchExpressions = [{
                    key      = "tsp.role"
                    operator = "In"
                    values   = [var.node_role]
                  }]
                }]
              }
            }
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
    apiVersion = "kafka.strimzi.io/v1"
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
