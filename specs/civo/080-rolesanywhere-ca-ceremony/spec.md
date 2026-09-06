---
id: "CIVO-080"
title: "Offline CA ceremony: generate, encrypt, commit, rotate"
status: "READY"
priority: "P0"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "Root-of-trust handling: key generation parameters, storage, and rotation must be right the first time"
effort_estimate: "One session (3–4 h); no cloud resources"
estimate_confidence: "high"
depends_on: ["CIVO-015"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-080 — CA ceremony

## 1. Outcome and rationale

A reproducible script creates the Roles Anywhere root CA for a project,
commits the public certificate as `secrets/<project>/civo-ca-cert.pem` and
the private key as KMS ciphertext `secrets/<project>/civo-ca-key.enc`,
and documents rotation. This is the initial trust ceremony ADR 0027 names;
automation cannot remove it, only make it repeatable.

## 2. Scope and non-goals

In scope: `scripts/civo-ca-init.sh`, README exception for a `.pem` public
file, rotation runbook, `.gitignore` guard against `*.key`. Not in scope:
Terraform (CIVO-082), in-cluster issuer (CIVO-085).

## 3. Current state / evidence

- `scripts/secret-encrypt.sh:16-17,32` reads `SECRET_VALUE` from the environment and pipes to `aws kms encrypt` with `alias/lab-secrets`; multi-line values work; KMS plaintext limit 4096 bytes.
- `secrets/README.md` states the one-ciphertext-per-value rule and that plaintext never lands in Git.
- Roles Anywhere requires a CA cert with `CA:true` and `keyCertSign`; SHA-256 or stronger (research.md).

## 4. Design and contracts

- `scripts/civo-ca-init.sh` *(new)*: refuses if `civo-ca-cert.pem` exists unless `ROTATE=1`; generates an EC P-256 key with `openssl` in a `mktemp -d` directory (`umask 077`), self-signed cert `CN=<project>-civo-workload-ca`, `O=<project>`, validity 5 years, `basicConstraints=critical,CA:true,pathlen:0`, `keyUsage=critical,keyCertSign,cRLSign`; writes the cert to `secrets/<project>/civo-ca-cert.pem`; pipes the key PEM through `scripts/secret-encrypt.sh` as `SECRET_NAME=civo-ca-key`; shreds the temp dir; prints the fingerprint only.
- `secrets/README.md`: the `.pem` is public material (a certificate), the only non-`.enc` file allowed; explains why.
- Rotation runbook (in the spec and README): generate a new pair with `ROTATE=1` into `civo-ca-cert-next.pem`; CIVO-082 adds a second trust anchor; CIVO-085 switches the issuer; remove the old anchor after all certs (24 h) expired; delete old files.
- Revocation runbook: disable the trust anchor (`aws rolesanywhere disable-trust-anchor`) stops new sessions immediately; existing sessions expire within their duration (1 h default in CIVO-090).

## 5. Files/components affected

`scripts/civo-ca-init.sh` (new), `secrets/README.md`, `.gitignore` (`*.key`, `*-key.pem`), `Makefile` target `civo-ca-init`.

## 6. Implementation steps

1. Write and `shellcheck` the script; test against a temporary project name to avoid touching `vk-civo-lab` files; verify the cert with `openssl x509 -text` (extensions, algorithm).
2. Verify the encrypted key round-trips with `secret-decrypt.sh` in memory only (`| openssl ec -check`), never to disk.
3. Run for `vk-civo-lab`; commit the two files.

## 7. Dependencies and blockers

CIVO-015 (ADR 0027 accepted). No cloud beyond KMS encrypt.

## 8. Acceptance criteria

- Certificate has `CA:true`, `pathlen:0`, `keyCertSign`, SHA-256, EC P-256, 5-year validity, CN as specified.
- `git grep -l "BEGIN EC PRIVATE KEY"` returns nothing; `.gitignore` blocks `*.key`.
- Script refuses to overwrite without `ROTATE=1`.
- Runbooks present.

## 9. Validation

Offline plus KMS encrypt (cents). No cluster.

## 10. AWS regression protection

No AWS resources; KMS key policy unchanged.

## 11. Rollout and rollback/recovery

Deleting the two files and rotating equals rollback; nothing depends on them until CIVO-082.

## 12. Risks and unresolved questions

- Whether to store the key `SecureString` in SSM too for CI convenience: no; CI decrypts the `.enc` like every other secret.

## 13. Definition of done

- [ ] Files committed; evidence of extensions; runbooks; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
