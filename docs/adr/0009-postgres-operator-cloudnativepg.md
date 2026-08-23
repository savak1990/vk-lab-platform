# ADR 0009: PostgreSQL operator — CloudNativePG

## Status

Accepted

## Context

Spec 007 requires an in-cluster, operator-managed PostgreSQL deployment
(architecture.md §13's "operator-managed" option, not RDS) and requires the
choice between candidate operators be recorded with rationale, per
constitution §13.

## Decision

**Use CloudNativePG (CNPG)**, not Zalando's postgres-operator.

- CNPG is a CNCF Sandbox project with materially higher release velocity than
  Zalando's operator as of 2025-2026, and is the operator most commonly
  recommended for new Postgres-on-Kubernetes builds.
- CNPG publishes official multi-arch (amd64 + arm64) operand images for every
  supported Postgres/Debian combination. This cluster's system and Karpenter
  node pools are arm64-only (Graviton, per the switch that landed in commit
  `4279365`), so first-class arm64 support is a hard requirement here, not a
  nice-to-have.
- CNPG defaults `wal_level` to `logical` (not `replica`), which satisfies
  Requirement 4's Debezium (spec 024) prerequisite with no override needed.
- CNPG's single-CRD (`Cluster`) model is simpler than Patroni/Spilo's extra
  moving parts, which matters more, not less, on a resource-constrained
  shared node.

**Rejected alternative: Terraform-owned EBS volume with a static PV/PVC**,
instead of CNPG's dynamically-provisioned PVC on the existing `ebs-retain`
StorageClass (spec 005 / ADR 0008). Requirement 7 requires grow-only resize
declared through the CR; a Terraform-declared volume size diverges from real
state the moment CNPG/CSI expands the volume, and since EBS cannot shrink,
Terraform's only resolution is to propose destroying and recreating the
volume — unacceptable for the volume holding live data.
`lifecycle { ignore_changes = [size] }` would avoid that, but defeats the
purpose of Terraform owning the resource in the first place. Dynamic
provisioning plus the existing Retain-based storage contract already
delivers the "data survives a restart" goal this alternative was proposed to
solve, at lower cost and with zero Terraform changes.

**Revisited under a different goal — see ADR 0010.** This rejection was
correct for the goal evaluated here (persistence itself). A separate goal
— automating what was otherwise a manual "find the volume ID after every
recreate" step — turned out to be answered by the same `ignore_changes`
mechanism noted above, without reintroducing the failure mode this section
rejected it for. ADR 0010 records that reversal; this section's original
reasoning stands unchanged as the record of what was true at the time.

## Scope narrowing for this pass (deliberate, not an oversight)

- **`local` target is out of scope.** Spec 007 describes running the same
  operator/CR on a future `local` target (spec 021) with a `Delete`-reclaim
  StorageClass, but spec 021 is not implemented yet — no
  `gitops/templates/platform/local/` tree or local Makefile targets exist on
  disk. This spec builds the `aws` path only; the Postgres Application and
  Cluster CR live under `gitops/templates/platform/aws/postgres/`, matching
  `karpenter`/`ebs-csi`'s existing `aws`-only convention, rather than the
  both-target ungated shape a spec-020-aware version would need. Revisit when
  spec 021 lands.
- **Resource requests/limits are deliberately unset for this pass.** Sizing
  the Postgres pod against real node capacity requires a live cluster to
  measure against (`kubectl describe node`); guessing numbers before that
  measurement exists just to fill the field would be worse than leaving it
  unset. `shared_buffers`/`max_connections` are left at Postgres defaults for
  the same reason — CNPG does not auto-derive these from resource limits, so
  they only need explicit values once real limits exist to size them
  against. A follow-up pass sets both once the cluster is up and measured.

## Consequences

- Zero Terraform changes for this spec; all persistence is gitops + the
  existing `ebs-retain` StorageClass.
- CNPG's Cluster CR takes over the `spec.storage.size` field for grow-only
  resize (Requirement 7) — confirmed online, no pod restart required, when
  the StorageClass supports online expansion, which `ebs-retain` does
  (`allowVolumeExpansion: true`).
- Destroy/recreate recovery (Requirement 2) does **not** reuse ADR 0008's
  generic hand-written-PV+PVC rebind procedure. CNPG creates and labels its
  own data PVC (`cnpg.io/pvcRole`, `cnpg.io/cluster`, `cnpg.io/instanceName`)
  at reconcile time and does not adopt a foreign PVC that merely carries the
  right labels — there is no "PVC adoption"/"instance re-attach" mechanism
  in CNPG. Its three supported `recovery` bootstrap sources (Barman
  object-store, VolumeSnapshot, existing `Backup` object) all build a *new*
  cluster from a physical backup, none of which apply here since this spec
  deliberately excludes a backup pipeline (non-goal per architecture.md §4).
  The supported mechanism for this exact scenario — only a raw, retained EBS
  volume survives, no WAL archive/Barman/snapshot — is CNPG's own **static
  provisioning of persistent volumes**: hand-write a `PersistentVolume`
  against the retained volume's `volumeHandle` (same AZ-pinning approach as
  ADR 0008), then the `Cluster` CR's `pvcTemplate` lets the
  operator-created PVC bind to that specific PV. CNPG's own docs discourage
  this pattern for production generally (it breaks the fully
  declarative/self-healing model) but document it as the supported route for
  exactly this situation.
