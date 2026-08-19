# 001 — Bootstrap

**Complexity:** Low–Medium
**Risk:** Medium — mistakes in the state backend or OIDC trust policy are foundational; everything else depends on this being right.
**Estimated cost:** ~0.5–1 day · AWS runtime cost: negligible (S3 + KMS, no compute)
**Recommended model:** Sonnet — well-documented Terraform patterns, low ambiguity.
**Depends on:** none (first spec after the constitution)
**Lifecycle class(es) touched:** Bootstrap

## Scope

Creates the root-of-trust infrastructure that every later Terraform stack reads or authenticates through:

- Terraform remote state backend (state bucket + locking) for every later stack (`bootstrap`, `persistent`, `disposable`, `ci/*`).
- GitHub OIDC provider in AWS, so GitHub Actions can assume roles without long-lived credentials.
- Foundational IAM roles/policies scoped per lifecycle stack (least-privilege, not one broad admin role).
- KMS key(s) used later to encrypt each individual bootstrap-config file under `secrets/` (one file per secret/config value — never a combined blob, per constitution §5/§14) and for encrypting Terraform state. These files carry both runtime secrets (populated fully in spec 013) and non-secret private configuration needed earlier — notably `secrets/root-domain.enc`, consumed by spec 002 — so the decrypt-and-supply mechanism this spec establishes must be usable well before spec 013's full secrets lifecycle exists.
- A provider-level `default_tags` block (AWS provider) establishing the platform's standard resource tags (constitution §16): `Project=vk-lab-platform`, `Scope=platform`, `Lifecycle=<bootstrap|persistent|disposable>`, `ManagedBy=terraform`. Every later Terraform stack inherits this pattern rather than re-inventing tagging per resource.
- `make bootstrap-up` / `make bootstrap-down` Makefile targets (constitution §17) wrapping `terragrunt apply`/`destroy` on `terraform/live/bootstrap/` — `make bootstrap-down` is a guarded, explicit-confirmation command this repository expects to run essentially never, not a routine target.

Excludes: networking (a dedicated VPC is deferred to spec 020 — EKS runs in the AWS default VPC until then, per spec 003), Route 53/ACM/Secrets Manager (002), EKS (003), any Kubernetes-facing IAM (Pod Identity roles are created alongside the workloads that need them, in later specs).

## Requirements

1. Terraform state MUST be stored remotely with locking, and state boundaries MUST be separate per lifecycle class (`bootstrap`, `persistent`, `disposable`, `ci/persistent`, `ci/disposable`) per architecture.md §33 and constitution §3 — a routine disposable destroy must not be able to touch persistent or bootstrap state.
2. Re-evaluate current Terraform S3-native state locking (`use_lockfile`) vs. the older S3+DynamoDB pattern before choosing — ADR 0001 explicitly says the DynamoDB-based backend from `bg-tf-bootstrap` is not carried over as-is.
3. GitHub Actions → AWS authentication MUST use OIDC and temporary credentials; no long-lived AWS access keys may be stored as GitHub secrets (constitution §5).
4. IAM roles created here MUST be scoped to what each Terraform stack actually needs (persistent stack cannot touch disposable-only resources and vice versa).
5. KMS key(s) created here are Bootstrap-lifecycle: created once, essentially never destroyed.
6. No plaintext secret may be committed to Git at any point (constitution §5) — this spec introduces the KMS key that makes the per-secret encrypted files under `secrets/` possible, but does not populate any of them with runtime secrets (that's spec 013).
7. The decrypt-and-supply mechanism (KMS decrypt → value available to `terraform apply` as a variable, without landing in a committed file) MUST be usable standalone, independent of any in-cluster component — spec 002 needs the decrypted root domain value (`secrets/root-domain.enc`) before EKS or Argo CD exist, so this cannot depend on Pod Identity or an in-cluster secrets controller (those come later, in spec 013, for runtime application secrets).
8. Each secret or private config value MUST live in its own ciphertext file under `secrets/`, named after its contents (e.g. `secrets/root-domain.enc`) — never combined into one shared file (constitution §5/§14).
9. Every AWS resource created here, and in every later Terraform stack, MUST carry the platform's standard tags (constitution §16) — `Project=vk-lab-platform`, `Scope=platform`, `Lifecycle=<bootstrap|persistent|disposable>`, `ManagedBy=terraform` — establishing this via each stack's own `default_tags` provider configuration, with only the `Lifecycle` value varying per stack.
10. `make bootstrap-down` MUST refuse to run while Persistent or Disposable state still exists, and MUST require an explicit, separate confirmation step beyond just invoking the command (constitution §17) — this is a deliberate, rarely-used escape hatch, not part of the routine lifecycle cycle.

## Implementation hints

- `terraform/live/bootstrap/` is its own Terragrunt stack, applied manually/locally first (chicken-and-egg: nothing else can use OIDC to apply Terraform until this exists).
- One GitHub OIDC provider, but multiple IAM roles — one per stack/environment pair (`bootstrap`, `persistent`, `disposable`, `ci-persistent`, `ci-disposable`), each with a trust policy scoped to the specific GitHub repo + branch/environment claim, not a blanket `repo:*` trust.
- Consider a single KMS key for lab bootstrap secrets and a separate one (or key policy) for Terraform state encryption, so blast radius of a key policy mistake stays contained.
- Terragrunt `remote_state` blocks in later stacks all point back to the bucket/table created here.
- The decrypt-and-supply mechanism can be as simple as a Makefile/CI step that runs `aws kms decrypt` against each relevant file under `secrets/` (e.g. `secrets/root-domain.enc` for spec 002, later other per-value files) and exports each decrypted value as its own `TF_VAR_*` environment variable before `terraform apply` — no plaintext file, no in-cluster dependency, usable from spec 002 onward.

## Testing / acceptance criteria

- `terraform plan`/`apply` succeeds for the bootstrap stack from a clean AWS account.
- Every resource created by this stack carries the standard tag set (`Project`, `Scope`, `Lifecycle=bootstrap`, `ManagedBy`) — spot-check via `aws resourcegroupstaggingapi get-resources` or equivalent, not just by reading the Terraform source.
- The OIDC trust policy is validated directly (e.g. `aws sts assume-role-with-web-identity` against a test token, or the AWS console's trust-policy simulator) with zero stored AWS credentials — this spec proves the IAM/OIDC infrastructure works, but does not create any `.github/workflows/*.yml` file to do so; actual GitHub Actions workflow wiring (`lab-up.yml`/`lab-down.yml`) is spec 015's job.
- `terraform destroy` on the disposable or persistent stack (once they exist) cannot affect anything created here — verified by state isolation, not just IAM.
- This spec has no destroy/recreate lifecycle test of its own (Bootstrap is "almost never destroyed" per architecture.md §6), so the full lifecycle test (constitution §11) does not apply here; standard fast validation (fmt, validate, plan) is sufficient.
- `make bootstrap-down` is exercised at most once, deliberately, in a disposable/throwaway test AWS account (never against the real personal-lab account) to confirm: it refuses to run while Persistent or Disposable state exists, it requires its confirmation step, and — only once both are already torn down — it successfully removes the state backend, OIDC provider, IAM roles, KMS keys, and Atlantis's compute (spec 017).
