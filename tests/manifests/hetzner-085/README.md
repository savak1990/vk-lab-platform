# Credential helper sidecar — positive/negative authorization proof (Hetzner)

Plain `kubectl` manifests, not Argo-managed, re-runnable on demand. They
contain `__TRUST_ANCHOR_ARN__`/`__PROFILE_ARN__`/`__ESO_ROLE_ARN__`/
`__EXTERNAL_DNS_ROLE_ARN__` placeholders — never commit them substituted
with real, per-account ARN values.

Prerequisite: HETZ-085's `eso`/`external-dns` Certificates are `Ready` on
the target cluster (`kubectl get certificate -A`).

The Hetzner set mirrors `tests/manifests/civo-090/` and adds one negative
Civo does not have. The three negatives break three different links in the
chain, and each stops at a different point:

| Fixture | What is wrong | Where it stops |
|---|---|---|
| `wrong-ca-pod` | certificate signed by a self-signed issuer, CN correct | the trust anchor rejects the signer |
| `wrong-role-pod` | real `eso` certificate, `external-dns` role ARN | the role's trust policy rejects the subject |
| `wrong-cn-pod` | real project CA, CN `vk-hetzner-lab-hetzner-nobody` | `CreateSession` rejects the subject |

`wrong-cn-pod` is the strongest of the three, because the anchor does trust
the signer. The request reaches `CreateSession` with a valid certificate and
is refused on the subject alone.

## Substituting the placeholders

Fetch the 4 real ARNs from SSM — the same 4 params `argo-up.sh`'s
`hetzner_resolve_inputs()` reads:

```
aws ssm get-parameters --region eu-west-1 --with-decryption \
  --names "/vk-hetzner-lab/bootstrap/rolesanywhere/trust_anchor_arn" \
          "/vk-hetzner-lab/bootstrap/rolesanywhere/profile_arn" \
          "/vk-hetzner-lab/bootstrap/rolesanywhere/role_arn/eso" \
          "/vk-hetzner-lab/bootstrap/rolesanywhere/role_arn/external-dns" \
  --query 'Parameters[].[Name,Value]' --output text
```

Substitute into scratch copies of the 5 pod files (never the committed
originals) via `sed`:

```
mkdir -p /tmp/hetzner-085-scratch
cp tests/manifests/hetzner-085/*.yaml /tmp/hetzner-085-scratch/
sed -i '' \
  -e "s|__TRUST_ANCHOR_ARN__|$TRUST_ANCHOR_ARN|g" \
  -e "s|__PROFILE_ARN__|$PROFILE_ARN|g" \
  -e "s|__ESO_ROLE_ARN__|$ESO_ROLE_ARN|g" \
  -e "s|__EXTERNAL_DNS_ROLE_ARN__|$EXTERNAL_DNS_ROLE_ARN|g" \
  /tmp/hetzner-085-scratch/*.yaml
```

## Apply order and expected outcomes

1. `kubectl apply -f /tmp/hetzner-085-scratch/positive-pod.yaml`
   Long-lived (`sleep infinity`) — proves the positive path:
   `kubectl exec hetzner-085-positive -c aws-cli -- aws sts get-caller-identity`
   succeeds, identity ARN `assumed-role/vk-hetzner-lab-ra-eso/...`, and
   `kubectl exec hetzner-085-positive -n external-secrets -c aws-cli -- aws
   ssm get-parameter --name /vk-hetzner-lab/persistent/postgres/app_password
   --with-decryption` returns the parameter.

   The parameter matters. The `ra-eso` role's inline `consumer` policy grants
   `ssm:GetParameter` on exactly the two parameters the ExternalSecrets read,
   and on nothing else, so a read of any other name is denied however healthy
   the chain is. This one is a `SecureString`, so the call also exercises the
   role's `kms:Decrypt` grant, and answering at all proves IPv4 egress from a
   Hetzner node to both SSM and KMS.
2. `kubectl apply -f /tmp/hetzner-085-scratch/wrong-ca-issuer.yaml`
   Wait for its Certificate to be `Ready`:
   `kubectl get certificate hetzner-085-wrong-ca -n external-secrets -w`
3. `kubectl apply -f /tmp/hetzner-085-scratch/wrong-ca-pod.yaml`
   Expect the sidecar log to show
   `AccessDeniedException: Untrusted signing certificate` and the
   `aws-cli` container to fail/exit non-zero.
4. `kubectl apply -f /tmp/hetzner-085-scratch/wrong-role-pod.yaml`
   Uses the real `eso` certificate but the `external-dns` role ARN.
   Expect the sidecar log to show
   `AccessDeniedException: Unable to assume role for arn:...role/vk-hetzner-lab-ra-external-dns`.
5. `kubectl apply -f /tmp/hetzner-085-scratch/wrong-cn-cert.yaml`
   Wait for it to be `Ready`:
   `kubectl get certificate hetzner-085-wrong-cn -n external-secrets -w`
   This one is issued by the real `hetzner-workload-ca` ClusterIssuer, so it
   must go `Ready` exactly like the four production Certificates.
6. `kubectl apply -f /tmp/hetzner-085-scratch/wrong-cn-pod.yaml`
   Expect the sidecar log to show `AccessDenied` from `CreateSession`, naming
   a subject the profile does not recognise. If it instead shows `Untrusted
   signing certificate`, the fixture is pointing at the wrong issuer.

Read each negative's sidecar log with
`kubectl logs <pod> -n external-secrets -c aws-signing-helper`.

None of these pods may use `hostNetwork`. The sidecar listens on
`127.0.0.1:9911`, which a hostNetwork pod on the same node cannot reach.

## Regenerating a fixture's sidecar fragment

If `platform.rolesAnywhereSidecar` in `gitops/templates/_helpers.tpl`
ever changes, regenerate the rendered fragment to keep these fixtures in
sync (they embed a copy of it, not a live include):

```
helm template gitops --set target=hetzner \
  --show-only <scratch-template-path>
```

against a scratch template file whose only content is a caller invoking
`{{ include "platform.rolesAnywhereSidecar" (dict "consumer" "eso" "namespace" "external-secrets" "root" $) }}`.
Diff the rendered `aws-signing-helper` container block against what's
embedded in each fixture and update by hand.

## Cleanup

```
kubectl delete -f /tmp/hetzner-085-scratch/positive-pod.yaml
kubectl delete -f /tmp/hetzner-085-scratch/wrong-ca-pod.yaml
kubectl delete -f /tmp/hetzner-085-scratch/wrong-role-pod.yaml
kubectl delete -f /tmp/hetzner-085-scratch/wrong-cn-pod.yaml
kubectl delete -f /tmp/hetzner-085-scratch/wrong-ca-issuer.yaml
kubectl delete -f /tmp/hetzner-085-scratch/wrong-cn-cert.yaml
kubectl delete secret hetzner-085-wrong-ca-cert -n external-secrets
kubectl delete secret hetzner-085-wrong-cn-cert -n external-secrets
```

cert-manager does not cascade-delete a Certificate's Secret when the
Certificate itself is deleted, so both negative Secrets need an explicit
delete.
