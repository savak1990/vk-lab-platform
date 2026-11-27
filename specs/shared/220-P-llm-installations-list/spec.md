---
id: "SHARED-220"
title: "vk-llm-on-demand installations as a platform list"
status: "READY"
priority: "P2"
milestone: "M2"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strong"
model_rationale: "A production AppProject and the three secrets its GPU worker depends on are refactored into a loop; a mistake in the per-entry namespace scoping reopens the cross-namespace isolation ADR 0021 requires."
effort_estimate: "One session (3-4 h)"
estimate_confidence: "medium"
depends_on: ["AWS-037"]
blocked_by: []
supersedes: []
created: "2026-11-27"
updated: "2026-11-27"
---

# SHARED-220 — The vk-llm-on-demand installation list

## 1. Outcome and rationale

`vkllm.instances`, a list in `gitops/values.yaml`, names every installation of
the `vk-llm-on-demand` application. One set of templates renders, per entry,
its pointer `Application`, an `AppProject` scoped to its own namespace, its
`Namespace` and three `ExternalSecret`s, and its `BackendTrafficPolicy`.
`scripts/argo-up.sh` builds Argo's `application.namespaces` from the same
list. The chat app's `open-webui-env` `ExternalSecret` gains `OPENAI_API_KEYS`,
one key per entry in list order. A second installation — `llm-dev`, tracking
`vk-llm-on-demand`'s newest build — needs one list entry and one value file;
production's rendered objects do not otherwise change.

