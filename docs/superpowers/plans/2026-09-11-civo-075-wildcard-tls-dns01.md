# CIVO-075: Wildcard TLS through DNS-01 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Civo's HTTP-01, explicit-hostname public certificate with one wildcard certificate (`civo.<root-domain>` + `*.civo.<root-domain>`) issued through cert-manager's DNS-01 Route53 solver, authenticated by a fourth Roles Anywhere consumer (`cert-manager`).

**Architecture:** A new `cert-manager` Roles Anywhere consumer (Terraform: IAM role scoped to TXT-only changes on the Civo zone) gets its own workload-identity `Certificate`/Secret and an `aws-signing-helper` sidecar on the cert-manager controller pod, following the exact pattern CIVO-090/110 already established for `eso`/`external-dns`. The two `ClusterIssuer`s switch their ACME solver from `http01.gatewayHTTPRoute` to `dns01.route53`, and the public `Certificate`'s `dnsNames` switch from two explicit hostnames to the fqdn + wildcard pair — matching the shape AWS's ACM certificate already has.

**Tech Stack:** Terraform/Terragrunt (`aws_iam_policy_document`, `aws_ssm_parameter`), Helm/Argo CD GitOps templates, cert-manager v1.21.1 (jetstack chart), Bash (`scripts/argo-up.sh`).

**Spec:** `specs/civo/075-wildcard-tls-dns01/spec.md`

## Global Constraints

- One identity per workload: the `cert-manager` Roles Anywhere role is separate from `eso`'s and `external-dns`'s (spec §4).
- `cert-manager`'s IAM role gets `route53:ChangeResourceRecordSets` + `route53:ListResourceRecordSets` scoped to the Civo hosted zone ARN only, with a `ForAllValues:StringEquals` condition on `route53:ChangeResourceRecordSetsRecordTypes = ["TXT"]`, plus `route53:GetChange` on `"*"`. It does **not** get `route53:ListHostedZones*` — the zone ID reaches the chart as a value, not a lookup (spec §4, correction 3 in the approved plan).
- The AWS target is completely unaffected — every new/changed object is gated on `target == civo`, or lives under a `civo/` template directory, or (Terraform) is created only when `PROVIDER=civo`'s bootstrap stack applies (spec §10). `scripts/gitops-render-check.sh`'s AWS golden diff must stay empty after every task.
- The `cert-manager` consumer's `ra-cert` Secret volume must be `optional: true` — unlike `eso`/`external-dns`, whose Secret already exists by the time their sidecar-carrying pod starts, cert-manager's own controller pod needs to start *before* its own `Certificate` can be reconciled into a Secret (approved-plan correction 1). This is the one place this consumer's wiring differs from the two existing ones.
- Real Let's Encrypt orders are rate-limited (5 duplicate certs/week, shared with the personal lab and with CIVO-070's already-issued certificate). Use the staging issuer for every real-cloud check except the final prod-issuer verification, which is an explicit user-confirmation gate, not something the executing agent decides on its own (per repo convention: same-waves/prod-order memory).
- `scripts/argo-up.sh`'s civo SSM batch call has a hard cap of 10 parameter names (spec §4/§8) — this plan's Task 3 brings it from 8 to 10 exactly. The next consumer after this one must split the call; note this in the code comment, don't just leave it implicit.
- Keep the same sync-wave number for the same *kind* of thing across both targets where an AWS equivalent exists; where there is no AWS equivalent (the `Certificate/platform-public` wave drop from 3 to 2 in Task 4), civo is free to change it on its own, since there's nothing on AWS to keep in sync with.

---

## Task 1: Terraform — `cert-manager` Roles Anywhere consumer and zone-ID SSM parameter

**Files:**
- Modify: `terraform/modules/rolesanywhere/main.tf` (add consumer + policy document)
- Modify: `terraform/modules/route53-zone/main.tf` (add `zone_id` SSM parameter)

