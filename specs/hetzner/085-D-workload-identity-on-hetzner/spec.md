---
id: "HETZ-085"
title: "Workload identity on Hetzner: CA issuer Secret, per-consumer Certificates, credential-helper sidecars for ESO and ExternalDNS"
status: "DONE"
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
updated: "2026-09-22"
completed: "2026-09-22"
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
- `gitops/values.yaml:67` pins `public.ecr.aws/rolesanywhere/credential-helper@sha256:56b03f3a…`, the amd64 image digest (tag `1.8.5-amd64-2026.08.24.20.52`), which resolves on an x86 `cx33` node exactly as it does on Civo. `research.md` confirms the repository also publishes a multi-arch manifest list for 1.8.5, needed only if CAX ever returns (HETZ-182).
- CIVO-100 and CIVO-110 inject the sidecar through the charts' `extraContainers` on `platform.selfManaged`; the mount of `<consumer>-ra-cert` and the `AWS_EC2_METADATA_SERVICE_ENDPOINT` env are unchanged.

## 4. Design and contracts

- Secret `cert-manager/hetzner-workload-ca` (type `kubernetes.io/tls`), created by `argo-up`, never pruned by Argo.
- ClusterIssuer `hetzner-workload-ca`. Certificates at sync wave 1, one per entry in `workloadIdentity.consumers`: the Certificate objects are named `eso`, `external-dns`, `cert-manager` and `pgbackup`, and only the Secrets they write carry the `-ra-cert` suffix (`identity/certificates.yaml:6,23`). CN `vk-hetzner-lab-hetzner-<consumer>`, duration 24 h, renew before 8 h, key usage `digital signature` alone. **Corrected 2026-09-22:** this line previously named the Secrets as the Certificates and asked for a second usage, `client auth`. The template emits `digital signature` only, and Civo runs that same template against the same Roles Anywhere trust policies, so `client auth` is not required and the spec was wrong rather than the code.
- Sidecar: `aws_signing_helper serve --certificate /ra/tls.crt --private-key /ra/tls.key --trust-anchor-arn … --profile-arn … --role-arn … --session-duration 3600 --hop-limit 1 --port 9911`, region `eu-west-1`, from `awsIdentity.rolesAnywhere.*` values that `argo-up` relays from SSM (HETZ-045).
- Image: `awsIdentity.rolesAnywhere.image` keeps the amd64 digest of `credential-helper:1.8.5` for both civo and hetzner, because both run x86 nodes — no per-target value and no manifest-list digest. HETZ-182 owns the switch to manifest-list digests for every image, including the repo-built `pg-backup` one, if CAX ever returns.
- Test manifests under `tests/manifests/hetzner-085/`: one pod with the ESO certificate mounted and the sidecar, running `aws sts get-caller-identity` and `aws ssm get-parameter --name /vk-hetzner-lab/persistent/postgres/app_password --with-decryption` with `amazon/aws-cli`. **Corrected 2026-09-22:** this line named `/vk-hetzner-lab/bootstrap/route53/fqdn`, which the `eso` role cannot read. Its inline `consumer` policy grants `ssm:GetParameter` on exactly the two parameters the ExternalSecrets consume and nothing else, so that read is denied however healthy the chain is. The parameter now named is one of those two, and being a `SecureString` it exercises the role's `kms:Decrypt` grant as well; and three negative pods, because three different links can deny the request and only distinct fixtures tell them apart: an untrusted signer (`wrong-ca-pod`, a self-signed issuer with the correct CN), an unassumable role (`wrong-role-pod`, the real `eso` certificate against the `external-dns` role ARN), and a subject the profile does not recognise (`wrong-cn-pod`, a Certificate issued by the real `hetzner-workload-ca` with CN `vk-hetzner-lab-hetzner-nobody`, expecting `AccessDenied` from `CreateSession`). The last is the strongest, because the anchor does trust the signer, so the request reaches `CreateSession` with a valid certificate and is refused on the subject alone; the other two never get that far.

## 5. Files/components affected

**The first three bullets need no edit, and did not when this spec was written.** The identity chain is not per-target: HETZ-016 hoisted it under one `platform.selfManaged` gate, which `_helpers.tpl:17-19` defines as `has .Values.target (list "civo" "hetzner")`, and `platform.workloadIssuerName` derives `hetzner-workload-ca` from `.Values.target` with no values entry. So the only change this spec makes is the new test directory.

- `gitops/values.yaml` — `workloadIdentity.consumers` is one shared list (`:183-195`), not a per-target one; the `awsIdentity.rolesAnywhere.image` digest is confirmed, not changed.
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
- Positive test: `get-caller-identity` returns the `ra-eso` role; `get-parameter` returns a parameter that role owns (proves IPv4 egress to SSM, and to KMS, from a Hetzner node).
- Negative test: `CreateSession` denied three ways — untrusted signer, unassumable role, and wrong CN — each with a distinct error, so a fixture aimed at the wrong object shows up as the wrong denial instead of passing quietly.
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

- [x] Acceptance criteria met and recorded
- [x] Three-target render check passes; the shared credential-helper pin confirmed unchanged
- [x] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-19 — kubeadm wording.
- 2026-09-20 — k3s (HETZ-017): the CNI is flannel, so the `hop-limit 1` check
  is against flannel's VXLAN rather than Cilium's. The identity chain is
  unaffected.
