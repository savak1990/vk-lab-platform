# 0020 — Dedicated VPC, public subnets only, no NAT Gateway

## Status

Accepted

## Context

Spec 020 replaces the AWS account's default VPC (used since spec 003) with a
platform-owned, Persistent-lifecycle VPC. The open question spec 020 leaves
for implementation: do EKS nodes move to private subnets (needing a NAT
Gateway or VPC interface endpoints) or stay in public subnets like today.

## Decision

Public subnets only, across two AZs, no NAT Gateway, no VPC interface
endpoints, no custom NACL. Every resource created (VPC, IGW, subnets, route
table) is free — this migration adds **$0** to the account's AWS bill.

A NAT Gateway costs ~$0.045/hr plus ~$0.045/GB processed; VPC interface
endpoints cost ~$7.30/month each, per AZ. Neither buys anything this lab
needs: nodes already have public IPs today (the default VPC's subnets), and
security is enforced at the security-group layer, not by network placement.
Constitution §9 requires an explicit justification to add either, and no
such justification exists yet.

## Consequences

- Nodes keep public IPs, same as before — no security regression, no
  security improvement either. Network isolation is future work if ever
  justified by a concrete requirement.
- `kubernetes.io/role/elb` is tagged directly on the new subnets, letting
  `aws-load-balancer-controller` auto-discover them — this is what actually
  motivated owning the VPC (see spec 020), independent of the public/private
  choice above.
- If a future workload needs private subnets, add them as a separate,
  cost-justified change rather than reopening this one.
- `karpenter-pod-identity` (disposable Terraform) tags the one node subnet
  with `karpenter.sh/discovery` — a cluster-scoped tag applied to a now
  repo-owned, Persistent-lifecycle subnet from the Disposable stack. Not new
  behavior (it already did this against the default VPC), but now a
  deliberate, documented exception rather than tagging an unowned resource.
