{{/*
Validates .Values.target against the supported set. Included from a
template that always renders, so an unknown target fails loudly instead
of silently rendering an empty chart.
*/}}
{{- define "platform.validateTarget" -}}
{{- if not (has .Values.target (list "aws" "civo" "local")) -}}
{{- fail (printf "unsupported .Values.target %q - must be one of: aws, civo, local" .Values.target) -}}
{{- end -}}
{{- end -}}

{{/*
The CSI StorageClass name for the current target. civo uses civo-volume,
preinstalled and owned by a k3s Addon (a patch to it gets reverted), so
it must only be referenced here, never defined by a template we own.
*/}}
{{- define "platform.storageClassName" -}}
{{- if eq .Values.target "civo" -}}
civo-volume
{{- else -}}
{{- .Values.storage.className -}}
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
