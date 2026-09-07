output "server_ip" {
  description = "Public IPv4 of the k3s node."
  value       = hcloud_server.k3s.ipv4_address
}

output "fetch_kubeconfig" {
  description = <<-EOT
    Run this once cloud-init has finished, to bring the cluster credentials
    down to your machine. The sed is not optional: k3s writes 127.0.0.1 as the
    server address, which is correct on the node and useless from here.
  EOT
  value = join(" ", [
    "ssh root@${hcloud_server.k3s.ipv4_address}",
    "'until [ -f /var/lib/cloud/k3s-ready ]; do sleep 5; done;",
    "cat /etc/rancher/k3s/k3s.yaml'",
    "| sed 's/127.0.0.1/${hcloud_server.k3s.ipv4_address}/'",
    "> ../k8s/kubeconfig.yaml",
  ])
}

output "next_step" {
  value = "Run the fetch_kubeconfig command, then: cd ../k8s && terraform init && terraform apply"
}