**Interfaces:**
- Consumes: `local.consumers` map (existing, keyed by consumer name → policy JSON string), `var.hosted_zone_id` (existing module input, already wired from `dependency.route53.outputs.zone_id` in `terraform/live/bootstrap/rolesanywhere/terragrunt.hcl:30`), `local.fqdn` (existing local in `route53-zone/main.tf:7`).
- Produces: SSM parameter `/${var.project}/bootstrap/rolesanywhere/role_arn/cert-manager` (via the existing generic `aws_ssm_parameter.role_arn` for_each — no new resource needed, it picks up the new consumer automatically), SSM parameter `/${var.project}/bootstrap/route53/zone_id` (new resource, consumed by Task 4's `issuers.yaml`).

- [ ] **Step 1: Add the `cert-manager` policy document and register it as a consumer**

In `terraform/modules/rolesanywhere/main.tf`, change the `locals.consumers` map (currently lines 16-19):

```hcl
  consumers = local.create ? {
    eso            = data.aws_iam_policy_document.eso.json
    "external-dns" = data.aws_iam_policy_document.external_dns.json
    "cert-manager" = data.aws_iam_policy_document.cert_manager.json
  } : {}
```

Then add a new policy document, placed after the existing `data "aws_iam_policy_document" "external_dns"` block (after line 95):

```hcl
# TXT-only, scoped to the Civo zone - cert-manager's DNS-01 solver never
# needs to touch the A records ExternalDNS owns, so the change permission
# is restricted by record type, not just by zone. No ListHostedZones*: the
# zone ID reaches this workload as a value (see route53-zone's zone_id SSM
# parameter), it never has to look the zone up.
data "aws_iam_policy_document" "cert_manager" {
  statement {
    actions   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.hosted_zone_id}"]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["TXT"]
    }
  }

  statement {
    actions   = ["route53:GetChange"]
    resources = ["*"]
  }
}
```

No other resource in this file needs a change: `data.aws_iam_policy_document.trust`, `aws_iam_role.consumer`, `aws_iam_role_policy.consumer`, `aws_rolesanywhere_profile.this`, and `aws_ssm_parameter.role_arn` all `for_each`/iterate over `local.consumers` already, so the new `cert-manager` key flows through automatically.

- [ ] **Step 2: Add the zone-ID SSM parameter**

In `terraform/modules/route53-zone/main.tf`, add after the existing `aws_ssm_parameter.fqdn` resource (after line 61):

```hcl

# Plain String - the zone ID is not a credential (constitution §14's
# root_domain/fqdn rationale applies equally here). Read by cert-manager's
# ClusterIssuer (dns01.route53.hostedZoneID) so the DNS-01 solver never
# needs route53:ListHostedZones to find its own zone.
resource "aws_ssm_parameter" "zone_id" {
  name        = "/${var.project}/bootstrap/route53/zone_id"
  type        = "String"
  value       = aws_route53_zone.this.zone_id
  description = "This project's Route53 hosted zone ID."
}
```

- [ ] **Step 3: Validate Terraform formatting and syntax**

Run: `terraform fmt -check terraform/modules/rolesanywhere/main.tf terraform/modules/route53-zone/main.tf`
Expected: no output (already formatted). If it reports a diff, run `terraform fmt` on both files and re-check.

Run: `cd terraform/modules/rolesanywhere && terraform init -backend=false && terraform validate`
Expected: `Success! The configuration is valid.`

Run: `cd terraform/modules/route53-zone && terraform init -backend=false && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Apply and verify against the real `vk-civo-lab` bootstrap stack**

Run: `PROVIDER=civo make bootstrap-up`
Expected: apply succeeds, plan shows one new `aws_iam_role.consumer["cert-manager"]`, one new `aws_iam_role_policy.consumer["cert-manager"]`, one new `aws_ssm_parameter.role_arn["cert-manager"]`, one new `aws_ssm_parameter.zone_id`, plus the existing `aws_rolesanywhere_profile.this` updated in place (its `role_arns` list grows by one).

Run:
```bash
aws ssm get-parameter --name /vk-civo-lab/bootstrap/rolesanywhere/role_arn/cert-manager --query Parameter.Value --output text
aws ssm get-parameter --name /vk-civo-lab/bootstrap/route53/zone_id --query Parameter.Value --output text
```
Expected: both commands print a value (an IAM role ARN and a Route53 zone ID respectively), no `ParameterNotFound` error.

- [ ] **Step 5: Commit**

```bash
git add terraform/modules/rolesanywhere/main.tf terraform/modules/route53-zone/main.tf
git commit -m "$(cat <<'EOF'
civo-075: add cert-manager Roles Anywhere consumer and zone-ID SSM param

Fourth Roles Anywhere consumer, scoped to TXT-only Route53 changes on the
Civo zone, for the upcoming DNS-01 solver. The zone ID is exported as a
plain SSM parameter so the solver never needs route53:ListHostedZones.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Xf1j66yKAhL57VEiMvx6L7
EOF
)"
```

---

## Task 2: GitOps — consumer wiring (values, relay, sidecar, identity cert, render-check)

**Files:**
- Modify: `gitops/values.yaml`
- Modify: `gitops/bootstrap/values.yaml`
- Modify: `gitops/bootstrap/templates/root-application.yaml`
- Modify: `gitops/templates/platform/civo/cert-manager/application.yaml`
- Modify: `scripts/gitops-render-check.sh`

**Interfaces:**
- Consumes: `platform.rolesAnywhereSidecar` named template (`gitops/templates/_helpers.tpl:30-66`, takes `dict "consumer" <string> "root" $`), the existing generic `civoIdentity.consumers` loop in `gitops/templates/platform/civo/identity/certificates.yaml` (no changes needed there — it already renders one `Certificate`/`<name>-ra-cert` Secret per list entry).
- Produces: `.Values.tls.hostedZoneId` (new value, consumed by Task 4's `issuers.yaml`), `.Values.awsIdentity.rolesAnywhere.roleArns."cert-manager"` (new value, consumed by the sidecar template via `index`), Secret `cert-manager-ra-cert` in namespace `cert-manager` (produced by the existing identity-certificates loop once the consumer list entry exists).

- [ ] **Step 1: Add the consumer entry and new values to `gitops/values.yaml`**

In `gitops/values.yaml`, change the `awsIdentity.rolesAnywhere.roleArns` block (currently lines 33-35):

```yaml
    roleArns:
      eso: ""
      external-dns: ""
      cert-manager: ""
