---
id: "HETZ-085"
title: "Workload identity on Hetzner: CA issuer Secret, per-consumer Certificates, credential-helper sidecars for ESO and ExternalDNS"
status: "READY"
priority: "P0"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "The chain is reused from CIVO-085/090/100/110, but the first run on a self-managed cluster exposes every image pin, and a wrong CN or digest fails silently as an IAM denial"
effort_estimate: "One session (4–6 h) including the negative test"
estimate_confidence: "medium"
depends_on: ["HETZ-045", "HETZ-050", "HETZ-080", "CIVO-085", "CIVO-090", "CIVO-100"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-19"
completed: ""
---

# HETZ-085 — Workload identity on Hetzner

## 1. Outcome and rationale

Every controller on the Hetzner cluster that needs AWS reaches it through
the Civo identity chain: cert-manager issues a 24-hour certificate per
consumer from the project CA, the credential-helper sidecar exchanges it
with Roles Anywhere, and the AWS SDK in ESO and ExternalDNS reads
temporary credentials from `127.0.0.1:9911`. No AWS key exists anywhere in
the cluster. The Hetzner nodes are x86 `cx33`, so the credential-helper
and `amazon/aws-cli` images are pulled by their amd64 digests, exactly as
on Civo; a manifest-list digest is only needed if CAX ever returns
(HETZ-182).

## 2. Scope and non-goals

In scope: `ensure_ca_secret` on hetzner, the ClusterIssuer and
Certificates from `workloadIdentity.consumers`, the ESO and ExternalDNS
sidecars, the credential-helper image digest, and the positive and
negative test pods on a `cx33` node. Not in scope: the cert-manager
consumer's DNS-01 use (HETZ-070), the `pgbackup` consumer's job (HETZ-120),
any change to the Civo project.

## 3. Current state / evidence

- HETZ-016 hoisted `platform/civo/identity/` to `platform/shared/identity/` gated by `platform.selfManaged`; HETZ-018 renamed the values key to `workloadIdentity` and the Secret/ClusterIssuer to `<provider>-workload-ca`.
- HETZ-045 makes `argo-up` call `ensure_ca_secret` on every non-AWS provider, decrypting `secrets/<project>/<provider>-ca-key.enc` into `cert-manager/<provider>-workload-ca`.
- `gitops/values.yaml:30` pins `public.ecr.aws/rolesanywhere/credential-helper@sha256:56b03f3a…`, the amd64 image digest (tag `1.8.5-amd64-2026.08.24.20.52`), which resolves on an x86 `cx33` node exactly as it does on Civo. `research.md` confirms the repository also publishes a multi-arch manifest list for 1.8.5, needed only if CAX ever returns (HETZ-182).
- CIVO-100 and CIVO-110 inject the sidecar through the charts' `extraContainers` on `platform.selfManaged`; the mount of `<consumer>-ra-cert` and the `AWS_EC2_METADATA_SERVICE_ENDPOINT` env are unchanged.

## 4. Design and contracts

- Secret `cert-manager/hetzner-workload-ca` (type `kubernetes.io/tls`), created by `argo-up`, never pruned by Argo.
- ClusterIssuer `hetzner-workload-ca`. Certificates at sync wave 1: `eso-ra-cert`, `external-dns-ra-cert`, `cert-manager-ra-cert`, `pgbackup-ra-cert`, CN `vk-hetzner-lab-hetzner-<consumer>`, duration 24 h, renew before 8 h, key usage `digital signature`, `client auth`.
- Sidecar: `aws_signing_helper serve --certificate /ra/tls.crt --private-key /ra/tls.key --trust-anchor-arn … --profile-arn … --role-arn … --port 9911 --hop-limit 1`, region `eu-west-1`, from `awsIdentity.rolesAnywhere.*` values that `argo-up` relays from SSM (HETZ-045).
- Image: `awsIdentity.rolesAnywhere.image` keeps the amd64 digest of `credential-helper:1.8.5` for both civo and hetzner, because both run x86 nodes — no per-target value and no manifest-list digest. HETZ-182 owns the switch to manifest-list digests for every image, including the repo-built `pg-backup` one, if CAX ever returns.
- Test manifests under `tests/manifests/hetzner-085/`: one pod with the ESO certificate mounted and the sidecar, running `aws sts get-caller-identity` and `aws ssm get-parameter --name /vk-hetzner-lab/bootstrap/route53/fqdn` with `amazon/aws-cli` (pulled by its amd64 digest); one pod with a Certificate whose CN is `vk-hetzner-lab-hetzner-nobody`, expecting `AccessDenied` from `CreateSession`.

## 5. Files/components affected

- `gitops/values.yaml` — `workloadIdentity.consumers` for `target: hetzner` (same four as civo); the `awsIdentity.rolesAnywhere.image` digest is confirmed, not changed.
- `gitops/templates/platform/shared/identity/{issuer,certificates}.yaml` — no change expected; verify the render for `target: hetzner`.
- `gitops/templates/platform/shared/external-secrets/application.yaml`, `shared/external-dns/application.yaml` — no change expected.
- `tests/manifests/hetzner-085/` (new).
- `scripts/argo-up.sh` — no change; HETZ-045 supplies the branch.

## 6. Implementation steps

1. `docker manifest inspect public.ecr.aws/rolesanywhere/credential-helper:1.8.5`; record the amd64 platform digest in §14 and confirm it is the one `gitops/values.yaml` already pins.
2. Render `aws`, `civo` and `hetzner`; the aws and civo renders are unchanged (the pin does not move and the sidecar template does not render on aws).
3. `PROVIDER=hetzner make argo-up` on a cluster from HETZ-045. Confirm the Secret, the ClusterIssuer `Ready`, and four Certificates `Ready` within two minutes.
4. Confirm the ESO and ExternalDNS pods run two containers on a `cx33` node and that the sidecar logs a successful `CreateSession`.
5. Apply the positive test pod; check `get-caller-identity` returns the assumed-role ARN `…/vk-hetzner-lab-ra-eso/…`. Apply the negative pod; check the denial. Delete both.

## 7. Dependencies and blockers

HETZ-080 supplies the CA and the ARNs; HETZ-045 the `argo-up` branch and
the SSM relay; HETZ-050 the `target: hetzner` render. CIVO-085/090/100
must be `DONE` and hoisted by HETZ-016.

## 8. Acceptance criteria

- `kubectl -n cert-manager get clusterissuer hetzner-workload-ca` is `Ready`; four Certificates `Ready`; each Secret's certificate has the expected CN and 24 h validity (`openssl x509 -noout -subject -dates`).
- Sidecar image on the running pods resolves to the pinned amd64 digest (`kubectl get pod -o jsonpath='{.status.containerStatuses[*].imageID}'` shows the digest that `docker manifest inspect` listed for `linux/amd64`).
- Positive test: `get-caller-identity` returns the `ra-eso` role; `get-parameter` returns the fqdn (proves IPv4 egress to SSM from a Hetzner node).
- Negative test: `CreateSession` denied for the wrong CN.
- ESO syncs `lab-postgres-app`; ExternalDNS logs a successful Route 53 list.
- Civo: untouched — the pin does not move, so no Civo re-run is needed.

## 9. Validation

Offline: three-target render, `kubeconform`. Real cloud: one Hetzner
cluster from HETZ-045 (about 0.10 EUR per hour).

## 10. AWS regression protection

AWS render byte-identical (the sidecar template is gated off). Civo render
byte-identical too: this spec adds `target: hetzner` consumers only and
leaves the shared credential-helper pin on its amd64 digest.

## 11. Rollout and rollback/recovery

Nothing shared moves, so there is no cross-target rollback; the
`target: hetzner` consumers revert with one values commit. Rollback on
Hetzner is `argo-down`; nothing persistent is created. If a Certificate stays not
`Ready`, the usual causes are a missing CA Secret (rerun `argo-up`) or a
CN mismatch against the role trust policy (compare with HETZ-080 §4).

## 12. Risks and unresolved questions

- The amd64 pin holds only while the nodes are x86; a move back to CAX makes every pin in the chain a manifest-list question again, which is HETZ-182's scope, not this spec's.
- If a future `amazon/aws-cli` pin stops publishing amd64, the test pod falls back to `alpine/k8s` with the AWS CLI installed at start.
- The `hop-limit 1` rule holds on flannel VXLAN (verify once), but the sidecar's localhost endpoint is unreachable from a `hostNetwork` pod on the same node; the test pods must not use `hostNetwork`.
- ESO's ClusterRole can still read the CA Secret (CIVO-205 open); Hetzner inherits that until CIVO-205 lands.

## 13. Definition of done

- [ ] Acceptance criteria met and recorded
- [ ] Three-target render check passes; the shared credential-helper pin confirmed unchanged
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-19 — kubeadm wording.
- 2026-09-20 — k3s (HETZ-017): the CNI is flannel, so the `hop-limit 1` check
  is against flannel's VXLAN rather than Cilium's. The identity chain is
  unaffected.
- 2026-09-19 — x86 pass: amd64 digests on cx33; multi-arch only if CAX returns (HETZ-182).
