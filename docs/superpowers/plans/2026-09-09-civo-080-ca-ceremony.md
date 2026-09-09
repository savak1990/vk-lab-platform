# CIVO-080 implementation plan — offline CA ceremony

Spec: `specs/civo/080-rolesanywhere-ca-ceremony/spec.md`. Depends on
CIVO-015 (DONE, ADR 0029 accepted). Branch: `civo-080-ca-ceremony`, forked
from `main` at the baseline verified clean by `make gitops-check`.

This is the highest-leverage unblocked task in the index: CIVO-082, 085,
090, 100, 110, 180, 200 all sit behind it directly or transitively. It is
also the session's first root-of-trust action — the CA private key this
script generates becomes, per ADR 0029, equivalent in blast radius to a
`lab-role` compromise if the `CIVO_TOKEN` is ever leaked. Nothing here is
reversible the way a Helm values change is: once `civo-ca-cert.pem` is
committed and trusted by real infrastructure (CIVO-082+), rotating it is a
multi-spec runbook, not a revert.

## Context gathered before planning

- `secrets/vk-civo-lab/` already exists (from CIVO-050/060 sessions) with
  `postgres-app-password.enc`, `grafana-admin-password.enc`,
  `argocd-admin-password.bcrypt`. This spec adds `civo-ca-cert.pem` and
  `civo-ca-key.enc` alongside them.
- `.gitignore`'s `secrets/` block currently whitelists only `*.enc`,
  `*.bcrypt`, `root-domain.enc`, `civo-token.enc`, and `README.md` — a
  `.pem` file is **not yet excepted** and would currently be git-ignored
  by the blanket `secrets/*/*` rule. This plan adds the exception
  narrowly (`!secrets/*/*.pem`), not by relaxing the blanket rule.
- `scripts/secret-encrypt.sh` takes `SECRET_NAME`/`SECRET_VALUE` from the
  environment (never argv), so a multi-line PEM value is safe to pass
  through it directly — this is the existing pattern the CA key rides on,
  not a new one.
- `openssl` on this machine is LibreSSL 3.3.6 (macOS system default).
  **Verified empirically before writing this plan:** `openssl req -x509
  ... -extfile ext.cnf` does NOT apply the extension file on LibreSSL —
  `req -x509`'s extension flags are `-extensions`/`-addext`/`-config`, not
  `-extfile`; `-extfile` silently produces a cert with no
  `X509v3 extensions` block at all (confirmed by rendering the output and
  finding `X509v3` absent). The **two-step CSR form** (`req -new` to build
  a CSR, then `x509 -req -extfile ext.cnf` to self-sign it) DOES apply the
  extension file correctly on LibreSSL — confirmed by rendering the
  output and finding `CA:TRUE, pathlen:1`, `Certificate Sign, CRL Sign`,
  and `Subject Key Identifier` all present. Use the two-step form. This
  also needs a plain-CSR-signkey step (`x509 -req -signkey`, not a CA
  database), since there is no CA index file for a self-signed root.

## Rulings

