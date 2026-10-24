/**
 * Phase 4 of docs/K8S_MIGRATION.md -- PersistentVolumeClaims for the data.
 *
 * THE CONSTRAINT THAT SHAPES THIS FILE
 *
 * The only StorageClass here is local-path, which is ReadWriteOnce: a volume is
 * a directory on ONE node's disk, and a pod anywhere else cannot see it. The
 * workspace is mounted by four pods -- three backends and the sandbox -- and
 * before this change they were spread across three nodes.
 *
 * So the pods are pinned to one node. The migration doc predicted this and
 * warned it "will fail in a way that looks like a scheduling problem rather
 * than a storage one": the PVC binds to whichever node claims it first, the
 * other pods stay Pending with an affinity-conflict message, and nothing says
 * the word storage.
 *
 * WHAT PINNING COSTS, PLAINLY
 *
 * No spreading. Lose that node and all three backends and the sandbox go with
 * it, where today they survive one node dying. That is a real reduction, and it
 * is accepted because the alternative -- Longhorn or an NFS provisioner for
 * genuine ReadWriteMany -- is a replicated storage system on a cluster with
 * 9.1Gi of allocatable memory total, of which Kafka already holds 1.5Gi.
 *
 * It also matches what exists today: one VM, one failure domain. This is not
 * worse than production, it just is not better.
 *
 * Revisit when the cluster is bigger, or when the workspace stops being shared.
 */

locals {
  # Mounted by three backends and the sandbox.
  workspace_pvc = "workspace"
}

resource "kubernetes_persistent_volume_claim" "workspace" {
  metadata {
    name      = local.workspace_pvc
    namespace = kubernetes_namespace.platform.metadata[0].name
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = { storage = var.workspace_pvc_size }
    }
  }

  # local-path binds WaitForFirstConsumer -- the volume is not created until a
  # pod actually schedules. Terraform waits for Bound by default, so leaving
  # this true means the apply hangs until it times out, on a PVC that is
  # behaving correctly.
  wait_until_bound = false
}

# Per-environment, so each is mounted by exactly one pod and ReadWriteOnce is
# no constraint at all. They are pinned only as a side effect of their pod
# being pinned for the workspace.
resource "kubernetes_persistent_volume_claim" "store" {
  for_each = var.backends

  metadata {
    name      = "store-${each.key}"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = { storage = var.store_pvc_size }
    }
  }

  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim" "datasets" {
  for_each = var.backends

  metadata {
    name      = "datasets-${each.key}"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = { storage = var.dataset_pvc_size }
    }
  }

  wait_until_bound = false
}
