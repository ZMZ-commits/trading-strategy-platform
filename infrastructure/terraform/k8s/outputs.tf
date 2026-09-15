output "bootstrap_internal" {
  description = "For anything running inside the cluster."
  value       = "${var.kafka_name}-kafka-bootstrap.${var.namespace}.svc:9092"
}

output "bootstrap_external" {
  description = "For the scraper and your laptop. Requires the NodePort open in the stack-1 firewall."
  value       = "<server_ip>:${var.external_node_port}"
}

output "verify" {
  description = "Prove it works before pointing anything at it."
  value = join("\n", [
    "kubectl -n ${var.namespace} get kafka,kafkanodepool,kafkatopic",
    "kubectl -n ${var.namespace} get pods -w",
    "kubectl -n ${var.namespace} run probe --rm -it --image=quay.io/strimzi/kafka:latest-kafka-${var.kafka_version} --restart=Never -- bin/kafka-topics.sh --bootstrap-server ${var.kafka_name}-kafka-bootstrap:9092 --list",
  ])
}
