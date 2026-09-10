# Credential helper sidecar — positive/negative authorization proof

Plain `kubectl` manifests, not Argo-managed, re-runnable on demand. They
contain `__TRUST_ANCHOR_ARN__`/`__PROFILE_ARN__`/`__ESO_ROLE_ARN__`/
`__EXTERNAL_DNS_ROLE_ARN__` placeholders — never commit them substituted
with real, per-account ARN values.

Prerequisite: CIVO-085's `eso`/`external-dns` Certificates are `Ready` on
the target cluster (`kubectl get certificate -A`).

## Substituting the placeholders

Fetch the 4 real ARNs from SSM — the same 4 params `argo-up.sh`'s
`civo_resolve_inputs()` reads:

```
aws ssm get-parameters --region eu-west-1 --with-decryption \
  --names "/$PROJECT_NAME/bootstrap/rolesanywhere/trust_anchor_arn" \
          "/$PROJECT_NAME/bootstrap/rolesanywhere/profile_arn" \
          "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/eso" \
          "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/external-dns" \
  --query 'Parameters[].[Name,Value]' --output text
```

Substitute into scratch copies of the 4 files (never the committed
originals) via `sed`:

```
mkdir -p /tmp/civo-090-scratch
cp tests/manifests/civo-090/*.yaml /tmp/civo-090-scratch/
sed -i '' \
  -e "s|__TRUST_ANCHOR_ARN__|$TRUST_ANCHOR_ARN|g" \
  -e "s|__PROFILE_ARN__|$PROFILE_ARN|g" \
  -e "s|__ESO_ROLE_ARN__|$ESO_ROLE_ARN|g" \
  -e "s|__EXTERNAL_DNS_ROLE_ARN__|$EXTERNAL_DNS_ROLE_ARN|g" \
  /tmp/civo-090-scratch/*.yaml
```

## Apply order and expected outcomes

1. `kubectl apply -f /tmp/civo-090-scratch/positive-pod.yaml`
   Long-lived (`sleep infinity`) — proves the positive path:
   `kubectl exec civo-090-positive -c aws-cli -- aws sts get-caller-identity`
   succeeds, identity ARN `assumed-role/vk-civo-lab-ra-eso/...`.
2. `kubectl apply -f /tmp/civo-090-scratch/wrong-ca-issuer.yaml`
   Wait for its Certificate to be `Ready`:
   `kubectl get certificate civo-090-wrong-ca-eso -n external-secrets -w`
3. `kubectl apply -f /tmp/civo-090-scratch/wrong-ca-pod.yaml`
   Expect the sidecar log to show
   `AccessDeniedException: Untrusted signing certificate` and the
   `aws-cli` container to fail/exit non-zero.
4. `kubectl apply -f /tmp/civo-090-scratch/wrong-role-pod.yaml`
   Uses the real `eso` certificate but the `external-dns` role ARN.
   Expect the sidecar log to show
   `AccessDeniedException: Unable to assume role for arn:...role/vk-civo-lab-ra-external-dns`.

## Regenerating a fixture's sidecar fragment

If `platform.rolesAnywhereSidecar` in `gitops/templates/_helpers.tpl`
ever changes, regenerate the rendered fragment to keep these fixtures in
sync (they embed a copy of it, not a live include):

```
helm template gitops --set target=civo \
  --show-only <scratch-template-path>
```

against a scratch template file whose only content is a caller invoking
`{{ include "platform.rolesAnywhereSidecar" (dict "consumer" "eso" "namespace" "external-secrets" "root" $) }}`.
Diff the rendered `aws-signing-helper` container block against what's
embedded in each fixture and update by hand.

## Cleanup

```
kubectl delete -f /tmp/civo-090-scratch/positive-pod.yaml
kubectl delete -f /tmp/civo-090-scratch/wrong-ca-pod.yaml
kubectl delete -f /tmp/civo-090-scratch/wrong-role-pod.yaml
kubectl delete -f /tmp/civo-090-scratch/wrong-ca-issuer.yaml
kubectl delete secret wrong-ca-eso-cert -n external-secrets
```

cert-manager does not cascade-delete the Certificate's Secret when the
Certificate itself is deleted, so `wrong-ca-eso-cert` needs an explicit
delete.
