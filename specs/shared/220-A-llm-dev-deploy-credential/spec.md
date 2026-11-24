---
id: "SHARED-220"
title: "The deploy credential generalizes; vk-llm-on-demand's pipeline deploys to llm-dev"
status: "IN_PROGRESS"
priority: "P2"
milestone: "M2"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strong"
model_rationale: "A second application reuses Ahorro's own IAM and RBAC shape; the risk is a templating mistake that widens Ahorro's existing grant or lets the new namespace read or write llm"
effort_estimate: "One session (3-4 h)"
estimate_confidence: "medium"
depends_on: ["SHARED-049"]
blocked_by: []
supersedes: []
created: "2026-11-23"
updated: "2026-11-24"
---

# SHARED-220 — The llm-dev deploy credential

## 1. Outcome

vk-llm-on-demand's pipeline can `helm upgrade` into namespace `llm-dev` and
cannot touch namespace `llm`. It reads
`/<project>/cluster/llm-deploy/{endpoint,ca,token,fqdn}` through
`vk-llm-ci-role`. The application's side is its own ADR 0021 and spec
CORE-280, in `vk-llm-on-demand`.

This repeats [SHARED-049](../049-A-ahorro-deploy-credential/spec.md)'s shape
for a second application, generalizing its deploy credential rather than
copying it.

## 2. Requirements

1. The deploy credential MUST be rendered from one generic template, driven
   by a `deployCredentials` list in `gitops/values.yaml`, not from an
   app-specific template per application.
2. Ahorro's rendered objects MUST keep their names, namespaces and rules
   unchanged once the template is generalized.
3. `scripts/lib/ahorro-deploy.sh`'s publish and forget functions MUST become
   one publisher/forget pair parameterised by app name, called for both
   Ahorro and vk-llm-on-demand.
4. Namespace `llm-dev`'s ExternalSecrets MUST read production's
   `/<project>/persistent/llm/*` SSM parameters — the same parameters
   namespace `llm` already reads.
5. The `llm-deploy` Role in `llm-dev` MUST cover exactly the kinds the dev
   values render: `get`, `list`, `watch`, `create`, `update`, `patch` and
   `delete` on ConfigMap, Secret (Helm's release storage), Service,
   ServiceAccount, Deployment, Role, RoleBinding, HTTPRoute and
   ServiceMonitor; `get`, `list` and `watch` on ReplicaSet, Pod and Event;
   and `get` on `pods/log`. It MUST NOT grant `bind`, `escalate` or
   `impersonate` — the chart's own Role grants only ConfigMap get/update,
   which the deploy identity already holds.
6. A `BackendTrafficPolicy` MUST set the same `requestTimeout` as
   production's, rendered from the same template (today 1200s), on
   HTTPRoute `gpu-on-demand` in namespace `llm-dev`.
7. `vk-llm-ci-role` MUST gain `ssm:GetParameter` on
   `/*/cluster/llm-deploy/*` and `/*/persistent/llm/api_token`, and
   `kms:Decrypt` limited by a `kms:EncryptionContext:PARAMETER_ARN`
   condition to `management_tokens`, `api_token` and
   `cluster/llm-deploy/token`.

## 3. Acceptance

1. `make gitops-check specs-check scripts-check terraform-check` all pass.
   *(Verified 2026-11-24: all four green, including the new
   `deploy-credential-test.sh` case for a failing `yq`.)*
2. The golden diff for Ahorro's deploy objects shows comment lines only:
   names, namespaces and rules are unchanged. *(Verified 2026-11-24:
   `git diff origin/main...HEAD -- tests/golden/gitops-aws` shows 18
   changed Ahorro golden files from the template generalization
   (da3350e/830404b). One glob diff over all 18 at once —
   `git diff origin/main...HEAD -- 'tests/golden/gitops-aws/*/*ahorro*' |
   grep '^[+-][^+-]' | grep -v '^[+-]#'` — is empty, so every changed
   `+`/`-` line across all of them starts with `#`. Names, namespaces and
   rules did not move. The later replicasets fix (requirement 5, finding
   10) re-ran `./scripts/gitops-render-check.sh update` and changed
   exactly three more files — `Role__llm-dev__llm-deploy.yaml` in the
   `platform`, `platform-backup` and `platform-backup-recovery` golden
   sets — and touched no Ahorro file.)*
3. `kubectl auth can-i --as=system:serviceaccount:llm-dev:llm-deploy create
   deployments -n llm-dev` answers `yes`.
4. `kubectl auth can-i --as=system:serviceaccount:llm-dev:llm-deploy get
   configmaps -n llm` answers `no`.
5. `kubectl auth can-i --as=system:serviceaccount:llm-dev:llm-deploy
   escalate roles -n llm-dev` answers `no`.

Acceptance 3–5 need a live cluster and are deferred to a post-merge PR, run
after `make account-up` and `make argo-up`.

## 4. Status history

- 2026-11-23 — created, READY.
- 2026-11-24 — IN_PROGRESS: both pull requests' implementation is in;
  acceptance 1 and 2 verified above. Acceptance 3–5 wait on a live
  cluster after merge, so status does not move to DONE in this pull
  request.
