# 020 — Local Development Mode (minikube/kind)

**Complexity:** Medium-High — no single hard AWS problem, but many small
divergences (install path, routing kind, secrets, storage) across specs that
must all cohere.
**Risk:** Medium — the risk is not a broken local cluster, it's the `aws`
target accidentally regressing while this is bolted on, or the two targets'
gitops trees drifting apart over time.
**Estimated cost:** ~2–3 days, spread across this spec plus the amendments
it requires to specs 004–013/017/018, and 023 · AWS runtime cost: none for the
default (placeholder-secrets) path; the opt-in real-secrets path costs
whatever `secrets/*.enc` KMS decryption already costs (a few KMS API calls).
**Recommended model:** Sonnet.
**Depends on:** 000-constitution (§18), ADR 0006. Constrains, rather than
depends on, specs 004 and 006–012, and 023 — those specs MUST be implemented with the
two-target structure described here from the outset, not retrofitted later.
**Lifecycle class(es) touched:** none. The `local` target sits entirely
outside the State/Bootstrap/Persistent/Disposable model (constitution §18,
architecture.md §6/§10a).

## Scope

This spec defines the **`local` execution target**: running the platform's
`gitops/` content on minikube or kind, AWS-free except for one deliberate,
opt-in exception (Requirement 12). It shares a single `gitops/` tree with
the existing **`aws` target** (real EKS) via Helm values-file overrides —
there is no separate local-only manifest tree.

Because `terraform/live/disposable/` and `gitops/` don't exist on disk yet,
this spec's requirements are binding on how specs 004 and 006–012, and 023, get
implemented, not an add-on applied after the fact. Any of those specs whose
current text assumes AWS is the only target has (or will get) a scope note
cross-referencing this spec.

