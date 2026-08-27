# Manual test plan: specs 010 + 011 — Envoy Gateway + NLB edge

Covers `gitops/templates/platform/aws/envoy-gateway/{application,gateway,httproutes,policies}.yaml`,
`gitops/templates/platform/aws/aws-load-balancer-controller/application.yaml`,
`terraform/modules/aws-lb-controller-pod-identity/`, `terraform/live/disposable/aws-lb-controller-pod-identity/`,
the `scripts/argo-up.sh`/`scripts/argo-down.sh` edits, and the metrics wiring added to
`gitops/templates/platform/aws/ebs-csi/application.yaml` and `aws-load-balancer-controller/application.yaml`.

No CI/automated test framework exists yet (specs 018/022/023 not implemented), so this is a manual checklist to
run by hand against a real cluster. Tick each box in order. Steps 5–8 are deliberately hop-by-hop, same rationale
as `009-observability.md`: each hop is independently checkable, which is also how you'd debug a broken one.

## 0. Pre-flight (already done during implementation)

- [ ] Not required to repeat unless a file below changed since implementation. Already verified: `helm template`
      of the full `gitops` umbrella chart renders with zero errors, and the vendored
      `terraform/modules/aws-lb-controller-pod-identity/iam-policy.json` was diffed byte-for-byte against AWS's
      live upstream document. If you've edited any file above since, re-run:
      ```
      helm template gitops --set target=aws >/dev/null
      ```
      Pass: exits 0, no error output.
- [ ] **Not yet done, do before first apply** — `terraform validate` never ran against
      `terraform/modules/aws-lb-controller-pod-identity` (blocked by a sandbox exec restriction during
      implementation, unrelated to the module itself):
      ```
      cd terraform/modules/aws-lb-controller-pod-identity && terraform init -backend=false && terraform validate
      ```
      Pass: `Success! The configuration is valid.`

## 1. Subnet discovery — the single most likely reason the NLB never appears

The AWS Load Balancer Controller discovers subnets to attach the NLB to via `kubernetes.io/role/elb` tags. This
account's default VPC/public subnets (persistent VPC work is deferred, spec 020) may not carry that tag.

- [ ] `aws ec2 describe-subnets --filters "Name=tag-key,Values=kubernetes.io/role/elb" --query 'Subnets[].SubnetId'`
- [ ] If empty: either tag the subnets you want the NLB in, or add an explicit `subnets`/`subnet-mappings`
      annotation to `EnvoyProxy.spec.provider.kubernetes.envoyService.annotations` in
      `gitops/templates/platform/aws/envoy-gateway/gateway.yaml` before proceeding.

Pass: at least one subnet returned, or the explicit annotation added. Do not proceed to step 3 without this —
the controller will log a subnet-discovery failure and the NLB Service will sit without an `EXTERNAL-IP`
indefinitely.

## 2. `make up` from clean — sync-wave order

- [ ] Run `make up` (or `scripts/argo-up.sh` directly) from a torn-down state.
- [ ] Watch `kubectl get applications -n argocd -w`.
- [ ] Confirm `aws-load-balancer-controller` and `ebs-csi-driver` (both wave `-5`) reach `Synced`/`Healthy` before
      `envoy-gateway` (wave `-1`), which reaches `Synced`/`Healthy` before the root-templated `GatewayClass`/
      `Gateway`/`EnvoyProxy`/`ClientTrafficPolicy` (wave `0`), before the `HTTPRoute`s/`BackendTrafficPolicy`
      (wave `2`).
- [ ] Confirm no resource ever reports a CRD-not-found error. There is deliberately no custom wait mechanism here
      (a `PreSync` hook was tried and reverted — see the plan/chat history) — this relies on the same
      `SkipDryRunOnMissingResource=true` + Argo `selfHeal`/reconciliation convergence this repo already trusts for
      Karpenter's `-4`/`-3` controller/CR split. If this step ever hangs on a `no matches for kind` error that
      doesn't self-resolve within a couple of reconciliation cycles (~3 min default), that convergence assumption
      was wrong for this case and needs revisiting — don't just add a bigger wave gap.

Pass: `kubectl get application root -n argocd -o jsonpath='{.status.sync.status}/{.status.health.status}'` prints
`Synced/Healthy`.

