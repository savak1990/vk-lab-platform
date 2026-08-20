# ADR 0006: Local (minikube/kind) execution target alongside AWS

## Status

Accepted

## Context

The platform today has exactly one execution target: real AWS/EKS. That is
correct for the platform's stated purpose (a realistic AWS learning
environment), but it means every iteration on `gitops/` content requires a
live AWS account and a running EKS cluster, with the AWS cost and cycle time
that implies. The user wants a second, AWS-free way to run the platform on
minikube or kind — sometimes the full AWS lifecycle is the point, sometimes
fast local iteration is the point, and the platform should support both
without becoming two different platforms.

This decision is made before `terraform/live/disposable/` and `gitops/` exist
on disk — spec 004 (Argo CD bootstrap) and everything downstream of it
(specs 006–012, and 023) are design-only. That timing matters: the two-target
structure below is meant to shape those specs from the outset, not be
retrofitted onto Helm charts and Argo Applications that already assume
AWS-only.

Several existing constitution rules assume a single, AWS-backed target
unconditionally: §3's "exactly one lifecycle class" taxonomy, §4's
persistence MUSTs, §5's Secrets-Manager MUST, and §8's mandated
Route53→ALB→Envoy public path. Per constitution §13, introducing a target
that doesn't fit those rules requires recording the conflict and updating
the constitution intentionally, rather than silently working around it —
this ADR is that record; constitution §18 is the resulting carve-out.

## Decision

A **`local` target** is added alongside the existing (now explicitly named)
**`aws` target**. Both targets share a single `gitops/` tree; they do not
fork into separate Kubernetes manifest trees.

- **Shared chart, per-target values.** Every `gitops/` component is one Helm
  chart with `values.yaml` (shared defaults) plus `values-aws.yaml` and
  `values-local.yaml` overrides. No Kustomize — Helm values files are the one
  overlay mechanism the platform uses, for both structural differences (which
  components render at all) and tuning differences (sizing, routing, TLS).
- **One root Application, parameterized.** The Argo CD root ("app-of-apps")
  `Application` from spec 004 is a single manifest, parameterized by a
  `target` value (`aws` | `local`) supplied at install time — not two
  separate root manifests. The umbrella chart's templating uses that value to
  omit AWS-only components (Karpenter, AWS Load Balancer Controller,
  external-dns, EBS CSI driver, RDS) from the rendered app list entirely when
  `target=local`, rather than installing and then disabling them.
- **Install path diverges by target.** For `aws`, Terraform installs Argo CD
  (spec 004, unchanged). For `local`, a plain script/Makefile target installs
  Argo CD directly — no Terraform involved at all for the local target.
  `make minikube-up` and `make kind-up` are the two entry points; there is no
  unified `make local-up` wrapper, so the choice of tool is explicit every
  time.
- **Local data is fully throwaway.** Postgres and Kafka on `local` use the
  cluster's default local StorageClass (hostpath/local-path) with `Delete`
  reclaim semantics — the deliberate inverse of spec 005's `aws`-target
  `Retain` requirement. There is no local persistent-lifecycle class and no
  destroy/recreate persistence proof for `local`; deleting the local cluster
  is expected to delete everything in it.
- **No AWS edge locally.** `local` has no ALB, Route53, or ACM. Access is via
  `kubectl port-forward` directly to Envoy Gateway's Service, which the
  `local` values file forces to `ClusterIP` (Envoy Gateway's own default,
  `LoadBalancer`, would hang `<pending>` indefinitely on kind/minikube with no
  cloud LB implementation present).
- **Path-based routing locally, by necessity.** `kubectl port-forward` to
  `localhost:PORT` cannot present the Host header that hostname-based Gateway
  API `HTTPRoute`s (`api.lab.<root-domain>`, etc.) match on. The `local`
  target's routes therefore match by **path** (`/api`, `/grafana`, `/argocd`)
  instead of hostname. This is an accepted, permanent divergence in
  route-matching *kind* between the two targets, not a values tweak that
  happens to look different.
- **Plain HTTP locally.** No cert-manager self-signed issuer, no TLS
  termination at Envoy for `local` at all. The public path's TLS requirement
  (constitution §8, architecture.md §12) is `aws`-target-only.
