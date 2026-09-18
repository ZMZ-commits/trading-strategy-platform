/**
 * Puts cluster Services onto the tailnet as machines of their own.
 *
 * The alternative was advertising the service range (10.43.0.0/16) from the
 * subnet router, which is one flag. It was rejected for two reasons: it gives
 * addresses rather than names, and -- decisively -- the router's provisioner
 * connects over the PUBLIC path by design, which the firewall admits only from
 * admin_cidrs. CI cannot apply a router change at all. This runs as ordinary
 * pods, so the pipeline owns it end to end.
 *
 * What it buys beyond a bookmark: the console has no authentication of its own
 * and browses every message in every topic. On the tailnet, Tailscale identity
 * IS the authentication -- a device that is not in your tailnet cannot resolve
 * the name, let alone reach it.
 */

resource "kubernetes_namespace" "tailscale" {
  metadata {
    name = "tailscale"
  }
}

resource "helm_release" "tailscale_operator" {
  name       = "tailscale-operator"
  repository = "https://pkgs.tailscale.com/helmcharts"
  chart      = "tailscale-operator"
  version    = var.tailscale_operator_version
  namespace  = kubernetes_namespace.tailscale.metadata[0].name

  # The operator must be running before an exposed Service means anything --
  # the annotation is inert until something is watching for it.
  wait          = true
  wait_for_jobs = true
  timeout       = 600

  # Roll back a failed install rather than leaving one behind, the same as the
  # Strimzi release: three dead revisions accumulated there during a failed
  # upgrade, each one state the next run had to reason about.
  atomic          = true
  cleanup_on_fail = true

  # An OAuth client, not a pre-auth key. The operator mints its own keys as it
  # creates devices, so a key would have to be rotated and re-pasted forever;
  # an OAuth client secret does not expire.
  #
  # set_sensitive rather than set, so the value is redacted in plan output and
  # in the job log rather than printed to anyone with repo access.
  set_sensitive {
    name  = "oauth.clientId"
    value = var.ts_oauth_client_id
  }

  set_sensitive {
    name  = "oauth.clientSecret"
    value = var.ts_oauth_client_secret
  }

  # Onto the observability node with the console, rather than competing with
  # the broker for the ~700Mi left on the stream node.
  #
  # A values block rather than `set`, because the key itself contains a dot --
  # `tsp.role` -- and Helm's dotted-path syntax would read that as nesting.
  # Escaping it works and is unreadable; yamlencode sidesteps the question.
  values = [yamlencode({
    operatorConfig = {
      nodeSelector = {
        "tsp.role" = var.console_node_role
      }
    }
  })]
}
