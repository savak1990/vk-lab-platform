---
id: "HETZ-165"
title: "argo-up creates the long-lived kubeadm join credential for autoscaled nodes: token, CA hash, rendered cloud-init in kube-system/hcloud-autoscaler"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "A Secret with three derived values and one cloud-init template; the judgement is in what the token may do"
effort_estimate: "Half a session (2–3 h)"
estimate_confidence: "medium"
depends_on: ["HETZ-037", "HETZ-045"]
blocked_by: []
supersedes: []
created: "2026-09-19"
updated: "2026-09-20"
completed: ""
---

# HETZ-165 — kubeadm join credential for autoscaled nodes

## 1. Outcome and rationale

An autoscaled worker joins the cluster with `kubeadm join`, which needs a
bootstrap token and the CA certificate hash; neither exists once the
fixed nodes are up, and the default token dies after 24 h, which the
autoscaler cannot renew itself. `argo-up` creates a `--ttl 0` token once
and stores it with the CA hash and the rendered join cloud-init in
`kube-system/hcloud-autoscaler`, which HETZ-170's cluster autoscaler
reads. The token grants node join only — it is not the Hetzner API
token, which is a separate Secret (HETZ-045).

## 2. Scope and non-goals

In scope: `ensure_autoscaler_secret()` in `scripts/argo-up.sh`, the
`kube-system/hcloud-autoscaler` Secret's three keys, and the cross-spec
edit this design forces on HETZ-030 — a §14 history line recording that
`templates/node.yaml.tftpl` is also rendered by this spec, and the
substitution-friendly constraint that places on that template, added in
the same commit as this spec's creation.

Not in scope: HETZ-170's autoscaler Application itself, which consumes
this Secret; HETZ-030's node cloud-init template
content, beyond keeping it substitution-friendly for this spec's own
render; `hetzner_ssh`, `cluster_exists` and
the kubeadm bootstrap/join mechanics on the fixed nodes, which HETZ-035
and HETZ-040 already own; an HA control plane, which would change the
`10.0.1.10:6443` endpoint this spec's rendered join line hard-codes
(decisions.md §3, Control-plane topology); any rotation automation
beyond the manual steps this spec documents.

## 3. Current state / evidence

- HETZ-045 §4 places the hook: `ensure_autoscaler_secret()` runs
  immediately after `wait_for_nodes_initialized()`, before
  the fast path returns, and is the consumer of the `worker_ips` /
  `control_plane_private_ip` SSM reads that batch grew to carry.
- research.md, "Bootstrap tokens" row: default TTL 24 h; `kubeadm token
  create --ttl 0` never expires; CA hash `openssl x509 -pubkey -in
  /etc/kubernetes/pki/ca.crt | openssl pkey -pubin -outform der | openssl
  dgst -sha256 -hex`.
  https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-token/
  ; https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-join/
