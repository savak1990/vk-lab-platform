# 005 — Storage Contract

**Complexity:** Medium
**Risk:** High — this is the linchpin persistence-safety spec. Every later stateful workload (Postgres, Kafka) trusts this to be correct; the failure mode is silent, delayed data loss, not an immediate error.
**Estimated cost:** ~1–2 days, including an actual destroy/recreate proof test · AWS runtime cost: EBS volume cost only (small test volume).
**Recommended model:** Opus — subtle AWS EBS/CSI reclaim-policy semantics, high blast radius if reasoning is wrong.
**Depends on:** 004-argocd-bootstrap (need Argo to deploy the CSI driver and a test workload the GitOps way)
**Lifecycle class(es) touched:** Disposable (the CSI driver, StorageClass, and PVC objects) / Persistent (the underlying EBS volume data, once retained)

## Scope

Proves, before any real database or message broker exists, that a Kubernetes-backed persistent volume genuinely survives EKS destruction and recreation:

- AWS EBS CSI driver, installed via Argo CD (constitution §2 — this is a controller, Argo-owned).
- A `StorageClass` with a non-destructive reclaim policy (`Retain`, not `Delete`) for anything intended to persist.
- A throwaway test `StatefulSet`/`PVC` used only to prove the reclaim/rebind contract — deleted once the proof is documented, not a long-lived component.

This spec, and its `Retain`-reclaim-policy/EBS-rebind requirements below, apply to the `aws` target only. The `local` target (spec 021) uses the cluster's default local StorageClass (hostpath/local-path) with `Delete` reclaim semantics instead — the deliberate inverse of Requirement 2 below — since local data is fully throwaway and needs no rebind procedure.

Excludes: the actual Postgres (007) and Kafka (024) deployments — this spec only proves the underlying mechanism they'll rely on.

## Requirements

1. Kubernetes resources may disappear, but the underlying AWS EBS data MUST remain — architecture.md §16's "Persistent Storage Contract" in full.
2. Destructive reclaim policies (`Delete`) MUST NOT be used for any storage class backing data intended to persist (constitution §4).
3. The PV/PVC lifecycle (what happens to the EBS volume when the PVC is deleted, when the node is replaced, when the whole cluster is destroyed and recreated) MUST be explicitly tested here, not assumed from Kubernetes semantics alone — constitution §4 explicitly warns "persistence assumptions MUST be verified against actual AWS resources, not only Kubernetes objects."
4. The process for recreating a cluster and rebinding/restoring a retained EBS volume to a new PVC MUST be documented as part of this spec's output, since spec 007 and 024 will follow this exact procedure for real data.
5. The EBS CSI driver is a controller and MUST be installed via Argo CD, not Terraform (constitution §2, §7).
6. Every `StorageClass` backing a persistent workload MUST set `allowVolumeExpansion: true` — EBS/its CSI driver support online (in-place) volume growth, and capacity increases MUST NOT require volume replacement, a new PVC, or data migration. This is grow-only: shrinking a volume is not supported and is out of scope. The consumer-facing resize procedure (e.g., the Postgres operator CR field that triggers it) is documented per-workload in spec 007.

## Implementation hints

- Two storage classes may be worth defining: one `Retain`-based for anything meant to survive (Postgres, Kafka data), and — only if genuinely needed — a `Delete`-based one for throwaway/scratch storage, so the distinction is explicit in code rather than implicit in developer memory. Both should use the `gp3` EBS volume type and set `allowVolumeExpansion: true`.
- The proof procedure: create PVC via the `Retain` StorageClass → write test data → delete the PVC (not just the pod) → confirm the EBS volume still exists in AWS (not just "Released" in Kubernetes) → manually create a new PV pointing at the same `volumeHandle` → bind a new PVC to it → confirm the data reads back correctly.
- Repeat the same proof across a full `terraform destroy`/`apply` of the disposable EKS cluster, not just a PVC delete/recreate within the same cluster — a surviving PVC inside a running cluster does not prove the EBS volume survives EKS being destroyed and rebuilt (this is exactly the constitution §4 distinction between Kubernetes objects and actual AWS resources).
- Document the rebind procedure (manual PV recreation with the retained volume's ID, or a controller-assisted approach) clearly enough that spec 007/024 can follow it verbatim for real Postgres/Kafka volumes.

## Testing / acceptance criteria

- Full lifecycle-style proof required, even at this early, throwaway-workload stage, because this is exactly the invariant the constitution's full lifecycle test (§11) exists to check: CREATE → WRITE test data → DESTROY (EKS, not just the pod/PVC) → VERIFY the EBS volume persisted → RECREATE (new EKS) → VERIFY the data is recoverable via the documented rebind procedure.
- The test workload is deleted once the proof is documented — it is not a long-lived platform component.
- Fast validation applies to the CSI driver's Argo manifests as usual (Helm render, k8s schema validation).