```

Change the `tls` block (currently lines 99-101) to add the zone ID:

```yaml
tls:
  issuer: "letsencrypt-prod"
  acmeEmail: ""
  # civo-only: the Civo zone's Route53 zone ID, read from
  # /${project}/bootstrap/route53/zone_id - lets the dns01.route53 solver
  # skip route53:ListHostedZones entirely.
  hostedZoneId: ""
```

Change the `civoIdentity.consumers` list (currently lines 106-110):

```yaml
civoIdentity:
  consumers:
    - name: eso
      namespace: external-secrets
    - name: external-dns
      namespace: kube-system
    - name: cert-manager
      namespace: cert-manager
```

- [ ] **Step 2: Mirror the same values in `gitops/bootstrap/values.yaml`**

Change the `tls` block (currently lines 39-41):

```yaml
tls:
  issuer: "letsencrypt-prod"
  acmeEmail: ""
  hostedZoneId: ""
```

Change the `awsIdentity.rolesAnywhere.roleArns` block (currently lines 47-48):

```yaml
    roleArns:
      eso: ""
      external-dns: ""
      cert-manager: ""
```

(`gitops/bootstrap/values.yaml` has no `civoIdentity.consumers` list — that value only exists in the root chart, `gitops/values.yaml`, relayed there directly since it's a list, not a scalar `--set`-able value. No relay entry is needed for it in `root-application.yaml`.)

- [ ] **Step 3: Add the relay entry in `root-application.yaml`**

In `gitops/bootstrap/templates/root-application.yaml`, add one `helm.parameters` entry immediately after the existing `awsIdentity.rolesAnywhere.roleArns.external-dns` entry (currently lines 58-59):

```yaml
        - name: awsIdentity.rolesAnywhere.roleArns.cert-manager
          value: {{ index .Values.awsIdentity.rolesAnywhere.roleArns "cert-manager" | quote }}
```

And add one more entry after the existing `tls.acmeEmail` entry (currently lines 50-51):

```yaml
        - name: tls.hostedZoneId
          value: {{ .Values.tls.hostedZoneId | quote }}
```

- [ ] **Step 4: Add the sidecar to the cert-manager Application**

In `gitops/templates/platform/civo/cert-manager/application.yaml`, this whole file is already gated on `target == civo` (line 1), so the sidecar block does not need its own `{{- if }}`. Add it inside `spec.source.helm.values` (the literal YAML block starting at line 21), after the existing `cainjector.resources` block (currently ending at line 46), before the closing `{{- end }}`:

```yaml
        extraContainers:
          {{- include "platform.rolesAnywhereSidecar" (dict "consumer" "cert-manager" "root" $) | nindent 10 }}
        volumes:
          # optional: true - unlike eso/external-dns, this consumer's own
          # Certificate can only be issued once this controller is running,
          # so the Secret does not exist yet on a fresh make up. The pod
          # starts anyway (sidecar crashloops until the Secret appears),
          # cert-manager's wave-1 Certificate still gets reconciled, and the
          # sidecar recovers on its next restart once kubelet refills the
          # volume.
          - name: ra-cert
            secret:
              secretName: cert-manager-ra-cert
              optional: true
        extraEnv:
          - name: AWS_EC2_METADATA_SERVICE_ENDPOINT
            value: http://127.0.0.1:9911
          - name: AWS_REGION
            value: {{ .Values.region | quote }}
