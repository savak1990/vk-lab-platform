# CI Random Passwords Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every lifecycle CI run gets random admin passwords, so no cluster on a public hostname ever has the password `test`.

**Architecture:** Delete the fixed-password mode instead of turning it off. `generate-secrets.sh` keeps one path, the random one the labs already use. The workflow env block, the Makefile override and every comment that describes the mode go with it. ADR 0026 records the withdrawal. One pull request, one Hetzner lifecycle run as proof.

**Tech Stack:** Bash, GitHub Actions, AWS Secrets Manager `get-random-password`, `htpasswd`.

**Spec:** No numbered spec. The requirement comes from the 2026-11-21 security review (finding 1): CI clusters expose Argo CD and Grafana with a public password while they hold the account-wide Hetzner token and the vast.ai key. ADR 0026 section 3 accepted that exposure on a premise that no longer holds.

## Global Constraints

- Branch from fresh `origin/main` in a git worktree. Ship as one PR. Never merge; the user merges.
- The PR carries the label `ci:lifecycle-hetzner` and no `ci:skip-lifecycle`. Add both changes in one `gh pr edit` if the label ever has to change.
- `AWS_PROFILE=viacheslav-dev` for every AWS call. Region `eu-west-1`.
- Never write a real root domain, account id, or password into any file, log, commit or PR text.
- Code comments: at most 3 lines, only where the why is not obvious, never a document reference in code.
- The `local` (kind) target keeps its fixed `test` login: `LOCAL_ARGOCD_PASSWORD` and `LOCAL_GRAFANA_PASSWORD` in `scripts/argo-up.sh` are a separate mechanism and stay as they are.
- Nothing in this plan touches a running cluster.

## Facts this plan relies on (verified 2026-11-22 on `main` at `e3511ba`)

- No test, script or workflow logs in with the literal `test` on a cloud target. The Grafana e2e test reads the in-cluster Secret `grafana-admin-credentials`. The Ahorro sign-in reads SSM `.../test_user_password`. The Argo CD e2e test only GETs `/healthz`.
- `lab-role` already allows `secretsmanager:GetRandomPassword`; the labs use that path on every bring-up.
- `htpasswd` is installed by `setup-lab-tools` at `scope: full`, which the `up` and `down` jobs use. The `test` job never generates secrets.
- The `down` job regenerates missing secret files with different random values. That is harmless: `persistent-down.sh` only needs the files to decrypt, and a destroy compares nothing.
- `get-random-password` includes an upper, a lower and a digit by default, which satisfies the Cognito policy the fixed `Test1234` was chosen for.
- Only one debugging path is lost: a human login to Argo CD on a CI cluster. Grafana's password stays readable from SSM `/<project>/persistent/grafana/admin_password` until `full-down`. Argo CD is reached with `kubectl` under `lab-role`: `PROVIDER=hetzner PROJECT_NAME=vk-hetzner-ci make kubeconfig`.

---

## File map

| File | Change |
|---|---|
| `.github/workflows/lifecycle-provider.yml:63-67` | delete the comment and `FIXED_TEST_PASSWORDS: "true"` |
| `scripts/generate-secrets.sh` | delete the mode: header comment, the variable, both `if` branches, the `Test1234` argument |
| `Makefile:452-462` | `generate-secrets` target: new comment, drop the `FIXED_TEST_PASSWORDS` export |
| `scripts/argo-up.sh:35-36, 237-240` | two comments stop naming a variable that no longer exists |
| `README.md:176, 456-460` | drop the table row; rewrite the warning paragraph |
| `secrets/README.md:94-101` | the `make generate-secrets` description says random, not `test` |
| `docs/adr/0026-on-demand-full-lifecycle-ci-workflow.md` | Status line and section 3: withdrawn |

---

### Task 1: Delete the fixed-password mode

