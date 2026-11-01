---
id: "AWS-037"
status: "DONE"
updated: "2026-11-01"
---
# 037 — vk-llm-on-demand secrets

**Complexity:** Small
**Risk:** Low — two more SSM parameters and two more `ExternalSecret`s on an
already-proven path; nothing else reads or depends on them yet.
**Estimated cost:** ~0.25 day · AWS runtime cost: two SSM `SecureString`
parameters, free at standard tier.
**Recommended model:** Sonnet.
**Depends on:** `013-D-secrets` (the ciphertext → decrypt → runtime-secret
flow), ADR 0023 (SSM Parameter Store is the actual mechanism this platform
uses for that flow — `013-D-secrets`'s text predates ADR 0023 and still
describes raw Secrets Manager; `persistent-secrets` already writes SSM, not
Secrets Manager, for `postgres-app-password`/`grafana-admin-password`, and
this addendum follows that real, current mechanism rather than the spec's
stale text).
**Lifecycle class(es) touched:** Persistent (SSM parameters) / Disposable
(the `Namespace` and `ExternalSecret`s, reconciled by Argo CD).

## Scope

Onboards two account-global credentials for a future `vk-llm-on-demand` API
(an external repository, not this one — the same split as `vk-ahorro`): a
vast.ai API key (instances read/write scope) and a static bearer token that
will authorize callers of that future API. Wires the existing
`persistent-secrets` → SSM → External Secrets Operator pipeline, already
used for `postgres-app-password` and `grafana-admin-password`, to these two
secrets, landing them as Kubernetes `Secret`s in a new namespace `llm`.

Excludes: the `vk-llm-on-demand` application itself, its `Application`/
`AppProject`/RBAC, and any workload that consumes these secrets — those
arrive when that app is onboarded, the same way `vk-ahorro`'s `Application`
and RBAC were a separate spec (`035`/`036`) from its secrets.

## Requirements

1. `secrets/vast-ai-api-key.enc` and `secrets/llm-on-demand-api-token.enc`
   MUST be account-global-scope ciphertext (`secrets/<name>.enc`, not under
   `secrets/<PROJECT_NAME>/`) — the vast.ai key and the API token are not
   per-project values.
2. `terraform/modules/persistent-secrets` MUST decrypt both via
   `data.aws_kms_secrets` (the same data source `postgres_app_password` and
   `grafana_admin_password` already use) and publish them as `SecureString`
   SSM parameters under `/${var.project}/persistent/llm/vast_ai_api_key` and
   `/${var.project}/persistent/llm/api_token`, `key_id = "alias/lab-secrets"`.
3. `terraform/live/persistent/secrets/terragrunt.hcl` MUST point the two new
   variables at the global ciphertext paths, not a per-project path.
4. A `Namespace/llm` MUST be created by GitOps ahead of the `ExternalSecret`s
   that target it — an `ExternalSecret` apply into a missing namespace fails
   outright; `SkipDryRunOnMissingResource` covers only the dry run, not the
   real apply (same reasoning already documented for `Namespace/ahorro-dev`).
5. Two `ExternalSecret`s in namespace `llm`, `secretStoreRef: { name:
   aws-parameter-store, kind: ClusterSecretStore }`, MUST sync the two SSM
   parameters into two single-key Kubernetes `Secret`s (`vast-ai-api-key`,
   `vk-llm-api-token`, each with key `value`) — matching the existing
   `lab-postgres-app`/`grafana-admin-credentials` shape, not a new mechanism.
6. This addendum MUST NOT render on the `local` target, matching
   `grafana-admin-secret.yaml`'s existing `{{- if ne .Values.target "local"
   }}` guard — `local` has no SSM/ESO per `013-D-secrets`.
7. GitOps/Helm configuration MUST reference these secrets by SSM path only,
   never contain either plaintext value (constitution §5, §6) — unchanged
   from the existing pattern, stated here only because this addendum adds no
   new exception to it.

## Testing / acceptance criteria

- `make terraform-check` passes with `persistent/secrets` already present in
  `LIVE_UNITS` (no script change needed — the directory was already covered).
- `make gitops-check` passes against the regenerated `tests/golden/gitops-aws`
  baseline (`./scripts/gitops-render-check.sh update`), and the civo/hetzner
  structural check still reports the expected object set.
## Evidence

- `make terraform-check`: passed (see #101).
- `make gitops-check`: passed against the regenerated golden baseline (see #101).
- `make persistent-up` ran on the live Hetzner lab: `aws ssm
  get-parameters-by-path --path /vk-hetzner-lab/persistent/llm` returned both
  `SecureString` parameters, confirming the plaintext round-trips from the
  committed ciphertext.
- The first live `make bootstrap-up`/`persistent-up` pass surfaced a real
  gap, not covered by `terraform-check`: the `eso` Roles Anywhere role's IAM
  policy (`terraform/modules/rolesanywhere/main.tf`) allowlists SSM parameter
  ARNs explicitly rather than by path prefix, so the two new parameters were
  denied (`AccessDeniedException` on `ssm:GetParameter`) until #102 added
  their ARNs to that allowlist (and to the AWS EKS Pod Identity equivalent,
  `external-secrets-pod-identity`, for parity). Fixed in #102.
- After `bootstrap-up` (IAM fix) and `persistent-up` (SSM parameters) both
  ran: `kubectl -n llm get externalsecret,secret` shows both `ExternalSecret`s
  `SecretSynced`/`Ready: True`, and both `Secret`s (`vast-ai-api-key`,
  `vk-llm-api-token`) exist with a one-entry `value` key, 64 bytes each,
  matching the committed plaintext length.