```

Use `volumes`/`extraEnv` (not `extraVolumes`/`env`, which is what the *external-dns* chart's schema uses) — `helm show values jetstack/cert-manager --version v1.21.1` confirms this chart's controller Deployment exposes `extraContainers`, `extraEnv`, `volumes`, and `volumeMounts` as top-level keys. The controller container itself needs no `volumeMounts` addition — only the sidecar (via `platform.rolesAnywhereSidecar`'s own `volumeMounts` block) reads `/ra`.

- [ ] **Step 5: Add the new required object to the render-check script**

In `scripts/gitops-render-check.sh`, add `Certificate__cert-manager__cert-manager` to `REQUIRED_OBJECTS_CIVO` (currently lines 63-69):

```bash
REQUIRED_OBJECTS_CIVO="EnvoyProxy__envoy__envoy-proxy-config Gateway__envoy__platform-gateway \
GatewayClass__cluster__envoy-gateway Application__argocd__cert-manager \
ClusterIssuer__cluster__civo-workload-ca Certificate__external-secrets__eso \
Certificate__kube-system__external-dns Certificate__cert-manager__cert-manager \
ClusterSecretStore__cluster__aws-parameter-store \
ExternalSecret__cnpg-system__lab-postgres-app Application__argocd__external-dns \
ClusterIssuer__cluster__letsencrypt-staging ClusterIssuer__cluster__letsencrypt-prod \
Certificate__envoy__platform-public HTTPRoute__envoy__https-redirect"
```

- [ ] **Step 6: Run the render check**

Run: `scripts/gitops-render-check.sh`
Expected: PASS for both `aws` and `civo` targets. The AWS golden diff is empty (nothing in this task touches an AWS-target-rendered object). The civo render now includes `Certificate__cert-manager__cert-manager` in its object set, matching the newly required entry.

If it fails because the new `Certificate`/Secret pair doesn't render as expected, inspect with:
```bash
helm template gitops --set target=civo --set project=vk-civo-lab | \
  yq -N 'select(.kind == "Certificate" and .metadata.namespace == "cert-manager")'
```
and check the `civoIdentity.consumers` entry from Step 1 matches (`name: cert-manager`, `namespace: cert-manager`).

- [ ] **Step 7: Commit**

```bash
git add gitops/values.yaml gitops/bootstrap/values.yaml \
  gitops/bootstrap/templates/root-application.yaml \
  gitops/templates/platform/civo/cert-manager/application.yaml \
  scripts/gitops-render-check.sh
git commit -m "$(cat <<'EOF'
civo-075: wire cert-manager as a fourth Roles Anywhere consumer

Adds the sidecar, the identity Certificate list entry, and the values/
relay plumbing for the cert-manager role ARN and the Route53 zone ID.
The Secret volume is optional - cert-manager's own certificate can only
be issued once its controller is already running.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Xf1j66yKAhL57VEiMvx6L7
EOF
)"
```

---

## Task 3: `scripts/argo-up.sh` — thread the role ARN and zone ID through the SSM batch

**Files:**
- Modify: `scripts/argo-up.sh`

**Interfaces:**
- Consumes: SSM parameters `/${PROJECT_NAME}/bootstrap/rolesanywhere/role_arn/cert-manager` and `/${PROJECT_NAME}/bootstrap/route53/zone_id` (produced by Task 1).
- Produces: shell variables `CERT_MANAGER_ROLE_ARN` and `ROUTE53_ZONE_ID`, passed to `helm upgrade --install root-application` as `awsIdentity.rolesAnywhere.roleArns.cert-manager` and `tls.hostedZoneId` (consumed by Task 2's relay in `root-application.yaml`).

- [ ] **Step 1: Add the two new SSM parameter names to the batch**

In `scripts/argo-up.sh`, change the `civo_ssm_names` array inside `civo_resolve_inputs()` (currently lines 82-91):

```bash
  # 10 names - this is the batch cap (aws ssm get-parameters' own limit).
  # The next new consumer/value must split this into two calls.
  local civo_ssm_names=(
    "/$PROJECT_NAME/bootstrap/route53/fqdn"
    "/$PROJECT_NAME/bootstrap/route53/zone_id"
    "/$PROJECT_NAME/persistent/argocd/admin_password_bcrypt"
    "/$PROJECT_NAME/persistent-civo/reserved-ip/address"
    "/$PROJECT_NAME/cluster-civo/network/lb_firewall_id"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/trust_anchor_arn"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/profile_arn"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/eso"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/external-dns"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/cert-manager"
  )
