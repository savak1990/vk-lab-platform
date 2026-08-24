# 019 — Dedicated Persistent VPC

**Complexity:** Medium
**Risk:** Medium–High — migrating a running platform off the AWS default VPC requires a full disposable-stack recreation, and any retained EBS volumes (Postgres, Kafka) are AZ-locked, so a careless subnet/AZ layout can strand real data.
**Estimated cost:** ~1–2 days · AWS runtime cost: $0 if the new VPC keeps everything in public subnets (no NAT Gateway); modest NAT Gateway cost only if private subnets are adopted and explicitly justified.
**Recommended model:** Opus — the migration path carries real data-loss risk via AZ-locked EBS volumes and requires careful sequencing; not a routine "add a VPC module" task.
**Depends on:** 002-persistent-foundation (this spec extends the persistent Terraform stack), 003-network-and-eks (the default-VPC EKS setup being replaced), and implicitly 005-storage-contract/007-postgres/024-kafka (retained data whose AZ placement constrains the new VPC's design)
**Lifecycle class(es) touched:** Persistent (new VPC/subnets) / Disposable (EKS and everything on it must be recreated inside the new VPC)

## Scope

Introduces a dedicated, platform-owned VPC to replace the AWS account's default VPC used since spec 003, and migrates the disposable stack onto it:

- VPC, subnets, and route tables under `terraform/live/persistent/vpc/`.
- A decision, recorded here, on whether EKS nodes move to private subnets (requiring a NAT Gateway or VPC endpoints, cost-justified per constitution §9) or stay in dedicated public subnets (keeping the current no-NAT-Gateway cost profile while still gaining a platform-owned, isolated network instead of the shared default VPC).
- A documented migration procedure for existing retained EBS volumes (Postgres, Kafka) from their current AZ(s) in the default VPC to the new VPC's subnet/AZ layout.

Excludes: any change to Route 53/ACM/Secrets Manager from spec 002 (independent of which VPC EKS runs in); any change to application-level architecture (Postgres/Kafka/Debezium configuration itself is unaffected, only where their pods/volumes physically run).

## Requirements

1. The new VPC MUST be Persistent-lifecycle (constitution §3, §15) — created by `terraform/live/persistent/vpc/`, surviving disposable-stack destroys from this point forward.
2. EKS cannot move VPCs in place — migrating onto the new VPC MUST be treated as a full disposable-stack recreation, and per constitution §12 (stateful/lifecycle-sensitive changes MUST be explicitly tested), MUST be proven via a full lifecycle test: any retained EBS volumes MUST either land in an AZ the new VPC's subnets also cover, or follow a documented volume-migration procedure (e.g., snapshot in the old AZ, restore into a new AZ within the new VPC) with zero data loss.
3. If private subnets are adopted for EKS nodes, a NAT Gateway or VPC endpoints MUST be explicitly justified against constitution §9's cost rules — the default assumption remains public subnets (matching spec 003's starting point) unless there's a specific reason to change it.
4. The public traffic path (architecture.md §8, §11) MUST keep working without regression — NLB and any public-facing resource must remain reachable via public subnets in the new VPC.
5. This spec MUST NOT modify or depend on the Route 53/ACM/Secrets Manager resources from spec 002 — those are independent of VPC choice.
6. Once this spec is complete, no Terraform stack in this repository should reference the AWS default VPC any longer.
7. Every resource here MUST carry the platform's standard tags (constitution §16) with `Lifecycle=persistent`, inherited from this stack's `default_tags` provider block — matching every other persistent-lifecycle resource from spec 002.

## Implementation hints

- Before writing any Terraform, record which AZs the default VPC's subnets used (per spec 003's implementation hint) — this determines whether existing EBS volumes can simply be reattached in the new VPC or need the snapshot/restore migration path.
- A safe migration sequence: create the new VPC → stand up a second, parallel disposable stack (EKS, Argo CD, everything) inside it while the old default-VPC stack is still running → validate the new stack reaches full health → migrate/restore data volumes into the new stack → cut DNS/NLB over → tear down the old stack. Avoid attempting an in-place `terraform apply` that tries to move an existing EKS cluster's VPC — that's not a supported operation.
- Revisit whether the added isolation of private subnets is worth a NAT Gateway's ongoing cost now that the platform is more mature, or whether staying fully public (as spec 003 started) remains the simplest, cheapest option for a personal lab — document the decision either way, with the trade-off made explicit rather than assumed.
- Update spec 003's Terraform to take the VPC/subnet IDs as inputs from this new persistent-layer output, replacing the default-VPC data source lookup.

## Testing / acceptance criteria

- Full lifecycle test re-run (constitution §11, using spec 014's sequence) against the new VPC: CREATE → VERIFY → WRITE → DESTROY → VERIFY PERSISTENCE → RECREATE → VERIFY RECOVERY → DESTROY → VERIFY NO LEAKS.
- All previously-retained EBS volumes (Postgres, Kafka) are confirmed rebound in the new VPC/AZ layout with no data loss — verify actual row/message content, not just that a PVC bound successfully.
- HTTPS through the platform's `*.lab.<root-domain>` hostnames continues to work after the migration, with no change to the Route 53 zone or ACM certificate from spec 002.
- Confirm no Terraform resource or data source in the repository still references the AWS default VPC.
- Security groups in the new VPC are re-verified against the same "deny unexpected inbound access" check spec 003 established, now with the added benefit of real network-layer isolation from other AWS account resources.
