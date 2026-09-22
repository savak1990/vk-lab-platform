---
id: "HETZ-070"
title: "TLS and DNS on Hetzner: wildcard DNS-01 certificate, ExternalDNS following a dynamic LB address, TLS Secret persistence"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Every mechanism exists from CIVO-070/075/110; the work is verifying it under a changing LB address and recording the timings"
effort_estimate: "Half a session (3–4 h) plus two real cycles"
estimate_confidence: "medium"
depends_on: ["HETZ-060", "HETZ-085", "CIVO-075", "CIVO-110"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: ""
---

# HETZ-070 — TLS and DNS on Hetzner

## 1. Outcome and rationale

Envoy on Hetzner serves one Let's Encrypt certificate for
`hz.<root-domain>` and `*.hz.<root-domain>`, issued through the
DNS-01 solver with the cert-manager Roles Anywhere consumer. ExternalDNS
writes the A records for the hostnames into the `hz.<root-domain>`
zone with owner `vk-hetzner-lab`. The TLS Secret survives `make down` and
`make up` through SSM, so a rebuilt cluster orders no new certificate.
Hetzner starts at the Civo end state (CIVO-075): HTTP-01 is never used,
because the LB address changes on every `make up` and HTTP-01 would wait
on DNS propagation before every issuance.

## 2. Scope and non-goals

In scope: the TLS Secret round-trip under the hetzner SSM path, the
ExternalDNS behaviour with a new LB address, the measured `wait_for_dns`
timings, and the switch to `letsencrypt-prod`. Not in scope: the identity
chain (HETZ-085), the LB itself (HETZ-060), the AWS and Civo targets.

**Narrowed by HETZ-060 (2026-09-22).** The HTTPS:443 listener and the
ExternalDNS records were both going to arrive here. Neither could wait:
every HTTPRoute the Gateway enables names a `sectionName`, two of them
`https`, and a route whose listener is missing is never Accepted, which
stalls the root sync behind its health check. So HETZ-060 shipped both
listeners, and because ExternalDNS sources `gateway-httproute`, the DNS
records with them. What is left here is the persistence and the
measurements, not the plumbing.

## 3. Current state / evidence

- CIVO-075 (DONE): `ClusterIssuer letsencrypt-{staging,prod}` with `dns01.route53 {region: eu-west-1, hostedZoneID: <value>}`, `Certificate platform-public` with the wildcard pair at wave 2, `cert-manager-ra-cert` sidecar via `extraContainers`, role `${project}-ra-cert-manager` limited to TXT changes on the project zone. CIVO-070's SSM Secret round-trip proved the same serial after `make down`/`make up`.
- CIVO-110 (DONE): ExternalDNS in `shared/`, `txtOwnerId` values-driven, `gateway-httproute` source, sidecar on non-AWS targets.
- After HETZ-016 the TLS files live under `shared/tls/` gated on `platform.selfManaged`, and the export/import functions read `/${project}/persistent/${PROVIDER}/tls/platform-public` (SSM Advanced `SecureString`, 8192-char limit; prod chain measured at 7390 chars on Civo).
- HETZ-085 issues `cert-manager-ra-cert` with CN `vk-hetzner-lab-hetzner-cert-manager`; HETZ-080 creates the matching role and `bootstrap/route53` writes `zone_id`.
- HETZ-060: the LB IP is new per `make up`; `argo-up` compares DNS with the discovered IP.

## 4. Design and contracts

- No new template. The hetzner render must contain `ClusterIssuer letsencrypt-staging`, `letsencrypt-prod`, `Certificate envoy/platform-public` with `dnsNames: [hz.<root>, *.hz.<root>]`, the redirect `HTTPRoute`, and `Certificate cert-manager/cert-manager`. `gitops-render-check.sh` requires them for hetzner (HETZ-050 set).
- The Gateway HTTPS:443 listener landed in HETZ-060, sharing Civo's `platform.envoyListeners` arm rather than gaining a hetzner one. It therefore carries **no** `hostname: "*.{{ .Values.envoyGateway.fqdn }}"`, which this bullet previously promised: the certificate is a wildcard and every HTTPRoute carries its own hostnames, so the listener needs no host constraint. This is what Civo has run since CIVO-070. `cert-manager.io/issue-temporary-certificate: "true"` on the Certificate stays, so the listener programs before the first order completes.
- ExternalDNS: `domainFilters: [hz.<root>]`, `txtOwnerId: vk-hetzner-lab`, `policy: sync`, `--interval 1m`. Route 53 record TTL is ExternalDNS's default 300 s. After `make up` the A record moves to the new LB IP within one interval plus the TTL, so the first `wait_for_dns` window (60 s, non-fatal) usually reports "not yet resolved"; this spec measures the real time and sets `HETZNER_ARGO_UP_DNS_WATCH_SECONDS` to the measured value plus margin if it is under 5 min. HETZ-060 set the initial default to 300 s; this spec replaces that guess with the measurement.
- Because DNS-01 needs no application record, issuance and DNS are independent: a fresh cluster obtains the certificate from SSM (round-trip) or orders one through TXT records while the A records are still stale. HTTP-01 is not configured on hetzner and never will be.
- Lab uses `letsencrypt-prod`; CI uses `letsencrypt-staging` with `E2E_INSECURE_TLS=1` (HETZ-140), identical to Civo.
- `argo-down` exports the Secret before the cascade; `argo-up` imports it before the root install; the Secret name `platform-public-tls` in namespace `envoy` is unchanged, so cert-manager adopts it and reissues only when `dnsNames` differ.

## 5. Files/components affected

`scripts/argo-up.sh` (the measured DNS watch default for hetzner),
`scripts/lib/provider.sh` and `scripts/argo-down.sh` (the TLS Secret
export and import on the hetzner SSM path). `gateway.yaml` and
`gitops-render-check.sh` were changed by HETZ-060. Everything else is
consumed as-is.

## 6. Implementation steps

1. Confirm HETZ-060's render is unchanged: `make gitops-check`. The HTTPS listener itself landed there.
2. Run `PROVIDER=hetzner TLS_ISSUER=letsencrypt-staging make up`. Watch `kubectl get challenge -A`: `type: DNS-01`, `state: valid`. `Certificate platform-public` Ready. Record the time from Service IP to Ready.
3. Watch Route 53: `aws route53 list-resource-record-sets --hosted-zone-id <id>` shows `argo.hz.<root>` A = LB IP and the `TXT` owner record with `vk-hetzner-lab`. Record the time from LB IP to record update.
4. Run `make down` then `make up`. `kubectl get order -A` is empty; the serial is unchanged; the A record moves to the new IP; measure the delay and confirm `curl https://argo.hz.<root>/` succeeds once it moves.
5. Negative tests with the cert-manager sidecar credentials: an A-record change on the hetzner zone is denied; any change on the civo zone is denied.
6. Switch to `letsencrypt-prod`. `curl -sv https://argo.hz.<root>/` verifies without `--insecure`.

## 7. Dependencies and blockers

HETZ-060 (Gateway and LB), HETZ-085 (the cert-manager consumer certificate
and sidecar on hetzner), CIVO-075 and CIVO-110 for the components.

## 8. Acceptance criteria

- `openssl s_client -servername argo.hz.<root-domain>` shows SANs exactly `hz.<root-domain>` and `*.hz.<root-domain>`.
- The challenge is DNS-01; no solver `HTTPRoute` exists.
- ExternalDNS rewrites the A record to the new LB IP after `make up`; the measured delay is recorded and is under 10 min.
- `make down`/`make up` creates no new `Order`; the serial is unchanged.
- The cert-manager role denies A-record changes and any change outside the hetzner zone.
- The AWS and Civo golden diffs are empty.

## 9. Validation

Offline: golden diffs, kubeconform. Real cloud: two Hetzner cycles (about
0.40 EUR). Route 53 API calls are free. Staging issuer until step 6.

## 10. AWS regression protection

Only the hetzner block of `gateway.yaml` and a hetzner default in
`argo-up.sh` change. Golden diffs for aws and civo stay empty. The Civo
TLS round-trip path is unchanged by construction (HETZ-016 parametrised it
by `PROVIDER`); run one Civo `argo-down`/`argo-up` and confirm the serial
is unchanged there too.

## 11. Rollout and rollback/recovery

Revert; the HTTPS listener disappears and HTTP:80 keeps serving. Delete
the SSM TLS parameter to force a fresh order if the stored Secret is
wrong. Data risk: none.

## 12. Risks and unresolved questions

- Stale DNS between `argo-down` and the next `make up` is unavoidable without a fixed address; the TTL bounds it. A lower TTL (60 s) through ExternalDNS's `--aws-... ttl` annotation is the knob if the measured delay is too long.
- Let's Encrypt rate limits: the SSM round-trip protects prod; CI uses staging. A rebuilt project (new bucket, no SSM parameter) orders once.
- The cert-manager controller pod starts before its own consumer certificate exists (CIVO-075 observed 7 sidecar restarts in 90 s); expected, self-heals.
- ExternalDNS `policy: sync` deletes records it owns when the Gateway disappears; `argo-down`'s Route 53 wait relies on this.
- Dual A records (LB IPv6) would appear if `ipv6-disabled` were dropped in HETZ-060; keep it.

## 13. Definition of done

- [ ] Evidence for staging and prod, down/up without a new order, DNS delay measured
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-22 — narrowed by HETZ-060. The HTTPS listener and ExternalDNS
  arrived there instead, for the reason in §2. §4's promised
  `hostname: "*.<fqdn>"` on the listener is deliberately absent: hetzner
  shares Civo's listener arm, and a per-target arm to add one constraint
  that a wildcard certificate and per-route hostnames already cover is
  duplication, not precision. §5 and §6 step 1 are corrected.

- 2026-09-22 — two findings from HETZ-060's live cycle, both narrowing this
  spec's remaining work.

  **The SSM round-trip already works on this target, and §8's "no new Order"
  criterion needs a condition attached.** `argo-up` restored
  `platform-public-tls` from SSM before the root install and reported the
  stored certificate's not-after date, so the mechanism HETZ-016 parametrised
  is live on hetzner with no further code. But the run passed
  `TLS_ISSUER=letsencrypt-staging` over a Secret issued by
  `letsencrypt-prod`, and cert-manager said exactly what that costs:

  ```
  Ready=False: Issuing certificate as Secret was previously issued by
    "ClusterIssuer.cert-manager.io/letsencrypt-prod"
  ```

  A full DNS-01 order followed and held the root sync for about ten of
  `argo-up`'s sixteen minutes. So the criterion holds only when the issuer is
  unchanged between cycles; state that, rather than leaving a future run to
  discover it. Alternating issuers costs a reissue **every** cycle, because
  `argo-down` exports whichever certificate is current - this teardown stored
  the staging one, so the next default `letsencrypt-prod` bring-up will
  reissue again.

  **The exported chain is 7713 characters.** §3 records Civo's prod chain at
  7390 against SSM Advanced's 8192-character limit. The staging chain is
  longer and leaves roughly 480 characters of headroom. Worth measuring the
  prod chain on this target too, and deciding whether the margin is
  acceptable before a chain change consumes it.

  One transient worth knowing about on a rebuilt project: the first DNS-01
  attempt failed its self-check with
  `SERVFAIL` querying the zone's SOA through cluster DNS, because the run had
  recreated the Route 53 zone minutes earlier and the delegation had not
  propagated to the nodes' resolver. The TXT record was already correct in
  Route 53 and public resolvers answered it. cert-manager's own retry cleared
  it with no intervention. Not a defect, but it explains a multi-minute
  stall that looks like one.