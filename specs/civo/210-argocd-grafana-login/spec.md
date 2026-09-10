---
id: "CIVO-210"
title: "Real login for Argo CD and Grafana (beyond the shared local admin password)"
status: "DRAFT"
priority: "P3"
milestone: "M2"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "SSO/OIDC wiring across two apps is mostly integration work once a provider is chosen; the open design question is which provider and how credentials are managed, not novel platform architecture"
effort_estimate: "Unestimated (design not yet resolved)"
estimate_confidence: "low"
depends_on: []
blocked_by: []
supersedes: []
created: "2026-09-10"
updated: "2026-09-10"
completed: null
---

# CIVO-210 — Real login for Argo CD and Grafana

## 1. Outcome and rationale

Both Argo CD and Grafana currently authenticate with a single shared local
admin credential each (Argo CD: a bcrypt-hashed password set at `argo-up`
time, `server.insecure=true`, no SSO; Grafana: `grafana-admin-credentials`
synced from SSM via ESO). This is adequate for a single-operator
educational lab but has no per-user identity, no audit trail of who did
what, and no way to grant a second person narrower access.

During CIVO-100/110's live-run session (2026-09-10), Argo CD's bundled
`dex-server` component (its OIDC/SSO broker) was found to segfault
consistently on the Civo cluster and was disabled
(`--set dex.enabled=false` in `scripts/argo-up.sh`'s `install_argocd()`)
since nothing in this platform uses it yet — this spec is the deferred
follow-up to actually configure real login, not just remove the unused,
crashing component.

## 2. Scope and non-goals

In scope: deciding on and wiring up a real authentication mechanism for
Argo CD and Grafana (candidates: dex re-enabled with a working image/config,
an OIDC provider like GitHub/Google, or another mechanism). Out of scope:
any change to the platform's own workload-identity mechanisms (EKS Pod
Identity / Roles Anywhere) — this is about human operator login only.

## 3. Current state / evidence

- `scripts/argo-up.sh`'s `install_argocd()` sets
  `configs.secret.argocdServerAdminPassword` (bcrypt hash) and
  `dex.enabled=false`. `dex-server`'s crash was reproducible across
  multiple nodes on the Civo cluster (exit code 139, SIGSEGV) — not
  investigated further at the time (out of scope for CIVO-100/110).
- Grafana's admin credential flows from
  `secrets/<project>/grafana-admin-password.enc` through
  `terraform/modules/persistent-secrets` (SSM SecureString) through ESO's
  `ExternalSecret` into a Kubernetes Secret consumed by the
  kube-prometheus-stack chart's `adminUser`/`adminPassword` values.

## 4. Design and contracts

Not yet resolved. Open questions for whoever picks this up:
- Re-enable dex (root-cause the segfault first) vs. a different SSO
  mechanism entirely vs. per-app native OIDC support (both Argo CD and
  Grafana support OIDC without dex as an intermediary).
- Whether this needs a real external identity provider account (GitHub
  OAuth app, Google Workspace, etc.) — which has real setup cost for a
  single-operator lab — or whether a lighter mechanism (e.g. multiple
  local users with distinct bcrypt hashes) satisfies the actual need.
- Whether this applies to both AWS and Civo targets or is scoped to one.

## 5. Files/components affected

`scripts/argo-up.sh` (`install_argocd()`), `gitops/argocd/values.yaml`,
Grafana's Application values under `gitops/templates/platform/*/observability/`.

## 6. Implementation steps

Not yet planned — design resolution (§4) comes first.

## 7. Dependencies and blockers

None formally, but likely benefits from landing after CIVO-160
(observability on Civo, brings Grafana to that target) so both targets can
be addressed together rather than twice.

## 8. Acceptance criteria

Not yet defined — depends on the chosen mechanism (§4).

## 9. Validation

Not yet defined.

## 10. AWS regression protection

Not yet defined — must not weaken or change AWS's existing working login
path without equivalent replacement.

## 11. Rollout and rollback/recovery

Not yet defined.

## 12. Risks and unresolved questions

- Root cause of the `dex-server` segfault is unknown; re-enabling dex
  without understanding it risks the same crash recurring.
- SSO setup for a personal/educational lab may not be worth the
  operational overhead compared to the status quo — this spec's design
  step should weigh that explicitly, not assume SSO is the right answer.

## 13. Definition of done

- [ ] Design resolved (§4); evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-10 — created as DRAFT, deferred out of CIVO-100/110's scope at
  the user's explicit request, to be picked up later in the roadmap.