- research.md, "hcloud CCM name matching" row: the CCM looks up a node by
  `spec.providerID`, falling back to the node name against the Hetzner
  server name; a kubelet joined without `cloud-provider=external` never
  gets a `providerID` (hccm issue #267). The autoscaler's own server name
  is `<pool>-<hex>`, which becomes the node's hostname automatically, so
  this fallback holds without any extra flag in the join line.
  https://github.com/hetznercloud/hcloud-cloud-controller-manager/blob/main/hcloud/instances.go
  ; https://github.com/hetznercloud/hcloud-cloud-controller-manager/issues/267
- research.md, "Cluster autoscaler `cloudProvider: hetzner`" row:
  `HCLOUD_CLUSTER_CONFIG` is base64 JSON carrying
  `nodeConfigs.<pool>.cloudInit` as its own base64 field; the upstream
  cloud-init example in that README is obsolete (Kubernetes 1.20, Docker
  runtime) and is not a source to copy from — this spec's cloud-init is
  built from HETZ-030's own template instead.
  https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/hetzner/README.md
- HETZ-030 §4 builds two cloud-init templates. The control plane's own,
  `templates/control-plane.yaml.tftpl`, is irrelevant here; the worker
  one, `templates/node.yaml.tftpl`, installs `containerd.io`, `kubeadm`,
  `kubelet`, `kubectl` and the kernel prerequisites only — no join token,
  no cluster state — and caps the rendered size at 32 KiB. That "package-install only" property is
  exactly why the same file is reusable for an autoscaled node: this
  spec reads it straight from the checkout `argo-up` already runs in,
  substitutes the same `${kubernetes_version}` and `${containerd_version}`
  placeholders Terraform fills via `templatefile()`, and appends a join
  `runcmd` block rather than maintaining a second template. HETZ-030's
  own `templatefile()` call still owns the fixed-node render; this spec
  never calls Terraform and never touches `terraform/live/`.
- This spec carries the rendered cloud-init through the repo checkout
  and the Kubernetes Secret only — no SSM parameter is in the path
  between the template and the autoscaler's node.
- HETZ-020 §4 item 5 (spike checklist, autoscaler-style join): a
  hand-created third node, cloud-init built from the same packages plus
  `kubeadm join` using a `--ttl 0` token, with
  `KUBELET_EXTRA_ARGS=--cloud-provider=external --node-ip=<metadata
  private ip>`, must join, get a `providerID`, and become `Ready`; from a
  `hostNetwork` pod on it, `curl 169.254.169.254/hetzner/v1/userdata`
  reads the cloud-init back, including the token — the metadata service
  exposes `metadata/private-networks` for the node's own private address
  (research.md, "Metadata service" row) and `/userdata` for the rendered
  cloud-init verbatim, unauthenticated to any process on that node.
- decisions.md §3, "Autoscaler credential" row: M1 decision is `argo-up`
  creates `kube-system/hcloud-autoscaler` with a `--ttl 0` bootstrap token
  and the CA hash; the token grants node join only; the join token is
  readable from the metadata service on autoscaled nodes only — the fixed
  nodes' `user_data` holds no secret, because HETZ-030 renders theirs
  before any token exists.

## 4. Design and contracts

- `ensure_autoscaler_secret()` in `scripts/argo-up.sh`, hetzner-only,
  called immediately after `wait_for_nodes_initialized()` returns and
  before the fast-path exit, per HETZ-045 §4's placement.
- Idempotence: if `kube-system/hcloud-autoscaler` exists, read its
  `token` key and run `hetzner_ssh <cp> kubeadm token list` on the
  control plane; if that token is still listed, keep the Secret unchanged
  and return. The comparison never echoes the token value to the
  script's own stdout, and the whole block is masked under
  `GITHUB_ACTIONS` like every other Hetzner credential.
- Otherwise: `TOKEN=$(hetzner_ssh <cp> kubeadm token create --ttl 0
  --description autoscaler)`; `HASH=$(hetzner_ssh <cp> 'openssl x509
  -pubkey -in /etc/kubernetes/pki/ca.crt | openssl pkey -pubin -outform
  der | openssl dgst -sha256 -hex | sed "s/^.* //"')`.
- Cloud-init render: `ensure_autoscaler_secret()` reads
  `terraform/modules/hcloud-nodes/templates/node.yaml.tftpl` directly
  from the checkout `argo-up` already runs in — no SSM parameter, no new
  Terraform output. The template's placeholders are the
  Terraform variable names `${kubernetes_version}` and
  `${containerd_version}`, so the script exports
  `kubernetes_version="$KUBERNETES_VERSION"` and
  `containerd_version="$CONTAINERD_VERSION"` from
  `scripts/lib/versions.sh`'s pins — the same values Terraform receives
  as `TF_VAR_kubernetes_version`/`TF_VAR_containerd_version` — and runs
  `envsubst '${kubernetes_version} ${containerd_version}'`, restricted to
  those two names so an unrelated `$`-sequence elsewhere in the template
  is never touched. It then appends one final
  `runcmd` block to the substituted text: first
  `echo "KUBELET_EXTRA_ARGS=--cloud-provider=external --node-ip=$(curl
  -sf http://169.254.169.254/hetzner/v1/metadata/private-networks | awk
  '/ip:/{print $2; exit}')" > /etc/default/kubelet` — the `awk` pattern
  is this spec's assumption about the `private-networks` metadata
  response shape; HETZ-020 §4 item 5 is the checklist item that confirms
  or corrects it against a real response, not yet run — then `kubeadm
  join 10.0.1.10:6443 --token $TOKEN --discovery-token-ca-cert-hash
  sha256:$HASH --node-name "$(hostname)"`. The control-plane endpoint is
  the fixed private IP HETZ-035 initialised with, not a variable this
  spec resolves itself.
- Write the Secret: `kubectl create secret generic
  hcloud-autoscaler -n kube-system --from-literal=token="$TOKEN"
  --from-literal=ca_hash="$HASH" --from-literal=cloud_init="$RENDERED" \
  --dry-run=client -o yaml | kubectl apply -f -` — piped, never through a
  temp file, never echoed.
- Size guard: Hetzner's `user_data` cap is 32 KiB per server (HETZ-030
  §3), and this spec's own render — the substituted template plus the
  appended `runcmd` block — is the value that ends up there once the
  autoscaler hands it to a new server. `ensure_autoscaler_secret()`
  measures the rendered file with `wc -c` before writing the Secret and
  fails with a clear message ("rendered cloud-init exceeds the 32 KiB
  Hetzner user_data limit") when the count exceeds 32768, rather than
  writing a Secret the autoscaler cannot actually use.
- Rotation: `kubectl delete secret hcloud-autoscaler -n kube-system`,
  then `hetzner_ssh <cp> kubeadm token delete <old-token-id>`, then a
  fresh `argo-up` — never delete the cluster-side token before the
  Secret, or an in-flight autoscaler scale-up reads a token that no
  longer exists.

## 5. Files/components affected

`scripts/argo-up.sh` (`ensure_autoscaler_secret`, which reads
`terraform/modules/hcloud-nodes/templates/node.yaml.tftpl` as a plain
file, not a Terraform output); `specs/hetzner/030-P-hetzner-terraform-kubeadm-nodes/spec.md`
(§14 history — the cross-spec edit recording that the template is also
rendered by this spec and must stay substitution-friendly).

## 6. Implementation steps

1. Add the HETZ-030 §14 line recording the template's dual use (this
   commit).
