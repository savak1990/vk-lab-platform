---
id: "HETZ-080"
title: "CA ceremony and bootstrap/rolesanywhere for the Hetzner project, before its first bootstrap-up"
status: "DRAFT"
priority: "P0"
milestone: "M1"
type: "implementation"
difficulty: "S"
recommended_model_tier: "strongest"
model_rationale: "Small change set, but it creates the trust root for every AWS credential the Hetzner cluster will ever hold, and the ordering trap silently mints a throwaway CA if missed"
effort_estimate: "Half a session (2–3 h) including the bootstrap apply"
estimate_confidence: "high"
depends_on: ["HETZ-018", "CIVO-080", "CIVO-082"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: ""
---

# HETZ-080 — CA ceremony and Roles Anywhere unit for the Hetzner project

## 1. Outcome and rationale

The Hetzner project `vk-hetzner-lab` has its own offline workload CA and
its own IAM Roles Anywhere trust anchor, profile and consumer roles. The
ceremony runs once, before the first `PROVIDER=hetzner make bootstrap-up`.
Nothing here is new design: CIVO-080 defines the ceremony and CIVO-082 the
Terraform unit, and HETZ-018 made both read the provider name. This spec
executes them for the second project and records the evidence.

One trust anchor per project is the existing shape. The unit lives in the
project's own `bootstrap/` stack and state bucket, guarded by
`fileexists()` on that project's CA certificate. A single account-wide
anchor would put the Civo and Hetzner clusters behind one CA key, so a
compromise on one target would reach the roles of the other.

## 2. Scope and non-goals

In scope: running `make ca-init` for the Hetzner project, committing the
ciphertext and certificate, applying `bootstrap/rolesanywhere` under the
Hetzner project, and confirming the SSM outputs. Not in scope: the
in-cluster issuer Secret, Certificates and sidecars (HETZ-085); the
`lab-role` SSM path additions (HETZ-025); any change to the Civo project.

## 3. Current state / evidence

- HETZ-018 renamed the ceremony to `scripts/ca-init.sh` and `make ca-init`, reading `PROVIDER` for the file names (`secrets/<project>/<provider>-ca-cert.pem`, `<provider>-ca-key.enc`) and the CN (`<project>-<provider>-workload-ca`).
- `terraform/live/bootstrap/rolesanywhere/terragrunt.hcl` reads `secrets/${project}/${provider}-ca-cert.pem` and applies zero resources when the file is absent.
- `terraform/modules/rolesanywhere` names the trust anchor `${project}-${provider}-workload-ca`, the profile `${project}-${provider}`, and the roles `${project}-ra-{eso,external-dns,cert-manager,pgbackup}` with `aws:PrincipalTag/x509Subject/CN` conditions on `${project}-${provider}-${consumer}`.
- CIVO-080 §12 records the trap: `bootstrap-up` and `persistent-down` call `generate-secrets.sh`, which mints a throwaway CA for any non-AWS project whose CA files are missing. A first `bootstrap-up` without this ceremony would therefore create a real trust anchor from a CA nobody keeps.

## 4. Design and contracts

- Files: `secrets/vk-hetzner-lab/hetzner-ca-cert.pem` (committed plaintext, public) and `secrets/vk-hetzner-lab/hetzner-ca-key.enc` (KMS ciphertext). The `.gitignore` exception from HETZ-018 admits the certificate.
- CA: EC P-256, `CA:true, pathlen:1`, five years, CN `vk-hetzner-lab-hetzner-workload-ca`, as CIVO-080.
- AWS resources, region `eu-west-1`, account layer unchanged: trust anchor `vk-hetzner-lab-hetzner-workload-ca` (external CA), profile `vk-hetzner-lab-hetzner` (session 3600 s), roles `vk-hetzner-lab-ra-eso`, `-external-dns`, `-cert-manager`, `-pgbackup`. Trust policies condition on `aws:SourceArn` = the new anchor and on the per-consumer CN.
- SSM outputs under `/vk-hetzner-lab/bootstrap/rolesanywhere/`: `trust_anchor_arn`, `profile_arn`, `role_arn_eso`, `role_arn_external_dns`, `role_arn_cert_manager`, `role_arn_pgbackup`. Plain `String`, as on Civo.
- Ordering contract: `make ca-init` precedes the first `bootstrap-up`. HETZ-025 §6 step 1 states the same rule from the other side.

## 5. Files/components affected

- `secrets/vk-hetzner-lab/hetzner-ca-cert.pem`, `secrets/vk-hetzner-lab/hetzner-ca-key.enc` (new).
- `terraform/live/bootstrap/rolesanywhere/` — no code change; a new state key in `vk-hetzner-lab-tf-state`.
- `terraform/modules/lab-role` — no change here; HETZ-025 owns the SSM ARNs.
- `specs/hetzner/README.md` index row.

## 6. Implementation steps

1. Confirm `secrets/vk-hetzner-lab/` does not yet contain any `*-ca-*` file. If `generate-secrets.sh` already minted one, delete both files and the matching SSM parameters before continuing, and record it in §14.
2. `PROVIDER=hetzner make ca-init`. Check the certificate with `openssl x509 -in secrets/vk-hetzner-lab/hetzner-ca-cert.pem -noout -subject -dates -ext basicConstraints,keyUsage`.
3. Commit both files. Never commit a `.pem` key.
4. `PROVIDER=hetzner make state-up` if the bucket does not exist, then `PROVIDER=hetzner make bootstrap-up`. The `rolesanywhere` unit now applies alongside `route53`.
5. Read the SSM outputs with `aws ssm get-parameters-by-path --path /vk-hetzner-lab/bootstrap/rolesanywhere`.
6. Run `terragrunt plan` in the Civo project's `bootstrap/rolesanywhere` and confirm no changes.

## 7. Dependencies and blockers

HETZ-018 must be `DONE`, or the ceremony still writes `civo-ca-*` names.
CIVO-080 and CIVO-082 supply the script and the unit. `account-up` must
already include the Roles Anywhere permissions in `lab-role` (CIVO-082).

## 8. Acceptance criteria

- `aws rolesanywhere list-trust-anchors` lists exactly one anchor named `vk-hetzner-lab-hetzner-workload-ca`, enabled, source type `CERTIFICATE_BUNDLE`.
- `aws rolesanywhere list-profiles` lists `vk-hetzner-lab-hetzner` with the four role ARNs.
- Each role's trust policy conditions on the new anchor ARN and on CN `vk-hetzner-lab-hetzner-<consumer>`.
- All six SSM parameters exist and hold ARNs.
- The Civo unit's plan shows no changes; `aws rolesanywhere list-trust-anchors` still lists the Civo anchor unchanged.
- `git log -p` for the commit shows no plaintext key material.

## 9. Validation

Offline: `openssl` checks on the certificate; `terragrunt validate`.
Real cloud: one `bootstrap-up` for the Hetzner project. Cost: Roles
Anywhere is free; SSM Standard parameters are free.

## 10. AWS regression protection

No AWS module changes. The Civo project's `bootstrap/rolesanywhere` plan
must show no changes, and the AWS project has no Roles Anywhere unit at
all (the `fileexists()` guard). `make -n bootstrap-up` output for `aws`
and `civo` is unchanged.

## 11. Rollout and rollback/recovery

Rollback: `PROVIDER=hetzner make bootstrap-down` destroys the anchor,
profile and roles; delete the two committed files and the SSM parameters.
A compromised CA key: disable the trust anchor first (stops new sessions
within seconds), then repeat this spec with a new CA. Issued sessions live
until expiry (at most one hour).

## 12. Risks and unresolved questions

- The throwaway-CA trap in §3. The `git status` check in step 1 is the only guard until HETZ-016 makes `generate-secrets.sh` refuse to mint a CA for a project whose `bootstrap/rolesanywhere` state already exists; consider that follow-up.
- Roles Anywhere quotas: 50 trust anchors per account. Two are used.
- The trust anchor's second certificate slot stays empty; rotation follows CIVO-080's runbook.

## 13. Definition of done

- [ ] Acceptance criteria met and recorded
- [ ] Civo and AWS plans unchanged
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
