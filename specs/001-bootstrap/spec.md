# 001 — Bootstrap

**Complexity:** Low
**Risk:** Low — narrow scope (one KMS key, tagging, a Makefile wrapper); the harder foundational risk moved with the state bucket to the State layer (ADR 0004).
**Estimated cost:** ~0.5 day · AWS runtime cost: negligible (KMS, no compute)
**Recommended model:** Sonnet — well-documented Terraform patterns, low ambiguity.
**Depends on:** the State layer (`make state-up`, ADR 0004) must already exist.
**Lifecycle class(es) touched:** Bootstrap

> **Scope amendments:**
> 1. The GitHub OIDC provider and OIDC-trusted per-stack IAM roles
>    originally planned here moved to **spec 015
>    (github-actions-lifecycle)** — the first spec that actually runs a
>    GitHub Actions workflow authenticating to AWS. Spec 017's Atlantis
>    authenticates via its own compute's instance/task role plus
>    `sts:AssumeRole`, not GitHub OIDC federation, so it never consumed
>    what this spec would have created. Local Terraform runs in this spec
>    authenticate with the operator's own AWS credentials (IAM Identity
>    Center/SSO), per architecture.md §34.
> 2. The Terraform state bucket originally planned here moved to its own
>    **State** lifecycle layer, below Bootstrap (`terraform/live/state/`,
>    `make state-up`/`make state-down`, guarded, essentially never run) —
>    see `docs/adr/0004-dedicated-state-lifecycle-layer.md` and
>    `docs/adr/0005-guarded-state-down.md`. This spec now only
>    covers the `kms` unit, tagging, and `make bootstrap-up`/
>    `make bootstrap-down`.

## Scope

Creates Bootstrap-lifecycle infrastructure, assuming the State layer (the Terraform remote-state bucket) already exists:

- One KMS key used later to encrypt each individual bootstrap-config file under `secrets/` (one file per secret/config value — never a combined blob, per constitution §5/§14). These files carry both runtime secrets (populated fully in spec 013) and non-secret private configuration needed earlier — notably `secrets/root-domain.enc`, consumed by spec 002 — so the decrypt-and-supply mechanism this spec establishes must be usable well before spec 013's full secrets lifecycle exists.
- A provider-level `default_tags` block (AWS provider) establishing the platform's standard resource tags (constitution §16): `Project=vk-lab-platform`, `Scope=platform`, `Lifecycle=<state|bootstrap|persistent|disposable>`, `ManagedBy=terraform`. Defined once in `terraform/live/root.hcl` (shared with the State layer and every later stack) rather than re-invented per resource.
- `make bootstrap-up` / `make bootstrap-down` Makefile targets (constitution §17) wrapping `terragrunt apply`/`destroy` on `terraform/live/bootstrap/` — `make bootstrap-down` is a guarded, explicit-confirmation command this repository expects to run essentially never, not a routine target.

Excludes: the Terraform state bucket (moved to the State layer — see the scope amendments above), the GitHub OIDC provider and OIDC-trusted IAM roles (spec 015), Atlantis's own per-stack IAM roles and compute (spec 017), networking (a dedicated VPC is deferred to spec 020 — EKS runs in the AWS default VPC until then, per spec 003), Route 53/ACM/Secrets Manager (002), EKS (003), any Kubernetes-facing IAM (Pod Identity roles are created alongside the workloads that need them, in later specs).

## Requirements

1. This stack MUST NOT create or manage the Terraform state bucket — that's the State layer's resource (ADR 0004). `terraform/live/bootstrap/`'s own units store their state in the bucket the State layer already created. `make bootstrap-up` MUST verify the State layer already exists (`make status`) and fail with an actionable error if it does not — it MUST NOT create the State layer on the caller's behalf (constitution §17).
2. GitHub Actions → AWS authentication MUST use OIDC and temporary credentials; no long-lived AWS access keys may be stored as GitHub secrets (constitution §5). This spec does not implement the OIDC provider/roles — that's spec 015 — but nothing built here may require a long-lived AWS key as a substitute in the meantime.
3. The KMS key created here (for `secrets/*.enc` only) is Bootstrap-lifecycle: created once, essentially never destroyed.
4. No plaintext secret may be committed to Git at any point (constitution §5) — this spec introduces the KMS key that makes the per-secret encrypted files under `secrets/` possible, but does not populate any of them with runtime secrets (that's spec 013).
5. The decrypt-and-supply mechanism (KMS decrypt → value available to `terraform apply` as a variable, without landing in a committed file) MUST be usable standalone, independent of any in-cluster component — spec 002 needs the decrypted root domain value (`secrets/root-domain.enc`) before EKS or Argo CD exist, so this cannot depend on Pod Identity or an in-cluster secrets controller (those come later, in spec 013, for runtime application secrets).
6. Each secret or private config value MUST live in its own ciphertext file under `secrets/`, named after its contents (e.g. `secrets/root-domain.enc`) — never combined into one shared file (constitution §5/§14).
7. Every AWS resource created here MUST carry the platform's standard tags (constitution §16) — `Project=vk-lab-platform`, `Scope=platform`, `Lifecycle=bootstrap`, `ManagedBy=terraform` — via the shared `default_tags` provider configuration in `terraform/live/root.hcl`.
8. `make bootstrap-down` MUST refuse to run while Persistent or Disposable state still exists, and MUST require an explicit, separate confirmation step beyond just invoking the command (constitution §17) — this is a deliberate, rarely-used escape hatch, not part of the routine lifecycle cycle. It MUST NOT touch the State layer's bucket — that's `make state-down`'s own separately-guarded command (ADR 0005), never invoked from here.

## Implementation hints

- Run `make state-up` first (once) if the State layer doesn't exist yet — see `terraform/live/state/README.md` and ADR 0004. This spec's units assume it already exists.
- One KMS key total, for the `secrets/*.enc` mechanism.
- The decrypt-and-supply mechanism can be as simple as a Makefile/CI step that runs `aws kms decrypt` against each relevant file under `secrets/` (e.g. `secrets/root-domain.enc` for spec 002, later other per-value files) and exports each decrypted value as its own `TF_VAR_*` environment variable before `terraform apply` — no plaintext file, no in-cluster dependency, usable from spec 002 onward.

## Testing / acceptance criteria

- `terraform plan`/`apply` succeeds for the `kms` unit, assuming the State layer already exists.
- Every resource created by this stack carries the standard tag set (`Project`, `Scope`, `Lifecycle=bootstrap`, `ManagedBy`) — spot-check via `aws resourcegroupstaggingapi get-resources` or equivalent, not just by reading the Terraform source.
- No OIDC-related acceptance criterion applies to this spec — the OIDC provider, its trust policy, and its validation (`aws sts assume-role-with-web-identity`, etc.) all move to spec 015, where they're actually created.
- No state-bucket acceptance criterion applies to this spec — see the State layer's own README/ADR 0004/ADR 0005 for its verification.
- This spec has no destroy/recreate lifecycle test of its own (Bootstrap is "almost never destroyed" per architecture.md §6), so the full lifecycle test (constitution §11) does not apply here; standard fast validation (fmt, validate, plan) is sufficient.
- `make bootstrap-down` is exercised at most once, deliberately, in a disposable/throwaway test AWS account (never against the real personal-lab account) to confirm: it refuses to run while Persistent or Disposable state exists, it requires its confirmation step, and it successfully removes the KMS key without touching the State layer's bucket. (The GitHub OIDC provider/roles from spec 015 and Atlantis's compute from spec 017 are separate Bootstrap-lifecycle resources this command must also account for once those specs exist.)
