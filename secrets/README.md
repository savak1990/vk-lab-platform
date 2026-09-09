# secrets/ — per-file KMS-encrypted values

**Exception — `.bcrypt` files:** a one-way bcrypt hash (e.g.
`argocd-admin-password.bcrypt`) is not encrypted and needs no key to read —
it can't be reversed back into the original password, only checked against
a login attempt. It's committed as plain text on purpose; nothing here
decrypts it, and `make secret-decrypt`/`secret-encrypt` don't apply to it.

**Exception — `.pem` certificate files:** a public certificate (e.g.
`civo-ca-cert.pem`) is not secret by design. IAM Roles Anywhere trust
anchors are public X.509 certificates; the private key is the only secret
(stored in the adjacent `.enc` file). The certificate is committed in the
clear for readability and to allow offline validation of signed objects;
nothing here encrypts it, and `make secret-decrypt`/`secret-encrypt` don't apply.

Each file here is one value — a runtime secret or a piece of non-secret
private configuration (like the root domain, constitution §14) — encrypted
independently with the shared, account-global secrets KMS key
(`alias/lab-secrets`, created once by `make account-up` — not per-project).
That key lives in the platform's single region, `eu-west-1` — the same region
everything else applies in, so `make secret-encrypt`/`secret-decrypt`/
`generate-secrets` always resolve it (ADR 0024).

Files live under a per-project directory, `secrets/<PROJECT_NAME>/<name>.enc`
(`PROJECT_NAME` defaults to `vk-lab-platform`), so a different `PROJECT_NAME`
run (e.g. a CI/disposable-account run) gets its own secret set without
colliding with the personal lab's — **except `root-domain.enc` and
`civo-token.enc`**, filed directly under `secrets/` with no project
directory, since both are account-global: one value shared by every
`PROJECT_NAME` in the account. `root-domain.enc` is applied once by
`terraform/live/account/root-domain`; `civo-token.enc` holds the Civo API
token, read by `scripts/lib/provider.sh`'s `civo_token` helper
(`PROVIDER=civo` only). For a throwaway
CI/test environment,
`make generate-secrets` creates this project's secrets automatically
(root domain from an argument, a fixed test Postgres password) instead of
requiring `make secret-encrypt` to be run by hand — see below.

Rules (constitution §5/§14, architecture.md §18):

- One value per file, named after its contents: `secrets/<project>/<name>.enc`.
- Never combine multiple values into one committed ciphertext file.
- Never commit a plaintext value anywhere in this repository.

## Encrypting a new value

```
make secret-encrypt NAME=<name> VALUE=<plaintext-value>
```

Writes `secrets/$PROJECT_NAME/<name>.enc`. Commit that file; never commit
the plaintext value you passed as `VALUE`.

## Generating throwaway secrets for CI/test environments

```
PROJECT_NAME=<ci-project-name> ROOT_DOMAIN=<domain> make generate-secrets
```

Creates `secrets/root-domain.enc` (from `ROOT_DOMAIN`, only if missing —
it's account-global, so an already-existing value from another project is
left alone), `secrets/$PROJECT_NAME/postgres-app-password.enc`, and
`secrets/$PROJECT_NAME/grafana-admin-password.enc` (each a fixed value,
`test`) — everything `make persistent-up` needs for a disposable
CI/test project, with no manually pre-committed ciphertext. Never use
this for the personal lab's own `PROJECT_NAME`; these values are fixed
and publicly known.

## Decrypting a value

```
make secret-decrypt NAME=<name>
```

Prints the plaintext to stdout. This works standalone from a laptop or CI —
it only needs `aws kms decrypt` against the ciphertext file and permission
to use the KMS key. It has no dependency on Terraform state, outputs, or
any in-cluster component, so it works from spec 002 onward, long before Pod
Identity or an in-cluster secrets controller exist (those are spec 014's
job, for runtime application secrets).

Terraform itself decrypts `secrets/root-domain.enc` and
`secrets/<project>/postgres-app-password.enc` directly, via the AWS
provider's `aws_kms_secrets` data source — `make secret-decrypt` is for
manual inspection of a value, not something spec 002's Terraform code
calls. A future spec's Terraform can still take the `TF_VAR_*` route
instead, if that fits better there:

```
export TF_VAR_some_value="$(make secret-decrypt NAME=some-value)"
```

## What's here right now

Nothing tracked yet — `secrets/vk-lab-platform/test.enc` is only spec 001's
acceptance-test fixture. Spec 002 needs two real values created once,
before `make persistent-up` can succeed:

- `root-domain.enc` — the account's real root domain value (account-global,
  not under a project directory), consumed by `terraform/live/account/root-domain`.
  Create it via `make secret-encrypt NAME=root-domain VALUE=<your real root domain>`,
  and make sure a public Route 53 hosted zone for that exact domain
  already exists in the target AWS account (looked up by name).
- `vk-lab-platform/postgres-app-password.enc` — the in-cluster Postgres
  `vkdb` role's password, consumed by spec 002's `secrets` unit. Create
  it via `make secret-encrypt NAME=postgres-app-password VALUE=<generated password>`.

## What happens to this directory on `make bootstrap-down`

`make bootstrap-down` destroys the KMS key these files are encrypted with.
Once that key is gone (after its deletion window), every `*.enc` file here
becomes permanently undecryptable ciphertext. `make bootstrap-down` does
not delete these files itself — they're left as-is for you to remove or
re-encrypt under a new key at your own judgment.

## Runbooks

### Rotating an IAM Roles Anywhere root CA certificate

When a root CA certificate needs rotation:

1. Generate a new certificate pair by running `scripts/civo-ca-init.sh` with
   `ROTATE=1`. This creates `civo-ca-cert-next.pem` and `civo-ca-key-next.enc`
   alongside the current pair.
2. Commit the new certificate and encrypted key.
3. In a later spec, register `civo-ca-cert-next.pem` as a second trust anchor
   with AWS IAM Roles Anywhere.
4. Update the cluster's certificate issuer to sign new workload certificates
   with the new root CA.
5. Wait at least 24 hours (the maximum workload certificate lifetime) for all
   outstanding certificates signed by the old root to naturally expire.
6. Remove the old trust anchor from AWS IAM Roles Anywhere.
7. Delete `civo-ca-cert.pem`, `civo-ca-key.enc`, and the rotation-candidate
   `-next` files; commit the removal.

### Revoking an IAM Roles Anywhere root CA certificate

To immediately stop new sessions from being created with a root CA that is
compromised or no longer trusted:

```
aws rolesanywhere disable-trust-anchor --trust-anchor-id <id>
```

This stops the trust anchor from accepting new credential requests immediately.
Sessions already issued will continue to work until they expire naturally
(configured per-role, typically 1 hour). To force existing sessions to
terminate, you must also update or delete the IAM role that trusted the
certificate.
