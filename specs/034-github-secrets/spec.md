# 034 — GitHub Secrets as the Source of Truth for Terraform Inputs

**Status:** Ready — approved for implementation, not started.

**Complexity:** Medium. The code change is small and mechanical. The governance
change is the large part: this spec reverses a decision the constitution and
three ADRs currently state.
**Risk:** High. Every entry point that supplies a secret to Terraform changes at
once. One value, `postgres-app-password`, cannot be rotated without breaking a
recovered database.
**Estimated cost:** ~1 day, plus one `make persistent-up` and one full
`make up`/`make down` cycle to prove it · AWS runtime cost: one disposable
cluster's usual spend.
**Recommended model:** Opus. The failure mode is silent plaintext leakage or an
unrecoverable database, and the spec reverses a recorded decision.
**Depends on:** ADR 0007 (fork configurability), ADR 0014 (the
never-regenerate rule for `postgres-app-password`), ADR 0023 (SSM Parameter
Store, which removed the previous GitHub-secret path), ADR 0030 (Civo API token
handling), spec 013 (secrets), CIVO-010 (the `PROVIDER` command surface).
**Lifecycle class(es) touched:** Bootstrap and Persistent inputs. No Disposable
resource changes.

## 1. Why this spec exists

The operator decided that GitHub secrets become the source of truth for every
value that Terraform needs as an input. The reasons given: fewer moving parts,
and a smaller attack surface than committed ciphertext.

Today the platform commits KMS-encrypted ciphertext files under `secrets/` and
decrypts them at apply time. That mechanism has three costs the operator wants
removed:

1. Every apply makes an AWS KMS round trip before Terraform can read a value.
2. `make bootstrap-down` destroys `alias/lab-secrets`. After the key's deletion
   window, every committed `*.enc` file becomes permanently unreadable. The
   files stay in Git and look valid. They are not.
3. A fork owner must run `make secret-encrypt` and commit ciphertext before the
   platform will apply.

## 2. The constraint that shapes the design

**A GitHub Actions secret cannot be read back.** The REST endpoint
`GET /repos/{owner}/{repo}/actions/secrets/{name}` returns the name and two
timestamps. It never returns the value. `gh secret list` prints names only. The
`integrations/github` Terraform provider registers no singular
`github_actions_secret` data source at all. Its plural `github_actions_secrets`
data source exposes only `name`, `created_at` and `updated_at`. The provider's
own `resourceGithubActionsSecretRead` reads those three fields and never touches
the value. The Go SDK struct behind it has no field for a value. Note the
argument rename: `plaintext_value` and `encrypted_value` are deprecated,
replaced by `value` and `value_encrypted`.

Every GitHub secret family behaves this way — Actions, Dependabot and
Codespaces, at repository, organization, environment and user scope. All use one
write-only sealed-box design. **Actions *variables* are the exception: their API
returns the value, and `gh variable get` reads it.** That matters for the open
question in section 8.

Only the Actions runtime can decrypt a secret, and only into a job's
environment.

Therefore the platform cannot "fetch secrets with the GitHub Terraform
provider". The workable form of the same intent is:

> **Terraform reads every secret from a `TF_VAR_*` environment variable. The
> context supplies that variable. GitHub Actions supplies it from a GitHub
> secret. A workstation supplies it from a local file that Git ignores.**

This keeps one code path for both providers and both contexts, which is what
"common logic for AWS and Civo" asks for. It does not keep one *source*.

## 3. What this reverses, and why that is acceptable

ADR 0007 alternative (c), as superseded by ADR 0023, removed a
`secrets.ROOT_DOMAIN` GitHub secret and replaced it with in-workflow decryption
of `secrets/root-domain.enc`. The stated benefit was that CI and a workstation
then used one mechanism.

This spec gives that benefit up on purpose. After this spec there are two
sources: a GitHub secret in CI, and `secrets/local.env` on a workstation. The
operator accepts that trade for the three costs listed in section 1. The
implementer must record the reversal in a new ADR rather than edit the old ones
in place. An ADR records what was decided when.

## 4. Scope

In scope: every value that Terraform or a script reads as an **input**.

| Value | Today | After |
|---|---|---|
| `root-domain` | `secrets/root-domain.enc` | GitHub secret `ROOT_DOMAIN` |
| `civo-token` | `secrets/civo-token.enc` | GitHub secret `CIVO_TOKEN` |
| `postgres-app-password` | `secrets/<project>/postgres-app-password.enc` | GitHub secret `POSTGRES_APP_PASSWORD` |
| `grafana-admin-password` | `secrets/<project>/grafana-admin-password.enc` | GitHub secret `GRAFANA_ADMIN_PASSWORD` |
| `argocd-admin-password.bcrypt` | committed one-way hash | unchanged |

Not in scope:

- SSM Parameter Store for Terraform-**derived** config. ADR 0023's other half
  stays exactly as it is. This spec touches inputs, not outputs.
- The `alias/lab-secrets` KMS key. It still encrypts SSM `SecureString`
  parameters, so it stays. Only the committed ciphertext files go away.
- Runtime application secrets inside the cluster. Spec 013 owns those.
- IAM Roles Anywhere and Pod Identity. Unchanged.

## 5. Requirements

1. **Terraform takes plain variables.** Delete both `data "aws_kms_secrets"`
   blocks — `terraform/modules/root-domain/main.tf:1` and
   `terraform/modules/persistent-secrets/main.tf:1`. Each module takes the
   value as a `variable` marked `sensitive = true`. Terragrunt passes it
   through. The variable is populated from `TF_VAR_*`, never from a file path.
   Delete the `*_secret_path` variables.

2. **The Makefile is the single injection point.** Before any Terragrunt or
   script call, the Makefile sources `secrets/local.env` when that file exists.
   The existing `secrets/*` deny-all rule in `.gitignore` already ignores that
   path; confirm with `git check-ignore -v secrets/local.env` and add no new
   rule. When the file is absent, the environment is used as-is, which is what
   CI needs.

3. **CI maps GitHub secrets to `TF_VAR_*`.** `lab.yml` and
   `lifecycle-test.yml` set `TF_VAR_root_domain: ${{ secrets.ROOT_DOMAIN }}`
   and the equivalent for each other value, at job level. `CIVO_TOKEN` keeps
   its own name, because the Civo Terraform provider and the `civo` CLI both
   read that exact variable.

4. **Every missing value fails early with a named error.** Extend
   `scripts/require-persistent-secrets.sh` to check the environment instead of
   the filesystem. It must name the missing variable and the GitHub secret that
   supplies it. It must never print a value.

5. **`postgres-app-password` must never change once a database exists.** CNPG's
   `bootstrap.recovery` restores PGDATA without resetting role passwords, so a
   new password desynchronises from a recovered database (ADR 0014, spec
   007-2). Two guards:
   - `secrets/README.md` states this in the instructions for that one secret.
   - `persistent-up` compares the supplied value against the copy already in
     AWS Secrets Manager and fails when they differ, rather than applying the
     new one. The operator overrides deliberately with a named variable.

6. **Delete the ciphertext mechanism.** Remove `secrets/*.enc`,
   `scripts/secret-encrypt.sh`, `scripts/secret-decrypt.sh`, and the encryption
   half of `scripts/generate-secrets.sh`. Remove the `civo_token()` helper from
   `scripts/lib/provider.sh`; `CIVO_TOKEN` now arrives in the environment
   already. Keep `argocd-admin-password.bcrypt` and the `.gitignore` allow-rule
   that admits it.

7. **`generate-secrets.sh` keeps its CI role, without KMS.** For a throwaway CI
   project it still produces fixed, publicly-known test values. It exports them
   as environment variables instead of writing ciphertext.

8. **Documentation.** See section 6. The documentation change is a deliverable
   of this spec, not a follow-up.

## 6. Documentation to update

Each item below currently states or assumes the ciphertext mechanism.

**New ADR** — `docs/adr/0032-github-secrets-for-terraform-inputs.md`. It records
this decision, supersedes ADR 0007 alternative (c) as resolved by ADR 0023,
supersedes the input half of ADR 0023, and supersedes ADR 0030's
KMS-ciphertext discipline for `CIVO_TOKEN`. It must state the trade accepted in
section 3 and must not edit those ADRs in place beyond a superseded-by note.

**Constitution** — `specs/000-constitution/spec.md`:

| Line | Currently states | Change |
|---|---|---|
| 107 | Each committed secret MUST be its own ciphertext file under `secrets/` | Replace with the one-secret-per-GitHub-secret rule and the no-combining rule |
| 276 | The root domain MUST use the KMS ciphertext mechanism | Point at the GitHub secret `ROOT_DOMAIN`. Keep the hygiene-not-security framing. State that it is a secret rather than a variable for uniformity, not because it is a credential |
| 333 | The `local` target's only AWS call is decrypting `secrets/*.enc` | The `local` target now makes no AWS call at all. This strengthens §333 |
| 354 | Fork setup includes committing your own `root-domain.enc` | Fork setup becomes: bootstrap, set four GitHub secrets, set `AWS_ROLE_ARN` |
| 356 | ADR 0023 superseded the separate-GitHub-secret path | Rewrite: ADR 0032 restores it, and says why |
| 369 | `CIVO_TOKEN` uses the same ciphertext discipline, ADR 0030 | Point at ADR 0032 |

**`secrets/README.md`** — rewrite. It becomes the operator's setup page: the
four secrets, what each is, where to get the value, the exact
`gh secret set` command, and the never-rotate warning on
`POSTGRES_APP_PASSWORD`. It also explains `secrets/local.env` for workstation
use and states that Git already ignores it.