## 3. The NLB actually provisions

- [ ] `kubectl get svc -n envoy -l gateway.envoyproxy.io/owning-gateway-name=platform-gateway`
- [ ] Confirm it shows `TYPE: LoadBalancer` and a non-`<pending>` `EXTERNAL-IP` (an NLB hostname, not an IP).
- [ ] `aws elbv2 describe-load-balancers --query "LoadBalancers[?Type=='network']"` — find it, confirm exactly
      **one** NLB exists (cross-check against the "one load balancer" confirmation from earlier in this work —
      `grep -rn "LoadBalancer" gitops/` should still show exactly one `type: LoadBalancer` in the whole repo).
- [ ] `aws elbv2 describe-tags --resource-arns <nlb-arn>` — confirm `Project=vk-lab-platform`, `Scope=platform`,
      `Lifecycle=disposable`, `ManagedBy=aws-load-balancer-controller` all appear (from the controller's
      `defaultTags` value in `aws-load-balancer-controller/application.yaml` — not Terraform, so `ManagedBy`
      names the controller instead of constitution §16's `terraform` value).

Pass: one NLB, tagged, `EXTERNAL-IP` populated.

## 4. The certificate actually served is the real one

- [ ] `terragrunt --working-dir terraform/live/persistent/acm output -raw certificate_arn` — note the ARN.
- [ ] `kubectl get envoyproxy envoy-proxy-config -n envoy -o jsonpath='{.spec.provider.kubernetes.envoyService.annotations}'`
      — confirm the `aws-load-balancer-ssl-cert` annotation matches that exact ARN (proves the
      `argo-up.sh` → `gitops/bootstrap` → `gitops/values.yaml` → `EnvoyProxy` wiring chain actually worked end to
      end, not just that some cert got attached).
- [ ] `openssl s_client -connect <nlb-hostname>:443 -servername grafana.lab.<root-domain> </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer`
      — confirm subject/issuer show the real ACM-issued cert for `lab.<root-domain>` / `*.lab.<root-domain>`, not
      a self-signed fallback.

Pass: annotation ARN matches Terraform's output exactly; TLS handshake presents the real cert.

## 5. Argo CD serves plain HTTP with no redirect loop

This is the fix for the "SSL workaround" discussed during implementation — `configs.params."server.insecure"=true`
in `scripts/argo-up.sh`.

- [ ] `kubectl get cm argocd-cmd-params-cm -n argocd -o jsonpath='{.data}'` — confirm `server.insecure: "true"` is
      present as a real key (this was verified once already with `helm template` during implementation; this step
      re-confirms it against the actually-running ConfigMap, not just the rendered chart).
- [ ] Add a local `/etc/hosts` entry: `<nlb-ip-or-resolved-address> argo.lab.<root-domain> grafana.lab.<root-domain>`
      (resolve the NLB hostname to an IP first, e.g. `dig +short <nlb-hostname>`).
- [ ] `curl -v https://argo.lab.<root-domain>` (no `-k` needed if step 4 passed) — confirm a single `200`/`30x` to
      the actual Argo CD login page, **not** an infinite series of redirects between `http://` and `https://`.

Pass: one clean response, Argo CD's login UI reachable, no redirect loop.

## 6. Routing — both HTTPRoutes reach their backends

- [ ] `curl -sk -o /dev/null -w '%{http_code}\n' https://argo.lab.<root-domain>` → `200`.
- [ ] `curl -sk -o /dev/null -w '%{http_code}\n' https://grafana.lab.<root-domain>` → `200`.
- [ ] `curl -sk -H "Host: nonsense.lab.<root-domain>" https://<nlb-hostname>` → should **not** match either route
      (confirms hostname matching is actually discriminating, not accidentally wildcard-routing everything to one
      backend).

Pass: both real hostnames route correctly; an unmatched hostname doesn't silently fall through to one of them.

## 6a. Ad-hoc workload — a route created directly via the Kubernetes API, not GitOps

Proves the Gateway isn't hardcoded to Argo CD/Grafana: `allowedRoutes.namespaces.from: All` on
`platform-gateway` (`gateway.yaml`) must let a plain `kubectl`-applied Deployment/Service/HTTPRoute in an
unrelated namespace attach and route traffic, with no Argo Application involved.

- [ ] `kubectl create namespace smoketest`
- [ ] `kubectl -n smoketest create deployment nginx --image=nginx:alpine`
- [ ] `kubectl -n smoketest expose deployment nginx --port=80`
- [ ] Apply an `HTTPRoute` (same shape as `httproutes.yaml`, no Argo annotations needed since this isn't
      GitOps-managed):
      ```
      cat <<'EOF' | kubectl apply -f -
      apiVersion: gateway.networking.k8s.io/v1
      kind: HTTPRoute
      metadata:
        name: smoketest
        namespace: smoketest
      spec:
        parentRefs:
          - name: platform-gateway
            namespace: envoy
        hostnames:
          - "test.lab.<root-domain>"
        rules:
          - backendRefs:
              - name: nginx
                port: 80
      EOF
      ```
- [ ] Add `test.lab.<root-domain>` to the same `/etc/hosts` line used in step 5.
- [ ] `curl -sk -o /dev/null -w '%{http_code}\n' https://test.lab.<root-domain>/` → `200` (nginx welcome page).
- [ ] Confirm the existing routes still work unaffected: repeat step 6's two `curl`s.
- [ ] Confirm cross-host isolation still holds: `curl -sk -H "Host: test.lab.<root-domain>" https://<nlb-hostname>`
      returns nginx, but the argo/grafana hostnames still don't route to it (or to each other).
- [ ] Clean up: `kubectl delete namespace smoketest` (also deletes the HTTPRoute; the Gateway itself is
      untouched since it's cluster-scoped and owned by GitOps).

Pass: a workload and route created with no GitOps/Argo involvement gets a working hostname through the same
Gateway, with zero interference to the pre-existing routes; deleting it leaves everything else running.

## 7. Proxy Protocol — client IP survives the NLB hop

This is the pairing advisor flagged as load-bearing: the `EnvoyProxy` NLB annotation
(`aws-load-balancer-proxy-protocol: "*"`) and the `ClientTrafficPolicy`'s `connection.enableProxyProtocol: true`
must both be correct, or every request appears to originate from the NLB's own IP and the rate-limit test in
step 8 silently becomes a global limit shared by all clients instead of a per-client one.

- [ ] From a machine with a distinct public IP (not localhost/NAT-shared with anything else hitting the NLB),
      `curl -sk https://grafana.lab.<root-domain>/api/health` a few times, then check Envoy's access logs:
      ```
      kubectl logs -n envoy -l gateway.envoyproxy.io/owning-gateway-name=platform-gateway --tail=20
      ```
- [ ] Confirm the logged client address is your real IP, not the NLB's private IP range.

Pass: real client IP visible in Envoy's logs. If every request shows the same NLB-internal address regardless of
source, Proxy Protocol is mismatched between the two halves — re-check both settings before trusting step 8.

## 8. Rate limit policy — the `BackendTrafficPolicy` on Grafana's route

Current values (`gitops/templates/platform/aws/envoy-gateway/policies.yaml`): 20 requests/second local limit,
15s request timeout, 2 retries.

- [ ] Confirm normal, human-paced browsing of Grafana's UI never triggers a `429` (open a few dashboards, let
      auto-refresh run for a minute).
- [ ] Burst past the limit:
      ```
      for i in $(seq 1 40); do curl -sk -o /dev/null -w '%{http_code}\n' https://grafana.lab.<root-domain>/ & done; wait
      ```
- [ ] Confirm at least some responses come back `429`.
- [ ] Confirm the **Argo CD** route is unaffected by the same burst (no policy attached there, by design — see
      chat history for why) — repeat the burst against `argo.lab.<root-domain>` and confirm no `429`s.

Pass: Grafana 429s under burst, normal use doesn't; Argo CD never 429s under any load.

## 9. Timeout/retry policy — a genuinely slow/dead backend

- [ ] `kubectl scale deployment kube-prometheus-stack-grafana -n observability --replicas=0`
- [ ] `time curl -sk -o /dev/null -w '%{http_code}\n' https://grafana.lab.<root-domain>/`
- [ ] Confirm the request fails (`503`/`504`) within roughly the configured `requestTimeout` (15s) plus retry
      overhead — not hanging indefinitely, and not failing instantly without attempting the configured 2 retries.
- [ ] `kubectl scale deployment kube-prometheus-stack-grafana -n observability --replicas=1` to restore it.
- [ ] Wait for the pod to become `Ready` again, confirm step 6's Grafana check passes again.

Pass: bounded failure time matching the configured timeout/retry, not a hang; full recovery after scaling back up.

## 10. Telemetry — metrics actually reach Prometheus

- [ ] `kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090`, open
      `http://localhost:9090/targets`.
- [ ] Confirm these pools all show `UP`, with zero scrape errors:
      - `serviceMonitor/envoy/envoy-gateway/0` (control plane)
      - `podMonitor/envoy/envoy-proxy/0` (data plane, `/stats/prometheus`)
      - `serviceMonitor/kube-system/aws-load-balancer-controller/0` (chart-native `serviceMonitor.enabled: true`)
      - `serviceMonitor/kube-system/aws-ebs-csi-driver-controller/0` and the `node` DaemonSet equivalent
        (chart-native `enableMetrics`/`serviceMonitor.forceEnable: true` — confirm the exact target names in the
        UI, since this was the first time these two flags were exercised in this repo)
- [ ] Query `envoy_http_downstream_rq_total` in the **Graph** tab — confirm non-zero values after steps 6–9's
      traffic.

Pass: all four target pools `UP`; the Envoy request-count query returns real data.

## 11. Logs — confirm they reach Loki (should need zero extra wiring)

Alloy is a cluster-wide log collector with no namespace filter (`gitops/templates/platform/aws/observability/alloy.yaml`)
— every pod's logs should already be flowing, without anything added for this spec.

- [ ] Grafana → Explore → Loki datasource: `{namespace="envoy"}` — confirm both the Envoy Gateway control-plane
      pod's and the Envoy proxy data-plane pod's logs appear, including access log lines from steps 6–9's traffic.
- [ ] `{namespace="kube-system", container="aws-load-balancer-controller"}` — confirm reconcile logs from NLB
      provisioning (step 3) appear.

Pass: both queries return recent, relevant log lines with no additional configuration.

## 12. `make down` — the NLB is actually gone before EKS teardown (the critical check)

This is the gap fixed in `scripts/argo-down.sh`: the root Application's cascade `--wait` only blocks on
Argo-tracked resources, and the `Service` Envoy Gateway's controller creates isn't one — so this step doesn't
just confirm the script exits 0, it confirms the thing the fix was actually for.

- [ ] `make down` (or `scripts/argo-down.sh` directly) — watch its output for the
      `"ARGO-DOWN: waiting on Envoy-managed NLB Service..."` lines. Confirm it does **not** exit until it prints
      `"ARGO-DOWN: Envoy-managed NLB Service confirmed gone."`
- [ ] Immediately after the script exits: `aws elbv2 describe-load-balancers --query "LoadBalancers[?Type=='network']"`
      — confirm zero results (the NLB from step 3 is gone, not still mid-deletion).
- [ ] `aws ec2 describe-network-interfaces --filters "Name=description,Values=*ELB*"` — confirm no leftover ENIs
      referencing a now-deleted NLB.
- [ ] Only after both checks pass, confirm disposable Terraform (`cluster-down` inside `make down`) proceeded to
      tear down EKS without an AWS-side dependency error.

Pass: script's explicit wait actually engaged and completed before exit; NLB and its ENIs confirmed gone via the
AWS API, not just inferred from the script's exit code.

## 13. `make up` again — full recreation

- [ ] `make up`.
- [ ] Repeat steps 1–6 (subnet discovery still passes since it's account-level, not disposable; NLB re-provisions;
      cert re-attaches from the same persistent ARN; Argo CD/Grafana routing works again).
- [ ] Confirm the ACM certificate ARN is identical to step 4's (persistent stack untouched by any of this).
- [ ] Confirm the NLB's hostname is a **new** one (a fresh NLB, not the deleted one) — update your local
      `/etc/hosts` entry accordingly.

Pass: full recreation with no manual `kubectl apply`, persistent cert/zone untouched throughout.
