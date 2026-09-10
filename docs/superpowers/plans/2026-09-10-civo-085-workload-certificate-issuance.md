# CIVO-085 — Workload certificate issuance (CA issuer Secret at argo-up, per-consumer Certificates, RBAC, rotation)

## Context

CIVO-080 (done) produced the offline root CA (committed public cert +
KMS-encrypted private key). CIVO-082 (done) taught AWS IAM to trust
certificates from that CA: it created a Roles Anywhere trust anchor, a
profile, and two IAM roles (`eso`, `external-dns`) whose trust policies
are conditioned on exact certificate CNs (`${project}-civo-${consumer}`)
and issuer CN (`${project}-civo-workload-ca`). Nothing yet issues those
certificates inside the cluster. CIVO-085 closes that gap: it teaches
`argo-up` to load the CA's private key into the cluster as a
cert-manager CA issuer, and defines the two `Certificate` objects
(`eso`, `external-dns`) whose CNs exactly match what CIVO-082's IAM
trust policies already expect. This is the last AWS-independent,
security-boundary-defining piece before CIVO-090's sidecar can present
these certs to Roles Anywhere and actually receive AWS credentials.

The core security property: whoever can create a `Certificate` object
with an arbitrary CN can obtain any Roles Anywhere role. In M1 this is
mitigated by ensuring only Argo CD (not any pod's ServiceAccount) can
write `Certificate`/`CertificateRequest` objects — a real approver
policy is deferred to CIVO-200.

## Design decisions (resolved from spec + verified against the codebase)

1. **CA Secret ceremony in `argo-up`** (`scripts/argo-up.sh`). Add a new
   function `ensure_ca_secret()`, called only when `PROVIDER=civo`,
   **before the idempotency fast-path exit** (currently at lines
   226-247 in the live file — the spec's own evidence citing "151-158"
   is stale, confirmed by direct read; insert the call before that
   block so repeated `argo-up` runs still repair/create the Secret even
   when the fast path would otherwise skip everything else). This
   function runs *before* Argo has synced anything — including before
   cert-manager's own Application (wave 0) has had a chance to
   `CreateNamespace=true` the `cert-manager` namespace — so it must
   also ensure that namespace itself, idempotently:

   ```bash
   ensure_ca_secret() {
     local ca_cert_path="${REPO_ROOT}/secrets/${PROJECT_NAME}/civo-ca-cert.pem"
     kubectl create namespace cert-manager \
       --dry-run=client -o yaml | kubectl apply -f -
     "$REPO_ROOT/scripts/secret-decrypt.sh" civo-ca-key | \
       kubectl create secret tls civo-workload-ca \
         --cert="$ca_cert_path" \
         --key=/dev/stdin \
         --namespace cert-manager \
         --dry-run=client -o yaml \
       | kubectl label --local -f - app.kubernetes.io/managed-by=argo-up -o yaml \
       | kubectl apply -f -
   }
   ```
   Uses the ambient `$PROJECT_NAME`/`$REPO_ROOT` the rest of
   `argo-up.sh` already relies on (not a function parameter) — matches
   `secret-decrypt.sh`'s own resolution (`PROJECT_NAME` env var, default
   `vk-lab-platform`), so the cert path and the key path always agree on
   the same project; passing a project as a local parameter instead
   risks decrypting one project's key against another's cert (fixed a
   near-identical `repo_root`-after-`cd` class of bug in commit
   f2e77ac — same category of mistake to avoid here). The decrypted key
   passes through the pipeline only in memory/stdin, never touching
   disk. Once cert-manager's own Application later runs its
   `CreateNamespace=true`, it is a no-op over the namespace this
   function already created.

   (exact piping mechanics to be finalized by the implementer — the
   binding constraints are: never write the decrypted key to disk, use
   `--dry-run=client -o yaml | kubectl apply -f -`, idempotent, label
   `app.kubernetes.io/managed-by: argo-up`, namespace `cert-manager`,
   Secret name `civo-workload-ca`, type `kubernetes.io/tls`). Heredocs
   and `/dev/stdin` in a pipeline both work under macOS bash 3.2 — the
   spec's flagged 3.2 risk applies to `mapfile`/associative
   arrays/`${var^^}`, none of which this function uses, so no separate
   verification task is needed for that specific risk.

