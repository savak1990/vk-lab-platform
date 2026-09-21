{{/*
Validates .Values.target against the supported set. Included from a
template that always renders, so an unknown target fails loudly instead
of silently rendering an empty chart.
*/}}
{{- define "platform.validateTarget" -}}
{{- if not (has .Values.target (list "aws" "civo" "hetzner" "local")) -}}
{{- fail (printf "unsupported .Values.target %q - must be one of: aws, civo, hetzner, local" .Values.target) -}}
{{- end -}}
{{- end -}}

{{/*
Whether the platform bootstraps the control plane itself. Those targets reach
AWS through Roles Anywhere and terminate TLS at Envoy; local does neither.
Emits "true"/"false" as a string, so compare it - a bare if takes "false".
*/}}
{{- define "platform.selfManaged" -}}
{{- has .Values.target (list "civo" "hetzner") -}}
{{- end -}}

{{/*
Name of the Roles Anywhere CA ClusterIssuer and of the Secret it reads. The
provider segment must match the trust anchor Terraform builds from the CA
certificate committed for this project, so both derive from the target.
*/}}
{{- define "platform.workloadIssuerName" -}}
{{- default (printf "%s-workload-ca" .Values.target) .Values.workloadIdentity.issuerName -}}
{{- end -}}

{{/*
The CSI StorageClass name for the current target. civo uses civo-volume,
preinstalled and owned by a k3s Addon (a patch to it gets reverted), so
it must only be referenced here, never defined by a template we own.
hetzner uses hcloud-volumes, which the CSI driver's own chart ships.
*/}}
{{- define "platform.storageClassName" -}}
{{- if eq .Values.target "civo" -}}
civo-volume
{{- else if eq .Values.target "hetzner" -}}
hcloud-volumes
{{- else -}}
{{- .Values.storage.className -}}
{{- end -}}
{{- end -}}

{{/*
spotAvoidance gates the observability anti-affinity blocks - meaningful
only where Karpenter's spot/on-demand distinction exists (aws).
*/}}
{{- define "platform.spotAvoidance" -}}
{{- and (eq .Values.target "aws") .Values.capacity.spotAvoidance -}}
{{- end -}}

{{/*
Whether metrics-server needs --kubelet-insecure-tls. The civo value is
unverified until measured on a live cluster.
*/}}
{{- define "platform.kubeletInsecureTls" -}}
{{- if eq .Values.target "civo" -}}false{{- else -}}{{ .Values.observability.kubeletInsecureTls }}{{- end -}}
{{- end -}}

{{/*
Whether metrics-server is deployed. The civo value is unverified until
measured on a live cluster.
*/}}
{{- define "platform.metricsServerEnabled" -}}
{{- if eq .Values.target "civo" -}}true{{- else -}}{{ .Values.observability.metricsServer.enabled }}{{- end -}}
{{- end -}}

{{/*
The E2E suite's RBAC subject. aws maps eks-test-identity to a Group via its
EKS access entry; a self-managed target has no IAM, so the suite uses a
ServiceAccount token.
A ServiceAccount subject is in the core group and must not set apiGroup.
*/}}
{{- define "platform.e2eTestSubject" -}}
{{- if (eq (include "platform.selfManaged" .) "true") -}}
- kind: ServiceAccount
  name: e2e-test
  namespace: e2e
{{- else -}}
- kind: Group
  name: e2e-test-readonly
  apiGroup: rbac.authorization.k8s.io
{{- end -}}
{{- end -}}

{{/*
Renders the Roles Anywhere credential-helper sidecar container only - the
caller owns the ra-cert volume and the main container's env vars, since a
named template can't reach a sibling container in the same Pod spec.
*/}}
{{- define "platform.rolesAnywhereSidecar" -}}
- name: aws-signing-helper
  image: {{ .root.Values.awsIdentity.rolesAnywhere.image | quote }}
  args:
    - serve
    - --certificate
    - /ra/tls.crt
    - --private-key
    - /ra/tls.key
    - --trust-anchor-arn
    - {{ .root.Values.awsIdentity.rolesAnywhere.trustAnchorArn | quote }}
    - --profile-arn
    - {{ .root.Values.awsIdentity.rolesAnywhere.profileArn | quote }}
    - --role-arn
    - {{ index .root.Values.awsIdentity.rolesAnywhere.roleArns .consumer | quote }}
    - --session-duration
    - "3600"
    - --hop-limit
    - "1"
    - --port
    - "9911"
    - --region
    - {{ .root.Values.region | quote }}
  securityContext:
    readOnlyRootFilesystem: true
    runAsNonRoot: true
    runAsUser: 65532
    allowPrivilegeEscalation: false
  resources:
    requests:
      cpu: 10m
      memory: 16Mi
  volumeMounts:
    - name: ra-cert
      mountPath: /ra
      readOnly: true
{{- end -}}
