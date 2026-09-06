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
Civo reserved IP. ExternalDNS writes the records into the
`civo.<root-domain>` zone with the owner ID `vk-civo-lab`. `argo-down`
removes the records before the controller is deleted. The AWS project's
records in `lab.<root-domain>` are never touched.

## 2. Scope and non-goals

In scope: the civo branch of the ExternalDNS Application (the sidecar, the
owner ID, the zone filter). Not in scope: TLS (CIVO-070).

## 3. Current state / evidence

- `gitops/templates/platform/aws/external-dns/application.yaml:22-44` sets `provider.name: aws`, `sources: [gateway-httproute]`, `domainFilters: [fqdn]`, `txtOwnerId: {{ .Values.project }}`, `policy: sync`, the Pod Identity SA, and `nodeSelector node-type: system`.
- The role `${project}-ra-external_dns` is scoped to the civo zone id (CIVO-082).
- `argo-down.sh:169-201` polls Route 53 for `heritage=external-dns` records in the `${SUBDOMAIN}.${ROOT_DOMAIN}` zone. This is already project-aware via `SUBDOMAIN=civo`.

## 4. Design and contracts

- Move the Application to `shared/external-dns/application.yaml`. Its values are: `txtOwnerId: {{ .Values.externalDns.txtOwnerId | default .Values.project }}`; `zoneIdFilters` optional; `nodeSelector` only when `capacity.systemNodeSelector` is set (aws); the sidecar block when `awsIdentity.mode == rolesAnywhere`; `serviceAccount.annotations` only on aws.
- On civo, the HTTPRoute hostnames yield A records to the Service IP (the reserved IP). With proxy protocol off, the status carries an IP.
- The owner ID on civo is `vk-civo-lab`. On aws it is unchanged (`vk-lab-platform`).

## 5. Files/components affected

`gitops/templates/platform/shared/external-dns/application.yaml` (moved and templated); `gitops/values.yaml`.

## 6. Implementation steps

1. Template the Application. The golden aws diff is empty.
2. Run `PROVIDER=civo make up`. Check that `dig argo.civo.<root-domain>` returns the reserved IP. Check that the TXT owner record is present.
3. Run `argo-down`. The records are gone before the cascade (the script gate).
4. Cross-zone check: run `aws route53 list-resource-record-sets` on the AWS lab zone before and after. The output is unchanged.

## 7. Dependencies and blockers

090 (the sidecar), 060 (the LB IP).

## 8. Acceptance criteria

- Records are created and deleted with the civo owner ID, only in the civo zone.
- The role denies `ChangeResourceRecordSets` on the AWS lab zone. This is a negative test with the `aws` CLI, using the helper's credentials.
- The AWS golden diff is empty.

## 9. Validation

Offline: the golden diff. Real cloud: civo up/down (~0.2 USD). The Route 53 API is free.

## 10. AWS regression protection

The template defaults reproduce the AWS file exactly (golden).

## 11. Rollout and rollback/recovery

Revert the change. The `argo-down` gate cleans stale records. Otherwise, clean them manually.

## 12. Risks and unresolved questions

- The `gateway-httproute` source needs the Gateway to publish addresses. This is verified in CIVO-060.

## 13. Definition of done

- [ ] Evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