2. **`ClusterIssuer`**: new file
   `gitops/templates/platform/civo/identity/issuer.yaml`, gated
   `{{- if eq .Values.target "civo" }}` (matching CIVO-065's pattern —
   no revived `certManager.enabled` flag). Verified this is a real,
   already-used convention: raw (non-`Application`) manifests already
   sit directly under `platform/<target>/<component>/*.yaml` alongside
   `application.yaml` files elsewhere in the tree (e.g.
   `platform/shared/envoy-gateway/gateway.yaml`,
   `platform/aws/external-secrets/secretstore.yaml`,
   `platform/aws/karpenter/nodepool.yaml`) — the umbrella chart renders
   every `.yaml` under `templates/`, so these become resources the
   `root` Application itself manages directly, distinguished from
   cert-manager's own separately-synced Application only by their
   sync-wave annotation, exactly as planned below. `kind:
   ClusterIssuer`, `metadata.name: civo-workload-ca`, `spec.ca.secretName:
   civo-workload-ca`. Sync wave: strictly greater than cert-manager's
   own Application wave (`0`) — use wave `1`, consistent with "issuer
   after the controller that serves it." CRD availability at wave 1 is
   covered by `root`'s existing `syncPolicy.retry` (limit 10,
   exponential backoff 15s→2m cap, ≈15 minutes total budget — verified
   in `gitops/bootstrap/templates/root-application.yaml`), which already
   exceeds Argo's ~10-minute API-discovery cache refresh window; no new
   readiness hook is needed.

3. **`Certificate` objects**: new file
   `gitops/templates/platform/civo/identity/certificates.yaml`, same
   `target: civo` gate, sync wave `1` (same wave as the issuer is fine —
   Certificates only need the `ClusterIssuer` API object to exist, not
   for it to be Ready, since cert-manager's own controller reconciles
   readiness independent of Argo wave ordering). Loop over a small
   fixed list (`eso`, `external-dns`) via a `range` in the template —
   add this list to `gitops/values.yaml` under a new key
   (`civoIdentity.consumers` or similar; there is currently no such list
   — CIVO-085 introduces it, matching spec §5's "the consumer list").
   Per consumer:
   - `metadata.name`/`namespace`: `eso` → namespace `external-secrets`;
     `external-dns` → namespace `kube-system` (matching those
     components' actual install namespaces already used elsewhere in
     `gitops/`). Verified both namespaces already exist by the time
     wave-1 resources sync regardless of provider: `external-secrets`
     is a `platform/shared/` component (not gated by `target`) at sync
     wave `-2` with `CreateNamespace=true`
     (`gitops/templates/platform/shared/external-secrets/application.yaml`) —
     CIVO-100 is about wiring a civo-specific `SecretStore`/sidecar, not
     installing ESO itself, so its READY (not DONE) status does not
     block this Certificate reaching `Ready`; `kube-system` always
     exists on any cluster. No namespace-creation logic is needed here.
   - `spec.commonName: "${project}-civo-${consumer}"` (must exactly
     match CIVO-082's `aws:PrincipalTag/x509Subject/CN` condition —
     verified from the live `terraform/modules/rolesanywhere/main.tf`).
   - `spec.subject.organizations: ["${project}"]`.
   - `spec.usages: ["digital signature"]`, `spec.isCA: false`.
   - `spec.duration: 24h`, `spec.renewBefore: 8h`.
   - `spec.privateKey: {algorithm: ECDSA, size: 256, rotationPolicy:
     Always}`.
   - `spec.secretName: "${consumer}-ra-cert"` (exact name CIVO-090
     expects to mount).
   - `spec.issuerRef: {name: civo-workload-ca, kind: ClusterIssuer}`.
   `project` comes from the same Helm value the rest of `gitops/`
   already threads through (`.Values.project`, set from `argo-up.sh`).

4. **RBAC**: no new RoleBinding/ClusterRoleBinding is added anywhere
   granting `create`/`update` on `certificates.cert-manager.io` or
   `certificaterequests.cert-manager.io` to any workload ServiceAccount
   — the acceptance criterion is a negative: default Kubernetes RBAC
   (no explicit grant exists) already denies this, verified with
   `kubectl auth can-i create certificates.cert-manager.io
   --as=system:serviceaccount:default:default` → `no`. Document (in the
   PR/commit, not in code comments) that a namespace admin could still
   forge a Certificate with a spoofed CN — CIVO-200's approver-policy is
   the real fix; M1 has no namespace admins besides the operator.

5. **Consumer Secret access**: no `get secrets` RoleBinding is added for
   `eso-ra-cert`/`external-dns-ra-cert` — those Secrets are read by
   CIVO-090's sidecar via a volume mount (whole-Secret, no `subPath`, so
   renewal updates propagate without a pod restart), which is CIVO-090's
   scope, not this task's. This task only needs the Secret to exist and
   be Ready.