2. Write `ensure_autoscaler_secret()`: token, hash, the template
   read/substitute/append render with its `wc -c` size guard, Secret
   write.
3. Run `PROVIDER=hetzner make argo-up` on the HETZ-045 baseline; confirm
   the Secret's three keys and `kubeadm token list` shows the new token
   with `<forever>`.
4. Hand-create one `cx33` from the decoded `cloud_init` key (§8); confirm
   it joins, gets a `providerID`, and reaches `Ready`.
5. Run `argo-up` again; confirm the same token is kept and no new
   `kubeadm token create` call happens.

## 7. Dependencies and blockers

HETZ-037 supplies the Ready, Cilium-networked nodes this design assumes
already exist before the CCM gate. HETZ-045 supplies
`wait_for_nodes_initialized()`, the call site immediately after it, and
the CCM-initialised nodes with `providerID` set. `hetzner_ssh` and
`cluster_exists` (HETZ-040) and the `templates/node.yaml.tftpl` file
itself (HETZ-030) arrive transitively through those two, the same way
HETZ-047 §7 describes its own transitive dependencies, and are not
listed as direct dependencies here.

## 8. Acceptance criteria

- After `argo-up`, `kube-system/hcloud-autoscaler` exists with keys
  `token`, `ca_hash`, `cloud_init`.
- `hetzner_ssh <cp> kubeadm token list` shows the token with usage
  `<forever>`.
