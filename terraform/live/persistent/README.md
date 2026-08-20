# Persistent stack

Creates Persistent-lifecycle resources that must survive `make down`: the
delegated `${SUBDOMAIN}.<root-domain>` Route 53 hosted zone (plus its NS
delegation record in the parent zone), an ACM certificate for that zone,
and Secrets Manager.

Three units, applied/destroyed together via `make persistent-up`/
`make persistent-down`:

- `route53/` — the delegated hosted zone, and the NS record delegating it
  from the parent zone (looked up by name, not by an explicit zone ID —
  see `docs/adr/0002-delegated-lab-subdomain.md`).
- `acm/` — the DNS-validated certificate for that zone, depends on `route53`.
- `secrets/` — one Secrets Manager secret, `${PROJECT_NAME}-secrets`, holding every runtime secret as a JSON key (currently just `postgres_admin_password`) — one secret, not one per value, since Secrets Manager bills per secret (~$0.40/month each) rather than per key.

## Configuration

Four things a new operator running this against their own domain needs,
supplied two different ways:

- `PROJECT_NAME` (env var, default `vk-lab-platform`)
- `REGION` (env var, default `eu-west-1`)
- `SUBDOMAIN` (env var, default `lab`)
- **root domain** — deliberately *not* an env var. Unlike the three above,
  which are expected to vary or be overridden casually, this repo only
  ever expects one real root domain in practice, and it's the one value
  that must never appear in a committed `.tfvars`/env default (constitution
  §14). Create it once via:

  ```
  make secret-encrypt NAME=root-domain VALUE=<your real root domain>
  ```

  and make sure a **public** Route 53 hosted zone for that exact domain
  already exists in the target AWS account — the `route53` unit finds it
  by name (`data "aws_route53_zone" { name = ...; private_zone = false }`),
  not by an explicit zone ID. If no such zone exists, or more than one
  public zone shares that name, `make persistent-up` fails at that lookup
  with a clear Terraform data-source error, not a silent fallback.

Also required: `secrets/$PROJECT_NAME/postgres-admin-password.enc`, via:

```
make secret-encrypt NAME=postgres-admin-password VALUE=<generated password>
```

For a throwaway CI/test `PROJECT_NAME`, `make generate-secrets` creates
both files in one step (fixed test Postgres password, real root domain
from an argument) — see `secrets/README.md`. Never use it for the
personal lab's own `PROJECT_NAME`.

## Usage

```
make persistent-up      # applies route53, acm, secrets in one pass
make persistent-down    # guarded, rarely-used - see constitution §17
```

With the root domain's hosted zone already present as described above,
`make persistent-up` runs zone → delegation → cert → secret straight
through, in one pass — Terragrunt's own `dependency` graph orders `acm`
after `route53` automatically, so there's no manual delegation step and no
gate to pass.

`make persistent-down` refuses to run while any Disposable-lifecycle
resource still exists, then hands off to terragrunt/terraform's own
interactive destroy confirmation (type `yes`) rather than a custom prompt,
and after destroying verifies every unit's state is actually empty before
reporting success — destroying `route53` removes both the zone and its
parent-zone NS delegation record together; the parent zone itself and its
other records are never touched.

If you switch `PROJECT_NAME`/`REGION`/`SUBDOMAIN`, run `make clear-cache`
first — a `.terragrunt-cache` left over from a different value bakes its
old backend config into the cached working directory and makes terraform
refuse to proceed ("Backend configuration has changed"). Not run
automatically by `persistent-up`/`persistent-down`.