Excludes: any attempt to make the `local` target's cluster/data survive
deletion (see Requirement 6 — it's deliberately throwaway); any attempt to
give `local` a real AWS-equivalent public edge (NLB/Route53/ACM) — see
Requirement 8; any CI integration for `local` beyond the fast-validation
rendering check in Requirement 16 — that CI integration now exists as its
own spec, **022-ci-kind-integration-test**, which reuses this spec's
`make kind-up` install path and runs spec 022's Go/Ginkgo E2E suite against
it (ADR 0007).

## Requirements

1. Two Argo CD targets, `aws` and `local`, MUST share a single `gitops/`
   tree. Every `gitops/` component MUST be one Helm chart with a shared
   `values.yaml` plus `values-aws.yaml` and `values-local.yaml` overrides.
   Kustomize MUST NOT be introduced as a second overlay mechanism.
2. The Argo CD root ("app-of-apps") `Application` (spec 004) MUST be a
   single manifest, parameterized by a `target` value (`aws` | `local`)
   supplied at install time — not two separate root manifests.
3. The umbrella/app-of-apps chart MUST use the `target` value to omit
   AWS-only components (Karpenter, AWS Load Balancer Controller,
   external-dns, EBS CSI driver, RDS) from the rendered app list entirely
   when `target=local`, via conditional templating — not by installing and
   then disabling them, and not by deleting/duplicating manifests.
4. Argo CD itself MUST be installed for the `local` target via a plain
   script/Makefile target, NOT via Terraform — diverging explicitly from
   spec 004's Terraform-installs-Argo-CD requirement, which remains in force
   for the `aws` target only.
5. `make minikube-up` and `make kind-up` MUST exist as two separate,
   explicit Makefile targets. There MUST NOT be a unified `make local-up`
   wrapper that picks a tool implicitly or via a flag — the choice of tool
   MUST be explicit in the command name every time.
6. Local Postgres/Kafka data MUST be fully throwaway: no local
   persistent-lifecycle class, no EBS, no destroy/recreate persistence
   proof. Local nodes MUST use the cluster's default local StorageClass
   (hostpath/local-path). `values-local.yaml` storage overrides MUST use
   `Delete` reclaim semantics — the deliberate inverse of spec 005's
   `aws`-target `Retain` requirement.
7. No AWS Load Balancer, Route 53, or ACM MUST be used for the `local`
   target. Access MUST be via `kubectl port-forward` directly to Envoy
   Gateway's Service.
8. `values-local.yaml` MUST force Envoy Gateway's Service type to
   `ClusterIP` (via `EnvoyProxy`/`GatewayClass` parameters). Envoy Gateway's
   own default Service type (`LoadBalancer`) MUST NOT be relied on for the
   `local` target — it hangs `<pending>` indefinitely on kind/minikube with
   no cloud LB implementation present, and no MetalLB/cloud-provider-kind
   substitute is used (see ADR 0006, alternative d).
9. The `local` target's Gateway API `HTTPRoute`s MUST match by **path**
   (e.g. `/api`, `/grafana`, `/argo`) rather than by hostname. The `aws`
   target MUST continue matching by hostname (`api.lab.<root-domain>`,
   etc.). This is a permanent, accepted divergence in route-matching *kind*
   between the two targets — a requirement to be implemented in spec 010,
   not a values-only difference.
10. The `local` target MUST use plain HTTP. No cert-manager self-signed
    issuer, and no TLS termination at Envoy, MUST be configured for
    `values-local.yaml`.
11. By default, `make minikube-up` and `make kind-up` MUST load generated,
    throwaway placeholder credentials directly into Kubernetes `Secret`
    objects, requiring zero AWS credentials. This is the default path.
12. A separate, explicit opt-in flag or Makefile target MUST exist that
    instead decrypts real values from `secrets/*.enc` via the existing
    `scripts/secret-decrypt.sh` (AWS KMS, `alias/${PROJECT_NAME}-secrets`)
    and loads those into the same Kubernetes `Secret` objects. This is the
    one deliberate AWS dependency anywhere in the `local` path, and MUST
    remain opt-in — never the default.
13. Neither the placeholder path (Requirement 11) nor the KMS-decrypt path
    (Requirement 12) MUST use AWS Secrets Manager, EKS Pod Identity, or
    External Secrets Operator. Spec 012 (Secrets Manager + Pod Identity)
    does not apply to the `local` target under either path.
14. Karpenter, AWS Load Balancer Controller, external-dns, EBS CSI driver,
    and RDS MUST NOT appear in the `local` target's rendered app list under
    any circumstance (reinforces Requirement 3 as an explicit, independently
    testable requirement).
15. The `local` target's root Argo Application MUST sync from the local
    working directory on disk, not from the GitHub repository, so that
    editing `gitops/` reconciles without a prior commit/push. The concrete
    mechanism (e.g. Argo CD's support for a local filesystem/git-server
    source, or a lightweight local git remote the install script sets up)
    MUST be chosen and documented as part of implementing this requirement
    — it MUST NOT be left as an unresolved detail. The `aws` target's root
    Application MUST continue syncing from the GitHub repository, unchanged.
16. `values-local.yaml` overrides for the observability stack, Kafka, and
    Postgres MUST state an explicit laptop-scale sizing/retention posture
    (replica counts, resource requests, retention windows). Any component
    omitted for `local` MUST be stated explicitly in that values file's
    comments or in this spec's implementation notes — never silently
    dropped.
17. Fast validation (spec 018) MUST `helm template` render both
    `values-aws.yaml` and `values-local.yaml` for every `gitops/` component,
    using dummy/placeholder secret values. This rendering check MUST NOT
    request AWS credentials — it validates templating only, and MUST remain
    compatible with spec 018's existing no-AWS-credentials rule even though
    Requirement 12 above introduces an opt-in AWS-dependent path elsewhere.

## Implementation hints

- The umbrella chart's `target` conditional is most naturally expressed as
  a top-level `target: aws|local` value consumed by `{{ if eq .Values.target
  "local" }}` guards around each AWS-only child `Application` block, rather
  than a boolean per component — keeps the umbrella chart's values file
  self-documenting about which components are AWS-only.
- For Requirement 15 (local sync source), `argocd-autopilot`-style local git
  remotes or a throwaway local Gitea/`git daemon` are both plausible; a
  simpler option worth trying first is Argo CD's native support for a
  `file://` or locally-mounted-path source referencing the working tree
  directly, if the installed Argo CD version supports it — validate this
  before committing to a heavier local git-server setup.
- For Requirement 11/12, keep the placeholder-vs-real-secrets choice a
  single flag consumed by one script (e.g. `scripts/local-load-secrets.sh
  --real` vs. no flag), so `make minikube-up`/`make kind-up` don't duplicate
  the secret-loading logic per tool.
- For Requirement 9, HTTPRoute path prefixes for `local` should mirror the
  `aws` target's per-component hostnames one-to-one (`argo.lab...` →
  `/argo`, `grafana.lab...` → `/grafana`) so the mapping is predictable
  without needing a separate lookup table.

## Testing / acceptance criteria

- `make minikube-up` (and separately, `make kind-up`) brings up a cluster,
  installs Argo CD, and reaches `Synced`/`Healthy` on the root Application
  with `target=local` and zero AWS credentials present in the environment.
- `kubectl port-forward` to Envoy Gateway's Service, followed by requests to
  `localhost:PORT/argo`, `/grafana`, etc., succeeds over plain HTTP.
- Editing a manifest under `gitops/` and re-syncing (without a git
  commit/push) is reflected by Argo CD — proves Requirement 15.
- Running the opt-in real-secrets flag decrypts and loads real values from
  `secrets/*.enc`; omitting it loads generated placeholders instead — both
  paths produce a usable cluster.
- `minikube delete` / `kind delete cluster` removes everything with no
  leftover local state — proves Requirement 6 (fully throwaway).
- Fast validation renders both `values-aws.yaml` and `values-local.yaml` via
  `helm template` for every component with no AWS credentials present
  (Requirement 17).
- A passing `local`-target run is explicitly not accepted as satisfying
  architecture.md §38 (full lifecycle acceptance test) or constitution §12
  (Definition of Done) for the `aws` target — those remain separately
  required.
