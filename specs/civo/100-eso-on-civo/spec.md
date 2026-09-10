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

On Civo, ESO syncs the Postgres app password and the Grafana admin
password from SSM into Kubernetes Secrets, exactly as on AWS. ESO
authenticates through the sidecar instead of Pod Identity. The
`ClusterSecretStore` and `ExternalSecret` manifests stay shared and
unchanged.

## 2. Scope and non-goals

In scope: the civo branch of the ESO Application values (`extraContainers`,
`extraVolumes`, env), and the least-privilege check. Not in scope: new
secrets.

## 3. Current state / evidence

- `gitops/templates/platform/shared/external-secrets/secretstore.yaml` (hoisted in CIVO-050) sets `provider.aws.service: ParameterStore` and `region`. It has no `auth`. For that reason, the controller pod credentials come from the SDK default chain (research.md).
- The ESO chart 2.9.0 `application.yaml` uses `webhook.failurePolicy: Ignore` and SSA.
- The role `${project}-ra-eso` allows `ssm:GetParameter` on the two parameter ARNs. It allows `kms:Decrypt` with `EncryptionContext:PARAMETER_ARN` (CIVO-082).

## 4. Design and contracts

- Use `gitops/templates/platform/civo/external-secrets/application-values.yaml`, or a values block selected by `.Values.awsIdentity.mode == rolesAnywhere`. The chart values are `extraContainers: [ {{ include "platform.rolesAnywhereSidecar" (dict "consumer" "eso" "namespace" "external-secrets" "root" $) }} ]`, `extraVolumes` for the Secret `eso-ra-cert`, and `extraEnv` with `AWS_EC2_METADATA_SERVICE_ENDPOINT` and `AWS_REGION`. The `root` key is required: a named template's own `.` becomes the dict passed to it, so without `root` the template's `.root.Values...` lookups can't reach the caller's `.Values` and the include fails at render time. The chart may lack these keys for the controller Deployment. In that case, use the chart's `deploymentAnnotations`/`podSpec` overrides, or a strategic-merge patch via Argo `kustomize` on the rendered chart. Record the chosen path.
- Only the controller needs credentials. The webhook and the cert-controller do not get the sidecar.
- Adding a third Roles Anywhere consumer (this task plus CIVO-110 are the first two) is not a single-file change: as of CIVO-090, it requires synchronized edits across 5 files/8 sites — Terraform's `local.consumers` (`terraform/modules/rolesanywhere/main.tf`), `gitops/values.yaml`'s `civoIdentity.consumers` and `awsIdentity.rolesAnywhere.roleArns`, `gitops/bootstrap/values.yaml`'s `roleArns`, `root-application.yaml`'s relay entry, and 3 sites in `scripts/argo-up.sh`. A future implementer adding a fourth consumer should also check `aws ssm get-parameters`'s 10-name batch cap — the civo batch is already at 8 names and has no headroom left for another consumer's role ARN without splitting the call.

## 5. Files/components affected

`gitops/templates/shared/external-secrets/application.yaml` (the values are conditional); `gitops/values.yaml`.

## 6. Implementation steps

1. Add the conditional values. The golden aws diff is empty.
2. Run `PROVIDER=civo make up`. Run `kubectl get externalsecret -A`. Both show `SecretSynced`. The Secrets contain the expected keys (do not print the values).
3. Rotate the SSM value in a test parameter. Confirm the refresh within `refreshInterval`.
4. Negative test: swap the sidecar `--role-arn` to the external-dns role. ESO gets `AccessDenied` on SSM (record this). Then restore the role.

## 7. Dependencies and blockers

CIVO-090 (the image and the template).

## 8. Acceptance criteria

- Both ExternalSecrets are `Ready=True` on civo. CNPG and Grafana consume them later.
- The cross-role negative test is denied.
- The AWS golden diff is empty. AWS ESO is unchanged.

## 9. Validation

Offline: the golden diff. Real cloud: civo (~cents).

## 10. AWS regression protection

The values are conditional. They apply only when `awsIdentity.mode == rolesAnywhere`.

## 11. Rollout and rollback/recovery

Revert the values. The secrets remain as last synced.

## 12. Risks and unresolved questions

- Chart support for `extraContainers` on the controller Deployment.

## 13. Definition of done

- [ ] Evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