**`CLAUDE.md`** — the "Secrets and authentication" section states the
one-ciphertext-file-per-secret rule. Replace it. Keep every other rule in that
section unchanged: no plaintext in Git, no long-lived AWS credentials in
Actions, OIDC only, Pod Identity for workloads, Secrets Manager for runtime
secrets.

**`docs/architecture.md`** — §17 and §18 describe the secret flow. Update both.

**Stack READMEs** — `terraform/live/account/README.md`,
`terraform/live/bootstrap/README.md`, `terraform/live/persistent/README.md`,
`terraform/live/state/README.md` each reference `make secret-encrypt` or a
`.enc` file.

**Specs that describe the old flow** — `specs/013-secrets/spec.md` (its
"deterministic KMS-encrypted bootstrap ciphertext flow" bullet),
`specs/022-local-dev-mode` (requirements 11–13), and
`specs/civo/README.md` if its protocol text names the ciphertext path.

## 7. Acceptance criteria

1. `grep -rn "\.enc" --exclude-dir=.git .` returns no hit outside historical
   ADR text and this spec.
2. `make secret-encrypt` and `make secret-decrypt` no longer exist.
3. With `secrets/local.env` present, `PROVIDER=aws make persistent-up` and
   `PROVIDER=civo make persistent-up` both succeed on a clean checkout with no
   file under `secrets/` except `README.md` and the `.bcrypt` hash.
4. With one variable unset, the run fails before Terraform starts, and the
   error names both the variable and the GitHub secret.
5. `terraform state pull | grep -c "<a real secret value>"` returns 0 for every
   unit. No secret value reaches state that did not reach it before.
6. A full `make up` → write data → `make down` → `make up` cycle recovers the
   database, proving `postgres-app-password` did not change.
7. Requirement 5's guard is proved: change `POSTGRES_APP_PASSWORD`, run
   `persistent-up`, and confirm it fails rather than applying.
8. `make bootstrap-down` followed by `make bootstrap-up` no longer strands any
   value.
9. Every document in section 6 is updated. No document still instructs an
   operator to commit ciphertext.

## 8. Risks and open questions

- **A workstation loses the only local copy.** `secrets/local.env` is not in
  Git. A GitHub secret cannot be read back. If the operator loses both, the
  values are gone. `POSTGRES_APP_PASSWORD` is the dangerous one: losing it
  while a database exists means the recovered database has a password nobody
  holds. Mitigation: AWS Secrets Manager already holds that value and stays the
  durable copy. Requirement 5's guard reads it.
- **Two sources instead of one.** Section 3 records this as accepted.
- **A GitHub secret is readable by any workflow in the repository.** A malicious
  or careless workflow change can print it. Branch protection (spec 017) and
  the trusted-context gate (constitution §11) are the existing controls.
  Confirm they cover workflow-file changes, and record the answer.
- **Never manage these GitHub secrets from Terraform.** The provider marks
  `value` as sensitive, and its own documentation states that this "does not
  hide it from state files". Creating the secrets with
  `resource "github_actions_secret"` would write every plaintext value into the
  S3 remote state. That breaks `CLAUDE.md`'s rule against putting decrypted
  secrets into state, and it is the opposite of this spec's intent. The operator
  sets them with `gh secret set`. This is a hard constraint, not a preference.
  A later change that wants Terraform to manage them must use `value_encrypted`
  with `github_actions_public_key`, and the plaintext must still come from
  somewhere else.
- ~~Open: should `ROOT_DOMAIN` be a GitHub *variable* rather than a secret?~~
  **Decided 2026-09-07 by the operator: a GitHub secret, like the other three.**
  A variable would have been readable through the API and through
  `gh variable get`, which would have given a workstation a real read path for
  that one value, and `AWS_ROLE_ARN` is already a variable. The decision goes
  the other way. The reason is uniformity: one rule for all four values, and no
  value rendered unmasked in build output. Two consequences follow. First,
  `ROOT_DOMAIN` needs an entry in `secrets/local.env` like every other value,
  because a workstation cannot read it back from GitHub either. Second,
  `AWS_ROLE_ARN` stays a variable: it is configuration, not a credential, and
  the constitution already treats the two differently.
- **Open:** whether `civo-autoscaler-token` (planned by CIVO-170) follows this
  spec or stays a Kubernetes Secret sourced differently. CIVO-170 decides.

## 9. Definition of done

- [ ] ADR 0032 merged with Status Accepted, and superseded-by notes added to
      ADRs 0007, 0023 and 0030
- [ ] Constitution rows in section 6 updated
- [ ] `secrets/README.md` rewritten as the setup page
- [ ] All acceptance criteria in section 7 met, with recorded evidence
- [ ] Index/status updated