**Files:**
- Modify: `.github/workflows/lifecycle-provider.yml:59-67`
- Modify: `scripts/generate-secrets.sh:2-20, 27, 49-66, 73-75`
- Modify: `Makefile:452-462`
- Modify: `scripts/argo-up.sh:35-36, 237-240`
- Modify: `README.md:176, 456-460`
- Modify: `secrets/README.md:94-101`

- [ ] **Step 1: Worktree and branch**

```bash
cd /Users/margo/Proj/Lab/vk-lab-platform
git fetch origin
git worktree add ../vk-lab-platform-wt-ci-passwords -b harden/ci-random-passwords origin/main
cd ../vk-lab-platform-wt-ci-passwords
```

- [ ] **Step 2: Workflow env block**

In `.github/workflows/lifecycle-provider.yml` delete these five lines, so `env:` keeps only `PROVIDER`, `PROJECT_NAME` and `SUBDOMAIN`:

```yaml
  # Known credentials for debugging a failed run, rather than digging a
  # generated password out of a torn-down cluster. Accepted exposure: ArgoCD and
  # Grafana admin is the literal string "test", reachable over public HTTPS for
  # the run's lifetime - see ADR 0026.
  FIXED_TEST_PASSWORDS: "true"
```

- [ ] **Step 3: The generator keeps one path**

In `scripts/generate-secrets.sh`:

Replace the header lines 12-17 (from `# Two modes, chosen by FIXED_TEST_PASSWORDS:` to `# rejects it - never use this for the personal lab's own PROJECT_NAME.`) with:

```bash
# Passwords get random values from AWS Secrets Manager. Called automatically
# by persistent-up, and by persistent-down for a checkout that never ran it.
```

Delete line 27: `FIXED_TEST_PASSWORDS="${FIXED_TEST_PASSWORDS:-false}"`.

Replace `generate_password_if_missing` and its comment (lines 49-66) with:

```bash
# The AWS call happens only when the file is actually missing.
generate_password_if_missing() {
  local name="$1"
  if [ -f "$SECRETS_DIR/$name.enc" ]; then
    echo "Skipping $name - $SECRETS_DIR/$name.enc already exists"
    return
  fi
  SECRET_NAME="$name" SECRET_VALUE="$(random_password)" "$SCRIPT_DIR/secret-encrypt.sh"
}
```

Line 75: `generate_password_if_missing ahorro-test-user-password Test1234` becomes `generate_password_if_missing ahorro-test-user-password`.

Replace the bcrypt comment (lines 111-114, from `# argocd-admin-password.bcrypt is plaintext-committed` to `# Postgres/Grafana.`) with:

```bash
# argocd-admin-password.bcrypt is committed as a hash, so secret-encrypt.sh
# does not apply; only the hash ever reaches SSM and the cluster.
```

In `generate_bcrypt_if_missing`, replace

```bash
  local plaintext
  if [ "$FIXED_TEST_PASSWORDS" = "true" ]; then
    plaintext="test"
  else
    plaintext="$(random_password)"
  fi
```

with

```bash
  local plaintext
  plaintext="$(random_password)"
```

- [ ] **Step 4: Makefile target**

Replace lines 452-462 of `Makefile` with:

```make
## Generates any missing secrets/$(PROJECT_NAME)/ files (random passwords,
## the Roles Anywhere CA, the SSH key) and secrets/root-domain.enc from
## ROOT_DOMAIN. persistent-up runs the same script; this target exists for
## a CI/test project that needs its files before the first persistent-up.
## Usage: PROJECT_NAME=vk-lab-ci ROOT_DOMAIN=<domain> make generate-secrets
generate-secrets: export ROOT_DOMAIN := $(ROOT_DOMAIN)
generate-secrets:
	@./scripts/generate-secrets.sh
```

- [ ] **Step 5: Comments in `scripts/argo-up.sh`**

Lines 35-36 become:

```bash
# local target only. Fixed and publicly known on purpose: the kind cluster
# is throwaway, reachable from this machine only, and holds nothing real.
```

