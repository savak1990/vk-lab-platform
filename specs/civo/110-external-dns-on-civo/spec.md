---
id: "CIVO-110"
title: "ExternalDNS on Civo via the Roles Anywhere sidecar with a project-scoped owner ID"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "Chart values and a Route 53 verification"
effort_estimate: "Half a session (2–3 h)"
estimate_confidence: "high"
depends_on: ["CIVO-090", "CIVO-060"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-110 — ExternalDNS on Civo

## 1. Outcome and rationale

`argo.civo.<root-domain>` and `grafana.civo.<root-domain>` resolve to the
Civo reserved IP, written by ExternalDNS into the `civo.<root-domain>`
zone with owner ID `vk-civo-lab`, and removed on `argo-down` before the
controller is deleted. The AWS project's records in `lab.<root-domain>`
are never touched.

## 2. Scope and non-goals

In scope: ExternalDNS Application civo branch (sidecar, owner ID, zone
filter). Not in scope: TLS (CIVO-070).

## 3. Current state / evidence

- `gitops/templates/platform/aws/external-dns/application.yaml:22-44`: `provider.name: aws`, `sources: [gateway-httproute]`, `domainFilters: [fqdn]`, `txtOwnerId: {{ .Values.project }}`, `policy: sync`, Pod Identity SA, `nodeSelector node-type: system`.
- Role `${project}-ra-external_dns` scoped to the civo zone id (CIVO-082).
- `argo-down.sh:169-201` polls Route 53 for `heritage=external-dns` records in the `${SUBDOMAIN}.${ROOT_DOMAIN}` zone: already project-aware via `SUBDOMAIN=civo`.

## 4. Design and contracts

- Move the Application to `shared/external-dns/application.yaml` with values: `txtOwnerId: {{ .Values.externalDns.txtOwnerId | default .Values.project }}`, `zoneIdFilters` optional, `nodeSelector` only when `capacity.systemNodeSelector` is set (aws), sidecar block when `awsIdentity.mode == rolesAnywhere`, `serviceAccount.annotations` only on aws.
- On civo, HTTPRoute hostnames yield A records to the Service IP (reserved IP). With proxy protocol off, status carries an IP.
- Owner ID on civo is `vk-civo-lab`; on aws unchanged (`vk-lab-platform`).

## 5. Files/components affected

`gitops/templates/platform/shared/external-dns/application.yaml` (moved + templated), `gitops/values.yaml`.

## 6. Implementation steps

1. Template; golden aws diff empty.
2. `PROVIDER=civo make up`; `dig argo.civo.<root-domain>` = reserved IP; TXT owner record present.
3. `argo-down`: records gone before cascade (script gate).
4. Cross-zone check: `aws route53 list-resource-record-sets` on the AWS lab zone unchanged before/after.

## 7. Dependencies and blockers

090 (sidecar), 060 (LB IP).

## 8. Acceptance criteria

- Records created and deleted with the civo owner ID only in the civo zone.
- Role denies `ChangeResourceRecordSets` on the AWS lab zone (negative test with the `aws` CLI using the helper's credentials).
- AWS golden diff empty.

## 9. Validation

Offline: golden diff. Real cloud: civo up/down (~0.2 USD); Route 53 API free.

## 10. AWS regression protection

Template defaults reproduce the AWS file exactly (golden).

## 11. Rollout and rollback/recovery

Revert; stale records cleaned by `argo-down` gate or manually.

## 12. Risks and unresolved questions

- `gateway-httproute` source needs the Gateway to publish addresses; verified in CIVO-060.

## 13. Definition of done

- [ ] Evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
