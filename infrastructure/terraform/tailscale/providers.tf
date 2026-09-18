terraform {
  required_version = ">= 1.5"
  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.29"
    }
  }
}

/**
 * Credentials come from the environment, never from a variable.
 *
 *   TAILSCALE_OAUTH_CLIENT_ID
 *   TAILSCALE_OAUTH_CLIENT_SECRET
 *
 * An OAuth client rather than an API access token because access tokens expire
 * after 90 days at most. An expiring credential in CI is a pipeline that breaks
 * one morning for a reason nobody remembers -- which is exactly the trap the
 * hand-pasted auth keys in the hetzner stack are already sitting in.
 */
provider "tailscale" {}
