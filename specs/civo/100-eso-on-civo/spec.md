---
id: "CIVO-100"
title: "External Secrets on Civo via the Roles Anywhere sidecar"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "Chart values change plus verification; the identity design is already fixed"
effort_estimate: "Half a session (2–3 h)"
estimate_confidence: "high"
depends_on: ["CIVO-090"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-100 — External Secrets on Civo

## 1. Outcome and rationale

On Civo, ESO syncs the Postgres app password and Grafana admin password
from SSM into Kubernetes Secrets exactly as on AWS, authenticated through
the sidecar instead of Pod Identity. The `ClusterSecretStore` and
`ExternalSecret` manifests stay shared and unchanged.

## 2. Scope and non-goals

In scope: civo branch of the ESO Application values (`extraContainers`,
`extraVolumes`, env), least-privilege check. Not in scope: new secrets.

## 3. Current state / evidence

- `gitops/templates/platform/shared/external-secrets/secretstore.yaml` (hoisted in CIVO-050): `provider.aws.service: ParameterStore`, `region`, no `auth` → controller pod credentials via the SDK default chain (research.md).
- ESO chart 2.9.0 `application.yaml` with `webhook.failurePolicy: Ignore`, SSA.
- Role `${project}-ra-eso` allows `ssm:GetParameter` on the two parameter ARNs and `kms:Decrypt` with `EncryptionContext:PARAMETER_ARN` (CIVO-082).

## 4. Design and contracts

- `gitops/templates/platform/civo/external-secrets/application-values.yaml` or a values block selected by `.Values.awsIdentity.mode == rolesAnywhere`: chart values `extraContainers: [ {{ include "platform.rolesAnywhereSidecar" (dict "consumer" "eso") }} ]`, `extraVolumes` for Secret `eso-ra-cert`, `extraEnv` with `AWS_EC2_METADATA_SERVICE_ENDPOINT` and `AWS_REGION`. If the chart lacks these keys for the controller Deployment, use the chart's `deploymentAnnotations`/`podSpec` overrides or a strategic-merge patch via Argo `kustomize` on the rendered chart; record the chosen path.
- Only the controller needs credentials; webhook and cert-controller do not get the sidecar.

## 5. Files/components affected

`gitops/templates/shared/external-secrets/application.yaml` (values conditional), `gitops/values.yaml`.

## 6. Implementation steps

1. Add the conditional values; golden aws diff empty.
2. `PROVIDER=civo make up`; `kubectl get externalsecret -A`: both `SecretSynced`; Secrets contain the expected keys (values not printed).
3. Rotate the SSM value in a test parameter and confirm refresh within `refreshInterval`.
4. Negative: swap the sidecar `--role-arn` to the external-dns role → ESO `AccessDenied` on SSM (recorded), then restore.

## 7. Dependencies and blockers

CIVO-090 (image, template).

## 8. Acceptance criteria

- Both ExternalSecrets `Ready=True` on civo; CNPG and Grafana consume them later.
- Cross-role negative test denied.
- AWS golden diff empty; AWS ESO unchanged.

## 9. Validation

Offline: golden diff. Real cloud: civo (~cents).

## 10. AWS regression protection

Conditional values only when `awsIdentity.mode == rolesAnywhere`.

## 11. Rollout and rollback/recovery

Revert values; secrets remain as last synced.

## 12. Risks and unresolved questions

- Chart support for `extraContainers` on the controller Deployment.

## 13. Definition of done

- [ ] Evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
