# 013 — Secrets

**Complexity:** Medium–High
**Risk:** High — security-sensitive; the failure mode is either plaintext leakage into Git/state, or over-broad IAM permissions granted to make something "just work."
**Estimated cost:** ~1.5–2 days · AWS runtime cost: Secrets Manager per-secret monthly cost (small; combine related credentials into one JSON object per the cost trade-off architecture.md §17 explicitly allows).
**Recommended model:** Opus — narrow IAM permission design and secret-flow correctness deserve the most careful reasoning in the roadmap.
**Depends on:** 001-bootstrap (KMS key), 002-persistent-foundation (Secrets Manager skeleton), every workload spec that currently uses a placeholder secret mechanism (007, 008, 009)
**Lifecycle class(es) touched:** Persistent (Secrets Manager values) / Disposable (Pod Identity wiring, External Secrets-style sync)

## Scope

Completes the full secrets lifecycle described in architecture.md §17–18, replacing the placeholder/minimal secret handling used ad hoc in specs 007–009:

- EKS Pod Identity (preferred per constitution §5, ADR 0001) wiring for workloads that need AWS API access (e.g., an External Secrets-style controller syncing from Secrets Manager into Kubernetes Secrets).
- The deterministic KMS-encrypted bootstrap ciphertext flow for *runtime application secrets*: one dedicated ciphertext file per credential under `secrets/` (e.g. `secrets/postgres-admin-password.enc`, `secrets/kafka-cluster-credentials.enc`) → each decrypted independently via the bootstrap KMS key → written into AWS Secrets Manager (not into Terraform state any more than necessary).
- Migration of Postgres/Kafka/Debezium credentials (currently handled minimally per specs 007–009) onto this real mechanism.

Excludes: application-level secrets (no application code in this repo); a full secrets-rotation automation story (not required by architecture.md, though the mechanism should not actively prevent rotation later); the root domain value (`secrets/root-domain.enc`) — that non-secret private config value is already bootstrapped in specs 001/002, since Terraform needs it before EKS or Argo CD exist, well before this spec's in-cluster Pod Identity mechanism is available. This spec extends the same one-file-per-secret pattern to runtime application credentials, it doesn't re-do the domain.

## Requirements

1. No plaintext secret may be committed to Git at any point (constitution §5) — each credential gets its own committed ciphertext file under `secrets/` (never combined into a shared file), and each MUST be genuinely encrypted ciphertext, decryptable only by authorized AWS identities via KMS.
2. Kubernetes workloads SHOULD use EKS Pod Identity (constitution §5) — this is the preferred mechanism per ADR 0001; IRSA remains permitted if Pod Identity proves impractical for a specific component, but the default choice here is Pod Identity.
3. Runtime secrets MUST live in AWS Secrets Manager (constitution §5) — Helm/GitOps configuration MUST reference secrets by identifier only, never contain secret values (constitution §5, §6).
4. Avoid unnecessarily persisting decrypted secret values in Terraform state (architecture.md §17) — prefer a flow where decryption and Secrets Manager population happen outside of `terraform apply`'s normal state-tracking path where practical (e.g., a bootstrap script/CI step using the KMS key directly, or a Terraform provisioner that writes but doesn't need to read back the plaintext into state).
5. Combining multiple related credentials into a single Secrets Manager JSON object is an accepted, intentional lab-specific cost trade-off (architecture.md §17) — don't over-engineer per-credential secret isolation here.
6. Every Secrets Manager secret created here MUST carry the platform's standard tags (constitution §16), with `Lifecycle=persistent`, so they're identifiable as platform (not service) resources alongside everything else this repository creates.
7. Every workload from specs 007–009 currently using a placeholder secret mechanism MUST be migrated to this real mechanism as part of this spec, not left on the placeholder indefinitely.

## Implementation hints

- A minimal External Secrets Operator-style controller (Argo-managed, using Pod Identity to read Secrets Manager) is the standard way to bridge AWS-managed secrets into Kubernetes Secrets without ever putting plaintext in Git or GitOps manifests.
- Per-credential flow: encrypt each credential locally/in CI with the bootstrap KMS key → commit as its own file (e.g. `secrets/postgres-admin-password.enc`) → a one-time (or idempotent) bootstrap step decrypts each file independently and writes it into Secrets Manager, run manually or via a scoped CI job, not as a routine part of every `terraform apply`.
- Revisit Postgres/Kafka/Debezium credential handling from specs 007–009 now: replace whatever operator-generated or ad hoc Secret was used with one sourced from Secrets Manager via this new mechanism, and confirm nothing broke in the process (a re-run of each spec's lifecycle test is warranted after this migration).
- Keep IAM policies attached to each Pod Identity role scoped to exactly the Secrets Manager ARNs that workload needs — no wildcard `secretsmanager:*` grants.

## Testing / acceptance criteria

- A workload using Pod Identity can read its designated secret from Secrets Manager and nothing else (verify a deliberately wrong secret ARN request is denied by IAM, not silently allowed).
- Each `secrets/*.enc` file can be decrypted only by the authorized AWS identity/KMS key — attempting decryption without the right IAM permissions fails.
- `git log -p` / a secret-scanning tool over the full repo history finds zero plaintext secret values.
- Re-run the lifecycle tests for Postgres (007), Kafka (008), and Debezium (009) after migrating their credentials to this mechanism — confirm nothing regressed in the destroy/recreate persistence proofs.
- Fast validation includes a security-scanning step (already required by constitution §11) specifically checking for committed plaintext secrets on every PR going forward.
- As part of spec 002's deliberate, once-only `make persistent-down` teardown scenario: confirm every secret this spec created in Secrets Manager is actually deleted (not just scheduled for deletion with a recovery window, unless that window is an explicit, intentional choice) — this is the real test that "runtime secrets survive `make down` but not `make persistent-down`" holds in practice, not only in the spec text.
