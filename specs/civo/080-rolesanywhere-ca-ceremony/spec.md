---
id: "CIVO-080"
title: "Offline CA ceremony: generate, encrypt, commit, rotate"
status: "DONE"
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
updated: "2026-09-09"
completed: "2026-09-09"
---

# CIVO-080 — CA ceremony

## 1. Outcome and rationale

A reproducible script creates the Roles Anywhere root CA for a project.
The script commits the public certificate as
`secrets/<project>/civo-ca-cert.pem`. It commits the private key as KMS
ciphertext `secrets/<project>/civo-ca-key.enc`. It documents rotation.
This is the initial trust ceremony that ADR 0029 names. Automation cannot
remove the ceremony. Automation can only make it repeatable.

## 2. Scope and non-goals

In scope: `scripts/civo-ca-init.sh`, the README exception for a `.pem`
public file, the rotation runbook, and the `.gitignore` guard against
`*.key`. Not in scope: Terraform (CIVO-082) and the in-cluster issuer
(CIVO-085).

**Addition (2026-09-09):** also wired disposable, generate-if-missing CA
creation into `scripts/generate-secrets.sh` for arbitrary/throwaway
`PROJECT_NAME`s (civo-only, gated on `PROVIDER`) — the same treatment
already given to the Postgres/Grafana passwords there, so a CI run against
an ephemeral project gets its own disposable trust root without a manual
ceremony. Never committed by that script; local-only for the run's
duration, per operator decision during planning.

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

