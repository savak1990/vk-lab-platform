---
id: "AWS-034"
status: "DEFERRED"
updated: "2026-09-25"
---
# 034 — A parked EKS cluster (Declined)

**Status note (2026-09-25):** declined on cost-benefit, not on feasibility. EKS
does support a managed node group at zero, so this is a road not taken rather
than a road that is closed. HETZ-200 implements parking on Hetzner and
`make park` refuses on this target, naming this document. Everything below is
the record of what building it would have cost and bought.

## What park would buy here

Roughly 21% of the bill, and it is the wrong 21%.

| Line | Running | Parked |
|---|---|---|
| EKS control plane, $0.10/hr | ~$73/mo | **~$73/mo** |
| 1 × t4g.medium system node | ~$24.50/mo | $0 |
| NLB | ~$18/mo | ~$18/mo |
| EBS volumes | ~$3.40/mo | ~$3.40/mo |
| **Total** | **~$119** | **~$94** |

The EKS control plane is a fixed hourly charge for the cluster's existence.
Parking cannot touch it, and it is the largest single line. On Hetzner the
platform owns its control plane and pays for a `cx23`, so parking there removes
the majority of the compute bill; here it removes the minority.

Figures are list prices, not read from an invoice.

## Why it is more work than Hetzner, not less

Three obstacles, in rising order of severity.

**Terraform owns all three scaling values.** `terraform/modules/eks/main.tf` sets
`min_size`, `max_size` and `desired_size` all to `var.min_worker_nodes`, with no
`lifecycle { ignore_changes }` anywhere in the module. So an out-of-band
`aws eks update-nodegroup-config` is reverted by the next `terragrunt apply`, and
`max_size` equal to the floor means the group cannot be scaled up by hand either.
Parking would mean decoupling the three in a module every target shares.

**The scale-down ignores PodDisruptionBudgets.** AWS documents that modifying
`NodegroupScalingConfig` terminates nodes through an Auto Scaling Group call
without considering PDBs, whatever the target size. So it is a hard kill, not a
drain — and CNPG keeps its PDB on this target alone, which makes the graceful
path both more necessary and unavailable.

**Karpenter cannot unpark itself.** It is the only thing that creates nodes here,
and it runs with `nodeSelector: node-type: system` — a label only the managed node
group carries. At zero nodes the Karpenter Deployment is unschedulable, so it
cannot provision the node it needs in order to run. Unpark is therefore
necessarily an out-of-band Terraform or EKS API operation, which returns to the
first obstacle.

There is also an ordering hazard with a cost attached. Karpenter's own nodes and
the NLB are not in Terraform state. Killing the system node group while Karpenter
nodes are up destroys the controller that owns them, and nothing then reclaims
those instances until someone runs a full `cluster-down`. A park would have to
drain Karpenter's capacity first, in the same order ADR 0012 and the sync waves
already encode for teardown.

## What to do instead

`make down`. It reaches approximately zero rather than $94, and on this target the
data of record is already outside the cluster. If the bring-up time is the real
complaint, the productive target is `ARGO_UP_WATCH_SECONDS` and the restore path,
which pays back on every cycle rather than only on parked ones.

## If this is ever revisited

The order that would make it safe: decouple the three scaling values and add
`ignore_changes` to the node group; give Karpenter and external-dns a home that
survives the park, or accept that unpark is Terraform-only and document it; drain
Karpenter capacity before the system group; and only then wire the `aws` arm of
`scripts/park.sh`. The saving would still be ~21%.