**Ruling 1 — validity days literal.** Spec says "5 years" without a day
count. Use `1826` days (5×365 + 1 leap day, matching how this repo already
treats ACM/cert lifetimes elsewhere — round up, never down, on a duration
that's expensive to extend later). Cost if wrong: cosmetic; nobody
depends on the exact expiry day for 5 years.

**Ruling 2 — rotation writes `-next` files, this task only builds the
generator.** Spec §4's rotation runbook needs `ROTATE=1` to write
`civo-ca-cert-next.pem` / a `civo-ca-key-next.enc` distinct name instead
of overwriting the live ones (so CIVO-082 can add a second trust anchor
before the old one is retired). The script accepts `ROTATE=1` and switches
its output filenames to the `-next` suffix; it does not implement any of
CIVO-082/085's actual dual-anchor cutover, since that's out of scope here
by §2's own words. Cost if wrong: a future spec finds the `-next` naming
convention doesn't fit and renames it — a one-line script change, no data
loss, since nothing consumes the convention yet.

**Ruling 3 — fingerprint output only, never the key material, on stdout
under any code path.** This is stated as an acceptance criterion (§4's
"prints the fingerprint only") but is worth calling out as a hard
constraint the task reviewer must check explicitly, given the root-of-
trust sensitivity: no `set -x`, no accidental `cat` of the temp key file,
no echoing `$VALUE`-shaped content anywhere in the script.

**Ruling 4 — keep "civo" in the CN and filenames, per operator decision
(2026-09-09).** Considered generalizing to a provider-agnostic
`${project}-workload-ca`/`rolesanywhere-ca-*` naming, since Roles Anywhere
itself isn't Civo-specific and `pathlen:1` already anticipates a future
intermediate (CIVO-200). Operator chose to keep the spec's original
`civo`-scoped naming: `${project}-civo-workload-ca`,
`secrets/<project>/civo-ca-cert.pem`/`civo-ca-key.enc` — matching what
CIVO-082's already-written §4 expects verbatim, no cross-spec correction
needed. Cost if wrong: a future second non-EKS provider would need this
CA renamed via the rotation runbook — a real but bounded cost, accepted
knowingly rather than by default.

## Design

### `scripts/civo-ca-init.sh` (new)

```bash
#!/usr/bin/env bash
# Generates the Roles Anywhere root CA: an EC P-256 self-signed certificate
# committed as public material, and its private key committed as KMS
# ciphertext via secret-encrypt.sh. Refuses to overwrite an existing CA
# unless ROTATE=1, which redirects output to *-next files instead.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
ROTATE="${ROTATE:-}"

SECRETS_DIR="$REPO_ROOT/secrets/$PROJECT_NAME"
mkdir -p "$SECRETS_DIR"

if [ -n "$ROTATE" ]; then
  CERT_FILE="$SECRETS_DIR/civo-ca-cert-next.pem"
  KEY_NAME="civo-ca-key-next"
else
  CERT_FILE="$SECRETS_DIR/civo-ca-cert.pem"
  KEY_NAME="civo-ca-key"
fi

if [ -f "$CERT_FILE" ] && [ -z "$ROTATE" ]; then
  echo "$CERT_FILE already exists. Set ROTATE=1 to generate a rotation candidate." >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -P "$WORKDIR"/*.key 2>/dev/null; rm -rf "$WORKDIR"' EXIT
umask 077

KEY_FILE="$WORKDIR/ca.key"
CSR_FILE="$WORKDIR/ca.csr"
CERT_TMP="$WORKDIR/ca.pem"
EXT_FILE="$WORKDIR/ext.cnf"

openssl ecparam -name prime256v1 -genkey -noout -out "$KEY_FILE"

cat > "$EXT_FILE" <<EOF
basicConstraints=critical,CA:true,pathlen:1
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
EOF

openssl req -new -key "$KEY_FILE" -sha256 \
  -subj "/O=${PROJECT_NAME}/CN=${PROJECT_NAME}-civo-workload-ca" \
  -out "$CSR_FILE"

openssl x509 -req -in "$CSR_FILE" -signkey "$KEY_FILE" -sha256 -days 1826 \
  -extfile "$EXT_FILE" \
  -out "$CERT_TMP"

# Encrypt the key before writing the cert to its committed path: if KMS
# encryption fails, no half-written pair is left behind for a re-run to
# trip over (the cert-exists refusal would otherwise block retrying).
SECRET_NAME="$KEY_NAME" SECRET_VALUE="$(cat "$KEY_FILE"; echo)" PROJECT_NAME="$PROJECT_NAME" \
  "$REPO_ROOT/scripts/secret-encrypt.sh"

cp "$CERT_TMP" "$CERT_FILE"

echo "Wrote ${CERT_FILE#$REPO_ROOT/}"
openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256
```

Notes for the implementer, not to be pasted verbatim without verification:
- The two-step CSR-then-self-sign form (not `req -x509 ... -extfile`) is
  **required**, not a style choice — verified empirically against this
  machine's LibreSSL 3.3.6 above; `req -x509`'s `-extfile` flag is
  silently ignored there, producing a root cert with no
  `basicConstraints`/`keyUsage` at all, which Roles Anywhere would reject
  as a trust anchor. Re-verify the same rendering check
  (`openssl x509 -text -noout | grep -A3 X509v3`) in the implementer's
  own environment before trusting this — do not assume it holds on a
  different OpenSSL/LibreSSL build without checking.
- `SECRET_VALUE="$(cat "$KEY_FILE"; echo)"` restores the PEM's trailing
  newline that command substitution strips — `secret-encrypt.sh`'s
  `printf '%s'` would otherwise commit a PEM missing its final newline,
  which some strict PEM parsers reject even though `openssl ec -check`
  doesn't care. **Verify this actually round-trips byte-for-byte**, not
  just that `openssl ec -check` passes (it normalizes and won't notice a
  missing newline): decrypt and `cmp`/`sha256sum` the result against the
  original `$KEY_FILE` in Task 1 step 3.
- Encrypt-before-write ordering: `secret-encrypt.sh` runs before
  `cp "$CERT_TMP" "$CERT_FILE"`, so a KMS failure never leaves a committed-
  shaped public cert with no matching key on disk (which would otherwise
  make a retry hit the "already exists" refusal with nothing to retry).
- Confirm `rm -P` exists on macOS (`man rm` — BSD `rm` supports `-P` as a
  3-pass overwrite; GNU `rm` on Linux CI runners does not — guard with
  `command -v` or `uname` and fall back to `shred -u` on Linux, per spec
  §4's "`rm -P` on macOS, `shred` where available" wording).
- `secret-encrypt.sh` writes to `secrets/$PROJECT_NAME/$NAME.enc`
  unconditionally for any name other than `root-domain`/`civo-token` — no
  change needed there, just confirm the round-trip in Task 1 step 2.

### `.gitignore`

Add, inside the existing secrets block, right after the `*.bcrypt`
exception line:

```
!secrets/*/*.pem
```

And add an explicit, defense-in-depth block for raw key material even
though the blanket `secrets/*/*` rule already covers it implicitly (spec
§2 calls this out by name as in-scope):

```
*.key
*-key.pem
```

### `secrets/README.md`

Add a new exception paragraph (mirroring the existing `.bcrypt` exception
paragraph's shape) documenting that `civo-ca-cert.pem` is public
certificate material, committed in the clear on purpose, and stating why
(Roles Anywhere trust anchors are public certs by design — the private
key is the only secret, and that's the `.enc` file next to it). Add the
rotation runbook (generate-with-`ROTATE=1` → CIVO-082 adds second trust
anchor → CIVO-085 switches issuer → wait 24h for outstanding certs to
expire → remove old anchor and files) and the revocation runbook
(`aws rolesanywhere disable-trust-anchor` stops new sessions immediately;
existing sessions still expire on their own within 1h) verbatim from spec
§4, in the README's own prose voice.

### `Makefile`

Add `civo-ca-init` to the `.PHONY` line and a target mirroring
`secret-encrypt`'s shape:

```makefile
## Generates the Roles Anywhere root CA: a public cert (secrets/$(PROJECT_NAME)/civo-ca-cert.pem)
## and its KMS-encrypted private key. Refuses to overwrite; set ROTATE=1 for a rotation candidate.
## Usage: make civo-ca-init [PROJECT_NAME=vk-civo-lab] [ROTATE=1]
civo-ca-init: export PROJECT_NAME := $(PROJECT_NAME)
civo-ca-init: export ROTATE := $(ROTATE)
civo-ca-init:
	@./scripts/civo-ca-init.sh
```

Place it directly after `generate-secrets` in the Makefile, matching the
spec's file grouping.

## Tasks

### Task 1 — write and test the script against a throwaway project name
1. Create `scripts/civo-ca-init.sh` as designed above (verify the
   macOS/Linux `rm -P`/`shred` fallback and the LibreSSL/OpenSSL extension
   syntax empirically, don't just trust the draft).
2. `chmod +x scripts/civo-ca-init.sh`; run `shellcheck` clean.
3. Test against `PROJECT_NAME=civo-ca-ceremony-test` (never `vk-civo-lab`
   this task — that's Task 4). Verify:
   - `openssl x509 -in secrets/civo-ca-ceremony-test/civo-ca-cert.pem -text -noout`
     shows `CA:TRUE`, `pathlen:1`, `Certificate Sign, CRL Sign`, SHA256,
     the correct CN/O, ~5-year validity window, EC prime256v1.
   - The encrypted key round-trips: `PROJECT_NAME=civo-ca-ceremony-test scripts/secret-decrypt.sh civo-ca-key | openssl ec -check -noout`
     in memory only (never written to disk) reports the key is valid.
   - **Byte-for-byte round-trip, not just `openssl ec -check`** (which
     normalizes and won't catch a missing trailing newline): compare
     `scripts/secret-decrypt.sh civo-ca-key | sha256sum` against the
     original key material's own `sha256sum`, computed in the same
     in-memory-only manner (no key material written to disk to compute
     it) — confirms the `; echo` newline fix in the script actually works.
   - Re-running the script without `ROTATE=1` refuses (non-zero exit,
     clear stderr message, no files touched).
   - Re-running with `ROTATE=1` writes `civo-ca-cert-next.pem` /
     `civo-ca-key-next.enc`, leaving the original two files untouched;
     verify the `-next` key round-trips the same way as the primary one.
   - Script output never contains the private key PEM anywhere in stdout.
4. Delete the `secrets/civo-ca-ceremony-test/` throwaway files (both the
   `.pem` and the `.enc`) at the end of this task — they must never be
   committed.

### Task 2 — `.gitignore` and `secrets/README.md`
1. Add the `.gitignore` changes above.
2. Add the README exception paragraph, rotation runbook, and revocation
   runbook above.
3. Verify against a throwaway project directory, not the real
   `vk-civo-lab` (which stays untouched until Task 4):
   `mkdir -p secrets/gitignore-test && touch secrets/gitignore-test/civo-ca-cert.pem && git status --short`
   shows it as trackable (not ignored) — `!secrets/*/*.pem` matches any
   project directory identically, so this proves the rule without staging
   anything under the real path. `touch secrets/gitignore-test/civo-ca-key.pem && git status --short`
   must show nothing (still ignored, proving the `*-key.pem` block
   works). **Also check the `-next` rotation-candidate names**:
   `touch secrets/gitignore-test/civo-ca-cert-next.pem` must show as
   trackable and `touch secrets/gitignore-test/civo-ca-key-next.pem` must
   show as ignored, the same as the primary pair — `civo-ca-key-next.enc`
   is already covered by the existing `!secrets/*/*.enc` rule, so only the
   `.pem`/`-key.pem` shapes need checking here. Remove
   `secrets/gitignore-test/` entirely afterward.

### Task 3 — Makefile target
1. Add `civo-ca-init` to `.PHONY` and the target block as designed above.
2. `make civo-ca-init PROJECT_NAME=civo-ca-ceremony-test-2` exercises the
   full make-wrapped path once; verify and delete the throwaway output
   the same way Task 1 did.

### Task 4 — wire into `generate-secrets.sh` for arbitrary/throwaway projects
Ordered before the real ceremony (Task 5) so every code path is reviewed
and clean before the irreversible action runs. Per operator decision
(2026-09-09): `vk-civo-lab`'s CA is the deliberate, committed ceremony
(Task 5). A CI run against an arbitrary, ephemeral `PROJECT_NAME` needs
the same auto-generate-if-missing treatment already given to
`postgres-app-password`/`grafana-admin-password` — generated locally for
that run, never committed (this script has never committed anything to
git; Terraform reads the local file during that run only).
1. `scripts/generate-secrets.sh`: source `scripts/lib/provider.sh` for
   `$PROVIDER` (the script currently doesn't look at `PROVIDER` at all,
   since DB passwords are needed by both providers — the CA is civo-only).
2. Add `generate_ca_if_missing()`, matching the shape of the existing
   `generate_password_if_missing()`: if `$PROVIDER = civo` and
   `secrets/$PROJECT_NAME/civo-ca-cert.pem` doesn't exist, call
   `PROJECT_NAME="$PROJECT_NAME" "$SCRIPT_DIR/civo-ca-init.sh"`; otherwise
   log the same "Skipping X - already exists" pattern. Call it after the
   existing `generate_password_if_missing` calls.
3. Test: `PROVIDER=civo PROJECT_NAME=civo-ca-gs-test FIXED_TEST_PASSWORDS=true make generate-secrets`
   produces a fresh CA for a throwaway name; a second run skips it (no
   `ROTATE=1` needed — the skip happens before `civo-ca-init.sh` is ever
   invoked). `PROVIDER=aws ... make generate-secrets` must not touch any
   CA file. Delete `secrets/civo-ca-gs-test/` afterward — never commit it.
4. Note in passing (no code change): once Task 5 commits `vk-civo-lab`'s
   real CA, a `generate-secrets` run against `vk-civo-lab` will also just
   skip CA generation via the same existence check — no special-casing
   needed between "the real project" and "a throwaway one."

### Task 5 — the real ceremony for `vk-civo-lab`
**This step is the actual root-of-trust action — stop and get explicit
operator go-ahead before running it, even though the rest of this plan
runs autonomously.** Runs last, after every code path around it (script,
gitignore, Makefile, generate-secrets wiring) has already been built and
reviewed clean. Once authorized:
1. `make civo-ca-init PROJECT_NAME=vk-civo-lab`.
2. Run the same verification battery as Task 1 step 3 against the real
   output (extensions, byte-for-byte round-trip, fingerprint), plus spec
   §8's stated acceptance check, **adapted from its literal wording**:
   spec §8 names `git grep -l "BEGIN EC PRIVATE KEY"`, but `git grep`
   only searches tracked files — at the moment this check would run, any
   leaked key sitting in an untracked scratch file would pass clean and
   the check would prove nothing. Use
   `grep -rl "BEGIN EC PRIVATE KEY" . --exclude-dir=.git` instead (covers
   tracked and untracked alike), and record this deviation from the
   spec's literal command in the execution evidence.
3. `git add secrets/vk-civo-lab/civo-ca-cert.pem secrets/vk-civo-lab/civo-ca-key.enc`
   — review `git status`/`git diff --cached --stat` before committing;
   confirm no other file is staged and the `.enc` file is opaque
   ciphertext, not readable key material.
4. Commit with a message recording the fingerprint (public info, safe in
   a commit message) but never the key.

### Task 6 — close the spec
Set `status: DONE`, `completed`, record execution evidence (script
verification, gitignore verification, real ceremony fingerprint, no
key-material leak checks, generate-secrets wiring evidence) per README
protocol step 7; update `specs/civo/README.md` index row. Also note in
§12 that `CIVO-205` was opened as a tracked follow-up for `lab-role`
least-privilege review (deferred, not part of this spec's scope), and
that a fully-automated ephemeral-CI-project Roles-Anywhere flow (beyond
`generate-secrets.sh`'s local-only generation) has no consuming spec yet
— flag it as an open question for whichever future spec needs it (likely
CIVO-140's unscoped successor or the not-yet-written PR-validation spec).

## Global constraints (carried into every task dispatch)

- Never write the CA private key to stdout, a log file, or any committed
  file — only `secret-encrypt.sh`'s KMS ciphertext output and the
  in-memory `openssl ec -check` round-trip may see the plaintext key.
- Never run the real ceremony (Task 5) against `vk-civo-lab` without
  fresh, explicit operator authorization at that step specifically — the
  earlier "let's go" authorizing this plan's autonomous execution covers
  Tasks 1-4, not the irreversible root-of-trust action in Task 5.
- Never commit a throwaway/test project's ceremony output.
- No ticket/spec IDs in code comments or runtime/error strings.
- Comments ≤3 lines.
- `shellcheck` clean on every new/edited script.
