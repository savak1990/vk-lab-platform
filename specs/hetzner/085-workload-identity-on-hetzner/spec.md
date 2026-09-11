---
id: "HETZ-085"
title: "Workload identity on Hetzner: CA issuer Secret, per-consumer Certificates, multi-arch credential-helper sidecars for ESO and ExternalDNS on ARM"
status: "DRAFT"
priority: "P0"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "The chain is reused from CIVO-085/090/100/110, but the first run on arm64 nodes exposes every image pin, and a wrong CN or digest fails silently as an IAM denial"
effort_estimate: "One session (4–6 h) including the negative test"
estimate_confidence: "medium"
depends_on: ["HETZ-045", "HETZ-050", "HETZ-080", "CIVO-085", "CIVO-090", "CIVO-100"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: ""
---

# HETZ-085 — Workload identity on Hetzner

## 1. Outcome and rationale

Every controller on the Hetzner cluster that needs AWS reaches it through
the Civo identity chain: cert-manager issues a 24-hour certificate per
consumer from the project CA, the credential-helper sidecar exchanges it
with Roles Anywhere, and the AWS SDK in ESO and ExternalDNS reads
temporary credentials from `127.0.0.1:9911`. No AWS key exists anywhere in
the cluster. On Hetzner the nodes are arm64, so this spec is also the
first place where every image pin in the chain is proven multi-arch.

## 2. Scope and non-goals

In scope: `ensure_ca_secret` on hetzner, the ClusterIssuer and
Certificates from `workloadIdentity.consumers`, the ESO and ExternalDNS
sidecars, the credential-helper image digest, and the positive and
negative test pods on an arm64 node. Not in scope: the cert-manager
consumer's DNS-01 use (HETZ-070), the `pgbackup` consumer's job (HETZ-120),
any change to the Civo project.

## 3. Current state / evidence

- HETZ-016 hoisted `platform/civo/identity/` to `platform/shared/identity/` gated by `platform.selfManaged`; HETZ-018 renamed the values key to `workloadIdentity` and the Secret/ClusterIssuer to `<provider>-workload-ca`.
- HETZ-045 makes `argo-up` call `ensure_ca_secret` on every non-AWS provider, decrypting `secrets/<project>/<provider>-ca-key.enc` into `cert-manager/<provider>-workload-ca`.
- `gitops/values.yaml:30` pins `public.ecr.aws/rolesanywhere/credential-helper@sha256:56b03f3a…`, which is the **amd64-only** image digest (tag `1.8.5-amd64-2026.08.24.20.52`). On a CAX node the pull fails with `no match for platform in manifest`. `research.md` confirms the repository publishes a multi-arch manifest list for 1.8.5.
- CIVO-100 and CIVO-110 inject the sidecar through the charts' `extraContainers` on `platform.selfManaged`; the mount of `<consumer>-ra-cert` and the `AWS_EC2_METADATA_SERVICE_ENDPOINT` env are unchanged.

## 4. Design and contracts

- Secret `cert-manager/hetzner-workload-ca` (type `kubernetes.io/tls`), created by `argo-up`, never pruned by Argo.
- ClusterIssuer `hetzner-workload-ca`. Certificates at sync wave 1: `eso-ra-cert`, `external-dns-ra-cert`, `cert-manager-ra-cert`, `pgbackup-ra-cert`, CN `vk-hetzner-lab-hetzner-<consumer>`, duration 24 h, renew before 8 h, key usage `digital signature`, `client auth`.
- Sidecar: `aws_signing_helper serve --certificate /ra/tls.crt --private-key /ra/tls.key --trust-anchor-arn … --profile-arn … --role-arn … --port 9911 --hop-limit 1`, region `eu-west-1`, from `awsIdentity.rolesAnywhere.*` values that `argo-up` relays from SSM (HETZ-045).
- Image: `awsIdentity.rolesAnywhere.image` changes for **both** civo and hetzner to the manifest-list digest of `credential-helper:1.8.5` (the digest that `docker manifest inspect` reports for the tag, not for one platform). On amd64 the resolved image is byte-identical to today's pin; on arm64 the runtime selects the arm64 layer. HETZ-182 owns the same rule for the repo-built `pg-backup` image; this spec owns the credential-helper line.
- Test manifests under `tests/manifests/hetzner-085/`: one pod with the ESO certificate mounted and the sidecar, running `aws sts get-caller-identity` and `aws ssm get-parameter --name /vk-hetzner-lab/bootstrap/route53/fqdn` with `amazon/aws-cli` (multi-arch); one pod with a Certificate whose CN is `vk-hetzner-lab-hetzner-nobody`, expecting `AccessDenied` from `CreateSession`.

## 5. Files/components affected

- `gitops/values.yaml` — `awsIdentity.rolesAnywhere.image` digest; `workloadIdentity.consumers` for `target: hetzner` (same four as civo).
- `gitops/templates/platform/shared/identity/{issuer,certificates}.yaml` — no change expected; verify the render for `target: hetzner`.
- `gitops/templates/platform/shared/external-secrets/application.yaml`, `shared/external-dns/application.yaml` — no change expected.
- `tests/manifests/hetzner-085/` (new).
- `scripts/argo-up.sh` — no change; HETZ-045 supplies the branch.

## 6. Implementation steps

1. `docker manifest inspect public.ecr.aws/rolesanywhere/credential-helper:1.8.5`; record the manifest-list digest and both platform digests in §14.
2. Change the values pin. Render `aws`, `civo` and `hetzner`; the aws render is unchanged (the sidecar template does not render on aws), the civo render differs only in the digest string.
3. `PROVIDER=hetzner make argo-up` on a cluster from HETZ-045. Confirm the Secret, the ClusterIssuer `Ready`, and four Certificates `Ready` within two minutes.
4. Confirm the ESO and ExternalDNS pods run two containers on a `cax21` node and that the sidecar logs a successful `CreateSession`.
5. Apply the positive test pod; check `get-caller-identity` returns the assumed-role ARN `…/vk-hetzner-lab-ra-eso/…`. Apply the negative pod; check the denial. Delete both.
6. On the Civo cluster, run `argo-up` once and confirm the sidecars restart on the new digest with no behaviour change.

## 7. Dependencies and blockers

HETZ-080 supplies the CA and the ARNs; HETZ-045 the `argo-up` branch and
the SSM relay; HETZ-050 the `target: hetzner` render. CIVO-085/090/100
must be `DONE` and hoisted by HETZ-016.

## 8. Acceptance criteria

- `kubectl -n cert-manager get clusterissuer hetzner-workload-ca` is `Ready`; four Certificates `Ready`; each Secret's certificate has the expected CN and 24 h validity (`openssl x509 -noout -subject -dates`).
- Sidecar image on the running pods resolves to an arm64 layer (`kubectl get pod -o jsonpath='{.status.containerStatuses[*].imageID}'` shows the platform digest that `docker manifest inspect` listed for `linux/arm64`).
- Positive test: `get-caller-identity` returns the `ra-eso` role; `get-parameter` returns the fqdn (proves IPv4 egress to SSM from a Hetzner node).
- Negative test: `CreateSession` denied for the wrong CN.
- ESO syncs `lab-postgres-app`; ExternalDNS logs a successful Route 53 list.
- Civo: sidecars run on the new digest; ESO and ExternalDNS behaviour unchanged.

## 9. Validation

Offline: three-target render, `kubeconform`. Real cloud: one Hetzner
cluster from HETZ-045 (about 0.10 EUR per hour) and one Civo `argo-up`.

## 10. AWS regression protection

AWS render byte-identical (the sidecar template is gated off). Civo render
differs only in the digest string; on amd64 the manifest list resolves to
the same image content as the old pin, verified by comparing the amd64
platform digest with the old pinned digest. One Civo `argo-up` confirms.

## 11. Rollout and rollback/recovery

Rollback the digest change with one values commit. Rollback on Hetzner is
`argo-down`; nothing persistent is created. If a Certificate stays not
`Ready`, the usual causes are a missing CA Secret (rerun `argo-up`) or a
CN mismatch against the role trust policy (compare with HETZ-080 §4).

## 12. Risks and unresolved questions

- The credential-helper repository has in the past published per-platform tags only; if 1.8.5 has no manifest list, pin the arm64 platform digest for hetzner and keep the amd64 digest for civo through a per-target value.
- `amazon/aws-cli` publishes arm64; if a future pin does not, the test pod falls back to `alpine/k8s` with the AWS CLI installed at start.
- The `hop-limit 1` rule holds on flannel as on Civo, but the sidecar's localhost endpoint is unreachable from a `hostNetwork` pod on the same node; the test pods must not use `hostNetwork`.
- ESO's ClusterRole can still read the CA Secret (CIVO-205 open); Hetzner inherits that until CIVO-205 lands.

## 13. Definition of done

- [ ] Acceptance criteria met and recorded
- [ ] Three-target render check passes; Civo sidecars verified on the new digest
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