6. **No new ADR**: ADR 0029 already covers the Roles Anywhere trust
   design and explicitly names this blast radius (cluster-admin →
   Secret read → arbitrary CN → role compromise) and its mitigations
   (short-lived certs, CN-conditioned policies, disable-trust-anchor
   runbook). CIVO-085 implements that ADR's stated mitigations; it does
   not introduce a new architectural decision requiring its own ADR.

## Global constraints for implementation

- `PROVIDER`/`PROJECT_NAME` env vars never leak across commands — set
  inline on the same command line, never exported ambiently.
- The decrypted CA private key must never be written to disk or printed
  in full in any command output/log — pipe/heredoc only, matching the
  ceremony pattern CIVO-080 already established and this session
  already used once during CIVO-082's negative test.
- Never put ticket/spec references in code, YAML, or shell comments —
  explain the *why* directly (e.g. why the Secret must be re-ensured
  before the fast-path exit) in at most 3 lines.
- AWS must be provably unaffected: `target: civo` gating on every new
  template; the golden AWS diff (used by CIVO-050) must stay empty.
- Do not add a `certManager.enabled` value flag or any other feature
  flag — follow CIVO-065's direct-target-gate precedent exactly.
- The real `argo-up` run against the live Civo cluster (which decrypts
  the real CA key and mutates a real cluster Secret) is gated: implement
  and validate everything offline first (`kubeconform`/`helm template`
  golden-diff check), then stop and ask before running it for real —
  same ceremony-gating precedent as CIVO-080/082.
- The RBAC negative-test command and the rotation/renewal check both
  require a real cluster and are part of the same gate as the real
  `argo-up` run above — not separately gateable, since they all need
  the live cluster state that only a real run produces.

## Task breakdown

