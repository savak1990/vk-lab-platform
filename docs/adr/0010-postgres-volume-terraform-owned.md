# ADR 0010: Postgres EBS volume moves to Terraform ownership

## Status

Accepted

## Context

ADR 0009 chose dynamic PVC provisioning (CNPG + the `ebs-retain`
StorageClass) over a Terraform-owned volume, specifically rejecting the
latter because a Terraform-declared `size` would fight CNPG's grow-only
resize (Requirement 7): once CNPG/CSI expands the volume, Terraform's
config diverges from real state, and since EBS can't shrink, Terraform's
only resolution would be to propose destroying and recreating the volume
holding live data.

That decision was correct for the goal it was evaluated against:
persistence itself. A different problem surfaced afterward that dynamic
provisioning doesn't solve — after every `disposable-down` →
`disposable-up` cycle, recovering the retained volume required manually
running `aws ec2 describe-volumes` to find its ID and AZ, then
hand-editing `gitops/values.yaml`. This ADR revisits the rejected
alternative under that new goal: deterministic automation of a step that
was manual, not persistence-by-Terraform.

## Decision

**Move the Postgres EBS volume into Terraform ownership**
(`terraform/modules/ebs-volume`, instantiated by
`terraform/live/persistent/postgres-volume`), with one change that removes
ADR 0009's objection:

```hcl
lifecycle {
  ignore_changes = [size]
}
```

Terraform now owns the volume's existence, identity, AZ, and tags.
**CNPG remains the sole owner of its size** — Terraform never reconciles
`size` after creation, so CNPG's grow-only resize through the CSI driver
never produces drift, and never risks the destroy-and-recreate failure
mode ADR 0009 rejected the idea for. This is one owner per attribute, not
two owners contending over one number.

**Shared AZ, decided once.** The volume's AZ and the EKS node group's
subnet both read the same value — `postgres_az` in `terraform/live/root.hcl`
(`eu-west-1a`, confirmed live and present in the default VPC at
implementation time) — rather than one being computed and the other risking
a mismatch. This removes what would otherwise be the real risk of a
Terraform-owned volume: pinning an AZ before Karpenter's node placement is
decided, potentially stranding the volume in an AZ with no spot capacity.
That risk turned out to already be moot independently — the EKS module
(`terraform/modules/eks/main.tf`) already pins the whole cluster (system
node group *and* Karpenter's subnet-discovery tag, via
`terraform/live/disposable/karpenter`) to one single, deterministic AZ.
There was never a second AZ in play to strand anything in; this ADR just
makes that AZ an explicit shared input instead of an independently
computed value, so a future change to one side can't silently diverge
from the other.

**Component tag, not CSI-driver-style tags.** The volume is tagged
`Component = "postgres"` directly by Terraform, since it's no longer
provisioned by the CSI driver and won't carry `kubernetes.io/created-for/*`
tags. This is the mechanism for identifying it, not the `ebs-retain`
StorageClass's tags (which remain generic and, per ADR 0009's later
addendum, ambiguous once other components share that class).

**Automatic wiring, not manual.** The volume ID and AZ flow from
`persistent/postgres-volume`'s outputs, through a new
`persistent → disposable` Terragrunt `dependency` (the first of its kind in
this repo — every prior example is disposable-to-disposable, but this one
is directionally safe because `make persistent-up` always runs before
`make disposable-up`), into `terraform/modules/argocd-bootstrap`'s
`helm_release.root_application`, through `gitops/bootstrap/templates/root-application.yaml`'s
explicit `helm.parameters` list (verified: this template does **not**
forward arbitrary values, only what's explicitly listed there), landing in
`gitops/values.yaml`'s `postgres.existingVolumeHandle`/`existingVolumeAz` —
the same fields the CNPG `Cluster` CR and its static-provisioning
`PersistentVolume` (`gitops/templates/platform/aws/postgres/{cluster,recovered-pv}.yaml`)
already consumed under ADR 0009's manual recovery mechanism. No template
changes were needed there — only where those two values come from changed.

**Consequence for that mechanism**: since the Terraform-owned volume exists
from the very first `persistent-up` onward, the "fresh dynamic-provisioning"
branch those two templates still technically support (triggered when
`existingVolumeHandle` is empty) never triggers in practice anymore. Left
in place rather than removed — it costs nothing and stays correct either
way.

## Consequences

- `docs/adr/0009-postgres-operator-cloudnativepg.md`'s "Rejected
  alternative" paragraph is not rewritten — it was correct for the goal it
  answered. A pointer note there directs to this ADR for the reversal under
  the new goal.
- No change to `scripts/persistent-down.sh` — verified, not assumed. Its
  volume-deletion filter (`Name=tag:ManagedBy,Values=ebs-csi-driver`)
  naturally never matches this volume, since Terraform's own `default_tags`
  (from `root.hcl`) set `ManagedBy = "terraform"` on it, not
  `ebs-csi-driver`. Deletion instead happens through the script's ordinary
  `terragrunt run --all destroy` call on the persistent stack, which runs
  *before* that script's manual tag-filtered cleanup step even executes.
  One consequence worth naming explicitly: ADR 0008's safety-visibility
  design (echoing volumes before the destroy prompt) covered CSI-provisioned
  volumes specifically; for this Terraform-owned volume, the equivalent
  visibility comes from **terragrunt's own interactive destroy plan**
  instead, not from that echo step. Both still require typing "yes" before
  anything is destroyed — the confirmation guarantee is unchanged, just
  which prompt carries it for this particular volume.
- The still-open, unresolved-by-CNPG's-docs question from ADR 0009 (whether
  CNPG starts against existing PGDATA on a `pvcTemplate`-bound volume, or
  re-runs `initdb`) is unchanged by this ADR and still needs the same
  throwaway-volume verification before the real destroy/recreate proof
  touches real data.
