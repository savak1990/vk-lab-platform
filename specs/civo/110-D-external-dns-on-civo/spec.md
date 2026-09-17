---
id: "CIVO-110"
title: "ExternalDNS on Civo via the Roles Anywhere sidecar with a project-scoped owner ID"
status: "DONE"
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
updated: "2026-09-10"
completed: "2026-09-10"
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
- The role denies `ChangeResourceRecordSets` on a zone outside its scope
  (tested against the parent root zone, not the AWS `lab.<root-domain>`
  zone specifically — that zone didn't exist at test time, since AWS's own
  disposable/persistent stack wasn't up this session; denial against the
  parent zone is at least as strong evidence of the role's IAM scoping).
  This is a negative test with the `aws` CLI, using the helper's
  credentials.
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

- [x] Evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
- 2026-09-10 — implemented via subagent-driven-development, combined with
  CIVO-100 in one session/plan at the user's request (both depend only on
  CIVO-090, share the same sidecar helper template and testing shape).
  - `gitops/templates/platform/aws/external-dns/application.yaml` moved to
    `gitops/templates/platform/shared/external-dns/application.yaml`.
    `provider.name` stays `aws` unconditionally on both targets — Route 53
    is still the DNS backend regardless of which cluster provider runs the
    workload. `domainFilters` needed no change (already correctly
    per-target via `envoyGateway.fqdn`). `txtOwnerId` changed to
    `{{ .Values.externalDns.txtOwnerId | default .Values.project | quote }}`
    (the SSM/`argo-up.sh` wiring for this was already in place from
    CIVO-090's session). `nodeSelector` wrapped in
    `eq .Values.target "aws"` directly, rather than inventing the
    `capacity.systemNodeSelector` values key §4 suggested — no such key
    exists anywhere in this codebase, and civo has no separate "system"
    node pool to select.
  - Ruling on `local` gating: implementer kept a `ne .Values.target "local"`
    gate on the Application (deviating from an earlier draft that called
    for it to render fully unconditionally). Investigated and accepted:
    the real codebase convention is "gate on `ne local` iff the object is
    listed as forbidden-on-local in `scripts/gitops-render-check.sh`" —
    ExternalDNS's Application was already in `FORBIDDEN_APPLICATIONS_LOCAL`
    before this task, and `provider.name` is hardcoded `aws` with no local
    credential path, so a true unconditional render would have broken
    `local` and contradicted a pre-existing, unrelated assertion. Not a
    defect.
  - No `zoneIdFilters` added, deliberately — `domainFilters` already
    scopes ExternalDNS to a different hostname suffix than any AWS zone,
    and independently, CIVO-082's `external-dns` role is IAM-scoped to
    only the civo zone's ARN, so a misconfigured filter still can't reach
    another zone. `zoneIdFilters` would be a third, redundant layer.
  - Civo-only `extraContainers`/`extraVolumes`/`env` sidecar block added
    (verified against the chart's real `values.yaml` at tag
    `external-dns-helm-chart-1.21.1` that these are the chart's actual
    keys — `env`, not `extraEnv`, unlike the ESO chart used in CIVO-100).
  - Live verification on a real Civo cluster (`vk-civo-lab`): `external-dns`
    Application `Synced/Healthy`, controller pod `2/2 Running`
    (`external-dns` + `aws-signing-helper`). `argo.civo.<root-domain>` A
    record resolved to the reserved IP; the matching TXT record read
    `heritage=external-dns,external-dns/owner=vk-civo-lab,...` — confirmed
    directly via `aws route53 list-resource-record-sets`, project-scoped
    owner ID as required, distinct from AWS's `vk-lab-platform`.
  - Cross-zone negative test (throwaway pod, deleted after): the real,
    correctly-issued `external-dns-ra-cert` + real `external-dns` role
    attempted `route53:ChangeResourceRecordSets` against the parent root
    zone (the AWS `lab.<root-domain>` zone didn't exist at test time —
    AWS's own stack wasn't up this session; see §8). Result:
    `AccessDenied ... is not authorized to perform:
    route53:ChangeResourceRecordSets on resource:
    arn:aws:route53:::hostedzone/<root-zone-id> because no identity-based
    policy allows the route53:ChangeResourceRecordSets action`. Confirmed
    afterward that the root zone had zero A/TXT records — the blocked
    attempt wrote nothing.
  - Deletion evidence (§6 step 3): `PROVIDER=civo make full-down` runs
    `argo-down` before `cluster-down`/`persistent-down`/`bootstrap-down`
    (verified in the Makefile). `argo-down`'s own output:
    "ARGO-DOWN: ExternalDNS-owned Route 53 records confirmed gone." —
    captured directly from the real teardown, not simulated.
  - `scripts/gitops-render-check.sh` confirmed the AWS golden render
    unchanged throughout.
  - Two pre-existing, unrelated infra bugs blocked the real-cluster run
    and were fixed with the user's explicit approval (not part of this
    spec's own scope): Civo's cluster-update API rejecting the `tags`
    attribute (`terraform/modules/civo-k8s/main.tf`,
    `lifecycle { ignore_changes = [tags] }`), and `argocd-dex-server`
    segfaulting on the Civo cluster (disabled, `dex.enabled=false` in
    `scripts/argo-up.sh` — unused, no SSO exists; deferred follow-up
    tracked as CIVO-210). See CIVO-100 §14 for the full diagnosis.
  - Full stack torn down afterward per the user's instruction — all
    clean, no leaked resources.
