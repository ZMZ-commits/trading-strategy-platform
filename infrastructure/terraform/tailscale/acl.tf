/**
 * The tailnet access policy.
 *
 * Kept in acl.hujson rather than inline, for two reasons: it is the format
 * Tailscale's own editor uses, so it can be pasted either way without
 * translation; and a policy change shows up in a PR as a diff of the policy
 * rather than a diff of a Terraform string.
 *
 * This resource owns the WHOLE file. Terraform does not merge -- anything
 * absent here is removed from the tailnet on apply. That is why the first
 * version of this file was taken verbatim from the live policy and imported,
 * so the opening plan reported no changes before anything was entrusted to it.
 *
 * What is at stake if this is wrong, concretely:
 *
 *   tag:ci      -> CI reaches 10.0.1.0/24:22,6443. Remove it and the pipeline
 *                  can no longer apply anything, including the fix.
 *   tag:router  -> autoApprovers for 10.0.1.0/24. Remove it and a rebuilt
 *                  subnet router advertises routes nobody approves, and the
 *                  tailnet stops reaching the cluster.
 *
 * Both failures are recoverable only from the web console, by hand.
 */

resource "tailscale_acl" "this" {
  acl = file("${path.module}/acl.hujson")

  # Refuse to clobber a policy Terraform has not been told about. With this
  # false, an apply against an unimported tailnet would replace whatever is
  # live with the contents of this file, which is precisely the accident the
  # import exists to prevent.
  overwrite_existing_content = false
}
