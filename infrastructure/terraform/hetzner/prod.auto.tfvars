# Non-secret values that define this environment. Tracked deliberately.
#
# Terraform loads *.auto.tfvars automatically, so this applies identically on a
# laptop and on a GitHub runner. That is the entire point: CI passes only
# hcloud_token, admin_cidrs, tailscale_auth_key and connect_via as TF_VAR_*, so
# every other variable takes its default there. A value set only in the
# untracked terraform.tfvars therefore survives locally and is reverted by the
# next CI apply -- silently, and for data_volume_gb destructively.
#
# Secrets do NOT belong here. This file is committed; terraform.tfvars is not.

# Kafka's external listener, so a producer outside the cluster can reach it.
#
# Both are required and opening only the first is a trap: a client bootstraps on
# 30092, receives metadata naming a SEPARATE per-broker port, and then fails
# against a port nobody opened -- which reads as a dead broker rather than a
# firewall rule. 30093 is broker 0 (external_node_port + 1 + index).
#
# Raising broker_count means adding a port here for each new broker.
public_tcp_ports = ["30092", "30093"]

# Zero on purpose, and stated rather than left to the default.
#
# The volume is the only resource in this stack that costs money and that
# Terraform can actually destroy -- the servers are `data` sources with no
# destroy verb. Writing it down means a future change to it is a visible diff
# rather than a default quietly changing underneath a plan.
data_volume_gb = 0

# Who may reach public_tcp_ports (Kafka's external listener).
#
# The VM at 37.27.41.226 runs the data pipeline and is the only external
# producer. The listener has no TLS and no authentication, so this list is the
# only thing standing between the broker and the internet.
#
# Shrinks to nothing when the pipeline moves into the cluster and uses
# tsp-kafka-bootstrap.kafka.svc:9092 instead.
public_tcp_source_ips = ["37.27.41.226/32"]
