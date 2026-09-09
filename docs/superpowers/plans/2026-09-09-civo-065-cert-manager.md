# CIVO-065 implementation plan — cert-manager install behind a target gate

Spec: `specs/civo/065-cert-manager-install/spec.md`. Depends on CIVO-050 (DONE).
Branch: `civo-065-cert-manager`, forked from `main` at the baseline verified
clean by `make gitops-check` (2026-09-09).

## Context the spec doesn't know about (drift since 2026-09-06)

1. `gitops/templates/platform/aws/cert-manager/application.yaml` now exists
   (added 2026-09-07, commit `6021b98`) — an **unconditional**, `target=="aws"`
   -gated cert-manager install (chart `cert-manager` v1.21.1) that exists
   solely to serve `aws-load-balancer-controller`'s own webhook certificate.
   It is unrelated to the public-ACME use case CIVO-065 is for. §3's "No
   cert-manager objects exist in `gitops/` (verified negative)" and §8's "On
   aws: no cert-manager objects exist" are both now false statements. This
   plan does not touch that file. §3/§8/§12 get a correction note (see
   Task 3) instead of trying to satisfy the old wording.
2. `gitops/values.yaml` already carries a `certManager: {enabled: false}`
   key with a comment describing exactly civo's future in-cluster-issuer
   need — pre-seeded for this spec, currently unread by any template. This
   plan deletes it rather than wiring it (see Ruling 1 below).
3. cert-manager's Gateway API support (confirmed against current upstream
   docs/release notes, not just the spec's guess): the value key is
   `config.gatewayAPI.enabled: true` (no feature gate — that mechanism was
   retired at v1.15). The Gateway API CRDs must exist **before the
   cert-manager controller pod starts**; arriving after boot needs a pod
   restart to be picked up. Envoy Gateway's Application (which supplies
   those CRDs) syncs at wave `-1`. CIVO-065's own spec text places
   cert-manager at wave `-3` — before its CRD source. That ordering is
   backwards.

## Rulings

**Ruling 1 — gate on `target`, not a value flag.** Spec §4 designs
`certManager.enabled` as the toggle: false by default, true on civo. In
practice there is no second position for that flag — civo always sets it
true, aws never reads it (aws's own cert-manager install is a separate,
already-unconditional file), and `local` never wants it. A flag with one
live value is dead weight: it would require adding `certManager.enabled` to
`gitops/bootstrap/values.yaml`, to `root-application.yaml`'s helm
parameters, to `argo-up.sh`'s civo installer, and regenerating
`tests/golden/gitops-aws/bootstrap/Application__argocd__root.yaml` — the
exact plumbing-drift class that broke `make gitops-check` on `main` after
CIVO-045 landed 3 unregenerated golden-fixture lines. Gating on
`{{- if eq .Values.target "civo" }}` (mirroring the aws cert-manager file's
own `{{- if eq .Values.target "aws" }}`) needs none of that. Cost if wrong:
if a future spec genuinely needs to disable cert-manager on civo
independent of target, re-adding the flag is a small, contained change —
cheaper than carrying unused plumbing now. The existing dead
`certManager.enabled` key in `gitops/values.yaml` is deleted as part of
Task 1 (same dead-key cleanup as CIVO-060's `service.annotations`/`tls.mode`
removal).

**Ruling 2 — no CRD-race hook in this spec.** cert-manager's docs say a
missing-CRD-at-boot miss needs a controller restart to fix, which reads like
CLAUDE.md's named exception for a hook ("a consumer controller that wedges
permanently after a single failed attempt and needs a pod restart"). But it
isn't yet known whether cert-manager actually wedges silently, or instead
crash-loops on the missing CRDs and self-heals once Envoy Gateway's
Application lands (no hook needed) — the two failure modes need opposite
fixes, and building a rollout-restart hook (its own ServiceAccount/Role/
RoleBinding, an image, and the `PostSync`/finalizer teardown-deadlock class
CLAUDE.md separately warns about) before knowing which one is real is
premature. Task 2's live verification step observes pod restart count and
the controller's own log line for "gateway api is not enabled" to settle
this. Cost if wrong: a live run shows the miss is real and silent — the fix
is a follow-up commit adding the hook, informed by real evidence instead of
a guess; nothing about placing the Application at wave `0` needs to be
undone.

**Ruling 3 — resource requests match AWS's proven values, not the spec's
unexamined 50m/64Mi.** Spec §4 states "resources: requests 50m/64Mi per
component" without justification. The identical chart at the identical
pinned version already runs on civo's sibling cost profile at 10m cpu /
32Mi memory request, 64Mi memory limit per component on AWS (no cpu limit).
Nothing about the civo cert-manager instance's workload (idle most of the
time until CIVO-070/085 create Certificates) needs 5x the CPU request of
its AWS counterpart. This plan uses the AWS file's values verbatim,
consistent with CLAUDE.md's cost-consciousness rule. Cost if wrong: a
future spec sees throttling in the controller's own metrics and bumps the
request in a one-line change — cheap to discover and fix.

## Design

New file `gitops/templates/platform/civo/cert-manager/application.yaml`
(target-exclusive directory, mirroring the aws file's own placement — not
`platform/shared/`, since the two installs serve unrelated purposes and
share no values beyond the chart/version):

```yaml
{{- if eq .Values.target "civo" }}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
  annotations:
    # Envoy Gateway (wave -1) supplies the Gateway API CRDs this chart's
    # gatewayAPI.enabled needs present at controller boot - wave 0 is the
    # minimum integer that syncs strictly after it (creation order only).
    argocd.argoproj.io/sync-wave: "0"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://charts.jetstack.io
    chart: cert-manager
    targetRevision: v1.21.1
    helm:
      values: |
        crds:
          enabled: true
        config:
          gatewayAPI:
            enabled: true
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            memory: 64Mi
        webhook:
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
        cainjector:
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
{{- end }}
```

