---
id: "HETZ-080"
title: "CA ceremony and bootstrap/rolesanywhere for the Hetzner project, before its first bootstrap-up"
status: "DONE"
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
completed: "2026-09-21"
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

## 4a. Deviations from §4 and §8

- **D1 — the role ARN parameter names.** §4 lists the SSM outputs as
  `role_arn_eso`, `role_arn_external_dns`, `role_arn_cert_manager` and
  `role_arn_pgbackup`. The unit writes them one level deeper, as
  `role_arn/<consumer>`, so a plain `get-parameters-by-path` returns only two
  parameters and `--recursive` is needed to see all six. This is CIVO-082's
  existing layout, unchanged by HETZ-018; the spec text was wrong, not the
  code. Every consumer reads its own parameter by full name, so nothing
  downstream is affected.
- **D2 — §8's Civo comparison could not be run.** It asks that the Civo unit's
  plan show no changes and that `list-trust-anchors` still list the Civo anchor
  unchanged. **There is no Civo anchor.** The personal Civo project is torn
  down to zero: `vk-civo-lab-tf-state` returns 404 and
  `aws iam list-roles` matches no `vk-civo-lab*` role. This is the same
  condition HETZ-018 recorded as its deviation D6. What the listing does prove
  is the property the check exists for — after this apply the account holds
  **exactly one** trust anchor, the Hetzner one, so nothing pre-existing was
  renamed, retargeted or destroyed.
- **D3 — `make state-up` was run as its own step.** §6 step 4 makes it
  conditional, and `bootstrap-up.sh` calls `state-up.sh` itself in any case.
  The bucket did not exist, so it was created first and deliberately, before
  anything read the backend.
- **D4 — `generate-secrets.sh` also minted two project passwords.**
  `bootstrap-up` calls it, and `vk-hetzner-lab` had no
  `postgres-app-password`, `grafana-admin-password` or
  `argocd-admin-password.bcrypt`. They are real random values, not the fixed
  test ones: `FIXED_TEST_PASSWORDS` was unset. §5 does not name these files;
  they are committed with the ceremony.

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

- [x] Acceptance criteria met and recorded
- [ ] **Civo plan unchanged** — could not be run; see D2
- [x] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-21 — executed on branch `hetzner-080-ca-ceremony`, off `main` at
  `c3ac8bb`. Deviations D1 to D4 in §4a.

  **The ceremony.** `PROVIDER=hetzner make ca-init` wrote
  `secrets/vk-hetzner-lab/hetzner-ca-cert.pem` and `hetzner-ca-key.enc`:

  | Property | Value |
  |---|---|
  | subject | `O=vk-hetzner-lab, CN=vk-hetzner-lab-hetzner-workload-ca` |
  | key | EC P-256 (`id-ecPublicKey`, 256 bit) |
  | basic constraints | `CA:TRUE, pathlen:1`, critical |
  | key usage | `Certificate Sign, CRL Sign`, critical |
  | validity | 2026-09-20 to 2031-09-20 (1826 days) |
  | sha256 | `F0:96:DD:A6:0C:E7:72:50:07:DD:24:58:3C:F9:5A:C3:92:FA:AD:EC:B8:95:66:D0:3C:E6:85:7D:D1:D8:CF:05` |

  The decrypted private key's public half was compared against the
  certificate's and matched; the decrypted copy was then removed. The staged
  diff contains no `BEGIN * PRIVATE KEY` line.

  **The ordering trap of §3 was observed working.** `generate-secrets.sh`, run
  inside `bootstrap-up` after the ceremony, printed *"Skipping
  hetzner-ca-cert — … already exists"*. Had the order been reversed it would
  have minted a throwaway CA under the real project name and the trust anchor
  would now anchor to a key nobody keeps.

  **The apply.** Planned before applying: `route53` 6 to add, `rolesanywhere`
  16 to add, **0 to change and 0 to destroy in both**, and no `vk-civo-lab`
  string anywhere in the plan. Applied clean at those same counts.

  | Object | Evidence |
  |---|---|
  | Trust anchor | `vk-hetzner-lab-hetzner-workload-ca`, enabled, `CERTIFICATE_BUNDLE`, id `2e40796f` — and the **only** anchor in the account |
  | Profile | `vk-hetzner-lab-hetzner`, enabled, 3600 s, four role ARNs |
  | Roles | `vk-hetzner-lab-ra-{eso,external-dns,cert-manager,pgbackup}` |
  | Trust policies | all four condition on `x509Issuer/CN = vk-hetzner-lab-hetzner-workload-ca`, on `x509Subject/CN = vk-hetzner-lab-hetzner-<consumer>`, and on `aws:SourceArn` = the new anchor |
  | SSM | all six parameters present, plain `String` (see D1 for their real path) |
  | Zone | `hz.<root-domain>` created; exactly one new NS record set in the parent zone, TTL 172800, four name servers |
  | ACM | none created — the account still lists only the external root-domain certificate |

  **This is the first end-to-end proof of HETZ-018.** Every name in the chain
  came out `hetzner`, from a `terragrunt.hcl` that derives the provider from
  which certificate is on disk rather than from an environment variable. The
  probe HETZ-018 ran was a scratch expression; this is the real chain.

  **Cost.** The Route 53 zone is 0.50 USD/month and is Persistent by design.
  The trust anchor, profile, IAM roles, `String` parameters and state bucket
  are free.