- **Placeholder secrets by default, real secrets opt-in.** `make
  minikube-up`/`make kind-up` load generated, throwaway placeholder
  credentials directly into Kubernetes `Secret` objects by default — zero AWS
  credentials required, consistent with local data being throwaway anyway. A
  separate opt-in flag/target instead decrypts real values from
  `secrets/*.enc` via the existing `scripts/secret-decrypt.sh` (AWS KMS,
  `alias/${PROJECT_NAME}-secrets`) and loads those. Neither local path uses
  Secrets Manager, Pod Identity, or External Secrets Operator — spec 012
  (Secrets Manager + Pod Identity) is `aws`-target-only and does not apply to
  `local` in either mode.
- **Local sync source is the working directory.** The `local` target's root
  Application syncs from the local working directory on disk, not GitHub, so
  editing `gitops/` and seeing Argo reconcile it does not require a
  commit/push first. (`aws` keeps syncing from the GitHub repo, unchanged.)
  The concrete mechanism is recorded as a requirement in spec 020, not left
  implicit here.

## Alternatives considered

**a. Separate local-only chart/manifest tree** (e.g. a parallel `gitops-local/`).
Rejected: guarantees drift between the two trees over time and doubles the
maintenance burden for every future component, defeating the reason to have
one `gitops/` tree in the first place.

**b. Kustomize overlays instead of Helm values files.**
Rejected: the platform already commits to Helm charts for every `gitops/`
component; introducing a second templating/overlay mechanism for one
dimension of variation (target) adds a tool rather than reusing the one
already in use.

**c. k3d/k3s instead of minikube/kind.**
Rejected: minikube and kind are the two most widely used local Kubernetes
tools and the ones the user asked for by name; nothing about this design
depends on a specific tool, but there's no reason to add a third option
unrequested.

**d. MetalLB or `cloud-provider-kind` to give Envoy's Service a real
LoadBalancer IP**, so the local target could look identical to `aws`
(hostname routing, no `kubectl port-forward`).
Rejected: adds a component whose only job is emulating cloud LB behavior, for
a target whose whole point is minimal local ceremony. `kubectl port-forward`
achieves the same reachability with nothing extra to install, at the cost of
path-based routing instead of hostname-based (accepted above).

**e. cert-manager self-signed `ClusterIssuer` for local TLS**, so both
targets terminate TLS at Envoy.
Rejected: `local` never leaves the operator's machine; there is no network
segment for TLS to protect, and a self-signed cert only adds browser/curl
warnings without adding security. Plain HTTP is the simpler, sufficient
choice for this target.

**f. LocalStack to emulate Secrets Manager/other AWS services locally.**
Rejected: would reintroduce an AWS-shaped dependency (a specific emulator,
with its own drift-from-real-AWS risk) for the sake of keeping spec 012's
mechanism nominally in play, when spec 012 simply doesn't apply to a target
that has no AWS Pod Identity to authenticate with in the first place.

## Consequences

- Specs 004 and 006–012, and 023, must be written (or amended) with the two-target
  structure from the start: a values-file split per component, and explicit
  scope notes wherever an existing requirement is `aws`-target-only or
  inverted for `local` (storage reclaim policy, routing kind, TLS, secrets
  mechanism, dynamic compute).
- Constitution §3 (lifecycle classes), §4 (persistence), §5 (Secrets Manager),
  and §8 (public path) each need an explicit "does not apply to the local
  target" carve-out (constitution §18) rather than silent non-mention, since
  the local target genuinely conflicts with those sections' unqualified MUSTs
  as originally written.
- The pre-existing use of "local" in `docs/architecture.md` §34 ("Local and
  GitHub Lifecycle Equivalence," meaning "you ran `make up` from your own
  workstation against real AWS") is renamed to "workstation-initiated"
  throughout, to free "local" to mean only this new target from here on.
- Fast validation (spec 017) gains a requirement to `helm template` render
  both `values-aws.yaml` and `values-local.yaml` for every component, using
  dummy/placeholder secret values — the credential-free rule in spec 017
  holds even though decision above adds an opt-in path elsewhere that does
  use AWS KMS.
- A local run is never a substitute for the `aws`-target full lifecycle
  acceptance test (architecture.md §38) or constitution §12's Definition of
  Done — it's a faster inner loop, not a smaller version of the real thing.
