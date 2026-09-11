# CIVO-070: Let's Encrypt TLS at Envoy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `https://argo.civo.<root-domain>` and `https://grafana.civo.<root-domain>` serve a valid Let's Encrypt certificate, terminated at Envoy Gateway, surviving `make down`/`make up` cycles without triggering a new ACME order each time.

**Architecture:** cert-manager (already installed, CIVO-065) runs a `ClusterIssuer` that solves Let's Encrypt's HTTP-01 challenge through a Gateway API `HTTPRoute`. The issued certificate lands in a Kubernetes `Secret` that Envoy's `platform-gateway` Gateway references directly on a new HTTPS:443 listener — Envoy itself terminates TLS on Civo (unlike AWS, where the NLB terminates TLS and Envoy never holds a cert). Because the Civo cluster is disposable, `argo-down`/`argo-up` export/import that Secret through an SSM `SecureString` parameter so the same certificate (and its `cert-manager.io/*` annotations) survives teardown/recreate, keeping ACME order volume near zero and inside Let's Encrypt's rate limits.

**Tech Stack:** Helm (`gitops/` chart), Gateway API, cert-manager v1.21.1 (`ClusterIssuer`/`Certificate`), AWS SSM Parameter Store (Advanced tier `SecureString`, `alias/lab-secrets` KMS key), bash (`scripts/argo-up.sh`, `scripts/argo-down.sh`, `scripts/lib/provider.sh`).

**Spec:** `specs/civo/070-letsencrypt-http01-tls/spec.md`

## Global Constraints

