---
id: "LOCAL-030"
title: "target=local render contract inverted; helpers, gates, render-check"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Mechanical gate edits guarded by the golden AWS diff and an explicit required/forbidden list"
effort_estimate: "One session (3–4 h)"
estimate_confidence: "high"
depends_on: ["LOCAL-010"]
blocked_by: []
supersedes: ["spec 022 Req 1, Req 8, Req 13"]
created: "2026-09-11"
updated: "2026-09-11"
completed: null
---

# LOCAL-030 — `target=local` render contract inverted; helpers, gates, render-check

## 1. Outcome and rationale

`helm template --set target=local` renders the platform a developer
actually wants — Envoy, CNPG operator and Cluster, storage class,
observability, RBAC — and nothing that needs a cloud. Today's contract in
`scripts/gitops-render-check.sh` says the opposite (operators without their
custom resources, External Secrets required). This spec flips the contract
and adjusts the few helpers that read provider-specific values, so
LOCAL-040/050/070 each only touch their own component.

## 2. Scope and non-goals

In scope:
- `_helpers.tpl`: `platform.storageClassName` local branch → `local-retain`.
- `gitops/values.yaml`: `capacity.spotAvoidance` documented as per-target;
  `argo-up` sets it `false` for local (LOCAL-010 already passes it).
- `shared/external-secrets/application.yaml`: gate `ne .Values.target "local"`.
- `shared/envoy-gateway/httproutes.yaml`: gate the whole file
  `ne .Values.target "local"` **for now** (LOCAL-050 re-enables it with the
  templated `sectionName`), so the dangling route disappears.
- `shared/postgres/application.yaml` stays ungated; the `Cluster` template
  stays forbidden for local until LOCAL-040.
- `scripts/gitops-render-check.sh`: rewrite `REQUIRED_OBJECTS` split per
  target where needed, `FORBIDDEN_KINDS_LOCAL`, `FORBIDDEN_APPLICATIONS_LOCAL`
  to the contract in §4.
- The `bootstrap/Chart.yaml` comment listing `aws|local` → `aws|civo|local`.

Not in scope:
- Gateway/EnvoyProxy local branch (LOCAL-050).
- StorageClass manifest and Cluster local branch (LOCAL-040).
- Observability un-gating (LOCAL-070).

## 3. Current state / evidence

- `gitops/templates/_helpers.tpl:7` allowlist `aws,civo,local`; `:17-23`
  storage class: civo → `civo-volume`, else `.Values.storage.className`.
- `gitops/values.yaml:20-21` `spotAvoidance: true` ungated.
- `shared/external-secrets/application.yaml` has no target condition;
  `secretstore.yaml:1` is `ne target "local"`.
- `shared/envoy-gateway/httproutes.yaml:1-24` ungated; renders an
  `HTTPRoute` with hostname `argo.` on local while `gateway.yaml` renders
  no Gateway.
- `scripts/gitops-render-check.sh:59-61` requires
  `Application/external-secrets` and `HTTPRoute__argocd__argocd` for local;
  `:72-78` forbids `Gateway`, `GatewayClass`, `EnvoyProxy`, `Cluster`,
  `StorageClass`, and the observability Applications for local.

## 4. Design and contracts

Final `target=local` contract (this spec lands the parts marked ●; the
rest arrive with the named spec and are added to the lists then):

Required:
- ● `Application/envoy-gateway`, `Application/cnpg-operator`,
  `PriorityClass`, `Application`s for kube-prometheus-stack, loki, alloy,
  metrics-server (LOCAL-070 flips them from forbidden to required),
  RBAC objects.
- `GatewayClass`, `EnvoyProxy`, `Gateway/envoy`, `HTTPRoute/argocd`,
  `HTTPRoute/grafana` (LOCAL-050).
- `Application/local-path-provisioner`, `StorageClass/local-retain`, `Cluster/lab-postgres` (LOCAL-040).

Forbidden for local (● all in this spec):
- Applications: `external-secrets`, `external-dns`, `cert-manager`,
  `ebs-csi`, `karpenter`, `aws-load-balancer-controller`.
- Kinds: `ExternalSecret`, `ClusterSecretStore`, `ClusterIssuer`,
  `Certificate`, `VolumeSnapshotClass`, `EC2NodeClass`, `NodePool`,
  `Service` with `type: LoadBalancer`, any object with an
  `service.beta.kubernetes.io/aws-load-balancer-*` or
  `kubernetes.civo.com/*` annotation.

Storage class helper:

```
{{- if eq .Values.target "civo" }}civo-volume
{{- else if eq .Values.target "local" }}local-retain
{{- else }}{{ .Values.storage.className }}{{ end }}
```

`storage.className` for local is also passed as `local-retain` by
`argo-up` so the observability files that read the raw value
(`kube-prometheus-stack.yaml:65-72,96-103`, `loki.yaml:69-72`) resolve
correctly without editing them here.

## 5. Files/components affected

`gitops/templates/_helpers.tpl`; `gitops/values.yaml`;
`gitops/bootstrap/Chart.yaml`;
`gitops/templates/platform/shared/external-secrets/application.yaml`;
`gitops/templates/platform/shared/envoy-gateway/httproutes.yaml`;
`scripts/gitops-render-check.sh`.

## 6. Implementation steps

1. Helper branch and values comment.
2. Gate ESO Application and (temporarily) `httproutes.yaml`.
3. Rewrite the render-check lists to the ● contract; add a LoadBalancer
   Service and cloud-annotation scan for local.
4. `make gitops-check`: golden AWS diff empty; civo render unchanged (diff
   `helm template --set target=civo` before/after); local render passes
   the new lists.
5. `PROVIDER=local make up`; root `Synced`/`Healthy`; `kubectl get
   application -n argocd` lists exactly the required Applications.

## 7. Dependencies and blockers

LOCAL-010 passes the local values.

## 8. Acceptance criteria

- `make gitops-check` passes with the new local lists; AWS golden diff
  byte-identical; civo render diff empty.
- Local render contains no `LoadBalancer` Service, no cloud annotation, no
  ESO/ExternalDNS/cert-manager/EBS/Karpenter/LBC Application.
- The local render contains no `HTTPRoute` (until LOCAL-050).
- Root Application reaches `Healthy` on the local cluster.

## 9. Validation

Offline: `make gitops-check`, `helm template` diffs, `kubeconform`.
Workstation: one `up`.

## 10. AWS regression protection

Golden diff byte-identical. Civo: `helm template --set target=civo` diff
empty before/after.

## 11. Rollout and rollback/recovery

Revert; the local render returns to the old (inert) contract.

## 12. Risks and unresolved questions

- Temporarily gating `httproutes.yaml` off for local means LOCAL-050 must
  land before anything is reachable through Envoy. Acceptable; nothing
  else consumes the routes.

## 13. Definition of done

- [ ] Gates and helper landed; render-check lists rewritten
- [ ] Golden and civo diffs empty; local `up` Healthy
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as `DRAFT` (blocked on LOCAL-010).
- 2026-09-11 — replanned wording for a developer-owned cluster.
