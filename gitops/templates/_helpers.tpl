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