- AWS golden diff must stay empty for every change — run `scripts/gitops-render-check.sh` after each task (from repo root, no arguments).
- civo is checked structurally, not against a golden file — new required/forbidden object names go into `scripts/gitops-render-check.sh`'s `REQUIRED_OBJECTS_CIVO`/`FORBIDDEN_*` lists (same file, ~lines 63-75).
- All new manifests live under `gitops/templates/platform/civo/tls/` except the Gateway listener change, which lives in the existing shared `gateway.yaml` (civo branch only).
- Private key: ECDSA, size 256, `rotationPolicy: Always` (spec §4 — standard Let's Encrypt key type, keeps the SSM parameter small, shortens the TLS handshake).
- `cert-manager.io/issue-temporary-certificate: "true"` annotation on the `Certificate` — the HTTPS listener must resolve to something during the very first order, before any real cert exists (spec's review amendment #4).
- The redirect `HTTPRoute` (added in a later task once one exists) must carry no path match — the ACME solver's own exact-match `/.well-known/acme-challenge/<token>` route must win by Gateway API path-precedence rules (spec's review amendment #5). No redirect route exists yet in this codebase for civo, so this plan does not add one speculatively — see Task 1's scope note.
- No plaintext secret material in Git, Argo, or logs. The exported Secret goes to SSM as `SecureString` only.
- Real-cloud verification steps (Tasks 5-6) run against the `vk-civo-lab` Civo project and cost real (small) money — confirm with the user before switching from the staging issuer to `letsencrypt-prod`, since a mistake there burns the exact rate limit this spec exists to protect.

---

### Task 1: Gateway HTTPS listener + ClusterIssuers + Certificate

**Files:**
- Modify: `gitops/templates/platform/shared/envoy-gateway/gateway.yaml:142-148` (civo branch's `Gateway` listeners block)
- Create: `gitops/templates/platform/civo/tls/issuers.yaml`
- Create: `gitops/templates/platform/civo/tls/certificate.yaml`
- Modify: `gitops/values.yaml` (add a `tls:` block)
- Modify: `scripts/gitops-render-check.sh:63-66` (add the new required objects to `REQUIRED_OBJECTS_CIVO`)

**Interfaces:**
- Consumes: `.Values.target` (existing, `"civo"`), `.Values.envoyGateway.fqdn` (existing — set by `argo-up.sh`)
- Produces: `.Values.tls.issuer` (string, `"letsencrypt-staging"` or `"letsencrypt-prod"`, consumed by Task 2's `--set`), `.Values.tls.acmeEmail` (string, non-secret), Secret `platform-public-tls` in namespace `envoy` (consumed by Tasks 3-4), `ClusterIssuer` names `letsencrypt-staging`/`letsencrypt-prod` (consumed by `certificate.yaml`'s `issuerRef`)

- [ ] **Step 1: Add the `tls` values block**

Edit `gitops/values.yaml`, right after the existing `externalDns:` block:

```yaml
# civo-only: which cert-manager ClusterIssuer the public Certificate uses.
# Staging avoids Let's Encrypt's real rate limits during automated/CI runs;
# prod is switched on explicitly for the real personal lab. acmeEmail is
# not a secret (Let's Encrypt account contact only).
tls:
  issuer: "letsencrypt-staging"
  acmeEmail: ""
```

- [ ] **Step 2: Add the HTTPS:443 listener to the civo Gateway**

In `gitops/templates/platform/shared/envoy-gateway/gateway.yaml`, replace the civo branch's `Gateway` listeners block (currently lines 142-148, the last block before `{{- end }}`) with:

```yaml
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
    # Civo has no NLB terminating TLS upstream (unlike aws) - Envoy holds
    # the certificate itself and terminates TLS directly.
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        certificateRefs:
          - name: platform-public-tls
      allowedRoutes:
        namespaces:
          from: All
```

- [ ] **Step 3: Create the ClusterIssuers**

Create `gitops/templates/platform/civo/tls/issuers.yaml`:

```yaml
{{- if eq .Values.target "civo" }}
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
  annotations:
    argocd.argoproj.io/sync-wave: "1"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: {{ .Values.tls.acmeEmail | quote }}
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: platform-gateway
                namespace: envoy
                kind: Gateway
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
  annotations:
    argocd.argoproj.io/sync-wave: "1"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: {{ .Values.tls.acmeEmail | quote }}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: platform-gateway
                namespace: envoy
                kind: Gateway
{{- end }}
```

- [ ] **Step 4: Create the Certificate**

Create `gitops/templates/platform/civo/tls/certificate.yaml`:

```yaml
{{- if eq .Values.target "civo" }}
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: platform-public
  namespace: envoy
  annotations:
    argocd.argoproj.io/sync-wave: "1"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
    # Resolves the HTTPS listener during the very first order, before any
    # real certificate exists yet (matches CIVO-060's temporary-cert amendment).
    cert-manager.io/issue-temporary-certificate: "true"
spec:
  secretName: platform-public-tls
  dnsNames:
    - "argo.{{ .Values.envoyGateway.fqdn }}"
    - "grafana.{{ .Values.envoyGateway.fqdn }}"
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  issuerRef:
    name: {{ .Values.tls.issuer | quote }}
    kind: ClusterIssuer
    group: cert-manager.io
{{- end }}
```

- [ ] **Step 5: Register the new objects with the render check**

In `scripts/gitops-render-check.sh`, extend `REQUIRED_OBJECTS_CIVO` (currently line 63-66) to also include:

```
ClusterIssuer__cluster__letsencrypt-staging ClusterIssuer__cluster__letsencrypt-prod \
Certificate__envoy__platform-public
```

(Append these to the existing string — don't remove any existing entries.)

- [ ] **Step 6: Render and verify**

Run: `bash scripts/gitops-render-check.sh`
Expected: `GITOPS-RENDER-CHECK: aws render matches the golden baseline.` and no `missing required object`/`unexpectedly renders` errors for civo. If `yq`/`helm`/`kubeconform` aren't on PATH, install per `scripts/gitops-render-check.sh`'s own header comments before proceeding — do not skip this check.

- [ ] **Step 7: Commit**

```bash
git add gitops/templates/platform/shared/envoy-gateway/gateway.yaml \
        gitops/templates/platform/civo/tls/issuers.yaml \
        gitops/templates/platform/civo/tls/certificate.yaml \
        gitops/values.yaml scripts/gitops-render-check.sh
git commit -m "civo-070: add HTTPS listener, Let's Encrypt ClusterIssuers, and public Certificate"
```

---

### Task 2: Thread the issuer selection through argo-up.sh

**Files:**
- Modify: `scripts/argo-up.sh:392-410` (`civo_install_root_application` function)

**Interfaces:**
- Consumes: `.Values.tls.issuer`, `.Values.tls.acmeEmail` (produced by Task 1)
- Produces: nothing new consumed by later tasks — this only wires an existing value through

- [ ] **Step 1: Add `--set` flags for the tls values**

In `scripts/argo-up.sh`, inside `civo_install_root_application` (the `helm upgrade --install root-application` call), add two lines after the existing `--set awsIdentity.rolesAnywhere.roleArns.external-dns="$EXTERNAL_DNS_ROLE_ARN"` line:

```bash
    --set awsIdentity.rolesAnywhere.roleArns.external-dns="$EXTERNAL_DNS_ROLE_ARN" \
    --set tls.issuer="${TLS_ISSUER:-letsencrypt-staging}" \
    --set tls.acmeEmail="${TLS_ACME_EMAIL:-}"
```

(Remove the trailing backslash from the line that used to be last, since `tls.acmeEmail` is now the final `--set`.)

- [ ] **Step 2: Verify the script still parses**

Run: `bash -n scripts/argo-up.sh`
Expected: no output (syntax OK).

- [ ] **Step 3: Commit**

```bash
git add scripts/argo-up.sh
git commit -m "civo-070: thread tls.issuer/acmeEmail through argo-up.sh"
```

---

### Task 3: Export the TLS Secret on argo-down

**Files:**
- Modify: `scripts/lib/provider.sh` (add `civo_export_tls_secret` next to the existing `civo_backup`, ~line 107)
- Modify: `scripts/argo-down.sh:44-46` (call the new function alongside `civo_backup`)

**Interfaces:**
- Consumes: `$PROJECT_NAME`, `$LAB_REGION` (existing globals from `scripts/lib/provider.sh`/`scripts/lib/region.sh`)
- Produces: SSM `SecureString` parameter `/${PROJECT_NAME}/persistent/civo/tls/platform-public` (consumed by Task 4)

- [ ] **Step 1: Write `civo_export_tls_secret` in `scripts/lib/provider.sh`**

Add this function directly after `civo_backup` (which ends around line 114):

```bash
# Exports the whole Secret manifest (not just cert/key fields) so its
# cert-manager.io/* annotations round-trip exactly - splitting them out
# risks cert-manager reissuing on next import (SecretPublicKeysDiffer /
# IncorrectIssuer policy checks). Missing Secret (first-ever run, or the
# Certificate hasn't issued yet) is not fatal - argo-up simply bootstraps
# a fresh order in that case.
civo_export_tls_secret() {
  if ! kubectl get secret platform-public-tls -n envoy >/dev/null 2>&1; then
    echo "ARGO-DOWN: no platform-public-tls Secret found - nothing to export."
    return 0
  fi
  local manifest
  manifest="$(kubectl get secret platform-public-tls -n envoy -o yaml \
    | yq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields)')"
  aws ssm put-parameter \
    --region "$LAB_REGION" \
    --name "/${PROJECT_NAME}/persistent/civo/tls/platform-public" \
    --type SecureString \
    --tier Advanced \
    --key-id alias/lab-secrets \
    --overwrite \
    --value "$manifest" >/dev/null
  echo "ARGO-DOWN: exported platform-public-tls Secret to SSM."
}
```

- [ ] **Step 2: Call it from argo-down.sh alongside `civo_backup`**

In `scripts/argo-down.sh`, change:

```bash
if [ "$PROVIDER" = civo ]; then
  civo_backup
fi
```

to:

```bash
if [ "$PROVIDER" = civo ]; then
  civo_backup
  civo_export_tls_secret
fi
```

- [ ] **Step 3: Verify scripts still parse**

Run: `bash -n scripts/lib/provider.sh && bash -n scripts/argo-down.sh`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add scripts/lib/provider.sh scripts/argo-down.sh
git commit -m "civo-070: export platform-public-tls Secret to SSM on argo-down"
```

---

### Task 4: Import the TLS Secret on argo-up, with a renewal-time guard

**Files:**
- Modify: `scripts/lib/provider.sh` (add `civo_import_tls_secret` next to `civo_export_tls_secret`)
- Modify: `scripts/argo-up.sh:124-127` (call the new function before `civo_install_root_application`)
- Modify: `scripts/argo-up.sh:202-203` (fix the stale DNS-wait message — see Global Constraints/spec follow-up)

**Interfaces:**
- Consumes: SSM parameter `/${PROJECT_NAME}/persistent/civo/tls/platform-public` (produced by Task 3)
- Produces: Secret `platform-public-tls` restored into namespace `envoy` before the root Application (and therefore the `Certificate`) is created — satisfies cert-manager's own "restore Secret before Certificate exists" guidance

- [ ] **Step 1: Write `civo_import_tls_secret` in `scripts/lib/provider.sh`**

Add this function directly after `civo_export_tls_secret`:

```bash
# Restores the Secret before the root Application creates the Certificate
# that references it (cert-manager's own backup/restore guidance - a
# Certificate reconciling against a missing Secret just orders fresh,
# which is also fine, but restoring first avoids a redundant order).
# Skips cleanly when no parameter exists (first-ever run) or when the
# stored cert's renewal time has already passed - importing a
# past-renewal cert would trigger cert-manager to reissue immediately on
# apply anyway, so re-ordering now (before Argo/Certificate even exist)
# doesn't save an order, and importing it first only adds a spurious
# apply/replace cycle.
civo_import_tls_secret() {
  local manifest
  manifest="$(aws ssm get-parameter \
    --region "$LAB_REGION" \
    --name "/${PROJECT_NAME}/persistent/civo/tls/platform-public" \
    --with-decryption \
    --query 'Parameter.Value' --output text 2>/dev/null || true)"
  if [ -z "$manifest" ] || [ "$manifest" = "None" ]; then
    echo "ARGO-UP: no stored platform-public-tls Secret in SSM - a fresh certificate will be ordered."
    return 0
  fi

  local not_after renew_before
  not_after="$(echo "$manifest" | yq '.metadata.annotations["cert-manager.io/certificate-not-after"] // ""')"
  renew_before="$(echo "$manifest" | yq '.metadata.annotations["cert-manager.io/renewal-time"] // ""')"
  if [ -n "$renew_before" ]; then
    local renew_epoch now_epoch
    renew_epoch="$(date -u -d "$renew_before" +%s 2>/dev/null || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$renew_before" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date -u +%s)"
    if [ "$renew_epoch" -gt 0 ] && [ "$now_epoch" -ge "$renew_epoch" ]; then
      echo "ARGO-UP: stored platform-public-tls Secret is past its renewal time ($renew_before) - skipping import, a fresh certificate will be ordered."
      return 0
    fi
  fi

  echo "$manifest" | kubectl apply -f - >/dev/null
  echo "ARGO-UP: restored platform-public-tls Secret from SSM (not-after: ${not_after:-unknown})."
}
```

- [ ] **Step 2: Call it before `civo_install_root_application`**

In `scripts/argo-up.sh`, right after the existing block:

```bash
if [ "$PROVIDER" = civo ]; then
  civo_resolve_inputs
else
  aws_resolve_inputs
fi
```

add a new line immediately after it:

```bash
if [ "$PROVIDER" = civo ]; then
  civo_resolve_inputs
else
  aws_resolve_inputs
fi

if [ "$PROVIDER" = civo ]; then
  configure_kubeconfig
  civo_import_tls_secret
fi
```

(`configure_kubeconfig` is already called at the end of `civo_resolve_inputs` — calling it again here is idempotent and only needed if a future refactor reorders things; if `civo_resolve_inputs` already guarantees kubeconfig is configured by this point, the extra call is redundant but harmless. Confirm `kubectl` works before proceeding by running `kubectl get ns envoy` manually if unsure.)

- [ ] **Step 3: Fix the stale DNS-wait message**

In `scripts/argo-up.sh`, `civo_wait_for_dns` (~line 202-203), replace:

```bash
  echo "ARGO-UP: DNS not resolved for argo.<fqdn> after ${watch_seconds}s - non-fatal on civo (external-dns isn't implemented yet, so no DNS record is created automatically)." >&2
  echo "ARGO-UP: root Synced/Healthy - platform ready (DNS not yet resolved, non-fatal on civo)."
```

with:

```bash
  echo "ARGO-UP: DNS not resolved for argo.<fqdn> after ${watch_seconds}s - non-fatal, but check ExternalDNS's Application health and Route 53 directly before assuming the platform is reachable." >&2
  echo "ARGO-UP: root Synced/Healthy - platform ready (DNS not yet resolved within the watch window)."
```

- [ ] **Step 4: Verify scripts still parse**

Run: `bash -n scripts/lib/provider.sh && bash -n scripts/argo-up.sh`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/provider.sh scripts/argo-up.sh
git commit -m "civo-070: import platform-public-tls Secret from SSM on argo-up; fix stale DNS-wait message"
```

---

### Task 5: Real-cloud verification against the staging issuer

**Files:** none (verification only — no code changes expected unless a bug surfaces, in which case fix in the file it belongs to and re-run this task's steps)

**Interfaces:**
- Consumes: everything from Tasks 1-4
- Produces: evidence recorded in `specs/civo/070-letsencrypt-http01-tls/spec.md` §14 (consumed by Task 6's closeout)

- [ ] **Step 1: Confirm `tls.issuer` defaults to staging**

Check `gitops/values.yaml`'s `tls.issuer` is `"letsencrypt-staging"` (Task 1, Step 1's default) — do not override to prod for this task.

- [ ] **Step 2: Bring the platform up**

Run: `PROVIDER=civo make up`
Expected: root Application reaches `Synced/Healthy`; no errors from `civo_import_tls_secret` (a "no stored Secret" message is expected and fine on a first run).

- [ ] **Step 3: Confirm the Certificate issues**

Run: `kubectl get certificate platform-public -n envoy -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'`
Expected: `True` (poll every 5-10s up to ~2 minutes if not immediately Ready — an ACME order takes a little time).

- [ ] **Step 4: Confirm it's the staging chain**

Run: `curl -kv https://argo.civo.<root-domain>/ 2>&1 | grep -i "issuer\|staging"`
Expected: the certificate issuer name contains `(STAGING)` (Let's Encrypt staging CA's own naming).

- [ ] **Step 5: Down/up cycle — confirm no new ACME order**

Run: `kubectl get order -A` (record output, expect empty or only fully-consumed/deleted orders), then `openssl s_client -connect argo.civo.<root-domain>:443 -servername argo.civo.<root-domain> </dev/null 2>/dev/null | openssl x509 -noout -serial` (record the serial).

Run: `PROVIDER=civo make down && PROVIDER=civo make up`

Run the same two commands again. Expected: `kubectl get order -A` still empty, and the certificate serial is unchanged — proves the Secret round-tripped through SSM correctly.

- [ ] **Step 6: Record evidence**

Append a dated entry to `specs/civo/070-letsencrypt-http01-tls/spec.md` §14 with: the `Certificate` Ready confirmation, the staging-issuer curl output, the before/after serial from the down/up cycle, and confirmation `kubectl get order -A` stayed empty across the cycle.

---

### Task 6: Switch to production issuer and close out the spec

**Files:**
- Modify: `gitops/values.yaml` (flip `tls.issuer` to `"letsencrypt-prod"`)
- Modify: `specs/civo/070-letsencrypt-http01-tls/spec.md` (§13 checkbox, `status:`, `completed:` front matter, §14 evidence)
- Modify: `specs/civo/README.md` (status column for CIVO-070)

**Interfaces:**
- Consumes: Task 5's confirmed-working staging path
- Produces: nothing further downstream — this is the terminal task for the goal ("https://argo.civo.<root-domain> reachable and login-capable")

**Confirm with the user before this task's Step 2** — it spends against the real Let's Encrypt production rate limit.

- [ ] **Step 1: Flip the issuer value**

Edit `gitops/values.yaml`: change `tls.issuer` from `"letsencrypt-staging"` to `"letsencrypt-prod"`.

- [ ] **Step 2: Apply and confirm trusted chain (confirm with user first)**

Run: `PROVIDER=civo make up` (or, if already up, `helm upgrade` the root Application the same way `argo-up.sh` does, or simply re-run `PROVIDER=civo make up` — it's idempotent).

Run: `curl -v https://argo.civo.<root-domain>/ 2>&1 | grep -i "SSL certificate verify"`
Expected: no verification error (a plain `curl` with no `-k` succeeds), proving a browser would trust it too. Also open it in a real browser and confirm no certificate warning.

- [ ] **Step 3: Confirm login end-to-end**

Log into Argo CD at `https://argo.civo.<root-domain>` with user `admin` and the password from `secrets/vk-civo-lab/argocd-admin-password.bcrypt` (the plaintext companion file, or ask the user — this repo's convention is the bcrypt hash is committed, the plaintext is not).

- [ ] **Step 4: Record final evidence and close the spec**

In `specs/civo/070-letsencrypt-http01-tls/spec.md`:
- Tick §13's `- [ ] Evidence for staging and prod; down/up without new order; index updated; status DONE` to `- [x]`.
- Set front matter `status: "DONE"`, `completed: "<today's date>"`, `updated: "<today's date>"`.
- Append a dated §14 entry summarizing Task 5's staging evidence and this task's prod-issuer confirmation (Ready condition, trusted-chain curl/browser check, successful admin login).

In `specs/civo/README.md`, change CIVO-070's status column from `READY` to `DONE`.

- [ ] **Step 5: Commit**

```bash
git add gitops/values.yaml specs/civo/070-letsencrypt-http01-tls/spec.md specs/civo/README.md
git commit -m "civo-070: switch to letsencrypt-prod, close spec as DONE with execution evidence"
```

---

## Self-Review Notes

- **Spec coverage:** §4's ClusterIssuer/Certificate/listener design → Task 1. §4's Secret export/import → Tasks 3-4. §6 step 1 (staging, golden diff) → Task 1/5. §6 step 2 (down/up, no new order) → Task 5 Step 5. §6 step 3 (switch to prod, browser check) → Task 6. §6 step 4 (rate-limit math) → covered by Task 5/6's evidence recording, not a separate task since it's arithmetic over already-recorded order counts, not a new artifact. §8 acceptance criteria (trusted chain, HTTP→HTTPS redirect, no new order on cycle, Secret round-trips, SecureString, AWS golden diff empty) → Tasks 1 (golden diff), 5 (order/serial), 6 (trusted chain). Note: the spec's §4/§8 HTTP→HTTPS redirect requirement has no dedicated task here because no HTTPRoute-based redirect mechanism exists yet anywhere in this codebase to model it on, and the ACME solver's own route already needs to keep working on port 80 regardless — flagged as a real gap the implementer must resolve with a ruling (see below), not silently dropped.
- **Known gap needing a ruling during execution:** this plan does not specify the exact Envoy Gateway API mechanism for the HTTP→HTTPS redirect (e.g., an `HTTPRoute` with a `RequestRedirect` filter) because no existing file in this codebase demonstrates that pattern to copy from. Task 1's implementer (or the controller, if raised as a review finding) must add one — a plain `HTTPRoute` on the `http` listener with no path match and a `filters: [{type: RequestRedirect, requestRedirect: {scheme: https, statusCode: 301}}]` rule is the standard Gateway API idiom, added alongside the ACME solver's own route (which cert-manager creates itself at challenge time and which will win by exact-path-match precedence per the spec's amendment). Record this as a ruling if the reviewer flags it, rather than treating it as scope creep.
- **Type/name consistency check:** `platform-public-tls` (Secret name) and `platform-public` (Certificate name) are used identically across Tasks 1, 3, 4, and 5 — verified. `/${PROJECT_NAME}/persistent/civo/tls/platform-public` (SSM parameter path) matches between Task 3 (write) and Task 4 (read) exactly. `tls.issuer`/`tls.acmeEmail` values.yaml keys match between Task 1 (defined) and Task 2 (consumed via `--set`) exactly.
