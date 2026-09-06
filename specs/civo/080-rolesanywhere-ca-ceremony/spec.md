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

A reproducible script creates the Roles Anywhere root CA for a project.
The script commits the public certificate as
`secrets/<project>/civo-ca-cert.pem`. It commits the private key as KMS
ciphertext `secrets/<project>/civo-ca-key.enc`. It documents rotation.
This is the initial trust ceremony that ADR 0027 names. Automation cannot
remove the ceremony. Automation can only make it repeatable.

## 2. Scope and non-goals

In scope: `scripts/civo-ca-init.sh`, the README exception for a `.pem`
public file, the rotation runbook, and the `.gitignore` guard against
`*.key`. Not in scope: Terraform (CIVO-082) and the in-cluster issuer
(CIVO-085).

## 3. Current state / evidence

- `scripts/secret-encrypt.sh:16-17,32` reads `SECRET_VALUE` from the environment. It pipes the value to `aws kms encrypt` with `alias/lab-secrets`. Multi-line values work. The KMS plaintext limit is 4096 bytes.
- `secrets/README.md` states the one-ciphertext-per-value rule. It also states that plaintext never lands in Git.
- Roles Anywhere requires a CA cert with `CA:true` and `keyCertSign`. The signature must be SHA-256 or stronger (research.md).

## 4. Design and contracts

- `scripts/civo-ca-init.sh` *(new)* refuses to run if `civo-ca-cert.pem` exists, unless `ROTATE=1` is set. It generates an EC P-256 key with `openssl` in a `mktemp -d` directory (`umask 077`). It creates a self-signed cert with `CN=<project>-civo-workload-ca`, `O=<project>`, and a validity of 5 years. It sets `basicConstraints=critical,CA:true,pathlen:1`. The pathlen is 1, not 0, so CIVO-200 can chain one intermediate under this root without a CA rotation (RFC 5280 §4.2.1.9). It sets `keyUsage=critical,keyCertSign,cRLSign`. It writes the cert to `secrets/<project>/civo-ca-cert.pem`. It pipes the key PEM through `scripts/secret-encrypt.sh` as `SECRET_NAME=civo-ca-key`. It removes the temp dir (`rm -P` on macOS, `shred` where available). It prints the fingerprint only.
- `secrets/README.md` states that the `.pem` is public material (a certificate). It is the only non-`.enc` file allowed. The README explains why.
- Rotation runbook (in the spec and README): first, generate a new pair with `ROTATE=1` into `civo-ca-cert-next.pem`. Then CIVO-082 adds a second trust anchor. Then CIVO-085 switches the issuer. Remove the old anchor after all certs (24 h) expired. Then delete the old files.
- Revocation runbook: disable the trust anchor with `aws rolesanywhere disable-trust-anchor`. This stops new sessions immediately. Existing sessions expire within their duration (1 h default in CIVO-090).

## 5. Files/components affected

`scripts/civo-ca-init.sh` (new); `secrets/README.md`; `.gitignore` (`*.key`, `*-key.pem`); the `Makefile` target `civo-ca-init`.

## 6. Implementation steps

1. Write the script. Run `shellcheck` on it. Test it against a temporary project name, so the test does not touch the `vk-civo-lab` files. Verify the cert with `openssl x509 -text` (extensions, algorithm).
2. Verify that the encrypted key round-trips with `secret-decrypt.sh`. Do this in memory only (`| openssl ec -check`), never to disk.
3. Run the script for `vk-civo-lab`. Commit the two files.

## 7. Dependencies and blockers

CIVO-015 (ADR 0027 accepted). No cloud resources are needed beyond KMS encrypt.

## 8. Acceptance criteria

- The certificate has `CA:true`, `pathlen:1`, `keyCertSign`, SHA-256, EC P-256, a 5-year validity, and the CN as specified.
- `git grep -l "BEGIN EC PRIVATE KEY"` returns nothing. `.gitignore` blocks `*.key`.
- The script refuses to overwrite without `ROTATE=1`.
- The runbooks are present.

## 9. Validation

Offline, plus KMS encrypt (cents). No cluster is needed.

## 10. AWS regression protection

No AWS resources are created. The KMS key policy is unchanged.

## 11. Rollout and rollback/recovery

Rollback: delete the two files and rotate. Nothing depends on them until CIVO-082.

## 12. Risks and unresolved questions

- Should the key also be stored as a `SecureString` in SSM for CI convenience? No. CI decrypts the `.enc` like every other secret.

## 13. Definition of done

- [ ] Files committed; evidence of extensions; runbooks; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
