output "server_ip" {
  description = "Public IPv4 of the control-plane machine. This is what kubectl talks to."
  value       = data.hcloud_server.server.ipv4_address
}

output "agent_ips" {
  description = "Public IPv4 of each agent, keyed by role."
  value       = { for n, a in var.agent_roles : a.role => data.hcloud_server.agent[n].ipv4_address }
}

output "private_ips" {
  description = "Private addresses assigned by this stack. The cluster talks over these, not the public ones."
  value = merge(
    { (var.server_role) = local.server_private_ip },
    { for n, a in var.agent_roles : a.role => local.agent_private_ips[n] },
  )
}

# ---------------------------------------------------------------- kubeconfig

output "fetch_kubeconfig" {
  description = <<-EOT
    Bring the cluster credentials down to your machine. Run once, after apply.

    The sed is not optional: k3s writes 127.0.0.1 as the server address, which
    is correct on the node and useless from anywhere else.

    This is the one step Terraform does not do for you. It could -- but writing
    a file full of cluster-admin credentials into your working directory as a
    side effect of `apply` is a decision worth making on purpose.
  EOT
  value = join(" ", [
    "ssh -i ${var.ssh_private_key_path} root@${data.hcloud_server.server.ipv4_address}",
    "'cat /etc/rancher/k3s/k3s.yaml'",
    "| sed 's/127.0.0.1/${data.hcloud_server.server.ipv4_address}/'",
    "> ../k8s/kubeconfig.yaml",
  ])
}

# -------------------------------------------------------------- verification

output "verify" {
  description = "What a healthy cluster looks like. Run after fetch_kubeconfig."
  value       = <<-EOT

    export KUBECONFIG=$PWD/../k8s/kubeconfig.yaml

    kubectl get nodes -L tsp.role
      -> ${1 + length(var.agent_roles)} nodes, all Ready, labelled:
         ${var.server_role}${join("", [for n, a in var.agent_roles : ", ${a.role}"])}

    kubectl describe node | grep -A6 Allocatable
      -> capacity MINUS the reservations, not the whole machine.
         These are 3814 MB boxes, so expect roughly:
           ${var.server_role}  ~1.9 GB allocatable
           agents  ~2.4 GB allocatable each
         If a node reports its full memory, the --kubelet-arg flags did not
         take and that node needs reinstalling.

  EOT
}

output "add_a_node" {
  description = "How to grow the cluster."
  value       = <<-EOT
    1. Create the server in the Hetzner console.
    2. Add one line to agent_roles in terraform.tfvars, e.g. "new-box" = "apps"
    3. terraform apply

    Terraform attaches the private network, applies the firewall, installs k3s
    with the right label and reservations, and joins it. No SSH by hand.
  EOT
}