- One hand-created node —
  `hcloud server create --type cx33 --location nbg1 --image
  ubuntu-24.04 --network <id> --user-data-from-file <decoded cloud_init>
  --label project=<p> --label scope=platform --label managed_by=autoscaler
  --name workers-test` — joins, gets a `providerID`, and becomes `Ready`
  within 5 minutes.
- `PROVIDER=hetzner make cluster-down` sweeps that hand-created server
  before the Terraform destroy (HETZ-040's label-based sweep).
- A second `argo-up` keeps the same token; `kubeadm token list` is
  unchanged.
- `ensure_autoscaler_secret()` measures its rendered cloud-init with
  `wc -c` and aborts with a clear message, writing no Secret, when the
  count exceeds 32768 (tested once by forcing an oversized render, then
  reverted).

## 9. Validation

Offline: `shellcheck` on the new function; `bash -n`. Real cloud: one
`argo-up` run that creates the Secret, one hand-created autoscaler-style
server (§8, one `cx33` for under an hour, about 0.02 EUR), and one
repeat `argo-up` proving the fast path. No AWS or Civo resources are
touched by this spec.

## 10. AWS regression protection

`ensure_autoscaler_secret()` is called only on the hetzner branch of
`argo-up.sh`; the aws and civo call paths are unchanged. `make -n
argo-up` for `PROVIDER=aws` and `PROVIDER=civo` is identical to the
recorded pre-change output.

## 11. Rollout and rollback/recovery

Revert the script. Deleting the Secret
does not affect the running fixed nodes; it only stops the autoscaler
(HETZ-170) from being able to grow the pool until the next `argo-up`
recreates it. Rotation is documented in §4 and never deletes the
cluster-side token before the Secret.

## 12. Risks and unresolved questions

- The join token is readable from the metadata service on autoscaled
  nodes (`/hetzner/v1/userdata`, unauthenticated to any process on that
  node) — documented, accepted, because the token is join-only. The
  fixed nodes carry no such secret, because HETZ-030 renders their
  cloud-init before this token exists.
- The Kubernetes API server on port 6443 is public (the join endpoint
  `10.0.1.10:6443` is private, but the firewall opens 6443 on the public
  IP); a leaked token lets anyone with network reach add a node to the
  cluster until it is rotated. Rotate on any suspicion of exposure (§4).
- The autoscaler's node name (`<pool>-<hex>`) must keep equaling its
  hostname for the CCM's fallback lookup to work; this spec's join line
  relies on that naming already holding rather than setting
  `nodeRegistration.name` itself.
- Kubelet version drift between HETZ-030's pin and the running cluster
  is possible if `scripts/lib/versions.sh` changes without a matching
  `make down`/`make up` cycle on the fixed nodes; both this spec's reused
  template and the fixed nodes read the same pin.
- `templates/node.yaml.tftpl` is read and substituted by this spec's
  script the same way HETZ-030's `templatefile()` call substitutes it
  for the fixed nodes; if that template ever gains a placeholder beyond
  `${kubernetes_version}` and `${containerd_version}`, or a per-server
  value, this spec's plain-substitution read breaks silently until the
  next real run is checked against the size guard and the join outcome.
  HETZ-030 §14 records the constraint this places on that template.
- The size guard (§4/§8) bounds the render at 32 KiB, but leaves no
  margin measured yet — the real template plus two apt keyrings is not
  written as code, so the actual headroom under the cap is unknown
  until then.

## 13. Definition of done

- [ ] Acceptance criteria evidence recorded
- [ ] `shellcheck` shows no new warnings
- [ ] AWS and Civo `make -n argo-up` identity recorded
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-19 — created as READY (kubeadm replan); takes the credential
  design of the old HETZ-170.
- 2026-09-20 — option C: HETZ-030 now has two templates; this spec still
  reads only the worker one, `templates/node.yaml.tftpl`, whose
  two-placeholder property is unchanged.