- The static `PersistentVolume` used for recovery must live inside the gitops
  tree (templated, gated on an empty-by-default values key), not be applied
  out-of-band with `kubectl`. The Postgres Application uses
  `syncPolicy.automated.selfHeal: true`; on a fresh cluster, Argo syncs the
  Cluster CR the instant the CNPG CRD registers, and if the recovery PV isn't
  already in place at that moment, CNPG's PVC dynamically provisions a
  brand-new empty volume and `initdb` runs against it — reporting `Healthy`
  in Argo with zero recovered data. Templating the PV at sync-wave `0`
  (ahead of the Cluster CR's wave `1`) makes recovery declarative instead of
  a race against a self-healing controller.
- `spec.storage.size` remains authoritative for resize even when
  `pvcTemplate` is also set (confirmed from CNPG source,
  `GetSizeOrNil()` in `cluster_funcs.go`) — `pvcTemplate`'s own
  `resources.requests.storage` is only a fallback read when `size` is empty,
  with no admission check flagging a mismatch between the two. `size` must
  therefore always be set explicitly, on both the fresh-install and
  recovery paths.
- Whether CNPG's instance manager starts against an already-initialized
  PGDATA on a `pvcTemplate`-bound pre-existing volume, versus running
  `initdb` and overwriting it, is not settled by CNPG's documentation (the
  closest thing to guidance is an open, maintainer-unanswered GitHub
  discussion). This must be verified empirically, on a throwaway volume,
  before the real destroy/recreate acceptance proof runs on data that
  matters.
- Per ADR 0008, the retained Postgres EBS volume this spec creates inherits
  that ADR's accountability path: deletion happens only via
  `make persistent-down`, not a separate mechanism, once this data is
  genuinely meant to go away.
- **Identifying which retained volume is Postgres's, once other components
  (Kafka, spec 008) share the same `ebs-retain` StorageClass**: the
  StorageClass's own tags (`Project`, `Scope`, `Lifecycle`, `ManagedBy`) are
  identical for every volume it provisions and cannot distinguish
  Postgres's volume from any other retained volume on the same class. Adding
  a component-specific tag at the StorageClass level isn't viable either —
  StorageClass parameters are shared by every PVC referencing that class.
  Instead, rely on the EBS CSI driver's `controller.extraCreateMetadata`
  setting, which is `true` by default in the chart version pinned here and
  not overridden off: it auto-tags every dynamically-provisioned volume with
  `kubernetes.io/created-for/pvc/name` and `.../pvc/namespace`. CNPG names
  its data PVC after the instance pod (e.g. `lab-postgres-1`, namespace
  `cnpg-system`), so filtering `aws ec2 describe-volumes` by that tag
  uniquely identifies the Postgres volume with no extra configuration
  needed. Confirm the exact PVC name against a live cluster before relying
  on it in a real recovery.

**Update, 2026-08-22:** the empirical verification this ADR called for
above happened, and the answer is the failure mode it warned about — CNPG
does not adopt the existing PGDATA on the static `PersistentVolume`; it
quarantines it (renames aside with a timestamp suffix) and runs `initdb`
fresh on every `cluster-down`/`cluster-up` cycle. See spec 007-1 for
the confirmed root cause and the candidate replacement design
(`bootstrap.recovery.volumeSnapshots`). This ADR's static-PV/`pvcTemplate`
decision is superseded there, not rewritten here — it was reasonable given
what was known at the time.
