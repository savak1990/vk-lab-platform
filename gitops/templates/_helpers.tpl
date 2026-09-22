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
local uses standard, which kind's own local-path provisioner ships - named
rather than left to the cluster default, and never defined here either.
*/}}
{{- define "platform.storageClassName" -}}
{{- if eq .Values.target "civo" -}}
civo-volume
{{- else if eq .Values.target "hetzner" -}}
hcloud-volumes
{{- else if eq .Values.target "local" -}}
standard
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
{{/*
Whether this target has a Gateway for Gateway API objects to attach to. False
on hetzner until HETZ-060 supplies the EnvoyProxy and Gateway: an HTTPRoute
with no Gateway is never Accepted, so Argo's health check on it never finishes
and the whole root sync stalls behind it, and a GatewayClass whose
parametersRef names a missing EnvoyProxy is rejected outright.
Emits "true"/"false" as a string, so compare it - a bare if takes "false".
*/}}
{{- define "platform.gatewayEnabled" -}}
{{- ne .Values.target "hetzner" -}}
{{- end -}}

{{- define "platform.metricsServerEnabled" -}}
{{- if eq .Values.target "civo" -}}true{{- else -}}{{ .Values.observability.metricsServer.enabled }}{{- end -}}
{{- end -}}

{{/*
The envoy Service's type and its provider annotations. Everything else about
the EnvoyProxy is identical on every target, so this is the whole of what
differs. Callers supply the envoyService key and indent by 8.
*/}}
{{- define "platform.envoyServiceSpec" -}}
{{- if eq .Values.target "aws" -}}
type: LoadBalancer
annotations:
  service.beta.kubernetes.io/aws-load-balancer-type: "external"
  service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
  # Public internet access to argo.lab.<root-domain>/grafana.lab.<root-domain>
  # requires this - default is "internal" (VPC-private only).
  service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
  # Explicit for now, though the platform VPC's subnets already
  # carry kubernetes.io/role/elb (spec 020) - drop this once the
  # pinned controller's tag-based discovery is verified against a
  # real NLB, so it doesn't also expect a cluster-scoped tag here.
  service.beta.kubernetes.io/aws-load-balancer-subnets: {{ .Values.envoyGateway.nlbSubnetIds | quote }}
  service.beta.kubernetes.io/aws-load-balancer-ssl-cert: {{ .Values.envoyGateway.acmCertificateArn | quote }}
  service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
  # Without this, every request appears to come from the NLB's own
  # IP and per-client rate limiting collapses into one global limit.
  # Must be paired with the listener-side PROXY protocol setting below.
  service.beta.kubernetes.io/aws-load-balancer-proxy-protocol: "*"
{{- else if eq .Values.target "civo" -}}
type: LoadBalancer
annotations:
  kubernetes.civo.com/firewall-id: {{ .Values.envoyGateway.firewallId | quote }}
  kubernetes.civo.com/ipv4-address: {{ .Values.envoyGateway.reservedIp | quote }}
  kubernetes.civo.com/loadbalancer-algorithm: round_robin
{{- else if eq .Values.target "local" -}}
# Stated rather than left to the CRD default of LoadBalancer: kind has no
# load-balancer implementation, so that default never gets an address, the
# Gateway's Programmed condition stays false, and the bring-up waits on a
# Degraded root until it times out. No annotations - there is no cloud here.
type: ClusterIP
{{- end -}}
{{- end -}}

{{/*
The Gateway's listeners. Callers supply the listeners key and indent by 4.
*/}}
{{- define "platform.envoyListeners" -}}
{{- if eq .Values.target "aws" -}}
# port 443, protocol HTTP: NLB terminates TLS and forwards plaintext
# here - Envoy never holds a cert. Must match ssl-ports=443 above, since
# the Service's ports mirror this list 1:1. No port 80, by design.
- name: https
  protocol: HTTP
  port: 443
  allowedRoutes:
    namespaces:
      from: All
{{- else if eq .Values.target "civo" -}}
- name: http
  protocol: HTTP
  port: 80
  allowedRoutes:
    namespaces:
      from: All
# Civo has no NLB terminating TLS upstream (unlike aws) - Envoy holds
# the certificate itself and terminates TLS directly.
- name: https
  protocol: HTTPS
  port: 443
  tls:
    certificateRefs:
      - name: platform-public-tls
  allowedRoutes:
    namespaces:
      from: All
{{- else if eq .Values.target "local" -}}
# One plain-HTTP listener: nothing terminates TLS in front of Envoy here, and
# a certificate protects no network segment on a cluster that never leaves
# this machine. Reached through kubectl port-forward.
- name: http
  protocol: HTTP
  port: 80
  allowedRoutes:
    namespaces:
      from: All
{{- end -}}
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
