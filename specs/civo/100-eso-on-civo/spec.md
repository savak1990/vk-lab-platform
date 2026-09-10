---
id: "CIVO-100"
title: "External Secrets on Civo via the Roles Anywhere sidecar"
status: "DONE"
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
updated: "2026-09-10"
completed: "2026-09-10"
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

- `lab-postgres-app` (the only ExternalSecret with a civo-reachable
  `ClusterSecretStore` at this point — Grafana's ExternalSecret depends on
  the `observability` namespace, which CIVO-160 brings to civo, not this
  task) is `SecretSynced=True` on civo. CNPG and Grafana consume the
  underlying capability later.
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

- [x] Evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
- 2026-09-10 — implemented via subagent-driven-development, combined with
  CIVO-110 in one session/plan at the user's request (both depend only on
  CIVO-090, share the same helper template and gating pattern).
  - Gating ruling: the sidecar block gates on `eq .Values.target "civo"`,
    not `.Values.awsIdentity.mode == "rolesAnywhere"` as §4 suggested —
    `awsIdentity.mode` is declared in `gitops/values.yaml` but never
    referenced by any template condition or set by `argo-up.sh` on either
    branch; every other target-specific block in this codebase gates on
    `.Values.target` directly, so the sidecar block follows that
    established convention instead of introducing an unused, redundant
    flag.
  - `gitops/templates/platform/aws/external-secrets/secretstore.yaml`
    moved to `gitops/templates/platform/shared/external-secrets/`, gate
    changed from `eq .Values.target "aws"` to `ne .Values.target "local"`
    — no other change; the `ClusterSecretStore`/`ExternalSecret` already
    had no explicit `auth:` block (ambient SDK credential chain), so
    nothing about the file's actual behavior needed to change, only its
    reachability on civo.
  - Civo-only `extraContainers`/`extraVolumes`/`extraEnv` block added to
    the ESO Application's `helm.values` (verified against the chart's real
    `values.yaml` at tag `v2.9.0` that these keys exist). `nindent 10`
    verified correct empirically on the first render — no leading `- `
    written before the `{{- include "platform.rolesAnywhereSidecar" ... }}`
    call (that would have produced a broken `- - name: ...` double-dash).
  - `scripts/gitops-render-check.sh` updated: `ClusterSecretStore`/
    `ExternalSecret` moved from `FORBIDDEN_KINDS_CIVO` to
    `REQUIRED_OBJECTS_CIVO` (civo is now positively expected to render
    them); `FORBIDDEN_KINDS_LOCAL` left untouched, proving the `ne "local"`
    gate is a real gate, not a blanket removal of the aws-only
    restriction.
  - Ruling: Grafana's ExternalSecret was deliberately left aws-only and
    out of scope (see §8) — it depends on the `observability` namespace,
    which doesn't exist on civo until CIVO-160 (which itself depends on
    this spec) brings kube-prometheus-stack there. §2's own "not in scope:
    new secrets" and this dependency made pulling CIVO-160 forward the
    wrong call.
  - Live verification on a real Civo cluster (`vk-civo-lab`,
    `PROVIDER=civo make full-up` after full recovery from a torn-down
    state): `lab-postgres-app` ExternalSecret showed
    `STATUS=SecretSynced READY=True` in `cnpg-system`; the ESO controller
    pod ran with 2 containers (`external-secrets`, `aws-signing-helper`).
  - Cross-role negative test (throwaway pod, deleted after): the real
    `eso-ra-cert` Secret mounted with the sidecar's `--role-arn` pointed
    at the `external-dns` role instead of `eso`'s own. Sidecar log:
    `AccessDeniedException: Unable to assume role for
    arn:aws:iam::753939038916:role/vk-civo-lab-ra-external-dns` — denied
    at `CreateSession` itself, before any SSM call was attempted (a
    stronger guarantee than "denied on SSM" as §6 step 4 literally
    phrased it). Reproduces, with the real production ESO cert this time,
    the same mechanism CIVO-090 already proved generically.
  - `scripts/gitops-render-check.sh` confirmed the AWS golden render
    unchanged throughout (`aws render matches the golden baseline.`).
  - Two pre-existing, unrelated infra bugs blocked the real-cluster run
    and were fixed with the user's explicit approval (not part of this
    spec's own scope, but required to reach the gated evidence above):
    Civo's cluster-update API rejects the `tags` attribute
    (`terraform/modules/civo-k8s/main.tf` gained
    `lifecycle { ignore_changes = [tags] }`), and `argocd-dex-server`
    segfaulted consistently on the Civo cluster (disabled via
    `dex.enabled=false` in `scripts/argo-up.sh`'s shared `install_argocd()`
    — dex was unused, no SSO/OIDC exists anywhere in this platform; a
    deferred follow-up to configure real login is tracked as CIVO-210).
  - Full stack torn down afterward per the user's instruction
    (`make full-down` then `persistent-down`/`bootstrap-down` with
    `CONFIRM_DESTROY=vk-civo-lab`) — all clean, no leaked resources.
