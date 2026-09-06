# 033 — LBC Webhook Cert Churn and the Workarounds Built Around It

**Status:** Partially implemented — requirement 1 landed; requirements 2–5 open.

**Complexity:** Small to implement, Medium to decide — the hard part is choosing
one solution and deleting the rest, not writing it.
**Risk:** Medium — touches the admission path every `type: LoadBalancer` Service
crosses, on the critical path of every `make up`. No AWS resource is created or
destroyed by the change itself.
**Estimated cost:** ~0.5 day plus one cold `make up`/`make down` acceptance
cycle · AWS runtime cost: one disposable cluster's usual spend.
**Recommended model:** Sonnet for the edits. The diagnosis below was expensive
to obtain; do not re-derive it.
**Depends on:** ADR 0025 (the retry-over-gates decision this partly falsifies),
ADR 0012 (Argo CD bootstrapped by a script), spec 010 (Envoy Gateway), spec 011
(NLB edge), spec 032 (bootstrap resilience).
**Lifecycle class(es) touched:** Disposable only.

## Why this spec exists

Three separate mechanisms in this repo exist to work around one defect that was
never correctly identified:

1. the `envoy-gateway-webhook-probe` Sync hook Job (`gitops/templates/platform/
   aws/envoy-gateway/webhook-ready-probe.yaml`), with a 480s in-pod budget;
2. the `root` Application's `syncPolicy.retry` budget of 10 (ADR 0025);
3. a `Gateway` health-check override in `gitops/argocd/values.yaml`.

Each was added after a bootstrap failure, each addressed a symptom, and none
addressed the cause. This spec records the cause, so the workarounds can be
removed rather than added to. **The default answer to a recurrence of this
failure is not another gate.**

## The actual defect

Two independent problems compound. Only the first is fixable in this repository.

### D1 — the LBC chart mints a new CA on every render, and the pod is never rolled

Chart `aws-load-balancer-controller` 1.13.0, `templates/_helpers.tpl`, chooses a
webhook cert in three branches: pinned `webhookTLS.*` values; else reuse of the
live Secret via `lookup` when `keepTLSSecret` is set; else `genCA` + a freshly
signed cert. The chart ships `keepTLSSecret: true`, but **Argo CD renders Helm
client-side with no cluster access, so `lookup` always returns nil and the reuse
branch is unreachable.** Every render therefore produces a new CA, written into
both the `kube-system/aws-load-balancer-tls` Secret and the `caBundle` of all
six webhook entries. The Deployment spec does not change, so Argo does not roll
the pod.

The result is a window in which the API server advertises a new CA while the
running controller still serves a certificate signed by the old one. Every
admission call against `mservice.elbv2.k8s.aws` in that window fails with
`x509: certificate signed by unknown authority`.

The window is **transient, not permanent**: the Secret is mounted as a whole
directory with no `subPath`, so kubelet's projection updates the file and
controller-runtime's certwatcher reloads it, bounded by the kubelet secret sync
period. This is precisely why a readiness probe can pass and a consumer can
still fail minutes later.

Evidence, measured on `vk-lab-ci-test-eks` during the 2026-09-06 incident:

| Fact | Value |
|---|---|
| `aws-load-balancer-tls` `ca.crt` notBefore | `2026-09-06T23:23:03Z` |
| LBC pod start / restart count | `2026-09-06T22:41:51Z` / **0** |
| Argo app sync history | one entry, revision `1.13.0`, `22:41:54Z` |

Same chart revision, two CAs 41 minutes apart, no pod restart.

**What drives the re-renders:** `argocd-application-controller-0` was OOMKilled
(exit 137) under `limits.memory: 768Mi`. Each restart re-syncs every
Application, and the LBC app was observed going Synced → OutOfSync → Synced at
`23:23:05Z` on an unchanged revision. Any event that provokes a re-render —
controller restart, repo-server restart, manifest cache expiry — opens a new
window.

### D2 — envoy-gateway drops the error and never retries

Envoy Gateway's infrastructure runner calls `CreateOrUpdateProxyInfra`, and on
error logs it and pushes it into an error channel that is drained into a log
line and a metric. There is no requeue, no re-delivery of the failed key, and no
periodic resync. The callback runs again only when a new IR value lands (i.e.
some Gateway API spec actually changes) or the process restarts. A rejected
admission call changes no spec, so nothing re-drives it. This is unchanged from
v1.2.1 through current `main`.

Consequence: a transient D1 window becomes a permanent wedge. The proxy
`Service` is never created, the `Gateway` stays `Programmed=False`, and only
`kubectl rollout restart deployment/envoy-gateway` recovers it.

The contrast that proves D2 is the durable defect: LBC's own
`mtargetgroupbinding` webhook has the same `failurePolicy: Fail` and the same
cert, and its path does **not** wedge — because LBC is a controller-runtime
reconciler that requeues on error.

**No upstream issue was found fixing the infra-apply retry path.** Do not book
an Envoy Gateway version bump as the fix for this.

## Why the existing workarounds cannot work

