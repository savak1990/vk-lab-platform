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
- The parent/root hosted zone and the root domain registration remain external infrastructure, entirely outside this repository's Terraform state and outside its lifecycle commands — **except** for the single NS record delegating `lab.<root-domain>`, which the persistent stack's `route53` unit now manages directly (see "Revision" below). The zone itself — its other records, its creation, its deletion — stays fully external.
- `make down` never deletes the lab hosted zone or its certificate — only disposable records inside the lab zone (e.g., the ALB's record) and the ALB itself are removed.
- The real root domain value is treated as private configuration (not a secret) and is sourced via the existing KMS-encrypted bootstrap mechanism — its own dedicated ciphertext file, `secrets/<project>/root-domain.enc`, decrypted (by Terraform directly, via `aws_kms_secrets`) and supplied at apply time — never committed in plaintext and never combined with other secrets in one file. Documentation uses `<root-domain>` / `lab.<root-domain>` placeholders throughout. This buys reproducibility, not secrecy: the value still lands in the persistent stack's Terraform state either way, so KMS-encrypting the source file adds no confidentiality the state doesn't already concede — the actual win is that a fresh checkout plus `kms:Decrypt` access is enough to bring up a new laptop or CI runner with no out-of-band handoff of the domain value.

## Alternatives considered

**a. Reuse the parent hosted zone directly** — create the platform's records (`api.lab...`, `grafana.lab...`, etc.) directly in the existing root hosted zone.
Rejected: requires the platform to hold standing write access to shared/external infrastructure it doesn't own, makes it easy for a platform bug or a `make down` mistake to affect unrelated DNS records in that zone, and ties platform record lifecycle to infrastructure this repository has no business managing.

**b. Terraform manages parent-zone records** — keep the parent zone external, but have the platform's Terraform create specific records inside it (without owning the whole zone).
Originally rejected for requiring write credentials scoped into the parent zone and risking collateral changes to shared infrastructure. **Revised (see below): partially accepted**, narrowed to exactly one record — the delegation NS record itself — rather than "specific records" generally.

**c. Delegated lab subdomain (chosen)** — a dedicated `lab.<root-domain>` hosted zone, fully owned by the platform's persistent Terraform layer, connected to the parent zone by one NS delegation.
Chosen: this is the standard pattern for handing a subdomain to a system that needs full control of its own DNS without touching the parent. It gives the platform a clean, fully-owned, disposable-friendly DNS/TLS surface, requires no ongoing access to any other part of the parent zone, and makes delegation itself (now usually Terraform-managed — see "Revision" below) the only touchpoint with external infrastructure.

## Revision: Terraform-managed NS delegation (accepted)

Alternative (b) above is now partially accepted, narrowly: the persistent stack's `route53` unit manages the single NS record set that delegates `lab.<root-domain>` from the parent zone, so `make persistent-up` creates that record and `make persistent-down` removes it — no manual delegation step, no gate to pass, in the common case.

Scoping that makes this different from "Terraform manages parent-zone records" generally, and from what (b) was originally rejected for:

- **Record-only, never the zone.** The parent zone itself is never created or deleted, and no other record inside it is ever read or modified — only this one NS record.
- **Located by name, not by an explicit zone-ID input.** The `route53` module uses `data "aws_route53_zone" { name = <root-domain>; private_zone = false }` rather than requiring an operator-supplied zone ID. This was a deliberate trade-off, favoring one fewer manual input over the narrower blast radius an explicit ID would give: IAM needs `route53:ListHostedZones`/`route53:GetHostedZone` account-wide (the lookup can't be scoped to one zone ARN) rather than being scoped to a single resource, and if more than one public hosted zone ever shared the root domain's name in the same account, the lookup could resolve to the wrong one — mitigated by `private_zone = false`, but not eliminated. Accepted as a known trade-off, not an oversight.
- **This assumes the parent/root zone is itself a Route 53 hosted zone reachable with the same AWS credentials.** If the real root domain is at a registrar or another DNS provider with no Route 53 API, this automated path does not apply, and delegation remains the original one-time manual step below.

This does not change the original objection to keeping the platform able to touch arbitrary parent-zone records generally, or to it creating/deleting the parent zone — those remain rejected. Only the single, narrowly-scoped delegation record is now in scope for Terraform.

## Consequences

- Where the automated delegation path applies (parent zone is Route 53, reachable with the same credentials): no manual step is required — `make persistent-up` handles zone creation and delegation together, in one pass.
- Where it doesn't apply (parent zone at a registrar/other provider): one manual, one-time step is still required outside the normal lifecycle, documented as a bootstrap prerequisite (specs 001/002).
- The platform's own hosted zone and certificate are fully disposable-lifecycle-safe to build against: any DNS/TLS work in this repository can be developed and torn down repeatedly with zero risk to the parent zone or its other records.
- The real domain value must flow through Terraform (it ends up in Route 53/ACM resource attributes), so persistent-stack Terraform state necessarily contains it. Remote state for the persistent stack must be treated as a private, access-controlled artifact — this ADR does not claim the domain can be fully hidden from Terraform state.
- `specs/002-persistent-foundation` and `specs/011-public-edge` must be read together with `specs/000-constitution/spec.md` §14 for the full ownership boundary.
- Reusing the parent zone's existing certificate, granting the platform write access to any other parent-zone record, or letting Terraform create/delete the parent zone itself, would all require superseding this ADR further.