1. **`ensure_ca_secret()` in `argo-up.sh`**: add the function and its
   call site (before the idempotency fast-path, `PROVIDER=civo`-gated
   only). Verify with `bash -n scripts/argo-up.sh` (syntax) and by
   reading the diff against the existing `civo_resolve_inputs`/
   `civo_wait_for_lb_ip` functions for naming-convention consistency.
   Offline only — no real decrypt/apply yet (test this function's
   actual behavior in Task 4's gated real run).

2. **Issuer + Certificates templates + values wiring**: write
   `gitops/templates/platform/civo/identity/{issuer,certificates}.yaml`
   and add the consumer list to `gitops/values.yaml`. Run `helm
   template` (or the repo's existing golden-diff check script) for both
   `target: aws` (expect zero new resources / unchanged golden diff) and
   `target: civo` (expect the `ClusterIssuer` + 2 `Certificate` objects
   to render with the exact CNs/usages/secretNames above). Run
   `kubeconform` against the rendered civo output if available in this
   environment.

3. **RBAC verification plan (offline part)**: confirm by reading
   `gitops/` that no existing RoleBinding/ClusterRoleBinding grants
   `cert-manager.io` create/update permissions to any workload
   ServiceAccount (this should already be true — nothing in the repo
   grants it — so this task step is a confirmation, not a code change).
   Defer the live `kubectl auth can-i ...` proof to Task 4.

4. **Real apply (gated — ask before running)**: run `PROVIDER=civo
   PROJECT_NAME=vk-civo-lab scripts/argo-up.sh` (or the `make` wrapper)
   twice, per spec §6 step 1, to prove idempotency of `ensure_ca_secret`.
   Verify: the `civo-workload-ca` Secret exists in `cert-manager`
   namespace, unchanged across the two runs (compare resourceVersion or
   a hash of the data); `kubectl get certificate -A` shows both
   Certificates `Ready`; inspect one issued cert's CN/usages/`CA:false`
   /issuer CN via `openssl x509 -text` on the Secret's `tls.crt` — and
   explicitly confirm `X509v3 Key Usage: critical` and `X509v3 Basic
   Constraints: critical` are present (CIVO-082's negative test found
   that Roles Anywhere rejects a leaf missing these with the *same*
   opaque 403 as a foreign CA — catch a missing-`critical` cert-manager
   default here, not while debugging CIVO-090's sidecar). Also record
   the issued private key's encoding (PKCS#8 vs SEC1) as evidence, since
   CIVO-090 will need to know it. Then run
   the RBAC negative check `kubectl auth can-i create
   certificates.cert-manager.io --as=system:serviceaccount:default:default`
   and confirm `no`; trigger rotation (`cmctl renew <name>` or wait for
   natural renewal) and confirm the Secret's `tls.crt`/resourceVersion
   changes, recording the timestamp as evidence for CIVO-090.

5. **Negative test — non-Argo Certificate creation**: from the gated
   real-cluster context, attempt to `kubectl apply` a `Certificate` with
   CN `${project}-civo-eso` as a low-privilege identity (default
   ServiceAccount, no elevated RBAC) and confirm it's forbidden (this
   proves the RBAC audit from Task 4 in practice, not just via
   `auth can-i`). The "wrong issuer, different CA" negative case (spec
   §6 step 4, second half) is explicitly deferred to CIVO-090 per both
   specs' own text — do not attempt it here.

6. **Close out**: update
   `specs/civo/085-workload-certificate-issuance/spec.md` (status →
   DONE, §14 execution evidence including the renewal timestamp handed
   off to CIVO-090, DoD checkbox) and `specs/civo/README.md` index row.

## Verification

- `bash -n scripts/argo-up.sh`.
- Golden AWS diff unchanged (`target: aws` helm render before/after).
- `helm template` / golden-diff check for `target: civo` showing exactly
  the new `ClusterIssuer` + 2 `Certificate` objects.
- `kubeconform` on rendered civo manifests, if available.
- Real `argo-up` run ×2 (idempotency) — gated, ask first.
- `kubectl get certificate -A` Ready; `openssl x509 -text` inspection of
  one issued cert — gated, same ask.
- `kubectl auth can-i create certificates.cert-manager.io
  --as=system:serviceaccount:default:default` → `no` — gated, same ask.
- Live non-Argo `Certificate` creation attempt → forbidden — gated, same
  ask.
- Rotation/renewal observed, timestamp recorded — gated, same ask.

## Files touched

- Edit: `scripts/argo-up.sh` (`ensure_ca_secret()` + call site).
- New: `gitops/templates/platform/civo/identity/issuer.yaml`.
- New: `gitops/templates/platform/civo/identity/certificates.yaml`.
- Edit: `gitops/values.yaml` (consumer list for the Certificates range).
- Edit: `specs/civo/085-workload-certificate-issuance/spec.md`,
  `specs/civo/README.md` (index row).