Lines 237-240 become:

```bash
# Reaches no cloud API at all. Every value the other resolvers read from SSM
# either has no local equivalent or is generated here, and the password is
# the publicly-known local "test" - nothing on this target is real enough to
# protect.
```

- [ ] **Step 6: README and secrets/README**

`README.md`: delete the table row `| \`FIXED_TEST_PASSWORDS\` | unset | \`true\` for CI only |` (line 176). Replace the paragraph at 456-460 (from `That is the whole sequence` to `only for throwaway CI environments.`) with:

```markdown
That is the whole sequence — `bootstrap-up` creates the new project's state
bucket and generates its secrets (random passwords) before anything needs
them. `make generate-secrets` runs the same generator and is only needed when
a project's files must exist before its first `persistent-up`.
```

`secrets/README.md` lines 94-101: replace `(each a fixed value,
\`test\`)` with `(each a random value)`, and delete the last sentence `Never use
this for the personal lab's own \`PROJECT_NAME\`; these values are fixed
and publicly known.`

- [ ] **Step 7: Prove nothing still names the mode, and the scripts parse**

```bash
git grep -n "FIXED_TEST_PASSWORDS\|Test1234" -- . ':!docs/adr' ':!specs' ':!docs/superpowers' || echo clean
bash -n scripts/generate-secrets.sh scripts/argo-up.sh
make scripts-check
command -v actionlint >/dev/null && actionlint .github/workflows/lifecycle-provider.yml
```

Expected: `clean`, no output from `bash -n`, `scripts-check` passes, `actionlint` passes or is absent.

- [ ] **Step 8: One real run of the generator, then remove its output**

This is the runnable check for the one path that remains. It needs AWS and the account-global KMS key, and writes under `secrets/plan-check/`, which must never be committed. `PROVIDER=aws` skips the CA and the SSH key, so nothing is created outside the repo.

```bash
export AWS_PROFILE=viacheslav-dev
PROJECT_NAME=plan-check PROVIDER=aws scripts/generate-secrets.sh 2>&1 | grep -E "Generated|Skipping|error" | sed -E 's/[0-9]{12}/<acct>/g'
head -c 7 secrets/plan-check/argocd-admin-password.bcrypt; echo
PROJECT_NAME=plan-check make secret-decrypt NAME=ahorro-test-user-password | wc -c
rm -rf secrets/plan-check
git status --short secrets/
```

Expected: `Generated` lines for `postgres-app-password`, `grafana-admin-password`, `ahorro-test-user-password` and `argocd-admin-password.bcrypt`; two `Skipping` lines for the CA and the SSH key; `$2y$10$`; `32`; and an empty `git status` for `secrets/`.

- [ ] **Step 9: Commit**

```bash
git add .github/workflows/lifecycle-provider.yml scripts/generate-secrets.sh Makefile scripts/argo-up.sh README.md secrets/README.md
git commit -m "Give every CI cluster random admin passwords"
```

---

### Task 2: ADR 0026 records the withdrawal

**Files:**
- Modify: `docs/adr/0026-on-demand-full-lifecycle-ci-workflow.md` (Status, and section 3)

- [ ] **Step 1: Status line**

Find the `## Status` section of the ADR. Append to its paragraph:

```markdown
Amended 2026-11-22: section 3, the fixed `test` password for CI runs, is
withdrawn; see the note in that section.
```

- [ ] **Step 2: Section 3**

Append under `### 3. \`FIXED_TEST_PASSWORDS=true\` in this workflow`, after its last paragraph:

```markdown
**Withdrawn 2026-11-22.** The premise "holds only synthetic CI data" stopped
being true when the CI projects started to receive the account-wide Hetzner
token (`kube-system/hcloud`) and the global vast.ai key and LLM token
(namespace `llm`). A public `test` login on a hostname that is committed to
this repository was then a path from the internet to the personal lab's
servers. The mode is deleted, not disabled: `generate-secrets.sh` has one
path, the random one every lab already uses. Grafana's password stays
readable from SSM for the run's lifetime. Argo CD on a CI cluster is reached
with `kubectl` under `lab-role`, not with a browser login.
```

