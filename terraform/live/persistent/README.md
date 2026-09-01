# Persistent stack

Creates Persistent-lifecycle resources that must survive `make down`: the
platform-owned VPC and Secrets Manager.

The delegated `${SUBDOMAIN}.<root-domain>` Route 53 hosted zone (plus its NS
delegation record in the parent zone) and its ACM certificate moved to
`terraform/live/bootstrap/` — see that stack's README. They're still
per-project and still survive `make down` in practice (nothing in the normal
flow calls `bootstrap-down`), just tagged Bootstrap-lifecycle now rather than
Persistent.

Two units, applied/destroyed together via `make persistent-up`/
`make persistent-down`:

- `vpc/` — the platform-owned VPC: public subnets across two AZs, no NAT
  Gateway (spec 020, ADR 0020).
- `secrets/` — one Secrets Manager secret, `${PROJECT_NAME}-secrets`, holding every runtime secret as a JSON key (currently just `postgres_app_password`) — one secret, not one per value, since Secrets Manager bills per secret (~$0.40/month each) rather than per key.

## Configuration

- `PROJECT_NAME` (env var, default `vk-lab-platform`)
- `REGION` (env var, default `eu-west-1`)

`root-domain`/`SUBDOMAIN` and the hosted-zone lookup now belong to
`bootstrap-up` (see `terraform/live/bootstrap/README.md`) — `bootstrap-up`
requires/decrypts `root-domain.enc` before this stack ever runs.

Also required: `secrets/$PROJECT_NAME/postgres-app-password.enc`, via:

```
make secret-encrypt NAME=postgres-app-password VALUE=<generated password>
```

For a throwaway CI/test `PROJECT_NAME`, `make generate-secrets` creates
this and `root-domain.enc` in one step (fixed test Postgres password) —
see `secrets/README.md`. Never use it for the personal lab's own
`PROJECT_NAME`.

## Usage

```
make persistent-up      # applies vpc, secrets
make persistent-down    # guarded, rarely-used - see constitution §17
```

`make persistent-down` refuses to run while any Disposable-lifecycle
resource still exists, then hands off to terragrunt/terraform's own
interactive destroy confirmation (type `yes`) rather than a custom prompt,
and after destroying verifies every unit's state is actually empty before
reporting success.

If you switch `PROJECT_NAME`/`REGION`, run `make clear-cache`
first — a `.terragrunt-cache` left over from a different value bakes its
old backend config into the cached working directory and makes terraform
refuse to proceed ("Backend configuration has changed"). Not run
automatically by `persistent-up`/`persistent-down`.
