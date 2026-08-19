# 002 — Persistent Foundation

**Complexity:** Low–Medium
**Risk:** Medium — persistent-lifecycle resources; mistakes are annoying to unwind but not catastrophic in a lab account.
**Estimated cost:** ~0.5–1 day · AWS runtime cost: Route 53 hosted zone ~$0.50/month, ACM certs free.
**Recommended model:** Sonnet — standard AWS networking/Terraform, low ambiguity.
**Depends on:** 001-bootstrap (state backend, IAM role for this stack, decrypt-and-supply mechanism for the root domain value)
**Lifecycle class(es) touched:** Persistent

## Scope

Creates the AWS resources that must outlive `make down`:

- A Route 53 public hosted zone for the platform's **delegated subdomain**, `lab.<root-domain>` — NOT the existing root/parent hosted zone, which is external infrastructure outside this repository (constitution §14, ADR 0002).
- An ACM certificate covering `lab.<root-domain>` and `*.lab.<root-domain>`, in the same AWS region as the ALB (spec 012), DNS-validated against the `lab.<root-domain>` zone created here.
- Empty/skeleton AWS Secrets Manager structure (the actual runtime secret values are populated in spec 013).
- `make persistent-up` / `make persistent-down` Makefile targets (constitution §17) wrapping `terragrunt apply`/`destroy` on `terraform/live/persistent/`. `make persistent-down` permanently deletes the lab DNS zone, its ACM certificate, everything in Secrets Manager, and retained EBS volumes — it is a deliberate, rarely-used, explicitly-confirmed command, never a side effect of `make down`.

Excludes: **a dedicated VPC** — deliberately out of scope for now. EKS (spec 003) runs in the AWS account's default VPC/default public subnets instead, to keep the first several specs simple. A dedicated persistent VPC is introduced later, as its own spec (020), once the rest of the platform is working. Also excludes: EKS and any Kubernetes-facing resource (003+), RDS (not used — Postgres is in-cluster per project decision), the ALB itself and any DNS record inside the lab zone (012 — those are disposable), the parent/root hosted zone and NS delegation into it (external, one-time manual bootstrap per constitution §14 — not Terraform-managed by this repo).

## Requirements

1. The `lab.<root-domain>` Route 53 hosted zone, its ACM certificate, and Secrets Manager MUST be Persistent-lifecycle — created by `terraform/live/persistent/` and MUST survive a disposable-stack destroy (constitution §3, §14, architecture.md §6, §12).
2. This spec MUST NOT create a VPC, subnets, or any networking resource — that is spec 020's scope. Nothing here should assume or reference a platform-owned VPC.
3. ACM certificate validation MUST be automated via Route 53 DNS validation records against the `lab.<root-domain>` zone (both Terraform-managed, so no manual console step) — not against the parent zone, and not by reusing the existing root-domain certificate (constitution §14).
4. This stack MUST NOT create, manage, or require write access to the parent/root hosted zone (constitution §14) — it only creates the delegated `lab.<root-domain>` zone.
5. This stack MUST NOT create or manage any Kubernetes resource — it is pure AWS infrastructure (constitution §2).
6. The root domain value (used to name the `lab.<root-domain>` zone and certificate) MUST be supplied to Terraform as a decrypted value from the bootstrap KMS-encrypted config mechanism (spec 001) — e.g. `secrets/root-domain.enc` decrypted to a `TF_VAR_root_domain` at apply time — and MUST NOT appear in any committed `.tfvars`, YAML, Helm values, or documentation. This is the first spec in the roadmap that actually consumes that mechanism.
7. Because the domain value ends up in Route 53/ACM resource attributes, it will appear in this stack's Terraform state; the persistent stack's remote state MUST be treated as a private, access-controlled artifact — the domain cannot be fully hidden from state (constitution §14).
8. Every resource here MUST carry the platform's standard tags (constitution §16) with `Lifecycle=persistent`, inherited from this stack's `default_tags` provider block.
9. `make up` (spec 014) MUST verify this stack's resources already exist before creating any Disposable-lifecycle resource, and MUST fail with an actionable error telling the operator to run `make persistent-up` first if they do not (constitution §17) — `make up` MUST NOT create Persistent resources on the caller's behalf.
10. `make persistent-down` MUST refuse to run while any Disposable-lifecycle resource still exists — in particular, the disposable-created DNS records inside the `lab.<root-domain>` zone (spec 012) MUST already be gone, since they reference a zone this command is about to delete (constitution §7, §17). `make persistent-down` MUST require an explicit confirmation step beyond just invoking the command, since it permanently deletes the lab DNS zone, its certificate, all Secrets Manager contents (spec 013), and retained EBS volumes (specs 005/007/008).

