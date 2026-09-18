/**
 * A read-only web console for Kafka.
 *
 * Typed Kubernetes resources rather than kubectl_manifest, which is the
 * opposite choice from the Kafka resources next door and deliberately so: a
 * Deployment, Service and ConfigMap are built-in types the provider can plan
 * against. Kafka had to be raw YAML only because its CRDs do not exist at plan
 * time. There is no reason to give up a real plan here.
 *
 * Redpanda Console rather than Kafka UI, AKHQ or Kafdrop, for one reason: it is
 * a Go binary and they are all JVM applications. It runs in ~128Mi where they
 * want 400-1000Mi, which on a node with 2490Mi allocatable is the difference
 * between a rounding error and a fifth of the machine. It speaks plain Kafka
 * and needs nothing Redpanda-specific.
 */

resource "kubernetes_config_map" "console" {
  metadata {
    name      = "kafka-console"
    namespace = kubernetes_namespace.kafka.metadata[0].name
  }

  # A mounted file rather than environment variables. Env var names drift
  # between major versions of this image; the config file is the documented
  # interface and reads as configuration rather than as incantation.
  data = {
    "config.yaml" = yamlencode({
      kafka = {
        brokers = ["${var.kafka_name}-kafka-bootstrap.${var.namespace}.svc:9092"]
      }
      server = {
        listenPort = 8080
      }
    })
  }
}

resource "kubernetes_deployment" "console" {
  # Not strictly required -- nothing here references the Kafka resource -- but
  # a console that starts before there is a cluster to inspect just logs
  # connection errors until one appears.
  depends_on = [kubectl_manifest.kafka]

  metadata {
    name      = "kafka-console"
    namespace = kubernetes_namespace.kafka.metadata[0].name
    labels    = { app = "kafka-console" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "kafka-console" }
    }

    template {
      metadata {
        labels = { app = "kafka-console" }
        # Roll the pod when the config changes. A ConfigMap update alone does
        # not restart anything, so without this a changed broker address is
        # applied to a file the running process has already read.
        annotations = {
          "tsp.config-hash" = sha256(kubernetes_config_map.console.data["config.yaml"])
        }
      }

      spec {
        # Onto the node this cluster set aside for exactly this kind of thing.
        # Without it the scheduler picks by free memory, and the console lands
        # next to the broker on the one node that has no room to spare.
        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "tsp.role"
                  operator = "In"
                  values   = [var.console_node_role]
                }
              }
            }
          }
        }

        container {
          name  = "console"
          image = "docker.io/redpandadata/console:${var.console_version}"

          env {
            name  = "CONFIG_FILEPATH"
            value = "/etc/console/config.yaml"
          }

          port {
            name           = "http"
            container_port = 8080
          }

          # Requests BELOW limits on purpose, which makes this Burstable rather
          # than Guaranteed -- the opposite of the broker, and for the opposite
          # reason. If the cluster runs short of memory this is the pod that
          # should be evicted FIRST. It is a web page; the broker holds the data.
          resources {
            requests = {
              memory = var.console_memory_request
              cpu    = "50m"
            }
            limits = {
              memory = var.console_memory_limit
              cpu    = "500m"
            }
          }

          # A TCP probe rather than an HTTP path.
          #
          # A readiness probe pointed at a health endpoint that moved between
          # versions never goes Ready, the Deployment never completes, and the
          # apply fails on a timeout that names nothing -- which is precisely
          # how the entity operator wasted an afternoon. "The port is open" is
          # less informative and cannot be wrong in that way.
          readiness_probe {
            tcp_socket { port = "8080" }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          liveness_probe {
            tcp_socket { port = "8080" }
            initial_delay_seconds = 30
            period_seconds        = 20
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/console"
            read_only  = true
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.console.metadata[0].name
          }
        }
      }
    }
  }
}

# ClusterIP, NOT NodePort.
#
# This console browses every message in every topic and has no authentication
# in this configuration. A NodePort would put that on the public internet next
# to the Kafka ports, guarded by nothing. Reach it deliberately instead:
#
#   kubectl -n kafka port-forward svc/kafka-console 8080:8080
#
# and open localhost:8080. Over the tailnet the same applies -- the service is
# reachable from inside the cluster network without any firewall rule.
resource "kubernetes_service" "console" {
  # Still ClusterIP. The operator does not change that -- it runs a proxy that
  # joins the tailnet and forwards to this Service, so nothing here is reachable
  # from outside the tailnet and no firewall port is opened.
  depends_on = [helm_release.tailscale_operator]

  metadata {
    name      = "kafka-console"
    namespace = kubernetes_namespace.kafka.metadata[0].name
    labels    = { app = "kafka-console" }

    # No tailscale.com/expose here any more -- see the Ingress below. That
    # annotation forwards the Service's own port, so the console answered on
    # :8080 and a browser trying 80/443 timed out. The Ingress puts Tailscale
    # Serve in front instead, which terminates HTTPS on 443.
  }

  spec {
    type     = "ClusterIP"
    selector = { app = "kafka-console" }

    port {
      name        = "http"
      port        = 8080
      target_port = "http"
    }
  }
}

/**
 * HTTPS on the tailnet, without a port.
 *
 * The Service annotations this replaces put the console on the tailnet at its
 * own port -- :8080 -- because that is what they forward. Correct, and
 * unmemorable: a browser defaults to 443 and times out against a machine that
 * is working perfectly.
 *
 * ingressClassName "tailscale" hands the Service to Tailscale Serve, which
 * listens on 443, terminates TLS with a certificate Tailscale issues for the
 * MagicDNS name, and forwards inward. The result is a URL with nothing after
 * the hostname.
 *
 * REQUIRES HTTPS certificates enabled for the tailnet (admin console -> DNS ->
 * HTTPS Certificates). Without it the proxy comes up, the machine appears, and
 * the certificate never issues -- the failure looks like a hang rather than a
 * missing setting.
 *
 * The name comes from tls.hosts rather than an annotation: for a Tailscale
 * Ingress that field IS the machine name, which is why there is no host on the
 * rule below.
 */
resource "kubernetes_ingress_v1" "console" {
  depends_on = [helm_release.tailscale_operator]

  metadata {
    name      = "kafka-console"
    namespace = kubernetes_namespace.kafka.metadata[0].name
  }

  spec {
    ingress_class_name = "tailscale"

    default_backend {
      service {
        name = kubernetes_service.console.metadata[0].name
        port {
          number = 8080
        }
      }
    }

    tls {
      hosts = [var.console_tailnet_hostname]
    }
  }
}
