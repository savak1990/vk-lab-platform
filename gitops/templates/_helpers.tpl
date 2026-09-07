{{/*
Validates .Values.target against the supported set. Included from
templates/_validate.yaml, which always renders regardless of target - no
platform file happens to gate on an unknown value, so without this an
unknown target would silently render an empty chart instead of failing.
*/}}
{{- define "platform.validateTarget" -}}
{{- if not (has .Values.target (list "aws" "civo" "local")) -}}
{{- fail (printf "unsupported .Values.target %q - must be one of: aws, civo, local" .Values.target) -}}
{{- end -}}
{{- end -}}

{{/*
The CSI StorageClass name for the current target. aws/local use
.Values.storage.className (default ebs-delete); civo uses civo-volume,
which is preinstalled and owned by a k3s Addon - it must never be defined
by a gitops template (a patch would be reverted by the Addon), only
referenced by name. See specs/civo/research.md's Storage row.
*/}}
{{- define "platform.storageClassName" -}}
{{- if eq .Values.target "civo" -}}
civo-volume
{{- else -}}
{{- .Values.storage.className -}}
{{- end -}}
{{- end -}}