## Implementation hints

- `terraform/live/persistent/` is a separate Terragrunt stack from disposable, with its own state file (per spec 001's state boundary work) — this is the enforcement mechanism for "disposable destroy can't touch persistent."
- Set this stack's `default_tags` provider block to inherit the bootstrap-established pattern (spec 001, constitution §16) with `Lifecycle=persistent` — don't hand-tag individual resources; state separation is the real safety net, tags are for identification and cost dashboards.
- Delegating `lab.<root-domain>` from the parent zone (the parent zone's NS records pointing at this zone's name servers) is a manual, one-time step performed outside `terraform apply` — after this stack creates the `lab.<root-domain>` zone and prints its name servers as an output, a human adds the NS records in the parent zone (in whatever system manages it). Document this as a bootstrap prerequisite, not something `make up` automates.
- Use `terraform/live/persistent/route53/` for the delegated zone and `terraform/live/persistent/acm/` for the certificate, per the repo layout in architecture.md §5 — both consume the decrypted root domain value from spec 001's mechanism as a Terraform variable. The ACM certificate's region must match whatever region spec 003 puts EKS/the ALB in — since both currently land in the account's default VPC region, this is a naming/variable-consistency concern, not a networking one.
- `make up`'s precondition check (Requirement 9) can be as simple as a `terragrunt output` or remote-state-existence check against `terraform/live/persistent/` before proceeding to `terraform/live/disposable/` — no new tooling needed, just an explicit early-exit step in the Makefile target built out fully in spec 014.
- `make persistent-down`'s precondition check (Requirement 10) can reuse spec 014's own postcondition-checklist approach: confirm the disposable stack's EKS/ALB/Karpenter-tagged resources are absent before allowing `terragrunt destroy` on this stack to proceed, and require a typed confirmation (e.g., re-entering the environment name) rather than a bare `y/n` prompt, given the permanence of what's being deleted.

## Testing / acceptance criteria

- `terraform plan`/`apply` succeeds against the persistent stack's own state, creating `lab.<root-domain>` without touching the parent zone.
- The `lab.<root-domain>` hosted zone exists after persistent bootstrap and its name servers are available as a Terraform output for the manual delegation step.
- NS delegation from the parent zone is verified (e.g., `dig NS lab.<root-domain>` resolves to the lab zone's name servers) and documented as a completed bootstrap prerequisite.
- ACM certificate for `lab.<root-domain>`/`*.lab.<root-domain>` reaches `ISSUED` status via DNS validation against the lab zone, without manual console intervention beyond the one-time delegation.
- Confirm no Terraform resource or provider call in this stack references or requires write access to the parent/root hosted zone.
- Fast validation only (fmt, validate, plan, security scan) for the routine create path — this spec has no disposable-stack coupling yet, so there's nothing to destroy/recreate against on every change. The real persistence proof comes once EKS/workloads exist (spec 005 onward) and can be destroyed around this foundation; spec 014's full lifecycle test additionally proves `make down`/`make up` never touch the lab zone, certificate, or parent zone.
- Running `make up` before `make persistent-up` has ever been run fails fast with a clear, actionable error naming `make persistent-up` — it does not create Persistent resources implicitly and does not proceed to create any Disposable resource (Requirement 9).
- **Persistent teardown (deliberate, run once, not part of routine CI):** with the disposable stack still up, attempting `make persistent-down` is refused (Requirement 10). After `make down` tears down the disposable stack, `make persistent-down` — after its explicit confirmation step — successfully deletes the `lab.<root-domain>` hosted zone, its ACM certificate, every secret in Secrets Manager (spec 013), and every retained EBS volume (specs 005/007/008). Confirm via the AWS console/API that all of these are actually gone, not just that Terraform reported success, and confirm the parent/root hosted zone is untouched throughout.
