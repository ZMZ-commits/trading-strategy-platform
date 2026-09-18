/**
 * Stack 3 of 3 -- the tailnet itself.
 *
 * Remote state on R2 beside the other two, under its own key. Separate key
 * rather than a separate bucket for the same reason as the others: these are
 * separate state files, not separate credentials, and the lock is per-object,
 * so an apply here cannot block or corrupt the cluster stacks.
 *
 * A SEPARATE STACK rather than more resources in hetzner/, deliberately. This
 * one owns the access control policy -- the thing that decides whether CI can
 * reach the cluster at all. Mixing it into the stack CI applies would mean a
 * single plan could both cut off the runner and be the thing the runner was
 * running. Distinct state keeps the blast radius where it can be reasoned about.
 */

terraform {
  backend "s3" {
    bucket = "tsp-tfstate"
    key    = "tailscale/terraform.tfstate"

    region = "auto"

    endpoints = {
      s3 = "https://6ca4b7fdec05454e6f55567122735dca.r2.cloudflarestorage.com"
    }

    use_lockfile = true

    # "You are not talking to AWS." Each of these is a call the SDK would
    # otherwise make to a service that is not there, and left on they do not
    # fail fast -- they hang and then name a service you are not using.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true

    # R2 rejects the newer checksum headers the AWS SDK adds by default, with
    # an error that reads like a permissions problem rather than a
    # compatibility one.
    skip_s3_checksum = true
  }
}
