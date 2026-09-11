---
id: "CIVO-075"
title: "Wildcard public TLS on Civo through the DNS-01 solver and a cert-manager Roles Anywhere consumer"
status: "DONE"
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
completed: "2026-09-11"
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
   `scripts/gitops-render-check.sh`. The AWS golden render changes only by
   the root Application's relay parameter list (two new empty-valued
   entries, matching the existing `roleArns.eso`/`roleArns.external-dns`
   pattern) — no civo-only object appears in it.
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
- The AWS golden render changes only by two new empty-valued relay
  parameters (the `roleArns.eso`/`roleArns.external-dns` pattern); no
  civo-only object appears in it. The `argo-up.sh` SSM batch has 10 names.

## 9. Validation

Offline: the golden diff, kubeconform, `terraform validate`. Real cloud: two
civo cycles (~0.3 USD). Route 53 API calls are free. Use the staging issuer
until step 6.

## 10. AWS regression protection

All objects are under `civo/` or gated on `target == civo`. The Terraform
role is created only for the civo project (`PROVIDER=civo`). The golden
render proves no civo-only object enters the AWS tree. One exception: the `zone_id` SSM
parameter lives in `terraform/modules/route53-zone`, a module shared by
both projects' bootstrap stacks, so the AWS project's next `bootstrap-up`
creates it too — additive and unused on AWS, but not civo-exclusive.

## 11. Rollout and rollback/recovery

Revert the change; HTTP-01 and the enumerated names return. Delete the SSM
TLS parameter to force a fresh order if the stored Secret carries the
wildcard names. Data risk: none.