- 2026-09-19 — x86 pass: amd64 digests on cx33; multi-arch only if CAX returns (HETZ-182).
- 2026-09-22 — implemented. The only change this spec needed was
  `tests/manifests/hetzner-085/`. Everything else it specifies already
  rendered: HETZ-016 hoisted the identity chain under one
  `platform.selfManaged` gate that already names hetzner, so the
  ClusterIssuer, the four Certificates and both sidecars come out of the same
  templates Civo uses, and `scripts/gitops-render-check.sh:187-195` was
  already asserting them. No file under `gitops/templates/` or `scripts/`
  moved, which is what makes §8's last criterion true by construction: no
  Civo golden render exists to prove "Civo untouched" with, so the argument
  has to be that the diff cannot reach it.

  Six claims in this spec were wrong and are corrected in place rather than
  implemented against. §4 named the Secrets as the Certificates; the
  Certificate objects are `eso`, `external-dns`, `cert-manager`, `pgbackup`
  and only their Secrets carry `-ra-cert`. §4 asked for a second key usage,
  `client auth`; the template emits `digital signature` alone and Civo runs
  that same template against the same trust policies, so the spec was wrong
  and not the code. §4's sidecar arg list omitted `--session-duration 3600`.
  §4 and §8 named `/vk-hetzner-lab/bootstrap/route53/fqdn` as the positive
  pod's read, which the `eso` role is not allowed to make — see the live
  entry below. §3 cited the image pin at `gitops/values.yaml:30`; it is at
  `:67`. And §5's first three bullets were never edits at all.

  The fixture set has three negatives where Civo has two. Civo covers an
  untrusted signer and an unassumable role; neither is the wrong-CN case §4
  asks for, and that one is the strongest of the three, because the anchor
  does trust the signer: the request reaches `CreateSession` with a valid
  certificate and is refused on the subject alone.
- 2026-09-22 — live evidence, one cycle on three `cx33` in `fsn1`, staging
  issuer. `state-up` 88s, `full-up` 983s. Every acceptance criterion met.

  ClusterIssuer `hetzner-workload-ca` `Ready`; four Certificates `Ready`;
  all four Secrets carry the expected subject and exactly 24 h of validity
  (`O=vk-hetzner-lab, CN=vk-hetzner-lab-hetzner-<consumer>`,
  `notBefore 20:59:13`, `notAfter` the same time next day). The sidecar's
  `imageID` on both consumer pods, and on the test pod, is the pinned amd64
  digest `credential-helper@sha256:56b03f3a…` unchanged from
  `gitops/values.yaml:67`.

  Positive: `get-caller-identity` returned
  `assumed-role/vk-hetzner-lab-ra-eso/…`.

  **The `get-parameter` half of that criterion could never have passed as
  written, and the failure is informative.** Reading
  `/vk-hetzner-lab/bootstrap/route53/fqdn` was refused with
  `AccessDeniedException … no identity-based policy allows the
  ssm:GetParameter action`. The `ra-eso` role's inline `consumer` policy
  lists exactly two resources — `/persistent/postgres/app_password` and
  `/persistent/grafana/admin_password`, the two the ExternalSecrets read —
  plus a `kms:Decrypt` conditioned on those same two parameter ARNs. The
  denial is therefore correct least privilege working, not a defect, and the
  criterion named a parameter outside the grant. Re-run against
  `/persistent/postgres/app_password --with-decryption`, the same pod
  returned the parameter and its type, `SecureString`. That is the stronger
  evidence anyway: a `SecureString` read exercises the `kms:Decrypt` grant as
  well, and an answer of any kind — the denial included — proves IPv4 egress
  from a Hetzner node to SSM, because a node without it would time out rather
  than receive a policy decision.

  Three negatives, three distinct denials, all 403 from `CreateSession`:
  `Untrusted signing certificate` for the self-signed issuer; `Unable to
  assume role for …:role/vk-hetzner-lab-ra-external-dns` for the real `eso`
  certificate pointed at the wrong role; and `Unable to assume role for
  …:role/vk-hetzner-lab-ra-eso` for the wrong CN. The last is the one worth
  reading twice: same trust anchor and same role ARN as the positive pod,
  only the CN differs, and it is refused — so the trust policy is discriminating
  on the subject and not merely on the signer.

  ESO: `lab-postgres-app` and `grafana-admin-credentials` both
  `SecretSynced True`. ExternalDNS: `4 record(s) were successfully updated`
  in the `hz.<root-domain>` zone, then `All records are already up to date`
  on every 1-minute pass. So §8's last criterion needed no split and no
  hand-off to HETZ-070.

  The cleanup the fixture README documents was run as written and left zero
  residue: the three chart pods, the `eso` Certificate and its Secret, and the
  three production ClusterIssuers, and nothing else. Both explicit
  `kubectl delete secret` lines are load-bearing, because cert-manager does
  not cascade a Certificate's Secret.

  Teardown, as a regression check on HETZ-047: `full-down` returned 0 in
  733s across all four layers. Both mechanisms that spec added fired -
  `ARGO-DOWN: hcloud load balancer confirmed gone` and `hcloud-csi released
  from the cascade; its controller outlives it` - and `cluster-down` reported
  no leaked disposable-lifecycle resources. Nothing this spec adds runs
  during a teardown, so this is evidence that the fixtures leave nothing
  behind, not that they were exercised.

  One operational note for the next session: `use_isolated_kubeconfig`
  (`scripts/lib/provider.sh:228-239`) overrides an exported `KUBECONFIG` with
  the repo-local `.kube/<project>.config`. A session that exports its own path
  and then runs `kubectl` against it reaches no cluster at all, and the error
  looks like a broken API server rather than a missing file.

