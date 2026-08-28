# 007-1 — Postgres Persistence Recovery (initdb doesn't reuse the retained volume)

**Status:** Implemented

**Complexity:** High
**Risk:** High — this is the platform's core persistence promise (constitution §4, spec 007 Requirement 2) empirically failing; every `cluster-down`/`cluster-up` cycle currently discards the previous cycle's data.
**Estimated cost:** ~1–2 days, including a real destroy/recreate proof against non-trivial data.
**Recommended model:** Opus — evaluating CNPG's recovery bootstrap sources and the VolumeSnapshot infrastructure they need is comparable in ambiguity to the original operator-selection work in spec 007.
**Depends on:** 007-postgres (the static-PV/`pvcTemplate` mechanism this spec replaces), ADR 0009, ADR 0010
**Lifecycle class(es) touched:** Disposable (the Cluster CR's bootstrap mechanism, a new snapshot lifecycle step) / Persistent (VolumeSnapshots, if that's the chosen fix, would be Persistent-lifecycle data alongside the EBS volume itself)

## Scope

Fixes the gap ADR 0009 flagged as unresolved and unverified — *"Whether CNPG's instance manager starts against an already-initialized PGDATA on a `pvcTemplate`-bound pre-existing volume, versus running `initdb` and overwriting it, is not settled by CNPG's documentation... This must be verified empirically, on a throwaway volume, before the real destroy/recreate acceptance proof runs on data that matters."* That verification has now happened, empirically, and the answer is the failure mode ADR 0009 warned about.

This spec covers:

- Documenting the confirmed root cause and the evidence for it.
- Evaluating CNPG's actual supported mechanisms for starting a new Cluster object from existing PGDATA bytes (not the static-PV/`initdb` approach spec 007 shipped with).
- A concrete replacement design, with acceptance criteria that only pass if data genuinely survives a real `cluster-down`/`cluster-up` cycle — not just "the volume exists" (spec 007's Requirement 2 was already written to require this; this spec is what actually makes it true).

Out of scope: any change to Karpenter/Argo teardown ordering (spec 006-1/ADR 0012 — orthogonal, already fixed); introducing a full backup/DR pipeline (Barman Cloud, continuous WAL archiving, cross-region anything) — that remains a non-goal per architecture.md §4 ("enterprise disaster recovery"). The mechanism this spec needs is a single recovery point per disposable-lifecycle boundary, not continuous backup.

## Problem

Spec 007 (ADR 0009) chose CNPG's **static PersistentVolume + `pvcTemplate`** mechanism to reattach the Terraform-owned, retained EBS volume (ADR 0010) across `cluster-down`/`cluster-up` cycles: hand-write a `PersistentVolume` against the volume's `volumeHandle`, let the operator-created PVC bind to it via `pvcTemplate`, and hope CNPG's `bootstrap.initdb` recognizes the existing PGDATA rather than reinitializing it.

It does not. Empirically confirmed on a live cluster (2026-08-22): after a `CREATE TABLE proof` written the previous day, followed by intervening `cluster-down`/`cluster-up` cycles (with no `persistent-down` — the EBS volume itself, `vol-0e2e01eb971e6be59`, was never destroyed), the same volume's mounted filesystem showed:

```text
/var/lib/postgresql/data/
├── pgdata                          (current, live — fresh, empty vkdb)
├── pgdata_20260821T184245Z         (144M — a full, valid PGDATA generation)
└── pgdata_20260822T130906Z         (112M — a second full generation, from an earlier cycle today)
```

`pgdata_20260821T184245Z/base/16385` — a non-default database OID (not one of the built-in `template0`/`template1`/`postgres` OIDs) — is present and intact. **The data is not destroyed; it is quarantined.** CNPG's pre-flight directory check (confirmed present in the pinned operator version, 1.30.0, via its own release notes: *"protects statically provisioned PVCs from being silently overwritten"*) does not error out and does not adopt existing data — it renames the unrecognized directory aside with a timestamp suffix and runs a fresh `initdb` into a new, empty `pgdata`.

The reason CNPG doesn't recognize the data as its own: CNPG's genuine PVC-reuse guarantee — *"when a pod needs to be recreated... the operator intelligently reuses the existing PersistentVolumeClaim if available"* — operates at the **Kubernetes PVC object** level, within one continuously-running cluster (pod eviction, node failure, etc.). `cluster-down` destroys the entire EKS cluster; every PVC object is gone with it. Each `cluster-up` creates a brand-new Cluster CR and a brand-new PVC (via `pvcTemplate`, bound by us to the same physical volume by ID) — from CNPG's perspective this is unconditionally "first bootstrap of a new Cluster," with no PVC history to reuse, regardless of what bytes are already on the disk it happens to attach to. Static-PV/`pvcTemplate` solves *where the bytes physically live*; it does not solve *whether CNPG treats them as continuous*.

This means every `cluster-down` → `cluster-up` cycle today silently discards the previous cycle's data into a new quarantine directory and starts fresh — the exact opposite of spec 007 Requirement 2 and the entire point of ADR 0010's Terraform-owned volume.

## Potential solution

CNPG has three built-in `bootstrap.recovery` sources, all of which start a *new* Cluster object from *existing* data rather than running `initdb` against it — the mechanism ADR 0009 needed but didn't have verified evidence for at the time:

1. **Barman Cloud (object-store WAL archive + base backup)** — rejected: this is the continuous backup pipeline architecture.md §4 excludes as a non-goal, and needs an S3 bucket, retention policy, and WAL-archiving sidecar this platform doesn't otherwise want.
2. **An existing `Backup` object** — same rejection; implies a Barman-based backup pipeline exists.
3. **`VolumeSnapshot`** (`bootstrap.recovery.volumeSnapshots.storage`) — **the candidate worth evaluating.** CNPG's recovery API (`DataSource.Storage`, a `corev1.TypedLocalObjectReference`) explicitly accepts either a `VolumeSnapshot` or, per CNPG's own webhook validation, a plain `PersistentVolumeClaim` as the recovery source — no Barman/WAL-archive/`externalClusters` block is required when only `volumeSnapshots.storage` (and optionally `walStorage`) is set. This is a single, one-shot recovery point per teardown/recreate cycle, not continuous backup — it fits this platform's actual requirement (survive `cluster-down`) without taking on the excluded non-goal (enterprise DR).

Rough shape of the design (to be finalized during implementation, not fixed here):

- Requires the EBS CSI driver's snapshot support enabled (the `external-snapshotter` CRDs/controller and a `VolumeSnapshotClass` for `ebs.csi.aws.com` — not currently installed anywhere in this repo; confirm during implementation) and a place for that controller to live in the Argo creation/deletion ordering (constitution's controller-outlives-its-resources rule applies here too).
- A `VolumeSnapshot` must be taken of the live PVC **before** `cluster-down` tears down the cluster — likely an `argo-down.sh` step (spec 006-1's script, which already runs before any Terraform/Terragrunt destroy) or an Argo `PreDelete` hook on the Postgres Application, not a new bespoke mechanism.
- The next `cluster-up`/`argo-up` cycle's Cluster CR needs `bootstrap.recovery.volumeSnapshots.storage` pointing at the most recent snapshot instead of `bootstrap.initdb` — meaning the Cluster CR template needs to distinguish "genuinely first-ever bootstrap" (no snapshot exists yet — use `initdb`) from "recovering across a teardown" (a snapshot exists — use `recovery`). Decide whether that's a manual `target`-style value (mirroring how `existingVolumeHandle` gates the static-PV branch today) or a script-driven lookup of the latest snapshot by label.
- Snapshot lifecycle is Persistent-lifecycle data (constitution §4) — decide retention (how many generations to keep — likely just the latest one, given the new mechanism replaces rather than supplements the raw-volume-reuse approach) and where cleanup is accounted for (likely `persistent-down.sh`, alongside the existing retained-EBS-volume cleanup it already does per ADR 0008).
- The existing static `PersistentVolume`/`pvcTemplate` mechanism (`gitops/templates/platform/aws/postgres/recovered-pv.yaml`, `cluster.yaml`) is likely fully replaced, not kept alongside — confirm during implementation whether any part of it survives (e.g., the raw EBS volume itself, Terraform-owned per ADR 0010, may still be the right *underlying storage*, just no longer bound directly via a hand-written PV).

Whichever design is chosen, it supersedes ADR 0009's static-PV/`pvcTemplate` recovery approach and should be recorded as a new ADR when implemented — per this repo's own rule, not a silent rewrite of ADR 0009 (which was a reasonable decision given the information available at the time; the empirical verification it explicitly called for is what invalidated it).

## Requirements

1. A `cluster-down` → `cluster-up` cycle MUST result in previously-written Postgres data being genuinely queryable afterward — not merely "the volume still exists" or "the cluster reports healthy." This is spec 007 Requirement 2, restated as a hard acceptance gate this spec must actually satisfy.
2. The chosen mechanism MUST NOT depend on Kubernetes PVC object continuity across a full EKS cluster teardown — that continuity is exactly what `cluster-down` breaks, and any design relying on it will reproduce this spec's Problem.
3. The chosen mechanism MUST NOT require a continuous backup pipeline (Barman Cloud, WAL archiving) — that remains a non-goal per architecture.md §4; a single recovery point per teardown cycle is sufficient and in-scope.
4. Whatever new component this introduces (a snapshot controller, a snapshot-creation step) MUST be placed correctly in Argo's creation/deletion ordering per constitution's "a controller must remain running until resources it manages have completed cleanup" rule — the same class of ordering problem spec 006-1 solved for Karpenter applies to any new controller here too.
5. The design MUST be verified on a throwaway/disposable dataset before being trusted with anything that matters, exactly as ADR 0009 already asked for and this spec's Problem section shows wasn't actually done before the first real attempt.
6. A genuinely first-time bootstrap (no prior recovery point exists yet — e.g., a brand-new environment, first `persistent-up`) MUST still work via `bootstrap.initdb`, unchanged — this spec only needs to fix the *recovery* path, not break the *initial creation* path.

## Testing / acceptance criteria

- Write non-trivial test data (more than one row, more than one table, per spec 007's own test plan pattern in `tests/manual/007-postgres.md`), run a full `argo-down` → `cluster-down` → `cluster-up` → `argo-up` cycle, and confirm the exact same data is queryable afterward — this is the acceptance test that spec 007 always intended and this spec is what makes actually pass.
- Repeat the cycle a second time back-to-back (per spec 014's idempotency expectation) — confirm data from *both* the original write and anything added after the first recovery survives the second cycle, not just the first.
- Confirm storage growth (spec 007 Requirement 7, `spec.storage.size` resize) still works after switching bootstrap mechanisms — the recovery path must not silently drop the grow-only resize guarantee.
- Confirm a genuinely fresh environment (new `persistent-up`, no prior snapshot) still bootstraps cleanly via `initdb` — Requirement 6 above.
- Update `tests/manual/007-postgres.md`'s destroy/recreate steps once the mechanism is implemented, since its current step 9/10 assumes the static-PV mechanism that this spec replaces.

## Resolution

Implemented as CNPG native `VolumeSnapshot` recovery (this spec's option 3), not Barman Cloud/object-store — see **ADR 0013**, which supersedes ADR 0009's static-PV/`pvcTemplate` decision and ADR 0010's Terraform-owned-volume decision. The Postgres EBS volume moves off Terraform entirely and becomes Disposable-lifecycle; the retained EBS snapshot (not the volume) is the new Persistent-lifecycle artifact. `tests/manual/007-postgres.md` is updated accordingly, including a third repeat cycle in its testing steps (not just two) per review feedback that a wrong snapshot-handle discovery or retention-count bug tends to surface on the third cycle.
