# secrets/ — per-file KMS-encrypted values

**Exception — `.bcrypt` files:** a one-way bcrypt hash (e.g.
`argocd-admin-password.bcrypt`) is not encrypted and needs no key to read —
it can't be reversed back into the original password, only checked against
a login attempt. It's committed as plain text on purpose; nothing here
decrypts it, and `make secret-decrypt`/`secret-encrypt` don't apply to it.

Each file here is one value — a runtime secret or a piece of non-secret
private configuration (like the root domain, constitution §14) — encrypted
independently with the shared, account-global secrets KMS key
(`alias/lab-secrets`, created once by `make account-up` — not per-project).
That key lives in one fixed region, `ACCOUNT_MAIN_REGION` (defaults
`eu-west-1`) — `make secret-encrypt`/`secret-decrypt`/`generate-secrets` all
call it under that variable, independent of whatever `PROJECT_REGION` the current
`PROJECT_NAME` uses for its own cluster/state bucket.

Files live under a per-project directory, `secrets/<PROJECT_NAME>/<name>.enc`
(`PROJECT_NAME` defaults to `vk-lab-platform`), so a different `PROJECT_NAME`
run (e.g. a CI/disposable-account run) gets its own secret set without
colliding with the personal lab's. For a throwaway CI/test environment,
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

Creates `secrets/$PROJECT_NAME/root-domain.enc` (from `ROOT_DOMAIN`),
`secrets/$PROJECT_NAME/postgres-app-password.enc`, and
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

Terraform itself decrypts `secrets/<project>/root-domain.enc` and
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

- `vk-lab-platform/root-domain.enc` — the platform's real root domain
  value, consumed by spec 002's `route53` unit. Create it via
  `make secret-encrypt NAME=root-domain VALUE=<your real root domain>`,
  and make sure a public Route 53 hosted zone for that exact domain
  already exists in the target AWS account (spec 002 looks it up by name).
- `vk-lab-platform/postgres-app-password.enc` — the in-cluster Postgres
  `vkdb` role's password, consumed by spec 002's `secrets` unit. Create
  it via `make secret-encrypt NAME=postgres-app-password VALUE=<generated password>`.

## What happens to this directory on `make bootstrap-down`

`make bootstrap-down` destroys the KMS key these files are encrypted with.
Once that key is gone (after its deletion window), every `*.enc` file here
becomes permanently undecryptable ciphertext. `make bootstrap-down` does
not delete these files itself — they're left as-is for you to remove or
re-encrypt under a new key at your own judgment.
