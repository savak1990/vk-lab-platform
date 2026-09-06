# Argo CD design

How Argo CD is installed, how the app-of-apps is structured, how ordering
and teardown work, and how a second execution target plugs in. Current
state as of commit `cfbb59bd340b6356bad3fb2493b41fa3a337efe5` (2026-09-06).

## 1. Install path

Argo CD is installed by a script, not Terraform (ADR 0012):

1. `scripts/argo-up.sh` reads five SSM parameters in one call and the EKS cluster name from Terragrunt output.
2. Configures kubeconfig with `eks-access-identity`.
3. Fast path: if the root Application is already `Synced/Healthy`, verify DNS and exit 0.
4. Discovers the newest Postgres EBS snapshot (ADR 0013) and prunes older ones.
5. `helm upgrade --install argocd argo-cd --version 10.4.0` with the admin bcrypt from SSM, resource requests, and a hard anti-affinity against spot nodes.
6. `helm upgrade --install root-application gitops/bootstrap --server-side --force-conflicts` with `--set target=aws`, project, VPC id, snapshot handle, storage size, Karpenter limits, ACM ARN, NLB subnets, FQDN.
7. Watches the root Application until `Synced/Healthy` (default 30 min), then waits for DNS.

Server-side apply on the root Application is required because the Argo
controller takes field ownership after first reconcile.

## 2. App-of-apps structure

Two Helm charts:

- `gitops/bootstrap/` renders exactly one object: the root `Application`
  (`templates/root-application.yaml`) with finalizer
  `resources-finalizer.argocd.argoproj.io`, `ServerSideDiff=true`,
  `automated {prune, selfHeal}`, `ServerSideApply=true`, and Helm
  `parameters` (scalars) plus `valuesObject` (lists).
- `gitops/` is the umbrella chart the root Application syncs from
  `path: gitops`. Every child Application and raw resource lives under
  `gitops/templates/platform/aws/<component>/`, and every file is wrapped in
  `{{- if eq .Values.target "aws" }}`. `.Values.target` is the only
  provider switch. There are no ApplicationSets, no cluster secrets, no
  Kustomize overlays authored in-repo, and no `values-<target>.yaml` files.

All 12 child Applications carry the resources finalizer and
`ServerSideApply=true`. `SkipDryRunOnMissingResource=true` is used where a
CRD comes from a sibling Application. `CreateNamespace=true` where needed.

## 3. Ordering (sync waves)

| Wave | Objects |
|---|---|
| -6 | external-snapshotter CRDs |
| -5 | aws-load-balancer-controller, ebs-csi-driver |
| -4 | karpenter (lowest controller so it is destroyed last) |
| -3 | EC2NodeClass/NodePools; envoy namespace, SA, Role, RoleBinding |
| -2 | external-secrets; ALB webhook readiness probe Job (Sync hook) |
| -1 | envoy-gateway, cnpg-operator, external-snapshotter controller |
| 0 | StorageClasses, VolumeSnapshotClass, EnvoyProxy/GatewayClass/Gateway/ClientTrafficPolicy, ClusterSecretStore + ExternalSecret, external-dns, recovered snapshot objects |
| 1 | kube-prometheus-stack, loki, metrics-server, PriorityClass |
| 2 | alloy, HTTPRoutes, BackendTrafficPolicy, monitors, dashboards, Grafana ExternalSecret, CNPG Cluster, e2e RBAC |
| 3 | PrometheusRule |

Wave numbers order creation of Application objects. They do not gate one
Application's controller readiness on a sibling's health; the only
cross-Application readiness guarantee in the tree is the ALB webhook probe
Job. Guidance: when a CRD or Secret from one Application must exist before
another starts, add a `PreSync` hook that waits on the concrete condition.

## 4. Values and injection

Root Application parameters → `gitops/values.yaml` defaults →
`{{ .Values.* }}` in templates. Keys today: `target`, `project`, `region`
(chart constant), `vpcId`, `postgres.{recoverySnapshotHandle,storageSize}`,
`karpenter.{spot,onDemand}.{instanceTypes,cpuLimit}`,
`envoyGateway.{acmCertificateArn,nlbSubnetIds,fqdn}`.

## 5. Teardown

`scripts/argo-down.sh` implements the deletion graph in reverse:

1. Prove the cluster exists (EKS API), configure kubeconfig, refuse if unreachable.
2. CNPG `Backup` with `volumeSnapshot`, wait for `completed`, prune old snapshots.
3. Disable `automated` sync and clear `operation` on every Application.
4. Delete all HTTPRoutes; poll Route 53 until ExternalDNS records are gone.
5. Delete the Gateway; poll until no LoadBalancer Service remains in `envoy`.
6. `kubectl delete application root --cascade=foreground --wait`, with a watcher printing stuck objects and their finalizers.
7. `helm uninstall` root-application, then argocd.

Helm `--wait` is not trusted for the cascade (ADR 0012). Explicit polls
exist because wave order does not guarantee teardown order across sibling
Applications; a second provider needs its own explicit gates for its LB and
DNS, not only renumbered waves.

## 6. Conventions

- Prefer `ServerSideApply=true` on every Application (large CRDs exceed the last-applied annotation cap).
- One deliberate exception: `VolumeSnapshotContent` is applied client-side because SSA would replace the atomic `volumeSnapshotRef`.
- `ignoreDifferences` on `VolumeSnapshotContent./spec/volumeSnapshotRef`.
- Every AWS-specific object stays inside the `aws` subtree; shared components read only contract values.

## 7. Adding a second execution target

The intended shape, used by the Civo target:

1. Add `gitops/templates/platform/civo/<component>/` files gated by `{{- if eq .Values.target "civo" }}`.
2. Hoist components with no provider coupling (Envoy Gateway chart, CNPG operator, ESO chart and its `ClusterSecretStore`, cert-manager) to `gitops/templates/platform/shared/` with no target gate, and make the provider-specific bits values-driven (storage class, spot anti-affinity, Service annotations, TLS mode, identity mode).
3. Prove AWS rendering is unchanged with a golden `helm template` diff (`--set target=aws`) before and after the hoist.
4. Give `argo-up.sh`/`argo-down.sh` a provider branch for kubeconfig, input discovery, persistence, and the LB/DNS teardown gates.
5. Keep the root Application, finalizers, waves, and SSA conventions identical.

Details: `docs/civo-high-level-design.md` and `specs/civo/050-gitops-civo-target-baseline`.
