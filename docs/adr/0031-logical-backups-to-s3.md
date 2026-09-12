# ADR 0031: Logical dumps to S3 as the single PostgreSQL backup mechanism

> **Amendment (2026-09-12):** the decision below stands — logical dumps to
> S3, one mechanism for both providers, point-in-time recovery accepted as
> lost. Three mechanics it describes were replaced after the operator
> reviewed the full set of options for reaching S3 from a Civo cluster.
>
> 1. **The job holds no AWS identity.** The "Decision" section below says
>    the job container uses `credential_process` with the Roles Anywhere
>    helper on Civo (ADR 0029) and Pod Identity on AWS. It uses neither.
>    The lifecycle script, which already holds AWS credentials on both
>    paths (`scripts/lib/provider.sh:136,160`), presigns a URL scoped to one
>    HTTP method on one object key for a few minutes; the job fetches or
>    uploads through that URL and carries no credential at all. This is an
>    explicit, recorded exemption from `CLAUDE.md`'s rule that a Kubernetes
>    workload reaching AWS uses Pod Identity or Roles Anywhere — the rule
>    exists to keep bearer credentials out of the cluster, and this design
>    removes the credential rather than choosing a better one. It also makes
>    the job manifest identical on both targets, which the original design
>    could not.
> 2. **No image is built by this repository.** The image existed solely to
>    host `credential_process`, and point 1 removes that need. The job runs
>    the upstream CNPG PostgreSQL image for `pg_dump`/`pg_restore`/`psql`
>    and an upstream `curl` image for the transfer, both pinned by digest,
>    in two containers sharing an `emptyDir`. One Helm value feeds both the
>    server's `imageName` and the job's PostgreSQL container, so client and
>    server versions cannot drift apart.
> 3. **"A shared S3 bucket" means a shared mechanism, not one bucket.** Each
>    project gets `${project}-backups`. CIVO-186's cross-provider promotion
>    depends on there being two, and ADR 0027's project isolation is easier
>    to keep true this way.
>
> The Consequences section's ownership line names spec CIVO-180 for the
> CronJob and Job; those moved to CIVO-120 on 2026-09-11. The bucket
> remains Terraform-owned and Persistent-lifecycle as stated.

## Status

Accepted

## Context

ADR 0013 moved AWS's Postgres recovery to CNPG `VolumeSnapshot`, backed
by the EBS CSI driver's native snapshot capability. That mechanism has no
Civo equivalent: Civo's CSI driver (`csi.civo.com`) does not implement
snapshot or clone capabilities at all — its `ControllerGetCapabilities`
response omits `CREATE_DELETE_SNAPSHOT` and related RPCs entirely, and
`CreateSnapshot`/`ListSnapshots` return `Unimplemented`. CNPG's
PVC-datasource recovery path, which clones a volume, is equally
unavailable for the same reason.

The other physical-backup path CNPG supports — the Barman Cloud plugin,
continuous WAL archiving to S3 — needs a sidecar container in the
instance pod to run the archiving/streaming process. CNPG has no
supported way to add a container of one's own to its managed instance
pods. That is a hard limitation, not a design choice this platform could
work around: it means an AWS identity for that sidecar (needed to reach
S3) would have nowhere to run under Roles Anywhere (ADR 0029), and the
only alternative would be a permanent AWS key baked into the Postgres
image or its environment — exactly the long-lived-credential pattern this
platform's identity design (ADR 0022, ADR 0029) exists to avoid.

## Decision

**Both providers use logical dumps to a shared S3 bucket as the single
backup mechanism**, starting with Civo in M1. AWS migrates onto the same
mechanism later, in CIVO-185 (M2, not yet committed) — not in M1, so this
ADR does not retire ADR 0013's mechanism for AWS immediately.

**The dump job runs from a container image this repository owns and
builds**, not a stock Postgres/Barman image with a sidecar. Because the
image is one this repository controls end to end, it needs no sidecar at
all: on Civo, the AWS CLI's `credential_process` invokes the Roles
Anywhere helper directly from within that same container (ADR 0029); on
AWS it uses Pod Identity, exactly as every other AWS-facing workload on
that target does. No permanent AWS key exists anywhere in this design.

**On AWS, this will replace ADR 0013's `VolumeSnapshot` mechanism as the
platform's Postgres backup approach, once CIVO-185 lands.** Until then,
ADR 0013's mechanism remains the active AWS backup path — this ADR
governs Civo from M1 and states the intended future AWS migration, it
does not enact it. ADR 0013 is not rewritten — it carries a pointer note
to this ADR, following the same convention ADR 0013 itself used when it
superseded ADR 0009/0010's storage decisions without rewriting them.

**The trade-off is stated explicitly: point-in-time recovery is lost.**
Logical dumps are discrete snapshots in time, not a continuous WAL
stream — restore points are exactly the dump instants, on the retention
window spec CIVO-180's job schedule and pruning policy define, not a
continuous recovery window. This platform accepts that loss on Civo in
exchange for removing the permanent-AWS-key requirement the alternative
would otherwise force; the same trade-off only becomes AWS's as well if
and when CIVO-185 migrates it.

**ADR 0013's failure philosophy carries forward unchanged**: if a dump
exists but restoring from it fails, the cluster stays down — there is no
silent fallback to `initdb`. A loud, visible failure is preferred to
silently discarding a recoverable database, on both targets.

## Consequences

- Civo's platform, from CIVO-120 onward, has a working, tested backup and
  restore cycle despite having no native volume snapshot capability at
  all — this was a hard blocker until this ADR, not a preference.
- AWS keeps ADR 0013's `VolumeSnapshot` mechanism unless and until
  CIVO-185 explicitly migrates it — the two targets may run different
  backup mechanisms for an extended period, which CIVO-185's own spec
  must treat as a tracked gap, not a permanent divergence, if and when it
  is scheduled.
- The shared S3 bucket and the dump/restore job images become new
  Terraform- and Argo-owned surface respectively (bucket: Terraform,
  Persistent-lifecycle; CronJob/Job: Argo, spec CIVO-180) — ownership
  follows the existing AWS-resource-vs-Kubernetes-resource split
  (`CLAUDE.md` "Core ownership model"), not a new exception.
- Losing point-in-time recovery is an accepted property of this design on
  Civo from M1. It is not proposed as an AWS-side change until CIVO-185
  (M2, not yet committed) migrates AWS onto the same mechanism — if and
  when that happens, the same loss becomes permanent on AWS too;
  reopening that would need a new ADR, not an amendment to this one.
