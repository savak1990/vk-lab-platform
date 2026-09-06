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
to GHCR. A reusable sidecar snippet turns a pod with a workload certificate
into a pod with continuously refreshed AWS credentials. The credentials
arrive via the SDK default chain. A test pod proves the allow and deny
paths end to end.

## 2. Scope and non-goals

In scope: pinning the official image by digest, a Helm named template for
the sidecar, and the test pod manifest under `tests/manifests/civo-090/`.
A repo-built image is a fallback only. Use it only if the official image
lacks a needed platform or version.
Not in scope: wiring into ESO/ExternalDNS (CIVO-100/110).

## 3. Current state / evidence

- The official container image exists: `public.ecr.aws/rolesanywhere/credential-helper` (amd64/arm64, immutable `<version>-<platform>-<timestamp>` tags; https://github.com/aws/rolesanywhere-credential-helper/blob/main/docker_image_resources/README.md). No repo-built image is needed.
- `serve` mode listens on `127.0.0.1:9911`. It is IMDSv2-compatible. It refreshes 5 min before expiry. It reloads the cert/key files. It handles SIGTERM gracefully.
- The SDKs use `AWS_EC2_METADATA_SERVICE_ENDPOINT=http://127.0.0.1:9911`.
- The Roles Anywhere outputs are in SSM (CIVO-082). The certs are in Secrets (CIVO-085).
- Repository rule: platform tooling images are allowed. Business code is not.

## 4. Design and contracts

- Image: `public.ecr.aws/rolesanywhere/credential-helper@sha256:<digest>` for 1.8.5, recorded in `gitops/values.yaml`.
- The Helm named template `platform.rolesAnywhereSidecar` (in `gitops/templates/_helpers.tpl`) defines the container `aws-signing-helper`. The container args are `serve --certificate /ra/tls.crt --private-key /ra/tls.key --trust-anchor-arn ... --profile-arn ... --role-arn ... --session-duration 3600 --hop-limit 1 --port 9911 --region eu-west-1`. The container mounts `/ra` from the consumer Secret (no `subPath`). It sets `readOnlyRootFilesystem` and `runAsNonRoot`. It requests 10m/16Mi. The main container gets the env `AWS_EC2_METADATA_SERVICE_ENDPOINT=http://127.0.0.1:9911` and `AWS_REGION=eu-west-1`.
- The ARNs come from values. `argo-up` populates the values from SSM.
- Endpoint isolation: the endpoint is localhost inside the pod network namespace only, with `hop-limit 1`.
- Test pod: image `amazon/aws-cli`, with the sidecar attached. It runs `aws sts get-caller-identity`. A second variant uses a Certificate from a throwaway CA issuer (self-signed). This variant expects failure.

## 5. Files/components affected

`gitops/templates/_helpers.tpl`; `tests/manifests/civo-090/*.yaml`; `gitops/values.yaml` (`awsIdentity.rolesAnywhere.*`).

## 6. Implementation steps

1. Pull the official image. Verify that `--version` = 1.8.5. Record the digest.
2. Add the helper template. Render it in a test pod. Apply the pod on civo.
3. Positive test: `get-caller-identity` returns the `eso` role ARN with the source identity `CN=<project>-civo-eso`.
4. Negative tests: a wrong-CA cert gives `AccessDeniedException`. An expired cert is denied. A wrong role ARN for the CN is denied.
5. Reload test: trigger a Certificate renewal. Confirm that the helper logs a reload. Confirm that the next credential refresh succeeds without a restart.
6. Clean up the test pods.

## 7. Dependencies and blockers

082 (the ARNs and roles), 085 (the certs).

## 8. Acceptance criteria

- The official image is pinned by digest in values.
- The positive test and the three negative tests are recorded.
- A credential refresh is observed across one expiry boundary. The test uses a 900 s session to shorten the wait.
- A reload without a restart is observed.
- The sidecar snippet has no host network and no privileges. It is localhost only.

## 9. Validation

Offline: the image digest check. Real cloud: civo test pods (~cents). AWS STS is free.

## 10. AWS regression protection

Not applicable to the AWS cluster. The workflow has no AWS access.

## 11. Rollout and rollback/recovery

Remove the sidecar. The consumers lose AWS access (fail closed).

## 12. Risks and unresolved questions

- Do the ESO/external-dns charts allow `extraContainers` and `extraVolumes`? This is validated in 100/110. Fallback: a wrapper chart.

## 13. Definition of done

- [ ] Evidence incl. negative and reload tests; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