- **The probe Job.** It proves the webhook answered at time T. D1 makes the
  property non-monotonic, so a later render invalidates the proof while the
  consumer's create is a separate, later, un-retried event. This is TOCTOU by
  construction. ADR 0025 kept the probe "for instance 3 alone"; the 2026-09-06
  incident is instance 3 recurring **with the probe in place and passing in
  three seconds**. Widening its budget cannot help.
- **`root`'s retry budget.** Retry re-runs a *sync*. It re-applies a `Gateway`
  that is already present and unchanged, producing no new IR value, so it cannot
  un-wedge envoy-gateway. The budget was observed reaching 8 of 10.
- **Sync waves.** They gate on child Application objects being *created*, not on
  the controllers inside them being healthy: a resource with no registered
  health check is marked succeeded the instant it is applied, and Argo CD ships
  no health assessment for `argoproj.io/Application`. Adding
  `resource.customizations.health.argoproj.io_Application` would make waves gate
  on child health — a legitimate improvement on its own merits, but it would
  only have delayed the Gateway apply, and the cert can rotate at any later
  moment regardless.
- **The `Gateway` health-check override.** Argo CD has shipped a built-in
  `Gateway` health check since v3.1.0; the cluster runs v3.5.1, so
  `gitops/argocd/values.yaml` overrides a built-in rather than filling the gap
  its comment claims. The override returns `Degraded` where the built-in returns
  `Progressing`, which is what made the failure fail fast and loudly instead of
  hanging for the full watch budget. That is arguably the better behaviour, but
  it reports; it does not remediate.

## Requirements

1. **Stop the cert churn.** The LBC Application MUST NOT re-apply the webhook
   certificate material on re-render. Implemented: `ignoreDifferences` covering
   the `aws-load-balancer-tls` Secret's `/data` and the `caBundle` of both the
   Mutating and Validating webhook configurations. This is the only measure that
   covers all six webhook entries, including the `mtargetgroupbinding` webhook
   that carries a hardcoded `failurePolicy: Fail` and no object selector.
2. **Remove the admission call from the Service-create path.** Evaluate
   `enableServiceMutatorWebhook: false`. The mutator exists only to set
   `spec.loadBalancerClass` on Services that did not opt in; this platform's one
   `type: LoadBalancer` Service already carries
   `service.beta.kubernetes.io/aws-load-balancer-type: external`, which both
   makes the in-tree cloud provider skip it and makes LBC claim it. Note
   `spec.loadBalancerClass` is immutable once set, so this is a change for a
   fresh disposable cluster, not an in-place edit.
3. **Size the application controller against the current Application count.**
   Its memory limit MUST be set from a measured figure rather than left at a
   value that OOMKills, since every OOM restart re-renders every Application and
   burns `root`'s retry budget mid-sync.
4. **Delete the webhook probe** once requirements 1 and 2 hold, including its
   ServiceAccount, Role and RoleBinding. The `envoy` Namespace object that file
   currently provides at wave -3 MUST be re-homed first — envoy-gateway's own
   Application creates it via `CreateNamespace=true`, which is too late for the
   resources that need it.
5. **Decide the `Gateway` health-check override deliberately.** Either keep it
   and record why `Degraded` is preferred over the built-in's `Progressing`, or
   drop it and accept upstream semantics. Its current justifying comment is
   factually wrong and MUST be corrected either way.

## The research this spec asks for

Requirements 1–5 are a set of mitigations, which is the shape this spec exists
to warn against. Before implementing 2–5, determine whether **one** change makes
the rest unnecessary. Specifically:

- Does pinning `webhookTLS.caCert/cert/key` deterministically — sourced the way
  this repo already handles committed KMS ciphertext — remove D1 entirely and
  make requirements 1, 3 and 4 moot? What is the real cost of a long-lived
  private key in the repository, given it protects only an in-cluster admission
  endpoint on a disposable cluster?
- Does `enableCertManager: true` become the right answer if cert-manager is
  wanted for other reasons, or does it merely relocate the bootstrap-cert
  problem one Application lower?
- Is there an upstream fix or configuration for D2 that was missed? The search
  performed found none for the infra-apply retry path.

The outcome MUST be a single mechanism plus the deletion of the workarounds it
replaces, recorded as an ADR. Adding a fourth workaround alongside the existing
three is an explicit non-goal.

## Testing / acceptance criteria

- A cold `make up` followed by forcing at least two re-syncs of the LBC
  Application (for example by restarting `argocd-application-controller`) leaves
  `aws-load-balancer-tls`'s `ca.crt` notBefore unchanged and the webhook
  `caBundle` matching it.
- Creating a `type: LoadBalancer` Service immediately after such a re-sync
  succeeds, rather than failing with `x509: certificate signed by unknown
  authority`.
- `Gateway/platform-gateway` reaches `Programmed=True` on a cold `make up`
  without any manual `rollout restart`, across three consecutive runs.
- `root` completes its sync with a `retryCount` well below its limit; a count
  near the limit means the budget is marginal and the underlying cause is not
  fixed.
- After requirement 4, no `envoy-gateway-webhook-probe` resources exist and the
  `envoy` Namespace is still created early enough for the resources that need
  it.
