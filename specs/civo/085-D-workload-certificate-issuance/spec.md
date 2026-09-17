---
id: "CIVO-085"
title: "Workload certificate issuance: CA issuer Secret at argo-up, per-consumer Certificates, RBAC, rotation"
status: "DONE"
priority: "P0"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "Authorization of who may obtain which identity is the core security property; mistakes grant AWS roles to arbitrary pods"
effort_estimate: "One session (4–6 h)"
estimate_confidence: "medium"
depends_on: ["CIVO-045", "CIVO-050", "CIVO-065", "CIVO-080"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-10"
completed: "2026-09-10"
---

# CIVO-085 — Workload certificate issuance

## 1. Outcome and rationale

Each Roles Anywhere consumer (ESO, ExternalDNS) receives a short-lived
certificate with a fixed CN. A cert-manager CA issuer issues the
certificate. The issuer key is the project CA, decrypted at `argo-up`.
Only Argo-owned `Certificate` objects can request those CNs. No pod can
mint its own identity.

## 2. Scope and non-goals

In scope: the CA Secret ceremony in `argo-up`, the `ClusterIssuer`, the
`Certificate` objects, RBAC, the rotation settings, and the negative tests.
Not in scope: the sidecar (CIVO-090), the roles (CIVO-082), and the
approver policy (CIVO-200).

## 3. Current state / evidence

- cert-manager is installed on civo (CIVO-065). The CA issuer type consumes a Secret with `tls.crt`/`tls.key` in the cert-manager namespace.
- `argo-up.sh` has an early exit at `:257-269`. The CA Secret must be ensured before that check, so re-runs repair it.
- Roles Anywhere requires end-entity certs with `digitalSignature`, `CA:false`, X.509v3, and SHA-256.

## 4. Design and contracts

- The `argo-up` civo branch calls `ensure_ca_secret()` before the fast path. The function decrypts `civo-ca-key` in memory. It creates or updates the Secret `civo-workload-ca` in namespace `cert-manager`. The Secret has type `kubernetes.io/tls`. `tls.crt` comes from the committed PEM. `tls.key` comes from the decrypted value. The function uses `kubectl create secret tls --dry-run=client -o yaml | kubectl apply -f -` through a pipe. It never uses a temp file. The function is idempotent. It sets the label `app.kubernetes.io/managed-by: argo-up`.
- `gitops/templates/platform/civo/identity/issuer.yaml` holds `ClusterIssuer civo-workload-ca` with `ca.secretName: civo-workload-ca`.
- One `Certificate` per consumer lives in the consumer's namespace: `eso` in `external-secrets`, `external-dns` in `kube-system`. Each Certificate sets `commonName: <project>-civo-<consumer>`, `subject.organizations: [<project>]`, `usages: [digital signature]`, `isCA: false`, `duration: 24h`, `renewBefore: 8h`, `privateKey: {algorithm: ECDSA, size: 256, rotationPolicy: Always}`, and `secretName: <consumer>-ra-cert`.
- RBAC: no human or workload ServiceAccount receives `create`/`update` on `certificates.cert-manager.io` or `certificaterequests`. The Argo controller is the only writer that goes through this RBAC path. cert-manager's own `ingress-shim` controller is a second writer, reachable by annotating an `Ingress`/`Gateway` object rather than by RBAC on `certificates.cert-manager.io` itself — in M1 only the operator/Argo can create those objects, so this path is currently unreachable; re-check once CIVO-070 (public TLS via Envoy Gateway) starts annotating the Gateway for cert-manager. Document that a namespace admin could still create a Certificate with a spoofed CN. CIVO-200 mitigates this with approver-policy. In M1, the cluster has no namespace admins other than the operator.
- Secret protection: the per-consumer leaf Secrets (`eso-ra-cert`, `external-dns-ra-cert`) are readable only by the consumer's own ServiceAccount, via the pod mount — this task adds no `get secrets` RoleBindings. The CA Secret itself (`cert-manager/civo-workload-ca`) is not similarly scoped: the pre-existing `external-secrets-controller` ClusterRole already grants cluster-wide `get`/`list`/`watch` on Secrets, so the ESO controller can read the CA private key directly and mint a certificate for any CN, bypassing per-consumer CN scoping entirely. CIVO-200's approver-policy does not close this — it gates Certificate approval, not Secret reads. The available mitigation, ESO's chart-supported `scopedNamespace`/`scopedRBAC` config, is a deferred follow-up, not implemented by this task — tracked in CIVO-205.
- Mount pattern (used by CIVO-090): mount the whole Secret as a volume, not with `subPath`, so renewals propagate.

## 5. Files/components affected

`scripts/argo-up.sh`; `gitops/templates/platform/civo/identity/{issuer,certificates}.yaml`; `gitops/values.yaml` (the consumer list).

## 6. Implementation steps

1. Add `ensure_ca_secret`. Run `argo-up` twice. Check that the Secret is present and unchanged.
2. Add the issuer and the Certificates. Check that `kubectl get certificate -A` shows Ready. Inspect one cert: the CN, the usages, `CA:false`, and the issuer CN.
3. Rotation: run `cmctl renew` or wait. Check that the Secret updates. Note the timestamp for CIVO-090's reload test.
4. Negative tests: apply a `Certificate` with CN `<project>-civo-eso` from a non-Argo identity with only default RBAC. Expect forbidden. Then create one via Argo with a wrong issuer. A different CA issues it. Roles Anywhere denies it (tested in CIVO-090).

## 7. Dependencies and blockers

045 (the argo-up civo branch), 050 (the `civo/` tree), 065 (cert-manager), 080 (the files).

## 8. Acceptance criteria

- The CA Secret exists only on civo. It is created before the root Application. It is never in Git or Argo.
- Two Certificates are Ready with the exact CN/usages. Renewal is observed.
- RBAC audit: `kubectl auth can-i create certificates.cert-manager.io --as=system:serviceaccount:default:default` returns no.
- AWS is unaffected (the golden diff is empty; no cert-manager on AWS).

## 9. Validation

Offline: the golden diff and kubeconform. Real cloud: civo (~cents). No AWS.

## 10. AWS regression protection

All objects are under `civo/`. The script branch runs only for civo.

## 11. Rollout and rollback/recovery

Delete the CA Secret — that's the actual rollback lever, since issuance fails without it. Deleting the `Certificate` objects alone is a no-op: they're Argo-managed with `selfHeal: true`, so Argo just recreates them within minutes. Already-issued leaf certs remain valid for up to 24h until they expire, then reissuance fails and the consumers lose AWS access (fail closed). Compromise response: disable the trust anchor (CIVO-080 runbook). Then rotate the CA.

## 12. Risks and unresolved questions

- cert-manager may refuse a CA cert without `keyCertSign`. CIVO-080 covers this.
- Secret creation via a pipe on macOS bash 3.2: verify.

## 13. Definition of done

- [x] Evidence incl. RBAC check and rotation; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
- 2026-09-10 — CIVO-082 (dependency) done; started implementation on branch
  `civo-085-workload-certificate-issuance`, promoted to IN_PROGRESS.
- 2026-09-10 — Implemented via subagent-driven-development (offline
  `ensure_ca_secret()` addition and the `ClusterIssuer`/`Certificate`
  templates each independently reviewed, one fix round on a comment
  exceeding the repo's 3-line limit; a read-only RBAC audit of `gitops/`
  confirmed no RoleBinding/ClusterRoleBinding anywhere grants
  `cert-manager.io` create/update to any workload ServiceAccount).
  `PROVIDER=civo make bootstrap-up`/`persistent-up`/`cluster-up` re-ran
  first (the cluster was down) — `bootstrap-up` recreated the Roles
  Anywhere trust anchor/profile/roles/SSM params torn down after
  CIVO-082's own test, `10 to add, 0 to change, 0 to destroy`. Mid-task
  finding: Argo CD's `root` Application syncs from a pushed git revision
  (`repoURL`/`targetRevision`, default `main`), not local working-tree
  state, so the new manifests were invisible until the branch was merged
  and pushed to `main` — merged and pushed ahead of the plan's own final
  whole-branch review at the user's explicit instruction ("just push
  changes to main"), which the review (below) still covers. `argo-up`
  run twice pre-merge proved `ensure_ca_secret()`'s idempotency
  (`secret/civo-workload-ca unchanged`, identical resourceVersion both
  runs); a third run post-push (after a forced Argo git refresh) synced
  the new resources. Verified live: `ClusterIssuer/civo-workload-ca`
  Ready; both `Certificate`s (`eso` in `external-secrets`,
  `external-dns` in `kube-system`) Ready with `secretName`
  `eso-ra-cert`/`external-dns-ra-cert`; the issued `eso` leaf cert has
  Issuer CN `vk-civo-lab-civo-workload-ca`, Subject CN
  `vk-civo-lab-civo-eso`, `X509v3 Key Usage: critical / Digital
  Signature`, `X509v3 Basic Constraints: critical / CA:FALSE`, ECDSA
  P-256 — exactly the CN pair AWS IAM's trust policy (CIVO-082) already
  expects, including the `critical` flags CIVO-082's own negative test
  found Roles Anywhere requires; private key is SEC1-encoded
  (`-----BEGIN EC PRIVATE KEY-----`), not PKCS#8 (recorded for
  CIVO-090). RBAC: `kubectl auth can-i create certificates.cert-manager.io
  --as=system:serviceaccount:default:default` → `no`. Negative test
  (live): applying a `Certificate` requesting CN `vk-civo-lab-civo-eso`
  as `system:serviceaccount:default:default` → `Forbidden` (cannot even
  `get` the resource). Rotation: deleted the `eso-ra-cert` Secret;
  cert-manager reissued within ~5s (new resourceVersion, creation
  timestamp `2026-09-10T08:44:40Z`) — this proves reissuance-on-missing-Secret
  works, but is not the same code path as an in-place `renewBefore`-triggered
  renewal (which updates the existing Secret rather than deleting and
  recreating it); CIVO-090's reload test should independently verify that
  in-place path, which this test didn't exercise. AWS unaffected: the `target: aws` render
  showed zero new resources in Task 2's offline check (the two new
  templates are unconditionally gated on `target: civo`).
