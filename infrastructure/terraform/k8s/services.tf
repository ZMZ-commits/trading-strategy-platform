/**
 * Phase 3 of docs/K8S_MIGRATION.md -- the stateless services.
 *
 * Redis, the sandbox and the three backends, as Deployments and Services.
 * NO ingress and NO data, deliberately: nothing here is reachable from the
 * internet and nothing here has persistent storage yet. The VM keeps serving
 * every live hostname throughout, because the cluster has no public entrance
 * at all -- no ingress controller, no TLS, and 80/443 are not even open in the
 * firewall. Deleting the VM is phase 9, five phases away.
 *
 * Reach these with `kubectl port-forward` until phase 5 adds ingress-nginx.
 *
 * Storage is emptyDir rather than a PersistentVolumeClaim. That is phase 4's
 * job, and the split is on purpose: this phase proves the containers start,
 * find each other and answer HTTP, which is a different question from whether
 * the data moved correctly. Mixing them means a failure could be either.
 */

resource "kubernetes_namespace" "platform" {
  metadata {
    name = var.platform_namespace
  }
}

# --------------------------------------------------------------------- redis

# No persistence, matching the VM. This Redis holds pub/sub in flight and a
# price cache with a one-day expiry -- losing it costs the cached prices, which
# the next tick repopulates. There is nothing here worth a volume.
resource "kubernetes_deployment" "redis" {
  metadata {
    name      = "redis"
    namespace = kubernetes_namespace.platform.metadata[0].name
    labels    = { app = "redis" }
  }

  spec {
    replicas = 1
    selector { match_labels = { app = "redis" } }

    template {
      metadata { labels = { app = "redis" } }
      spec {
        # The node this cluster set aside for stateful-ish things. Not the
        # stream node, which runs the broker and has the least room.
        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "tsp.role"
                  operator = "In"
                  values   = ["data"]
                }
              }
            }
          }
        }

        container {
          name  = "redis"
          image = var.redis_image

          port {
            name           = "redis"
            container_port = 6379
          }

          resources {
            requests = { memory = "128Mi", cpu = "50m" }
            limits   = { memory = "256Mi", cpu = "500m" }
          }

          # Redis answers PING before it is useful for anything else, which is
          # exactly what a readiness probe wants to know.
          readiness_probe {
            exec { command = ["redis-cli", "ping"] }
            initial_delay_seconds = 3
            period_seconds        = 5
          }

          liveness_probe {
            tcp_socket { port = "6379" }
            initial_delay_seconds = 15
            period_seconds        = 20
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "redis" {
  metadata {
    name      = "redis"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }

  spec {
    type     = "ClusterIP"
    selector = { app = "redis" }
    port {
      name        = "redis"
      port        = 6379
      target_port = "redis"
    }
  }
}

# ------------------------------------------------------------------ backends

/**
 * Three backends from one resource, via for_each.
 *
 * They differ in exactly two things -- the image tag and the CORS origin -- so
 * writing them out three times would be three places to forget to change.
 * Compose has them as three near-identical blocks; this is the same shape said
 * once.
 *
 * Each keeps its own Service, because they are genuinely separate environments
 * that will eventually sit behind three different hostnames. Sharing a Service
 * would load-balance prod traffic onto dev.
 */
resource "kubernetes_deployment" "backend" {
  for_each = var.backends

  metadata {
    name      = "backend-${each.key}"
    namespace = kubernetes_namespace.platform.metadata[0].name
    labels    = { app = "backend", env = each.key }
  }

  spec {
    replicas = 1
    selector { match_labels = { app = "backend", env = each.key } }

    template {
      metadata { labels = { app = "backend", env = each.key } }
      spec {
        container {
          name  = "backend"
          image = "${var.backend_image}:${each.value.tag}"

          # Redis is reached by Service name rather than by address. The whole
          # point of moving in here: `redis` resolves within the namespace, and
          # keeps resolving when the pod is rescheduled onto another node.
          env {
            name  = "REDIS_URL"
            value = "redis://${kubernetes_service.redis.metadata[0].name}:6379"
          }

          env {
            name  = "CORS_ORIGINS"
            value = each.value.cors_origin
          }

          env {
            name  = "STORE_ROOT"
            value = "/data/trading-strategies"
          }

          env {
            name  = "IDE_WORKSPACE"
            value = "/workspace"
          }

          env {
            name  = "DATASET_ROOT"
            value = "/data/datasets"
          }

          port {
            name           = "http"
            container_port = 8000
          }

          resources {
            requests = { memory = "256Mi", cpu = "100m" }
            limits   = { memory = "512Mi", cpu = "1" }
          }

          # TCP, not an HTTP path. A readiness probe pointed at an endpoint
          # that does not exist never goes Ready, the Deployment never
          # completes, and the apply fails on a timeout naming nothing -- which
          # is exactly how the Strimzi entity operator cost an afternoon.
          readiness_probe {
            tcp_socket { port = "8000" }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          liveness_probe {
            tcp_socket { port = "8000" }
            initial_delay_seconds = 30
            period_seconds        = 20
          }

          # emptyDir, NOT a PVC. Phase 4 moves the data; this phase only proves
          # the containers start and talk to each other. The paths have to
          # exist or the process fails on a missing directory, but nothing in
          # them survives a restart and nothing is supposed to yet.
          volume_mount {
            name       = "store"
            mount_path = "/data/trading-strategies"
          }

          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }

          volume_mount {
            name       = "datasets"
            mount_path = "/data/datasets"
          }
        }

        volume {
          name = "store"
          empty_dir {}
        }

        volume {
          name = "workspace"
          empty_dir {}
        }

        volume {
          name = "datasets"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_service" "backend" {
  for_each = var.backends

  metadata {
    name      = "backend-${each.key}"
    namespace = kubernetes_namespace.platform.metadata[0].name
    labels    = { app = "backend", env = each.key }
  }

  spec {
    type     = "ClusterIP"
    selector = { app = "backend", env = each.key }
    port {
      name        = "http"
      port        = 8000
      target_port = "http"
    }
  }
}

# ------------------------------------------------------------------- sandbox

/**
 * Runs published indicator code on demand, invoked by the backend on :9000.
 *
 * It reads the registry that code-server writes, READ-ONLY. That read-only
 * mount is a security boundary rather than tidiness: this process executes
 * user-authored code, so it must not be able to modify the registry it is
 * executing from.
 *
 * In phase 3 that registry is an emptyDir, so there is nothing to execute yet.
 * The service exists so the backend has something to call and the wiring is
 * proven before phase 4 supplies real content.
 */
resource "kubernetes_deployment" "sandbox" {
  metadata {
    name      = "sandbox"
    namespace = kubernetes_namespace.platform.metadata[0].name
    labels    = { app = "sandbox" }
  }

  spec {
    replicas = 1
    selector { match_labels = { app = "sandbox" } }

    template {
      metadata { labels = { app = "sandbox" } }
      spec {
        container {
          name  = "sandbox"
          image = var.sandbox_image

          # Same entrypoint compose uses. The image has no default CMD that
          # serves HTTP, so without this it starts and does nothing.
          command = [
            "uvicorn", "tsp.worker:create_app", "--factory",
            "--host", "0.0.0.0", "--port", "9000",
          ]

          env {
            name  = "TSP_REGISTRY"
            value = "/work/registry"
          }

          port {
            name           = "http"
            container_port = 9000
          }

          resources {
            requests = { memory = "256Mi", cpu = "100m" }
            limits   = { memory = "1Gi", cpu = "1" }
          }

          readiness_probe {
            tcp_socket { port = "9000" }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          volume_mount {
            name       = "registry"
            mount_path = "/work"
            read_only  = true
          }
        }

        volume {
          name = "registry"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_service" "sandbox" {
  metadata {
    name      = "sandbox"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }

  spec {
    type     = "ClusterIP"
    selector = { app = "sandbox" }
    port {
      name        = "http"
      port        = 9000
      target_port = "http"
    }
  }
}