`scripts/civo-ca-init.sh` (new); `secrets/README.md`; `.gitignore` (`*.key`, `*-key.pem`, plus `!secrets/*/*.pem` to allow the public cert); the `Makefile` target `civo-ca-init`; `scripts/generate-secrets.sh` (the throwaway-project wiring, §2's addition).

## 6. Implementation steps

1. Write the script. Run `shellcheck` on it. Test it against a temporary project name, so the test does not touch the `vk-civo-lab` files. Verify the cert with `openssl x509 -text` (extensions, algorithm).
2. Verify that the encrypted key round-trips with `secret-decrypt.sh`. Do this in memory only (`| openssl ec -check`), never to disk.
3. Run the script for `vk-civo-lab`. Commit the two files.

## 7. Dependencies and blockers

CIVO-015 (ADR 0029 accepted). No cloud resources are needed beyond KMS encrypt.

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
- **Deviation from §4 (2026-09-09):** kept `civo` in the CN and filenames (`${project}-civo-workload-ca`, `civo-ca-cert.pem`/`civo-ca-key.enc`) rather than a provider-agnostic name, per explicit operator decision — considered generalizing since Roles Anywhere itself isn't Civo-specific and `pathlen:1` already anticipates a future intermediate (CIVO-200), but kept the original naming to match CIVO-082's already-written §4 verbatim, with no cross-spec correction needed. A future second non-EKS provider would need this CA renamed via the rotation runbook if this choice is ever revisited.
- **Finding (2026-09-09):** on this machine's LibreSSL 3.3.6, `openssl req -x509 ... -extfile` silently does NOT apply the extension file — it produces a root cert missing `basicConstraints`/`keyUsage` entirely, which Roles Anywhere would reject as a trust anchor. The implemented script uses the two-step CSR-then-self-sign form (`req -new` then `x509 -req -extfile`) instead, verified empirically to apply extensions correctly. Worth knowing if this script is ever ported to a different OpenSSL build.
- **Finding (2026-09-09):** a bare `$(cat "$KEY_FILE"; echo)` does not restore a PEM's stripped trailing newline — bash command substitution strips all trailing newlines regardless of what follows in the substitution. Fixed with a sentinel-byte trick (`$(cat "$KEY_FILE"; printf 'x')` then strip the trailing `x`), verified byte-for-byte via independent review.
- **Deviation from §8 (2026-09-09):** the stated acceptance check `git grep -l "BEGIN EC PRIVATE KEY"` only searches tracked files — at the point this check runs, a leaked key in an untracked scratch file would pass clean. Used `grep -rl "BEGIN EC PRIVATE KEY" . --exclude-dir=.git` instead, which covers tracked and untracked alike.
- **Ruling (2026-09-09):** `generate-secrets.sh`'s new CA wiring is reachable from **`bootstrap-up.sh`**, not just `persistent-up` — `bootstrap-up.sh` calls `generate-secrets.sh` directly and early (so `root-domain.enc` exists before its own `route53` Terraform apply decrypts it), and `persistent-up-civo.sh`/`persistent-down.sh` call the same idempotent script again later as a no-op for anything already generated. So a `PROVIDER=civo make bootstrap-up` run for a brand-new civo project, run *before* its deliberate `make civo-ca-init` ceremony, would silently auto-generate that project's real CA as a side effect of the very first lifecycle command — earlier than `persistent-up`, which is itself downstream of `bootstrap-up`. Same crypto properties, printed fingerprint, but without the deliberate standalone step. Not code-gated, since hardcoding "this project name is special" into a general-purpose throwaway-secrets script would be worse coupling than documenting the correct operating order: **run the ceremony (`make civo-ca-init`) before the first-ever lifecycle command of any kind (`bootstrap-up` included) against a new civo project**, not after.

## 13. Definition of done

- [x] Files committed; evidence of extensions; runbooks; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
- 2026-09-09 — dependency CIVO-015 confirmed DONE; started via subagent-driven development on branch `civo-080-ca-ceremony`; promoted to IN_PROGRESS.
- 2026-09-09 — implemented via subagent-driven development: 5 tasks (script + throwaway test, gitignore/README, Makefile target, generate-secrets.sh wiring, the real ceremony) each with a fresh implementer + task review; the real ceremony (Task 5) was controller-run directly, gated on explicit operator go-ahead, and verified transparently rather than dispatched to a subagent. No fix loops needed — every task review came back clean on the first pass; two Minor findings on Task 4 were parked with rulings (recorded above in §12) rather than looped on.
- 2026-09-09 — offline evidence: `scripts/civo-ca-init.sh` shellcheck-clean; certificate extensions (`CA:TRUE`, `pathlen:1`, `keyCertSign`/`cRLSign` critical, `Subject Key Identifier`, `ecdsa-with-SHA256`, P-256, 5-year validity, correct CN/O) independently verified by task review against a throwaway project, and again by the controller against the real `vk-civo-lab` cert. Key round-trip verified byte-for-byte (throwaway) and via pubkey-match (real ceremony — the decrypted key's derived public key matches the committed certificate's public key exactly, `sha256sum` `01778632...`). `ROTATE=1` behavior verified: writes `-next` files, leaves originals untouched, `-next` key round-trips identically. Refusal-without-`ROTATE=1` verified non-destructive. `.gitignore` rules verified for both the primary and `-next` name shapes (`.pem` trackable, `-key.pem`/`.key` ignored). `generate-secrets.sh` wiring verified: civo generates a fresh throwaway CA, a second run skips it, aws never touches CA files. Repo-wide `grep -rl "BEGIN EC PRIVATE KEY" . --exclude-dir=.git` (tracked and untracked) returns only this spec's and the plan's own prose mentioning the string — no actual key material anywhere.
- 2026-09-09 — real ceremony: `make civo-ca-init PROJECT_NAME=vk-civo-lab` generated and committed `secrets/vk-civo-lab/civo-ca-cert.pem` (public) and `secrets/vk-civo-lab/civo-ca-key.enc` (KMS ciphertext via `alias/lab-secrets`, a real `aws kms encrypt` call). SHA256 fingerprint `26:FC:8B:F7:E3:36:1B:2F:35:0D:11:EB:36:6B:5E:B5:88:75:30:B0:7D:D4:B7:0C:62:EF:A0:08:82:48:81:4E`. No cloud resources beyond the KMS encrypt call (no AWS regression risk; no cluster involved). Status: `DONE`.