Forward upgrade: on the first `make up` after this change runs against an
already-existing cluster from before it, the old (pre-wildcard,
HTTP-01-issued) certificate gets restored from the SSM-backed Secret
persistence (CIVO-070's mechanism, unchanged by this spec) and served
until cert-manager notices the `dnsNames` no longer match the `Certificate`
spec and reissues on its own — self-healing, one to three minutes on
DNS-01, no manual action needed.

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
- `scripts/argo-up.sh`'s idempotency fast-path guard exits early once
  `kubectl get application root` reports `Synced/Healthy`, before reaching
  its own `helm upgrade` call — so a plain `TLS_ISSUER=letsencrypt-prod
  make up` does not switch the issuer on an already-running cluster; the
  fast path never re-applies the new value. To force a resync of a running
  cluster's Helm parameters (e.g. to switch issuers), re-issue the
  underlying `helm upgrade --install root-application ... --server-side
  --force-conflicts` command directly with the new `--set
  tls.issuer=letsencrypt-prod` — the same command
  `civo_install_root_application()` runs. This is safe because of
  `--server-side --force-conflicts`; it is just not exposed as a
  convenient re-run path yet (a follow-up to give `argo-up.sh` a real
  force-re-apply escape hatch is out of scope for this spec).

## 13. Definition of done

- [x] Evidence for staging and prod; down/up without new order
- [x] Index and roadmap updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as READY at the user's request during CIVO-070
  verification: the AWS target uses a wildcard through ACM, and the Civo
  target should present the same shape.
- 2026-09-11 — implemented (Tasks 1-4: Roles Anywhere `cert-manager`
  consumer and TXT-only-scoped role, the sidecar wiring, the SSM zone-ID
  parameter through `argo-up.sh`, the `dns01.route53` `ClusterIssuer`s and
  the wildcard `Certificate`) and verified end-to-end against a fresh
  `vk-civo-lab` cluster (Task 5):
  - **DNS-01 issuance**: the completed staging `Order`
    (`envoy/platform-public-2-4038833104`) shows
    `spec.dnsNames: [civo.<root-domain>, *.civo.<root-domain>]` and
    `status.authorizations[].challenges[].type: dns-01`; `Certificate
    cert-manager` and `Certificate platform-public` both reached
    `Ready: True`. No solver `HTTPRoute` was created
    (`kubectl get httproute -A | grep -i acme` empty).
  - **The circular Roles Anywhere bootstrap**: on a genuinely fresh
    cluster the cert-manager controller pod started with the
    `aws-signing-helper` sidecar unready (`1/2 Error`, the sidecar
    restarting on the not-yet-existing `cert-manager-ra-cert` Secret — 7
    restarts observed in ~90s), then recovered to `2/2 Running` once
    cert-manager's own `Certificate` issued that Secret. The `optional:
    true` volume design works as intended.
  - **Wildcard SANs (staging)**: `openssl x509` on the
    `platform-public-tls` Secret showed
    `DNS:*.civo.<root-domain>, DNS:civo.<root-domain>` under the
    `(STAGING)` Let's Encrypt issuer.
  - **Negative tests**: using a throwaway pod carrying the real
    `cert-manager` Roles Anywhere sidecar (same trust-anchor/profile/role
    ARNs, port 9911), an A-record `ChangeResourceRecordSets` inside the
    allowed Civo zone (`Z089258123NOYWF13YBZ0`) was denied
    (`AccessDenied` — the `ForAllValues:StringEquals` record-type
    condition), and a TXT `ChangeResourceRecordSets` against the AWS
    account's root zone `<root-domain>` (`Z00765244550N5OIUMQC`, substituted
    for the AWS `lab` zone — `lab.<root-domain>` does not exist in this
    account, since the `vk-lab-platform` AWS project's persistent
    Route 53/ACM stack has never been applied there) was also denied
    (`AccessDenied` — the resource-scoped policy statement only names the
    Civo zone's ARN). Both confirm the role's TXT-only,
    single-zone scope.
  - **`make down`/`make up` round-trip**: `kubectl get order -A` was
    empty after the cycle, and the certificate serial
    (`2C016914025A480E95743AA19114D2F91B23`) was identical before and
    after — the SSM Secret-persistence round-trip restored the existing
    certificate rather than ordering a new one.
  - **Prod-issuer switch**: `ClusterIssuer letsencrypt-prod` reissued the
    same wildcard pair — the new prod `Order`
    (`envoy/platform-public-1-3845236320`) and `Challenge`
    (`envoy/platform-public-1-3845236320-2957023773`) both reached
    `valid` for `civo.<root-domain>` (a fresh SAN-set bucket, separate from
    CIVO-070's staging cert, as expected). `Certificate/platform-public`
    shows `issuerRef.name: letsencrypt-prod`, `Ready: True`. The live
    certificate's SANs are `DNS:*.civo.<root-domain>, DNS:civo.<root-domain>`,
    issuer `/C=US/O=Let's Encrypt/CN=YE1` (production, not staging),
    serial `05F4DB49913F65315EC4337334CF0001AF50`.
    `curl -sv https://argo.civo.<root-domain>/` succeeded with no
    `--insecure` flag (`SSL certificate verify ok`, HTTP/2 200) —
    confirming a trusted public-CA chain end-to-end. `grafana.civo.<root-domain>`
    could not be cross-checked: this verification cluster has no
    observability stack deployed (only the `argocd` `HTTPRoute` exists;
    `kubectl get httproute -A` confirms), so the hostname has no DNS
    record at all. This is not a CIVO-075 gap — the spec's acceptance
    criterion is the one wildcard certificate's SAN set and trusted
    chain, both fully confirmed on `argo.civo.<root-domain>`; there is
    simply no second live hostname on this cluster to compare against.
  - No code defects were found in the implementation. The only issues
    encountered during verification were environmental/process gaps
    unrelated to this spec's code: the `vk-civo-lab` persistent-lifecycle
    stack (network + reserved IP) had to be created first
    (`make persistent-up`); the verification branch had to be pushed to
    `origin` and referenced via `TARGET_REVISION`, since `argo-up.sh`
    always deploys from a remote git ref rather than the local working
    tree; and `argo-up.sh`'s own idempotency fast-path guard (exits early
    when the root Application is already `Synced/Healthy`) had to be
    bypassed by re-running its underlying `helm upgrade --install
    root-application ... --server-side --force-conflicts` command
    directly (the same command the script itself would run) to re-point
    the already-up cluster at a new git revision and, later, the prod
    issuer, without a full cluster teardown/recreate each time.
