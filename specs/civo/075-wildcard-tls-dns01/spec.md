---
id: "CIVO-075"
title: "Wildcard public TLS on Civo through the DNS-01 solver and a cert-manager Roles Anywhere consumer"
status: "READY"
priority: "P2"
milestone: "M2"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Repeats the CIVO-090 consumer pattern and swaps a cert-manager solver; the IAM scope and the SSM round-trip need care but are specified"
effort_estimate: "Half a session (3–4 h)"
estimate_confidence: "medium"
depends_on: ["CIVO-070", "CIVO-082", "CIVO-090"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: null
---

# CIVO-075 — Wildcard TLS through DNS-01

## 1. Outcome and rationale

Envoy on Civo serves one Let's Encrypt certificate for `civo.<root-domain>`
and `*.civo.<root-domain>`. This is the same shape as the ACM certificate
on AWS (`lab.<root-domain>` and `*.lab.<root-domain>`). A new hostname
needs no change to the `Certificate`. cert-manager proves domain control
with the DNS-01 solver, which writes a TXT record into the Civo Route 53
zone. Let's Encrypt issues wildcards only through DNS-01.

CIVO-070 chose HTTP-01 because it needs no AWS identity. HTTP-01 has three
costs that this spec removes: the certificate lists each hostname; the
HTTP listener must carry an ACME solver route that wins over the
HTTP→HTTPS redirect; and issuance depends on ExternalDNS publishing the
application records first.

## 2. Scope and non-goals

In scope:

- a fourth Roles Anywhere consumer, `cert-manager`, with a role scoped to
  TXT records in the Civo zone;
- the sidecar on the cert-manager controller pod;
- the `ClusterIssuer`s switched to the `dns01.route53` solver;
- the `Certificate` switched to the wildcard pair;
- the HTTP→HTTPS redirect no longer needs the ACME exemption.

Not in scope: the AWS target (ACM stays), the workload-identity
certificates (CIVO-085), and the Secret persistence in `argo-down`/`argo-up`
(CIVO-070; it keeps working unchanged because the Secret name does not
change).

## 3. Current state / evidence

- CIVO-070 (verified 2026-09-11 on `vk-civo-lab`): `Certificate platform-public`
  with `dnsNames: [argo.<fqdn>, grafana.<fqdn>]`, HTTP-01 through
  `gatewayHTTPRoute`, staging issuer, Secret round-trip through SSM proven
  (same serial after `make down`/`make up`, no new `Order`).
- The cert-manager chart v1.21.1 exposes `extraContainers`, `extraEnv`,
  `volumes` and `volumeMounts` for the controller Deployment (checked with
  `helm show values`).
- CIVO-090 §4 records what one more consumer costs: `terraform/modules/rolesanywhere`
  (`local.consumers` and the trust policy), `gitops/values.yaml`
  (`civoIdentity.consumers`, `awsIdentity.rolesAnywhere.roleArns`),
  `gitops/bootstrap/values.yaml` and `root-application.yaml` (the relay), and
  three sites in `scripts/argo-up.sh`. The SSM `get-parameters` batch in
  `argo-up.sh` holds 8 names; the cap is 10.
- `Certificate/platform-public` sits at sync-wave 3 (ADR 0025 amendment,
  2026-09-11) only because HTTP-01 needs the wave-2 HTTPRoutes' DNS records.

## 4. Design and contracts

- Consumer name `cert-manager`, namespace `cert-manager`. The Certificate
  `cert-manager` (CIVO-085 pattern) yields the Secret `cert-manager-ra-cert`.
  The trust policy matches the CN `cert-manager` exactly, as for `eso` and
  `external-dns`.
- Role `${project}-ra-cert-manager`. It allows `route53:GetChange` on `*`,
  and `route53:ListResourceRecordSets` and `route53:ChangeResourceRecordSets`
  on the Civo zone ARN only. The change permission carries the condition
  `route53:ChangeResourceRecordSetsRecordTypes` = `["TXT"]`, so the role can
  never touch the A records ExternalDNS owns. It does not get
  `route53:ListHostedZones*`; the issuer names the zone ID directly.
- The zone ID reaches the chart as a value. `argo-up.sh` already reads
  `/${project}/bootstrap/route53/fqdn`; add `/${project}/bootstrap/route53/zone_id`
  (a plain `String`, written by `terraform/modules/route53-zone`) to the same
  batch. The batch grows from 8 to 10 names (zone ID and the new role ARN).
  That is the cap: the next consumer must split the call.
- The cert-manager Application (`gitops/templates/platform/civo/cert-manager/application.yaml`)
  adds the sidecar through the chart's `extraContainers`, the Secret volume
  through `volumes`/`volumeMounts` (mount `/ra`, read-only), and the env
  `AWS_EC2_METADATA_SERVICE_ENDPOINT`/`AWS_REGION` through `extraEnv`. Use
  `platform.rolesAnywhereSidecar` from `_helpers.tpl` with
  `consumer=cert-manager`, `namespace=cert-manager`, `root=$`.
- `ClusterIssuer letsencrypt-staging`/`-prod` replace the `http01` solver with:
  `dns01.route53: { region: eu-west-1, hostedZoneID: <value> }` and no
  `accessKeyID`/`role` fields, so the AWS SDK default chain reaches the
  sidecar. Keep the `selector` empty; both names are in this zone.
- `Certificate platform-public` sets
  `dnsNames: ["civo.<fqdn root>", "*.civo.<fqdn root>"]` — in template terms
  `{{ .Values.envoyGateway.fqdn }}` and `"*.{{ .Values.envoyGateway.fqdn }}"`.
  `secretName`, key algorithm, rotation policy and the temporary-certificate
  annotation stay as in CIVO-070. The sync-wave drops from 3 to 2: issuance
  no longer waits for the application records, only for the Gateway (wave 0)
  and the identity Certificates (wave 1). It must stay after wave 1.
- The redirect `HTTPRoute` stays. Its comment no longer needs to explain the
  ACME solver precedence; remove that sentence.
- The Route 53 role and the ExternalDNS role stay separate. One identity per
  workload is the CIVO-085/090 invariant.

## 5. Files/components affected

`terraform/modules/rolesanywhere/main.tf` (consumer, role, policy);
`terraform/modules/route53-zone/main.tf` (zone-ID SSM parameter);
`gitops/values.yaml`; `gitops/bootstrap/values.yaml`;
`gitops/bootstrap/templates/root-application.yaml`;
`gitops/templates/platform/civo/cert-manager/application.yaml`;
`gitops/templates/platform/civo/identity/certificates.yaml` (one more
consumer renders from the list; verify the loop covers it);
`gitops/templates/platform/civo/tls/{issuers,certificate,redirect}.yaml`;
`scripts/argo-up.sh`; `scripts/gitops-render-check.sh`
(`Certificate__cert-manager__cert-manager` becomes required on civo).

## 6. Implementation steps

1. Terraform: add the consumer and the role. Run `PROVIDER=civo make bootstrap-up`.
   Check that `/${project}/bootstrap/rolesanywhere/role_arn/cert-manager`
   and `/${project}/bootstrap/route53/zone_id` exist.
2. GitOps: add the consumer, the sidecar and the values. Run
   `scripts/gitops-render-check.sh`. The AWS golden diff is empty.
3. Switch the issuers and the Certificate. Keep the staging issuer for the
   first cycle. Run `PROVIDER=civo make up`. Check the `Challenge` reaches
   `valid` through DNS-01 and the Certificate is `Ready`.
4. Negative test with the helper's credentials: `ChangeResourceRecordSets`
   with an A record on the Civo zone is denied; a TXT change on the AWS
   `lab` zone is denied.
5. Run `make down`/`make up`. No new `Order`; the serial is unchanged.
6. Switch to prod. Check `curl https://argo.civo.<root-domain>` and
   `https://grafana.civo.<root-domain>` both present the one wildcard
   certificate.

## 7. Dependencies and blockers

CIVO-070 (issuers, Certificate, persistence), CIVO-082 (role and trust
policy structure), CIVO-090 (sidecar template).

## 8. Acceptance criteria

- `openssl s_client` on `argo.civo.<root-domain>` shows a certificate whose
  SANs are exactly `civo.<root-domain>` and `*.civo.<root-domain>`.
- `kubectl get challenge -A` for the issuance shows `type: DNS-01` and
  `state: valid`. No solver `HTTPRoute` is created.
- The cert-manager role denies A-record changes on the Civo zone and any
  change on the AWS zone (negative tests with the `aws` CLI).
- A `make down`/`make up` cycle creates no new `Order`; the serial is unchanged.
- The AWS golden diff is empty. The `argo-up.sh` SSM batch has 10 names.

## 9. Validation

Offline: the golden diff, kubeconform, `terraform validate`. Real cloud: two
civo cycles (~0.3 USD). Route 53 API calls are free. Use the staging issuer
until step 6.

## 10. AWS regression protection

All objects are under `civo/` or gated on `target == civo`. The Terraform
role is created only for the civo project (`PROVIDER=civo`). The golden
render proves the AWS tree is unchanged.

## 11. Rollout and rollback/recovery

Revert the change; HTTP-01 and the enumerated names return. Delete the SSM
TLS parameter to force a fresh order if the stored Secret carries the
wildcard names. Data risk: none.

## 12. Risks and unresolved questions

- DNS-01 issuance takes one to three minutes (TXT propagation and
  cert-manager's self-check). Argo's Certificate health check holds wave 2
  open for that time. Acceptable.
- `route53:ChangeResourceRecordSetsRecordTypes` limits record types, not
  names. The role can still write any TXT record in the Civo zone,
  including ExternalDNS's ownership TXT records. Accepted for the lab; the
  next hardening step is a separate zone for `_acme-challenge` names.
- The chart's `volumes` and `volumeMounts` apply to the controller only,
  which is the pod that runs the solver. Confirm no other component needs
  the sidecar.

## 13. Definition of done

- [ ] Evidence for staging and prod; down/up without new order
- [ ] Index and roadmap updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as READY at the user's request during CIVO-070
  verification: the AWS target uses a wildcard through ACM, and the Civo
  target should present the same shape.
