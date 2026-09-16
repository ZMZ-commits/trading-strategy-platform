/**
 * Remote state on Cloudflare R2, same bucket as stack 1, different key.
 *
 * Same reasoning as there: a GitHub runner is destroyed after every job, so
 * state on its disk is state that does not exist. Without this, a CI run would
 * see no Strimzi and offer to install a second one.
 *
 * Separate key rather than a separate bucket because they are separate state
 * files, not separate credentials. One `terraform apply` in hetzner/ must not
 * be able to lock or corrupt this one, which distinct keys give you -- the lock
 * is per-object.
 */

terraform {
  backend "s3" {
    bucket = "tsp-tfstate"
    key    = "k8s/terraform.tfstate"

    region = "auto"

    endpoints = {
      s3 = "https://6ca4b7fdec05454e6f55567122735dca.r2.cloudflarestorage.com"
    }

    # Terraform writes <key>.tflock with an If-None-Match conditional PUT, so a
    # second apply cannot start while one is running. Verified working against
    # R2 when stack 1 migrated.
    use_lockfile = true

    # "You are not talking to AWS." Each of these is a call the SDK would
    # otherwise make to a service that is not there -- STS, IAM, the region
    # list, EC2 instance metadata. Left on they do not fail fast; they hang
    # until a timeout and then name a service you are not using.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true

    # R2 rejects the newer checksum headers the AWS SDK adds by default, with an
    # error that reads like a permissions problem rather than a compatibility
    # one.
    skip_s3_checksum = true
  }
}

# Credentials come from the environment (AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY) or ~/.aws/credentials. Named for the S3 protocol, not
# for AWS -- nothing here talks to Amazon.