```

- [ ] **Step 2: Add the matching case arms**

In the same function's dispatch `case` statement (currently lines 110-119), add two arms:

```bash
    case "${civo_ssm_names[$i]}" in
      */fqdn) LAB_FQDN="$found" ;;
      */route53/zone_id) ROUTE53_ZONE_ID="$found" ;;
      */admin_password_bcrypt) ADMIN_PASSWORD_BCRYPT_HASH="$found" ;;
      */reserved-ip/address) RESERVED_IP="$found" ;;
      */lb_firewall_id) FIREWALL_ID="$found" ;;
      */rolesanywhere/trust_anchor_arn) TRUST_ANCHOR_ARN="$found" ;;
      */rolesanywhere/profile_arn) PROFILE_ARN="$found" ;;
      */rolesanywhere/role_arn/eso) ESO_ROLE_ARN="$found" ;;
      */rolesanywhere/role_arn/external-dns) EXTERNAL_DNS_ROLE_ARN="$found" ;;
      */rolesanywhere/role_arn/cert-manager) CERT_MANAGER_ROLE_ARN="$found" ;;
    esac
```

(`*/fqdn` must stay listed before `*/route53/zone_id` only if both patterns could otherwise ambiguously match the same string — they can't, since one ends in `/fqdn` and the other in `/zone_id`; order between them doesn't matter. Keep them adjacent for readability since both come from the same `route53-zone` module.)

- [ ] **Step 3: Pass both values to the root Application install**

In `civo_install_root_application()` (currently lines 397-417), add two `--set` lines after the existing `awsIdentity.rolesAnywhere.roleArns.external-dns` line:

```bash
    --set awsIdentity.rolesAnywhere.roleArns.eso="$ESO_ROLE_ARN" \
    --set awsIdentity.rolesAnywhere.roleArns.external-dns="$EXTERNAL_DNS_ROLE_ARN" \
    --set awsIdentity.rolesAnywhere.roleArns.cert-manager="$CERT_MANAGER_ROLE_ARN" \
    --set tls.issuer="${TLS_ISSUER:-letsencrypt-prod}" \
    --set tls.acmeEmail="${TLS_ACME_EMAIL:-}" \
    --set tls.hostedZoneId="$ROUTE53_ZONE_ID"
```

- [ ] **Step 4: Syntax-check the script**

Run: `bash -n scripts/argo-up.sh`
Expected: no output (valid syntax).

Run: `shellcheck scripts/argo-up.sh` (if shellcheck is installed; skip otherwise — it's not a hard gate in this repo, but worth a quick look for a typo'd variable name in the new case arms/`--set` lines).
Expected: no new warnings introduced by this change (pre-existing warnings, if any, are out of scope).

- [ ] **Step 5: Commit**

```bash
git add scripts/argo-up.sh
git commit -m "$(cat <<'EOF'
civo-075: thread cert-manager role ARN and zone ID through argo-up.sh