- [ ] **Step 3: Commit, push, open the PR**

```bash
git add docs/adr/0026-on-demand-full-lifecycle-ci-workflow.md docs/superpowers/plans/2026-11-22-ci-random-passwords.md
git commit -m "ADR 0026: withdraw the fixed CI password"
git push -u origin harden/ci-random-passwords
gh pr create --title "Give every CI cluster random admin passwords" --label ci:lifecycle-hetzner --body "$(cat <<'B'
CI lifecycle runs generated Argo CD and Grafana admin passwords as the literal
`test`, on hostnames that are committed here, while the CI cluster holds
account-wide cloud credentials. ADR 0026 accepted that on the premise that a CI
cluster holds nothing real; that premise no longer holds.

This deletes the fixed-password mode rather than turning it off: the generator
keeps the random path the labs already use. No test or script depended on the
literal. The lifecycle run on this PR is the proof: `up` generates, `test`
reads Grafana's password from the cluster, `down` destroys.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01GiCsYKAgwEUe6VjvFBJRpg
B
)"
```

---

### Task 3: Proof from the lifecycle run

No files. The PR's own `lifecycle-hetzner` run is the acceptance test.

- [ ] **Step 1: Wait for the run, then read three things**

```bash
RUN="$(gh run list --repo savak1990/vk-lab-platform --branch harden/ci-random-passwords --limit 1 --json databaseId -q '.[0].databaseId')"
gh run view "$RUN" --repo savak1990/vk-lab-platform --json jobs -q '.jobs[]|select(.name|test("lifecycle-hetzner|pr-gate"))|"\(.name): \(.conclusion)"'
UP="$(gh run view "$RUN" --repo savak1990/vk-lab-platform --json jobs -q '.jobs[]|select(.name=="lifecycle-hetzner / up")|.databaseId')"
gh run view "$RUN" --repo savak1990/vk-lab-platform --job "$UP" --log | grep -E "Generated .*(password|bcrypt)" | cut -d$'\t' -f3-
gh run view "$RUN" --repo savak1990/vk-lab-platform --job "$UP" --log | grep -c "::add-mask::" ; true
```

Expected: `up`, `test`, `down` and `pr-gate` all `success`; four `Generated` lines (three `.enc`, one `.bcrypt`); no plaintext anywhere in the log (a random value never appears because the generator never echoes it).

- [ ] **Step 2: While the run is in its `test` job, the old login must fail**

Optional, needs a browser and the run window of a few minutes: open `https://argo.hzci.<root-domain>` and try `admin` / `test`. Expected: rejected.

- [ ] **Step 3: Hand over**

Tell the user the run is green and the PR is ready to merge. The user merges. No live cluster changes follow: the labs already use random passwords, and the next CI run picks the new generator up from `main`.

---

## Skipped, and when to add it

- **Plaintext Argo CD password in SSM for CI projects** (so an operator can use the Argo UI on a CI cluster). Add when someone actually needs the UI during a failed run and `kubectl` under `lab-role` is not enough. Shape when it comes: generate `argocd-admin-password.enc` next to the bcrypt, decrypt it into a SecureString in `terraform/modules/persistent-secrets`, guarded by `fileexists()` so the labs without that file keep working.
- **A separate Hetzner project for CI**, which would take the shared token out of CI clusters altogether. Blocked by the 5-server account limit shared with the lab.
- **A unit test for `generate-secrets.sh`.** The remaining logic is "skip if the file exists, else encrypt a random value"; Task 1 Step 8 runs it once for real, and every lab bring-up runs it again.

## Time

Task 1 about 30 minutes. Task 2 about 10 minutes. Task 3 is one Hetzner lifecycle run, about 45 minutes of waiting.