`gitops/values.yaml`: delete the dead `certManager: {enabled: false}` block
and its comment (Ruling 1). No other file in the bootstrap→root-application→
argo-up chain needs a change — this is the plumbing Ruling 1 avoids.

## Tasks

### Task 1 — add the Application, remove the dead value
1. Create `gitops/templates/platform/civo/cert-manager/application.yaml` as above.
2. Delete `certManager:` block from `gitops/values.yaml`.
3. `make gitops-check` — aws golden diff must stay empty (untouched file/path);
   civo/local structural check will fail until Task 2 updates the required-
   object list — expected, not a regression.
4. `helm template gitops --set target=civo` piped through `kubeconform`
   (repo's existing kubeconform invocation/CRD schema set) for the new object.
5. `bash -n`/shellcheck N/A (no script changes this task).

### Task 2 — wire the structural check
1. `scripts/gitops-render-check.sh`: add `Application__argocd__cert-manager`
   to `REQUIRED_OBJECTS_CIVO`.
2. Split `FORBIDDEN_APPLICATIONS` into `FORBIDDEN_APPLICATIONS_LOCAL` (keeps
   `cert-manager`) and `FORBIDDEN_APPLICATIONS_CIVO` (drops it), following
   the existing `FORBIDDEN_KINDS_LOCAL`/`_CIVO` split pattern from CIVO-060;
   wire both into `verify_object_set`'s `case "$target" in civo) ... ;; esac`
   branch, defaulting local's branch to the `_LOCAL` list.
3. Fix the forbidden-application error string ("aws-only until a later
   spec)") so it no longer claims aws-only for the local branch's remaining
   entries — reword without naming a spec, per CLAUDE.md's no-ticket-
   references-in-runtime-messages rule (which already extended to comments
   and error text in the CIVO-060 fix round).
4. `make gitops-check` clean end to end (aws golden diff empty, civo/local
   structural check passing with the new required object).

### Task 3 — spec text corrections (§3/§4/§8/§12), no code
1. §3: append a correction note recording the AWS cert-manager file's
   existence since 2026-09-07 and its unrelated purpose.
2. §4: correct the wave placement text (was: "Place it at -3" — now: wave 0,
   with the CRD-ordering rationale) and record the handoff invariant for
   CIVO-070: its Certificates must sit at a wave strictly greater than
   cert-manager's (0), not both at 0 as §4 currently assumes — mirrors the
   060→070 cross-spec correction already on file.
3. §8: reword the unsatisfiable "On aws: no cert-manager objects exist" to
   "this spec adds no cert-manager objects to the AWS render; the golden
   diff stays empty."
4. §12: record Ruling 1/2/3 above (gate choice, no hook yet, resource sizing)
   as spec-level "Deviations from §4" notes, same shape as CIVO-060's §12.

### Task 4 — live verification on civo
1. `PROVIDER=civo make argo-up` against this branch's `TARGET_REVISION`
   (branch not yet merged — same pre-merge-testing question CIVO-060 hit;
   default to the same resolution unless told otherwise: merge to `main`
   first, then live-verify against `main`, since root only reads git).
2. `kubectl get crd certificates.cert-manager.io` → `Established`.
3. `kubectl get pods -n cert-manager` → all `Ready`; **record the restart
   count** (Ruling 2's evidence: 0 restarts with the feature registered
   means the wave-0 ordering won the race cleanly; a restart with the
   feature then present means it crash-looped and self-healed, still no
   hook needed; a steady-state 0 restarts with the feature *absent* from
   the log is the one outcome that means Ruling 2 was wrong and a hook is
   needed as a same-day follow-up).
4. `kubectl -n cert-manager logs deploy/cert-manager | grep -i gateway` —
   look for the feature being registered vs. a "gateway api is not enabled"
   line (replaces spec §6 step 3's weak dry-run-only check, which passes
   regardless of whether the feature is actually on, since the
   `gatewayHTTPRoute` field lives in cert-manager's own Issuer CRD schema
   either way).
5. Throwaway `ClusterIssuer` with a `gatewayHTTPRoute` solver referencing
   `platform-gateway`, dry-run only, then delete it — still run as
   documented evidence, just not the sole check.
6. `make gitops-check` clean against the merged tree; note that a live AWS
   `argocd app diff root` (spec §10) is deferred the same way CIVO-060's
   was — no live AWS cluster is running this session; the golden diff is
   the AWS regression gate actually exercised.
7. Full teardown (`argo-down`, `cluster-down`, `persistent-down`,
   `bootstrap-down`), verified zero Civo resources left, matching the
   CIVO-060 teardown-verification shape.

### Task 5 — close the spec
Set `status: DONE`, `completed`, record execution evidence (Task 1-4
results, live restart-count/log evidence, rulings) per README protocol
step 7; update `specs/civo/README.md` index row.

## Global constraints (carried into every task dispatch)

- Never touch `gitops/templates/platform/aws/cert-manager/application.yaml`.
- Never touch `gitops/bootstrap/*`, `scripts/argo-up.sh`, or the bootstrap
  golden fixture — Ruling 1 means none of them need a change; a dispatched
  implementer touching any of them is a plan violation, not a judgment call.
- No ticket/spec IDs in code comments or runtime/error strings.
- Comments ≤3 lines.
- `make gitops-check` must stay clean (aws golden diff empty) after every task.