Grows the civo SSM batch from 8 to 10 names (the hard cap for one
get-parameters call) and passes both new values to the root Application.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Xf1j66yKAhL57VEiMvx6L7
EOF
)"
```

---

## Task 4: Switch the ClusterIssuers to DNS-01 and the Certificate to the wildcard pair

**Files:**
- Modify: `gitops/templates/platform/civo/tls/issuers.yaml`
- Modify: `gitops/templates/platform/civo/tls/certificate.yaml`

**Interfaces:**
- Consumes: `.Values.tls.hostedZoneId` (produced by Task 2/3), `.Values.envoyGateway.fqdn` (existing value, already set by `argo-up.sh` to the Civo project's fqdn, e.g. `civo.<root-domain>`).
- Produces: no new interface — same `ClusterIssuer` names (`letsencrypt-staging`, `letsencrypt-prod`) and same `Certificate`/Secret name (`platform-public`/`platform-public-tls`) that CIVO-070's Secret-persistence machinery (`argo-down.sh`'s `civo_export_tls_secret`, `argo-up.sh`'s `civo_import_tls_secret`) already round-trips through SSM, unchanged by this task.

- [ ] **Step 1: Replace the HTTP-01 solver with DNS-01 in both ClusterIssuers**

Replace the full contents of `gitops/templates/platform/civo/tls/issuers.yaml`:

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
      - dns01:
          route53:
            region: {{ .Values.region | quote }}
            hostedZoneID: {{ .Values.tls.hostedZoneId | quote }}
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
      - dns01:
          route53:
            region: {{ .Values.region | quote }}
            hostedZoneID: {{ .Values.tls.hostedZoneId | quote }}
{{- end }}
```

No `accessKeyID`/`role`/`secretAccessKeySecretRef` fields — cert-manager's Route53 DNS-01 solver falls back to the AWS SDK's default credential chain, which resolves through the `aws-signing-helper` sidecar via `AWS_EC2_METADATA_SERVICE_ENDPOINT=http://127.0.0.1:9911` (set in Task 2 Step 4). `selector` is omitted (defaults to matching all names) since both the apex and the wildcard live in the one zone.

- [ ] **Step 2: Switch the Certificate's dnsNames to the wildcard pair and drop the sync-wave**

Replace the full contents of `gitops/templates/platform/civo/tls/certificate.yaml`:

```yaml
{{- if eq .Values.target "civo" }}
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: platform-public
  namespace: envoy
  annotations:
    # Wave 2: DNS-01 only needs the wave-0 Gateway (for the HTTPS listener
    # it targets) and the wave-1 identity Certificates (cert-manager's own
    # signing sidecar) - unlike HTTP-01, it never waits on application
    # HTTPRoutes or their DNS records.
    argocd.argoproj.io/sync-wave: "2"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
    # Resolves the HTTPS listener during the very first order, before any
    # real certificate exists yet (matches CIVO-060's temporary-cert amendment).
    cert-manager.io/issue-temporary-certificate: "true"
spec:
  secretName: platform-public-tls
  dnsNames:
    - {{ .Values.envoyGateway.fqdn | quote }}
    - {{ printf "*.%s" .Values.envoyGateway.fqdn | quote }}
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

- [ ] **Step 3: Run the render check**

Run: `scripts/gitops-render-check.sh`
Expected: PASS. AWS golden diff empty. On the civo render, confirm both `ClusterIssuer` objects' `spec.acme.solvers[0]` now has a `dns01.route53` key (not `http01`), and `Certificate/platform-public`'s `spec.dnsNames` is the two-element wildcard pair with `argocd.argoproj.io/sync-wave: "2"`:

```bash
helm template gitops --set target=civo --set project=vk-civo-lab \
  --set envoyGateway.fqdn=civo.example.com --set tls.hostedZoneId=Z123EXAMPLE | \
  yq -N 'select(.kind == "Certificate" and .metadata.name == "platform-public") | .spec.dnsNames, .metadata.annotations["argocd.argoproj.io/sync-wave"]'
```
Expected output: `["civo.example.com", "*.civo.example.com"]` followed by `"2"`.

- [ ] **Step 4: Commit**

```bash
git add gitops/templates/platform/civo/tls/issuers.yaml \
  gitops/templates/platform/civo/tls/certificate.yaml
git commit -m "$(cat <<'EOF'
civo-075: switch civo TLS to DNS-01 and the wildcard certificate pair

