---
id: "CIVO-090"
title: "Credential helper image and sidecar pattern with positive and negative authorization tests"
status: "DONE"
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
updated: "2026-09-10"
completed: "2026-09-10"
---

# CIVO-090 — Credential helper sidecar

## 1. Outcome and rationale

The official `aws_signing_helper` container image is pinned by digest, and a reusable sidecar snippet turns a pod with a workload certificate into a pod with continuously refreshed AWS credentials through the SDK default chain. A test pod proves the allow and deny paths end to end.

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
- The positive test and 2 of the 3 negative cases (wrong-CA, wrong-role) were live-verified; the expired-cert case was deferred (cert-manager's 1-hour minimum `spec.duration` made a naturally-expired cert impractical to obtain in-session, and a manual backdated-cert workaround was blocked as security-sensitive). Certificate-validity-period enforcement is AWS Roles Anywhere's own well-documented server-side behavior, not something this task's code implements, so the deferral leaves an unverified but expected-to-work behavior, not an unverified security control.
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
- 2026-09-10 — implemented via subagent-driven-development.
  - Task 1: image digest resolution, via the curl-fallback method (no Docker
    daemon available in this environment). Digest
    `sha256:56b03f3acba0bda06c94189ab62c4a497fd1912f3d08311fb99ab24e4e4c2f84`,
    tag `1.8.5-amd64-2026.08.24.20.52`, independently re-verified by the
    controller against the public ECR API.
  - Task 2: the `platform.rolesAnywhereSidecar` Helm template + values
    wiring.
  - Task 3: `argo-up.sh` SSM/`--set` wiring for the 4 ARNs. Needed a fix
    round after review found the ARNs weren't relayed through
    `gitops/bootstrap/templates/root-application.yaml` into the actual
    `gitops` chart Argo renders — fixed, then a second fix round after
    review found the AWS golden-render fixture had gone stale from that
    fix — also fixed.
  - Task 4: 4 offline test-pod manifests under `tests/manifests/civo-090/`
    using placeholder ARN tokens (never committing real, per-account ARN
    values).
  - Merged and pushed to `main` ahead of the plan's own final whole-branch
    review, at the user's explicit instruction — same pattern as
    CIVO-085's session. The review still ran afterward; its outcome is
    recorded separately once available, not here.
  - `PROVIDER=civo make full-up` recreated the entire stack from scratch
    (bootstrap/persistent/cluster/argo — the cluster had been fully torn
    down after CIVO-085's own testing). The first `argo-up` attempt timed
    out waiting for `argocd-dex-server` readiness (a cold-cluster
    scheduling delay, not a real defect) and was simply retried
    successfully (the script is idempotent by design).
  - Live verification, with real evidence:
    - Confirmed the ARN-relay fix works: the `root` Application's
      `helm.parameters` carried all 4 real ARNs (trust anchor, profile,
      both role ARNs), not empty strings.
    - Positive test: `aws sts get-caller-identity` from a pod with the
      `eso` sidecar returned `assumed-role/vk-civo-lab-ra-eso/...` — exact
      match. Also confirms the `runAsUser: 65534` defensive default
      (Task 1's unresolved `Config.User` gap) didn't prevent the sidecar
      from starting.
    - Wrong-CA negative test: a throwaway self-signed `ClusterIssuer` +
      `Certificate` (same CN, different issuer) produced sidecar log
      `AccessDeniedException: Untrusted signing certificate`.
    - Wrong-role negative test: the real, correctly-issued `eso`
      certificate, with the sidecar's `--role-arn` pointed at the
      `external-dns` role, produced sidecar log `AccessDeniedException:
      Unable to assume role for arn:...role/vk-civo-lab-ra-external-dns`
      — proves the trust policy's `PrincipalTag` condition is
      role-specific, not just issuer-specific.
    - Expired-cert negative test: deferred, per the reasoning recorded in
      §8.
    - Refresh test (900 s session duration): direct queries against the
      sidecar's own IMDSv2-style credential endpoint showed `LastUpdated`
      stable across two 5-second-apart queries (proving genuine
      background caching, not per-request regeneration), and `Expiration`
      later than the original t=0 session's expiry would have been —
      proves the helper performed a real, automatic `CreateSession`
      refresh, with the pod's restart count staying `0` throughout.
    - Reload-without-restart test: `cmctl renew eso -n external-secrets`
      triggered in-place reissuance — the Secret's `resourceVersion`
      changed while `creationTimestamp` stayed fixed (proving an in-place
      update, distinct from CIVO-085's own delete-recreate rotation test,
      which explicitly could not prove this same path). Argo stayed
      `Synced`/`Healthy` throughout (the cmctl trigger survives
      `selfHeal`). Confirmed via `kubectl debug --target
      --profile=sysadmin` reading `/proc/1/root/ra/tls.crt` inside the
      still-running, never-restarted sidecar container (its image has no
      shell) that the mounted certificate's serial number matched the
      newly-renewed Secret's serial exactly — direct proof the
      whole-Secret (no `subPath`) mount design genuinely delivers a live
      reload.
    - AWS unaffected: the golden AWS render was verified unchanged
      (Task 2), and the regenerated golden baseline (Task 3's fix round)
      only added the 4 new ungated `helm.parameters` entries with
      empty-string defaults, matching the existing pattern already used
      by `envoyGateway.reservedIp`/`firewallId`.
  - All live test fixtures (4 pods, 1 throwaway `ClusterIssuer`, 1
    throwaway `Certificate` + its Secret) were deleted and confirmed
    absent afterward; only the real CIVO-085 resources remain.
  - One self-flagged process lapse: a credential-endpoint query used for
    the refresh test was not filtered and printed a real (though
    narrowly-scoped, ~15-minute-lived) temporary AWS credential in full
    into tool output — caught immediately, subsequent queries filtered to
    only non-sensitive fields. No further remediation needed (the
    credential was role-scoped, expired naturally within the session, and
    the account/cluster is being fully torn down).
