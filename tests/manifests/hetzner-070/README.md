# cert-manager Route 53 scope — what the DNS-01 role can and cannot change (Hetzner)

Plain `kubectl` manifests, not Argo-managed, re-runnable on demand.
`cert-manager-role-pod.yaml` holds `__TRUST_ANCHOR_ARN__`,
`__PROFILE_ARN__` and `__CERT_MANAGER_ROLE_ARN__` placeholders — never
commit them substituted with real, per-account ARN values.

Prerequisite: HETZ-085's `cert-manager` Certificate is `Ready`
(`kubectl get certificate cert-manager -n cert-manager`).

The role is `${PROJECT_NAME}-ra-cert-manager`. Its policy grants
`route53:ChangeResourceRecordSets` and `ListResourceRecordSets` on this
project's hosted zone only, under a
`ForAllValues:StringEquals route53:ChangeResourceRecordSetsRecordTypes = [TXT]`
condition. So three attempts, and all three matter:

| Attempt | Expected | What it proves |
|---|---|---|
| TXT change, this project's zone | **allowed** | the role works at all |
| A change, this project's zone | `AccessDenied` | the record-type condition holds |
| any change, a zone outside this project | `AccessDenied` | the zone scope holds |

Without the first, the two denials prove only that the role is broken.

## Substituting the placeholders

```
aws ssm get-parameters --region eu-west-1 --with-decryption \
  --names "/vk-hetzner-lab/bootstrap/rolesanywhere/trust_anchor_arn" \
          "/vk-hetzner-lab/bootstrap/rolesanywhere/profile_arn" \
          "/vk-hetzner-lab/bootstrap/rolesanywhere/role_arn/cert-manager" \
  --query 'Parameters[].[Name,Value]' --output text
```

```
mkdir -p /tmp/hetzner-070-scratch
cp tests/manifests/hetzner-070/*.yaml /tmp/hetzner-070-scratch/
sed -i '' \
  -e "s|__TRUST_ANCHOR_ARN__|$TRUST_ANCHOR_ARN|g" \
  -e "s|__PROFILE_ARN__|$PROFILE_ARN|g" \
  -e "s|__CERT_MANAGER_ROLE_ARN__|$CERT_MANAGER_ROLE_ARN|g" \
  /tmp/hetzner-070-scratch/*.yaml
```

This project's zone id comes from SSM:

```
aws ssm get-parameter --region eu-west-1 \
  --name /vk-hetzner-lab/bootstrap/route53/zone_id --query Parameter.Value --output text
```

For the out-of-scope attempt, use the parent zone
(`aws route53 list-hosted-zones`). Another project's zone works too, but the
parent is the better target: it is the one zone the platform must never write
to, and it exists whether or not any other project is up.

## Running the three attempts

```
kubectl apply -f /tmp/hetzner-070-scratch/cert-manager-role-pod.yaml
X() { kubectl exec hetzner-070-cert-manager -n cert-manager -c aws-cli -- "$@"; }
X aws sts get-caller-identity
```

The identity ARN must be `assumed-role/vk-hetzner-lab-ra-cert-manager/...`.

1. **TXT on this zone — allowed.** Write one record, then delete it. Use
   `UPSERT` then `DELETE` with the same `ResourceRecordSet`, against
   `_acme-challenge-scopetest.hz.<root-domain>`, TTL 60, value `"probe"`.
   A `ChangeInfo` with `Status: PENDING` is the pass.
2. **A on this zone — denied.** The same `UPSERT` with `Type: A` and an
   address value. Expect
   `AccessDenied ... not authorized to perform: route53:ChangeResourceRecordSets`.
3. **Any change outside this project's zone — denied.** Attempt 1's TXT
   batch against the parent zone, with the name under `<root-domain>`. Expect
   the same `AccessDenied`, naming that zone instead.

`ListResourceRecordSets` on this project's zone is granted and is the
cheapest way to confirm attempt 1 landed and was then removed.

## Cleanup

```
kubectl delete pod hetzner-070-cert-manager -n cert-manager
rm -rf /tmp/hetzner-070-scratch
```

The pod mounts an existing Secret and creates none, so nothing else is left
behind. Attempt 1's TXT record is removed by its own `DELETE`; confirm with
`ListResourceRecordSets` before deleting the pod.