Both ClusterIssuers now solve through Route53 DNS-01 instead of the
Gateway HTTPRoute HTTP-01 solver; the public Certificate now covers
civo.<root-domain> and *.civo.<root-domain> instead of enumerated
hostnames, matching the shape the AWS ACM certificate already has.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Xf1j66yKAhL57VEiMvx6L7
EOF
)"
```

---

## Task 5: Real-cloud verification (staging, negative tests, down/up round-trip, prod switch)

**Files:** none (verification only — no code changes unless a real-cloud check surfaces a defect, in which case fix it in the relevant task's file and re-run from that task's render-check step).

**Interfaces:**
- Consumes: everything produced by Tasks 1-4.
- Produces: the spec's acceptance evidence (§8), to be recorded in `specs/civo/075-wildcard-tls-dns01/spec.md` §14 once done.

- [ ] **Step 1: Fresh cluster on the staging issuer**

This step specifically must run against a **fresh** cluster (not an upgrade of one already running from before this branch), because it is the only way to exercise the optional-Secret startup path from the Global Constraints section (the `cert-manager` consumer's own Secret does not exist until its own controller has already started once).

Run: `PROVIDER=civo TLS_ISSUER=letsencrypt-staging make down` (tear down any existing cluster first, if one exists from prior work)
Run: `PROVIDER=civo TLS_ISSUER=letsencrypt-staging make up`

Expected: the cluster comes up. `kubectl -n cert-manager get pod` shows the cert-manager controller pod; it may show `0/2 Ready` briefly right after creation (sidecar `aws-signing-helper` restarting on a missing `/ra/tls.crt`) before settling to `2/2 Ready` once its own `Certificate` is issued.

Run: `kubectl get certificate -n cert-manager cert-manager -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'`
Expected: `True` (may need a few retries/seconds).

Run: `kubectl get challenge -A`
Expected: one or more rows with `TYPE` column `DNS-01` (or `STATE` `valid` if it already completed — the CRD calls the field `type: DNS-01` in its spec).

Run: `kubectl get certificate -n envoy platform-public -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'`
Expected: `True`.

Run: `kubectl get httproute -A | grep -i acme` (or `cm-acme-http-solver`)
Expected: no output — DNS-01 creates no solver HTTPRoute, unlike CIVO-070's HTTP-01.

- [ ] **Step 2: Confirm the wildcard SANs**

Run:
```bash
kubectl get secret -n envoy platform-public-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -noout -text | grep -A2 "Subject Alternative Name"
```
Expected: exactly `DNS:civo.<root-domain>, DNS:*.civo.<root-domain>` (the actual root domain value from your project's SSM `fqdn` parameter).

- [ ] **Step 3: Negative tests with the cert-manager consumer's own credentials**

Launch a throwaway pod carrying the same sidecar this consumer's real workload uses, then delete it when done:

```bash
kubectl run cert-manager-negtest --image=amazon/aws-cli --restart=Never -n cert-manager \
  --overrides="$(cat <<'JSON'
{
  "spec": {
    "containers": [
      {
        "name": "aws-cli",
        "image": "amazon/aws-cli",
        "command": ["sleep", "300"],
        "env": [
          {"name": "AWS_EC2_METADATA_SERVICE_ENDPOINT", "value": "http://127.0.0.1:9911"},
          {"name": "AWS_REGION", "value": "eu-west-1"}
        ]
      }
    ]
  }
}
JSON
)"
```

Wait for it to be running, then exec in a test batch (fill in the two zone IDs — the Civo zone from Step 2's `route53/zone_id` SSM parameter, and the AWS project's own `lab` zone ID):

```bash
kubectl exec -n cert-manager cert-manager-negtest -- aws route53 change-resource-record-sets \
  --hosted-zone-id "$CIVO_ZONE_ID" \
  --change-batch '{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"probe.civo.example.com","Type":"A","TTL":60,"ResourceRecords":[{"Value":"1.2.3.4"}]}}]}'
```
Expected: `AccessDenied` (or `AccessDeniedException`) — the `ForAllValues:StringEquals` condition on record types blocks a non-TXT change even inside the allowed zone.

```bash
kubectl exec -n cert-manager cert-manager-negtest -- aws route53 change-resource-record-sets \
  --hosted-zone-id "$AWS_LAB_ZONE_ID" \
  --change-batch '{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"_acme-challenge.lab.example.com","Type":"TXT","TTL":60,"ResourceRecords":[{"Value":"\"probe\""}]}}]}'
```
Expected: `AccessDenied` — the resource-scoped statement only names the Civo zone's ARN, so any zone ID outside it (including a TXT change) is denied regardless of record type.

Clean up: `kubectl delete pod -n cert-manager cert-manager-negtest`

- [ ] **Step 4: `make down`/`make up` round-trip — no new order, unchanged serial**

Run: `kubectl get secret -n envoy platform-public-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -serial` and record the output as `SERIAL_BEFORE`.

Run: `PROVIDER=civo TLS_ISSUER=letsencrypt-staging make down`
Run: `PROVIDER=civo TLS_ISSUER=letsencrypt-staging make up`

Run: `kubectl get order -A`
Expected: empty (no rows) — CIVO-070's Secret-persistence round-trip through SSM restores the existing cert instead of ordering a new one, and this spec doesn't touch that machinery.

Run: `kubectl get secret -n envoy platform-public-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -serial` and compare to `SERIAL_BEFORE`.
Expected: identical.

- [ ] **Step 5: STOP — confirm with the user before the prod-issuer switch**

Do not proceed past this point without explicit user confirmation. Switching to `letsencrypt-prod` for this wildcard name set is a fresh Let's Encrypt bucket (different SAN set than CIVO-070's certificate) and spends one production order against the shared 5-duplicate-certificates/week limit.

