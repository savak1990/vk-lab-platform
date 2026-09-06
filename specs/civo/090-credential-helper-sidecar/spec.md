---
id: "CIVO-090"
title: "Credential helper image and sidecar pattern with positive and negative authorization tests"
status: "READY"
priority: "P0"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Packaging and a known sidecar pattern; the security-relevant decisions were made in 082/085"
effort_estimate: "One session (4–6 h)"
estimate_confidence: "medium"
depends_on: ["CIVO-082", "CIVO-085"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-090 — Credential helper sidecar

## 1. Outcome and rationale

A pinned `aws_signing_helper` container image is published from this repo
to GHCR, and a reusable sidecar snippet turns a pod with a workload
certificate into a pod with continuously refreshed AWS credentials via the
SDK default chain. A test pod proves allow and deny paths end to end.

## 2. Scope and non-goals

In scope: pinning the official image by digest, Helm named template for
the sidecar, test pod manifest under `tests/manifests/civo-090/`. A
repo-built image is a fallback only if the official image lacks a needed
platform or version.
Not in scope: wiring into ESO/ExternalDNS (CIVO-100/110).

## 3. Current state / evidence

- Official container image exists: `public.ecr.aws/rolesanywhere/credential-helper` (amd64/arm64, immutable `<version>-<platform>-<timestamp>` tags; https://github.com/aws/rolesanywhere-credential-helper/blob/main/docker_image_resources/README.md). No repo-built image is needed.
- `serve` mode: `127.0.0.1:9911`, IMDSv2-compatible, refresh 5 min before expiry, reloads cert/key files, graceful SIGTERM.
- SDKs: `AWS_EC2_METADATA_SERVICE_ENDPOINT=http://127.0.0.1:9911`.
- Roles Anywhere outputs in SSM (CIVO-082); certs in Secrets (CIVO-085).
- Repository rule: platform tooling images are allowed; business code is not.

## 4. Design and contracts

- Image: `public.ecr.aws/rolesanywhere/credential-helper@sha256:<digest>` for 1.8.5, recorded in `gitops/values.yaml`.
- Helm named template `platform.rolesAnywhereSidecar` (in `gitops/templates/_helpers.tpl`): container `aws-signing-helper` with args `serve --certificate /ra/tls.crt --private-key /ra/tls.key --trust-anchor-arn ... --profile-arn ... --role-arn ... --session-duration 3600 --hop-limit 1 --port 9911 --region eu-west-1`, volume mount `/ra` from the consumer Secret (no `subPath`), `readOnlyRootFilesystem`, `runAsNonRoot`, requests 10m/16Mi; env for the main container: `AWS_EC2_METADATA_SERVICE_ENDPOINT=http://127.0.0.1:9911`, `AWS_REGION=eu-west-1`.
- ARNs come from values populated by `argo-up` from SSM.
- Endpoint isolation: localhost inside the pod network namespace only; `hop-limit 1`.
- Test pod: image `amazon/aws-cli`, sidecar attached, runs `aws sts get-caller-identity`; second variant with a Certificate from a throwaway CA issuer (self-signed) expects failure.

## 5. Files/components affected

`gitops/templates/_helpers.tpl`, `tests/manifests/civo-090/*.yaml`, `gitops/values.yaml` (`awsIdentity.rolesAnywhere.*`).

## 6. Implementation steps

1. Pull the official image, verify `--version` = 1.8.5, record the digest.
2. Add the helper template; render in a test pod; apply on civo.
3. Positive: `get-caller-identity` returns the `eso` role ARN with source identity `CN=<project>-civo-eso`.
4. Negative: wrong-CA cert → `AccessDeniedException`; expired cert → denied; wrong role ARN for the CN → denied.
5. Reload: trigger a Certificate renewal; confirm the helper logs a reload and the next credential refresh succeeds without restart.
6. Clean up test pods.

## 7. Dependencies and blockers

082 (ARNs, roles), 085 (certs).

## 8. Acceptance criteria

- Official image pinned by digest in values.
- Positive and three negative tests recorded.
- Credential refresh observed across one expiry boundary (session 900 s in the test to shorten the wait).
- Reload without restart observed.
- Sidecar snippet has no host network, no privileges, localhost only.

## 9. Validation

Offline: image digest check. Real cloud: civo test pods (~cents); AWS STS free.

## 10. AWS regression protection

Not applicable to the AWS cluster; the workflow has no AWS access.

## 11. Rollout and rollback/recovery

Remove the sidecar; consumers lose AWS access (fail closed).

## 12. Risks and unresolved questions

- Whether the ESO/external-dns charts allow `extraContainers` and `extraVolumes` (validated in 100/110; fallback: wrapper chart).

## 13. Definition of done

- [ ] Evidence incl. negative and reload tests; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