Recorded in
[ADR 0021](https://github.com/savak1990/vk-llm-on-demand/blob/main/docs/adr/0021-installations-are-argo-applications-from-one-chart.md)
(vk-llm-on-demand's repository), which this spec implements on the platform
side. The application's own side is its CORE-280.

## 2. The problem

Today `gitops/templates/apps/vk-llm-on-demand/{application,appproject,
traffic-policy}.yaml` and `gitops/templates/platform/shared/llm/secrets.yaml`
hardcode one installation: namespace `llm`, `AppProject`/`Application`
`vk-llm-on-demand`. `scripts/argo-up.sh` hardcodes
`application.namespaces="ahorro,llm"`. A second installation that tracks
`main` for a dev environment (CORE-280) needs the same pointer, project,
secrets and traffic policy shape in a second namespace, and nothing here
today can add one without duplicating every file or widening the existing
`AppProject` to cover two namespaces — which ADR 0021 §5 rules out, because a
wrong namespace in either installation's value files would then reach the
other's.

A design that gave the dev installation's pipeline a cluster credential to
`helm upgrade` into `llm-dev` directly was implemented and withdrawn
(branch `llm-dev-deploy-credential`) before this spec: a `ServiceAccount`,
two `Role`/`RoleBinding` pairs and a cluster-wide namespace-read `ClusterRole`,
published to SSM the way `SHARED-049` publishes Ahorro's. It is rejected for
the reason ADR 0021 gives — a credential in GitHub that can read every
`Secret` in `llm-dev`, including the Vast.ai key, for a second installation
that is otherwise identical to the first. This spec adds no such credential;
every installation is, as production already is, an Argo CD `Application`
synced from Git.

## 3. Scope and non-goals

In scope: `vkllm.instances` in `gitops/values.yaml`; the loop over it in the
four template files named above; `scripts/argo-up.sh`'s
`application.namespaces` built from the list; `open-webui-env`'s
`OPENAI_API_KEYS`; the dev entry itself; `scripts/gitops-render-check.sh`'s
`REQUIRED_OBJECTS` and the `aws` golden fixtures for the dev entry's objects.

**Non-goals.** Anything inside the `vk-llm-on-demand` repository — the
`gitops/` chart's merged value files, `values-dev.yaml`, the image-tag
fallback, the smoke hook, the version format, `gpu-control.yml`'s `target`
input — all CORE-280. A per-namespace credential or RBAC grant of any kind.
A third installation. Pinning the chat app's own version (a separate spec).
A dashboard namespace selector.

## 4. Requirements

1. `gitops/values.yaml`'s `vkllm` key MUST carry `instances`, a list of
   `{namespace, project, valueFiles}` entries — `namespace` is where the
   entry's pointer lands its child objects, `project` names its
   `Application`/`AppProject` pair, `valueFiles` is passed through verbatim
   as the pointer's `source.helm.valueFiles`. `vkllm.targetRevision` stays a
   single top-level key, shared by every entry — a provider's lifecycle test
   pins it to one SHA, not one per installation.
2. `vkllm.instances` MUST carry two entries: production
   (`namespace: llm, project: vk-llm-on-demand, valueFiles: [values.yaml]`)
   and dev (`namespace: llm-dev, project: vk-llm-on-demand-dev,
   valueFiles: [values.yaml, values-dev.yaml]`).
3. `gitops/templates/apps/vk-llm-on-demand/{application,appproject,
   traffic-policy}.yaml` and `gitops/templates/platform/shared/llm/
   secrets.yaml` MUST range over `vkllm.instances`, rendering one
   `Application`, `AppProject`, `Namespace`, three `ExternalSecret`s and one
   `BackendTrafficPolicy` per entry — named from `.project` where the
   existing single-installation templates hardcode `vk-llm-on-demand`, and
   placed in `.namespace` where they hardcode `llm`.
4. Production's entry MUST render byte-for-byte the objects rendered today,
   except comments and the now-explicit `source.helm.valueFiles:
   [values.yaml]` on its pointer — Argo's own default, made visible by the
   loop needing a list to range over (ADR 0021 §1).
5. Each entry's `AppProject` MUST set `sourceNamespaces` and
   `destinations.namespace` to that entry's own namespace only; no entry's
   `AppProject` MUST reference another entry's namespace (ADR 0021 §5).
6. The three `ExternalSecret`s rendered for every entry MUST read
   production's SSM parameters under `/${project}/persistent/llm/...` —
   never a per-entry SSM path — so every installation shares one Vast.ai
   key, one client-key/management-token/worker-seed set and one SSH key
   (ADR 0021 §7; the application's CORE-280 accepts a dev token being a
   production token).
7. `scripts/argo-up.sh`'s `configs.params."application\.namespaces"` MUST be
   built from `ahorro` plus `vkllm.instances[].namespace`, read from
   `gitops/values.yaml` with `yq` as a preflight before the `helm upgrade`
   that installs Argo CD — never hand-typed — so a third installation needs
   no change here.
7a. The same computation MUST also run on the idempotency fast path (the
    branch that `exit 0`s when `root` is already `Synced/Healthy`), not only
    inside `install_argocd` below it — matching the "both arms" shape
    `SHARED-049` R7 already uses for the Ahorro deploy credential's
    publication. On the live personal lab, `root` is normally already
    `Synced/Healthy`, so a run that only updated the main-path computation
    would never reach it, and `llm-dev` would never join
    `application.namespaces` without a full teardown and recreate.
8. `gitops/templates/platform/shared/chat/secrets.yaml`'s `open-webui-env`
   `ExternalSecret` MUST template an `OPENAI_API_KEYS` key: the chat
   inference key (the same value templated into `OPENAI_API_KEY` today),
   repeated once per `vkllm.instances` entry, `;`-joined, in list order —
   the separator and the per-URL pairing the `open-webui` subchart's
   `OPENAI_API_BASE_URLS`/`OPENAI_API_KEYS` env vars already require. Every
   value is the same key today, so entry order cannot desynchronize it from
   `openaiBaseApiUrls`' order; a future per-installation key would need the
   two lists kept in lock step across repositories.
9. This spec MUST NOT add any IAM policy, Role, RoleBinding, ServiceAccount,
   or SSM-published cluster credential. The three `ExternalSecret`s per
   entry are the only new access path, identical in shape to production's
   existing ones and reading the same `ClusterSecretStore`.
10. The `local` target MUST continue to render none of `vkllm`'s objects —
    the existing `{{- if ne .Values.target "local" }}` guard, preserved
    across the loop, not duplicated per file.
11. `scripts/gitops-render-check.sh`'s checks MUST gain the dev entry's
    objects, regenerated/edited in the same commit, so the golden diff for
    production's objects stays comment-only (requirement 4):
    - The `aws` golden fixtures (`tests/golden/gitops-aws`) gain the dev
      entry's seven rendered objects (`Application`, `AppProject`,
      `Namespace`, three `ExternalSecret`s, `BackendTrafficPolicy`),
      bringing the golden total for `vkllm` from seven to fourteen.
    - `REQUIRED_OBJECTS_CIVO` and `REQUIRED_OBJECTS_HETZNER`, which today
      assert only production's three (`AppProject__argocd__
      vk-llm-on-demand`, `Application__argocd__vk-llm-on-demand`,
      `BackendTrafficPolicy__llm__gpu-on-demand-traffic-policy`), each gain
      the dev entry's seven: `AppProject__argocd__vk-llm-on-demand-dev`,
      `Application__argocd__vk-llm-on-demand-dev`,
      `Namespace__cluster__llm-dev`,
      `ExternalSecret__llm-dev__vast-ai-api-key`,
      `ExternalSecret__llm-dev__vk-llm-api-token`,
      `ExternalSecret__llm-dev__vk-llm-ssh-key`,
      `BackendTrafficPolicy__llm-dev__gpu-on-demand-traffic-policy`.
      Production's three stay as they are.
    - `FORBIDDEN_APPLICATIONS_LOCAL` gains `vk-llm-on-demand-dev` beside
      the existing `vk-llm-on-demand`, so the `local` target's structural
      check still refuses both installations' child `Application`s.

## 5. Implementation hints

`gitops/templates/platform/shared/identity/certificates.yaml` already ranges
over a list value (`workloadIdentity.consumers`) inside the same
`{{- if ... }}` / `{{- end }}` target guard this spec's four files already
carry — copy that shape, remembering `$.Values` (not `.Values`) for anything
read outside the loop variable once inside `range`.

`scripts/argo-up.sh`'s `install_argocd` currently hardcodes
`--set configs.params."application\.namespaces"="ahorro\,llm"`; building the
value from `yq '.vkllm.instances[].namespace' gitops/values.yaml`, joined
with `ahorro`, keeps the same `--set` call shape with a computed right-hand
side. `yq` is already a dependency of this script and of
`gitops-render-check.sh`. `install_argocd` itself is called only once, after
the idempotency guard's `exit 0` — the guard exists for speed, not
correctness (the comment above it notes the chart's own `helm upgrade` is
already safe to repeat), so requirement 7a's fast-path computation can call
`install_argocd` unconditionally, or diff the computed list against
`argocd-cmd-params-cm`'s current value and skip the call when unchanged;
either satisfies the requirement.

The withdrawn branch's `ExternalSecret` names
(`vast-ai-api-key`/`vk-llm-api-token`/`vk-llm-ssh-key`) need no per-entry
suffix: Kubernetes `Secret` names are namespace-scoped, so the same three
names in `llm` and `llm-dev` do not collide.

Production's pointer, project and traffic policy carry their own
`sync-wave` annotations today (4, 5, 6); every entry keeps the same numbers,
because each entry's objects are a separate graph the root `Application`
creates independently — the wave only orders creation within one entry, not
across entries.

The platform PR that carries this spec creates the dev pointer with
`valueFiles: [values.yaml, values-dev.yaml]` before `values-dev.yaml` exists
on `vk-llm-on-demand`'s `main` (CORE-280's own rollout merges the platform PR
first). The dev pointer's Helm render fails until that second file lands —
visible as the `vk-llm-on-demand-dev` `Application` stuck `Unknown`/
`ComparisonError`. This is harmless to the rollout: Argo CD dropped the
built-in `argoproj.io/Application` health check in 1.8, and
`gitops/argocd/values.yaml` customizes health only for `Gateway`
(`HTTPRoute` there has only an `ignoreDifferences` entry, no health check),
so `root`'s own health does not aggregate a child `Application`'s
comparison error. `make argo-up`'s wait, and production, are unaffected;
the dev pointer self-heals once the application PR merges.

## 6. Testing / acceptance criteria

1. `make gitops-check`, `make scripts-check` and `make specs-check` pass.
2. The `aws` golden diff for production's pointer, `AppProject`, the three
   `llm` `ExternalSecret`s and the traffic policy is comment-only, except the
   explicit `valueFiles: [values.yaml]` parameter (requirement 4).
3. After `make argo-up`, `kubectl get application -n argocd` lists both
   `vk-llm-on-demand` and `vk-llm-on-demand-dev`, and
   `kubectl -n argocd get cm argocd-cmd-params-cm -o jsonpath='{.data.application\.namespaces}'`
   contains `llm` and `llm-dev`.
4. On a cluster already `root` `Synced/Healthy` with `application.namespaces`
   still `ahorro,llm` (the fast-path case), re-running `make argo-up` adds
   `llm-dev` without a teardown and recreate (requirement 7a).
5. `kubectl -n chat get secret open-webui-env -o jsonpath='{.data.OPENAI_API_KEYS}' | base64 -d`
   decodes to the chat inference key repeated twice, `;`-joined.
6. No `Role`, `RoleBinding`, `ServiceAccount` or IAM statement appears in the
   rendered output or in `terraform plan` as a result of this spec.

## 7. Status history

- 2026-11-27 — created, READY.