Once confirmed:

Run: `PROVIDER=civo TLS_ISSUER=letsencrypt-prod make up` (or re-run the full down/up cycle with `TLS_ISSUER=letsencrypt-prod`, per whatever the operator prefers for switching issuers on a live cluster — check `Certificate/platform-public`'s `issuerRef.name` picks up the new value and cert-manager reissues).

Run: `curl -sv https://argo.civo.<root-domain>/ 2>&1 | grep -E "SSL certificate|subject:|issuer:"`
Run: `curl -sv https://grafana.civo.<root-domain>/ 2>&1 | grep -E "SSL certificate|subject:|issuer:"`
Expected: both succeed with **no** `--insecure` flag needed (trusted chain from a public CA), and both show the same certificate (same `subject:`/SAN set — the one wildcard cert).

- [ ] **Step 6: Record the evidence in the spec**

Edit `specs/civo/075-wildcard-tls-dns01/spec.md`:
- Check both boxes in §13 Definition of done.
- Add a dated entry to §14 Execution evidence and status history summarizing: the DNS-01 challenge type/state observed in Step 1, the SAN set confirmed in Step 2, the negative-test results from Step 3, the unchanged-serial round-trip from Step 4, and the prod-issuer trusted-chain confirmation from Step 5.
- Update the frontmatter `status` to `"DONE"` and `completed` to today's date.

Commit:
```bash
git add specs/civo/075-wildcard-tls-dns01/spec.md
git commit -m "$(cat <<'EOF'
civo-075: close spec as DONE with real-cloud evidence

DNS-01 issuance verified on a fresh cluster (staging), wildcard SANs
confirmed, negative tests pass (TXT-only, Civo zone only), down/up
round-trip issues no new order, prod issuer confirmed trusted end-to-end.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Xf1j66yKAhL57VEiMvx6L7
EOF
)"
```

---

## Self-review notes (spec coverage check)

- Spec §4 bullet "consumer name `cert-manager`, namespace `cert-manager`" → Task 2 Step 1.
- Spec §4 bullet "Role `${project}-ra-cert-manager`" → produced automatically by the existing generic `aws_iam_role.consumer` for_each (Task 1 Step 1 note) — the name pattern `${var.project}-ra-${each.key}` already yields exactly this.
- Spec §4 bullet "zone ID reaches the chart as a value... batch grows from 8 to 10" → Task 1 Step 2, Task 3 Step 1.
- Spec §4 bullet "sidecar through extraContainers... platform.rolesAnywhereSidecar" → Task 2 Step 4.
- Spec §4 bullet "ClusterIssuers... dns01.route53... no accessKeyID/role fields" → Task 4 Step 1.
- Spec §4 bullet "Certificate... dnsNames wildcard pair... sync-wave drops from 3 to 2" → Task 4 Step 2.
- Spec §4 bullet "redirect HTTPRoute stays, comment no longer needs..." → verified in research: `redirect.yaml` carries no ACME-precedence comment today (nothing to remove), so this task list has no step for it — not a gap, the spec's assumption about that comment's location was already stale before this plan.
- Spec §5 file list → every file listed there is touched by Tasks 1-4 except `gitops/templates/platform/civo/identity/certificates.yaml`, which needs no code change (confirmed generic over the consumer list) — called out explicitly in Task 2's Interfaces section instead of a phantom step.
- Spec §8 acceptance criteria → Task 5 Steps 1-5 cover all five bullet points (SANs, DNS-01 challenge type, negative tests, no-new-order round-trip, empty golden diff/10-name batch).
- Spec §6 "fix the stale DNS-wait timeout message" (this line comes from the earlier approved plan, not spec §075 itself) → verified during research that `scripts/argo-up.sh` no longer contains this stale message (already fixed on `main`); dropped from this plan as not applicable.
