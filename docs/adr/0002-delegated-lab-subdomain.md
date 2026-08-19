# ADR 0002: Delegated `lab.<root-domain>` subdomain for platform DNS/TLS

## Status

Accepted

## Context

The platform needs a public DNS name and a matching TLS certificate for its ALB/Envoy Gateway public edge (architecture.md §11–12). The user already owns a root domain with an existing Route 53 hosted zone, managed as external/shared infrastructure outside this repository — it predates this project and may host other, unrelated DNS records.

The platform is also a public repository (constitution §5, §11). The root domain name is not itself a secret, but it is personal infrastructure detail the user does not want committed in plaintext to a public repository, and the platform must not require standing write access to infrastructure it does not own.

A DNS/TLS design decision was needed that:

- keeps the platform's `make up`/`make down` lifecycle from ever needing write access to the parent hosted zone;
- keeps the parent zone and its existing certificate untouched by routine platform operation;
- gives the platform full, disposable-friendly control over its own DNS records and certificate;
- keeps the real domain name out of the public repository without pretending that is a security boundary.

## Decision

The platform uses a **delegated subdomain**: `lab.<root-domain>`.

- The Terraform **persistent** layer creates and owns a Route 53 public hosted zone for `lab.<root-domain>` and an ACM certificate covering `lab.<root-domain>` and `*.lab.<root-domain>`, in the same AWS region as the ALB, validated via DNS against the delegated zone.
- The parent/root hosted zone and the root domain registration remain external infrastructure, entirely outside this repository's Terraform state and outside its lifecycle commands.
- NS delegation from the parent zone to `lab.<root-domain>` is a one-time external/manual bootstrap step (create the NS records in the parent zone pointing at the lab zone's name servers), performed once, outside `make up`/`make down`.
- The platform never requires write access to the parent zone during normal operation.
- `make down` never deletes the lab hosted zone or its certificate — only disposable records inside the lab zone (e.g., the ALB's record) and the ALB itself are removed.
- The real root domain value is treated as private configuration (not a secret) and is sourced via the existing KMS-encrypted bootstrap mechanism — its own dedicated ciphertext file, `secrets/root-domain.enc`, decrypted and supplied to Terraform as a variable at apply time — never committed in plaintext and never combined with other secrets in one file. Documentation uses `<root-domain>` / `lab.<root-domain>` placeholders throughout.

## Alternatives considered

**a. Reuse the parent hosted zone directly** — create the platform's records (`api.lab...`, `grafana.lab...`, etc.) directly in the existing root hosted zone.
Rejected: requires the platform to hold standing write access to shared/external infrastructure it doesn't own, makes it easy for a platform bug or a `make down` mistake to affect unrelated DNS records in that zone, and ties platform record lifecycle to infrastructure this repository has no business managing.

**b. Terraform manages parent-zone records** — keep the parent zone external, but have the platform's Terraform create specific records inside it (without owning the whole zone).
Rejected: still requires write credentials scoped into the parent zone, still risks collateral changes to shared infrastructure, and blurs the ownership boundary the constitution requires to be explicit (§2, §14) — Terraform would partially manage a zone it doesn't otherwise control.

**c. Delegated lab subdomain (chosen)** — a dedicated `lab.<root-domain>` hosted zone, fully owned by the platform's persistent Terraform layer, connected to the parent zone by one NS delegation.
Chosen: this is the standard pattern for handing a subdomain to a system that needs full control of its own DNS without touching the parent. It gives the platform a clean, fully-owned, disposable-friendly DNS/TLS surface, requires zero ongoing access to the parent zone, and makes the one-time delegation step the only external dependency.

## Consequences

- One manual, one-time step is required outside the normal lifecycle: delegating `lab.<root-domain>` from the parent zone. This must be documented as a bootstrap prerequisite (specs 001/002) and is not automated by `make up`.
- The platform's own hosted zone and certificate are fully disposable-lifecycle-safe to build against: any DNS/TLS work in this repository can be developed and torn down repeatedly with zero risk to the parent zone.
- The real domain value must flow through Terraform (it ends up in Route 53/ACM resource attributes), so persistent-stack Terraform state necessarily contains it. Remote state for the persistent stack must be treated as a private, access-controlled artifact — this ADR does not claim the domain can be fully hidden from Terraform state.
- `specs/002-persistent-foundation` and `specs/012-public-edge` must be read together with `specs/000-constitution/spec.md` §14 for the full ownership boundary.
- Reusing the parent zone's existing certificate, or granting the platform write access to the parent zone, would require superseding this ADR.
