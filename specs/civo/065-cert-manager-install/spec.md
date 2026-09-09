---
id: "CIVO-065"
title: "cert-manager installed on civo, unrelated to aws's existing webhook-cert install"
status: "DONE"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "One Helm Application with a well-known chart"
effort_estimate: "Half a session (2–3 h)"
estimate_confidence: "high"
depends_on: ["CIVO-050"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-09"
completed: "2026-09-09"
---

# CIVO-065 — cert-manager install

## 1. Outcome and rationale

cert-manager runs on the Civo target with the Gateway API HTTP-01 solver
enabled. cert-manager already runs on AWS unconditionally, for the ALB
controller's own webhook cert (added 2026-09-07, unrelated to this spec);
this spec's civo install is gated on `target == "civo"` alone, not a toggle.
Both CIVO-070 (public TLS) and CIVO-085 (workload identity certificates)
need it. For that reason, it is its own small slice.

## 2. Scope and non-goals

In scope: the Application, the CRDs, the namespace, and the wave. Not in
scope: the issuers and the certificates (CIVO-070, CIVO-085); the monitors
gating, deferred to CIVO-160 (`kube-prometheus-stack` is forbidden on civo
entirely, so no `ServiceMonitor` gating applies here).

## 3. Current state / evidence

No cert-manager objects exist in `gitops/` (verified negative). ADR 0011
rejects cert-manager for AWS's public-edge TLS termination. CIVO-015's
ADR 0028 allows it on Civo.

- **Correction (2026-09-09):** `gitops/templates/platform/aws/cert-manager/application.yaml` already exists (added 2026-09-07) — an unconditional, `target=="aws"`-gated cert-manager install that exists solely to serve aws-load-balancer-controller's own webhook certificate. It is unrelated to this spec's civo/ACME use case and this spec does not touch it.

## 4. Design and contracts

- `gitops/templates/platform/shared/cert-manager/application.yaml` is gated by `{{- if .Values.certManager.enabled }}`. **Correction (2026-09-09):** the implemented path is `gitops/templates/platform/civo/cert-manager/application.yaml`, not `shared/` — this install and AWS's existing one are unrelated, so it isn't a shared/target-branched file (see the §12 deviation on the gate choice). The chart is `cert-manager` from `https://charts.jetstack.io`. Pin the version at implementation (latest 1.x). Set `crds.enabled: true`. Set `config.gatewayAPI.enabled: true` (current docs; https://cert-manager.io/docs/configuration/acme/http01/) or the key for the pinned version. Set `ServerSideApply=true`. Wave: the first candidate was -2 (before ESO/consumers, after the Envoy chart CRDs at -1). cert-manager must be Established before the Certificates at wave 0. Place it at -3. Note that the Gateway API CRDs come from Envoy Gateway at -1. The HTTP-01 Gateway solver needs that CRD only at runtime, not at install.
- Resources: requests 50m/64Mi per component.
- `certManager.enabled` defaults to false. The civo values set it to true.

**Review amendments (2026-09-06, kubernetes-architect):**
- Add a `PreSync` hook Job on the consumers' Applications (or on the cert-manager Application's dependents) that waits for `certificates.cert-manager.io` to report `Established`, per this repository's rule that sync waves do not gate CRD readiness across Applications.

**Correction (2026-09-09):** the wave placement above is wrong — wave -3 syncs before Envoy Gateway's Application (wave -1, the CRD source), not after. The implementation uses wave 0, the minimum integer that syncs strictly after -1. This is also a forward note for CIVO-070: its Certificates must sit at a wave strictly greater than cert-manager's (0), not both at wave 0 as this section's original text assumed.

## 5. Files/components affected

`gitops/templates/platform/civo/cert-manager/application.yaml` (the new
file above, per the §4 correction); `gitops/values.yaml`; the monitors
gating in CIVO-160.

## 6. Implementation steps

1. Add the Application. The golden aws diff is empty (gated off).
2. Render civo. Run `PROVIDER=civo make argo-up`. Check that `kubectl get crd certificates.cert-manager.io` shows Established. Check that the webhook is ready.
3. Confirm the Gateway API feature flag. Create a throwaway `Issuer` with a `gatewayHTTPRoute` solver that references the platform Gateway. The dry-run must be accepted.

## 7. Dependencies and blockers

The CIVO-050 layout. This spec runs in parallel with CIVO-060.

## 8. Acceptance criteria

- On civo: the cert-manager pods are Ready. The CRDs are Established. The Gateway API solver is accepted.
- On aws: this spec adds no cert-manager objects to the AWS render (the pre-existing aws-load-balancer-controller cert-manager install is untouched). The golden diff is empty.

## 9. Validation

Offline: the golden diff and kubeconform. Real cloud: civo (~cents).

## 10. AWS regression protection

The chart only renders when `target == civo`; AWS is unaffected. The golden diff protects AWS.

## 11. Rollout and rollback/recovery

Revert the change. Argo prunes the objects. There is no data risk.

## 12. Risks and unresolved questions

- The flag name for Gateway API support varies by chart version. Verify it at pin time.
- **Deviation from §4 (2026-09-09):** the civo cert-manager Application is gated on `target == "civo"` alone, not on the `certManager.enabled` value flag §4 describes. That flag had no genuine second position (civo always true, aws never reads it, local never wants it) and wiring it through `gitops/bootstrap/values.yaml`/`root-application.yaml`/`argo-up.sh` plus regenerating the bootstrap golden fixture was avoidable plumbing. The dead `certManager.enabled` key was removed from `gitops/values.yaml`.
- **Deviation from §4 (2026-09-09):** resource requests use aws's proven cert-manager values (10m cpu / 32Mi memory request, 64Mi memory limit per component) instead of §4's unexamined 50m/64Mi — the identical chart at the identical pinned version already runs at the lower values on aws with no stated reason for civo to need 5x the CPU request.
- **Open question, findings (2026-09-09):** upstream cert-manager docs say the Gateway API CRD check runs only at controller startup, and the documented remedy for a missed check is a manual `kubectl rollout restart deployment cert-manager -n cert-manager` — meaning the expected failure mode, if the wave-0 ordering loses its race against Envoy Gateway's CRDs, is a silent miss (the pod stays healthy, the feature is just off), not a crash-loop. Root's `syncPolicy.retry` does not cover this: it retries failed applies (`no matches for kind`), not a running pod's already-cached feature set, and `selfHeal` never triggers because the manifest never changes. A miss here is invisible to every gate this spec adds and would surface later as CIVO-070's Certificates hanging forever. No hook is added speculatively (Ruling 2, above), but Task 4's live check for the feature being registered in the cert-manager controller's own log is treated as required evidence before this spec can close DONE, not as optional exploration.
  **Resolved (2026-09-09):** the live run's cert-manager controller log showed `"enabling the sig-network Gateway API certificate-shim and HTTP-01 solver"`, the `gateway-shim` controller started, and its `*v1.Gateway` cache populated — the feature registered correctly, with 0 pod restarts across controller/webhook/cainjector. The wave-0 ordering won the race on this run; no hook was needed. This is one data point, not proof it holds every cycle — CIVO-070's first live run (the actual consumer of this feature) is the next real test.
- **Operational note (2026-09-09):** Argo's root Application only reconciles against `repoURL`+`targetRevision` (`main`) via `origin` — a local `git merge --no-ff` is invisible to a running cluster until `git push origin main` happens. This branch's merge was pushed before live verification could see any of it; the same PROVIDER-env-leak-shaped mistake is easy to repeat with the merge step itself. Worth a standing reminder alongside the "push before argo-up" note this repeats from CIVO-060's session.

## 13. Definition of done

- [x] Evidence recorded; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
- 2026-09-09 — dependency CIVO-050 confirmed DONE; started via subagent-driven development on branch `civo-065-cert-manager`; promoted to IN_PROGRESS.
- 2026-09-09 — implemented via subagent-driven development: 3 tasks (Application file, structural-check wiring, spec-text corrections) each with a fresh implementer + task review, then a final whole-branch review (opus) with 3 Important + 3 Minor findings, one bundled fix round + scoped re-review (all addressed, no code changes needed - all findings were documentation/spec-prose). Merged to `main` (`0d4d911`), no PR.
- 2026-09-09 — offline evidence: `make gitops-check` clean (aws golden diff empty; civo/local structural check correct) at every task, after the fix round, and after merge. `bash -n`/shellcheck clean on `scripts/gitops-render-check.sh`.
- 2026-09-09 — live evidence (civo, region LON1): fresh bring-up via `PROVIDER=civo ARGO_UP_WATCH_SECONDS=900 make full-up` against merged `main` (pushed to `origin` first - Argo only reads git, a local merge is invisible until pushed, see §12's operational note). `root` reached Synced/Healthy a second time on civo (first was CIVO-060), now with `cert-manager` Application also Synced/Healthy alongside cnpg-operator/envoy-gateway/external-secrets. `kubectl get crd certificates.cert-manager.io`/`gateways.gateway.networking.k8s.io` both `Established=True`. All 3 cert-manager pods (controller/webhook/cainjector) `Running`, 0 restarts. Controller log confirmed the Gateway API HTTP-01 solver registered (`"enabling the sig-network Gateway API certificate-shim and HTTP-01 solver"`, `gateway-shim` controller started, `*v1.Gateway` cache populated) - the load-bearing check from §12's open question, resolved. Throwaway `ClusterIssuer` with a `gatewayHTTPRoute` solver dry-run accepted. `make gitops-check` clean against the merged tree; live AWS `argocd app diff root` deferred (no AWS cluster running this session, same as CIVO-060), golden diff is the AWS gate actually exercised. `PROVIDER=civo make full-down` (with `CONFIRM_DESTROY=vk-civo-lab` for the persistent/bootstrap stages) tore down the LB, cluster, firewalls, reserved IP, network, secrets, and Route 53 delegation in the expected order; final check (`civo kubernetes/volume/loadbalancer/ip ls`, `aws s3 ls`) confirmed zero Civo resources and no state bucket, matching the pre-run baseline exactly. Status: `DONE`.
