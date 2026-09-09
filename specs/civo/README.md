# Civo provider planning package

This folder holds the planning and specification documents for adding Civo
managed Kubernetes as a second execution target next to AWS/EKS.
Implementation code does not live here. It lands in the normal repository
locations that each spec names.

Living high-level design: `docs/civo-high-level-design.md`.
Baseline inspected: branch `main`, commit `cfbb59bd340b6356bad3fb2493b41fa3a337efe5`, 2026-09-06.

## Reading order

1. `docs/civo-high-level-design.md` — constraints, stage model, decisions.
2. `architecture.md` — current AWS flow, coupling inventory, target design, change map.
3. `research.md` — verified capabilities, prices, uncertainties.
4. `decisions.md` — accepted constraints, proposed ADRs, open decisions.
5. `roadmap.md` — milestones, dependency graph, first PRs, coverage.
6. The spec you were asked to implement, plus its `depends_on` specs.

## Format note

Specs in this folder use YAML front matter and a fixed 14-section body. The
planning brief requires this format. Other specs in `specs/` use Markdown
bold-label headers. The folder name (`NNN-title`) and the `id` field are the
stable identifiers. Never renumber them. Numbers step by ten. Insert later
work into the gaps (`085-...`) without renumbering.

## Status protocol

| Status | Meaning |
|---|---|
| `DRAFT` | Specification incomplete, unapproved, or design unresolved |
| `READY` | Approved for development; no active blocker. An implementer may start only when every `depends_on` is `DONE` (checked at session start) |
| `IN_PROGRESS` | An authorized implementer started the bounded work |
| `BLOCKED` | Needs a named decision, capability, prerequisite, or unfinished hard dependency; `blocked_by` names it |
| `IN_REVIEW` | Implementation and checks complete, awaiting review. **Used only when the operator asks for a pull request.** A change that goes straight to `main` skips this status |
| `DONE` | Acceptance criteria and gates passed, evidence recorded, reviewed and integrated |
| `CANCELLED` | Abandoned or superseded; rationale and replacement kept |

Flow: `DRAFT → READY → IN_PROGRESS → DONE`, or
`DRAFT → READY → IN_PROGRESS → IN_REVIEW → DONE` when a pull request exists.
`BLOCKED` may interrupt anywhere. It returns to `READY` or `IN_PROGRESS`.
A review failure returns the spec to `IN_PROGRESS`. Reopening `DONE` needs a
recorded reason.

Priority:

- `P0`: a critical prerequisite or a security/data-safety blocker for the milestone.
- `P1`: required for the first viable Civo platform.
- `P2`: a follow-up.
- `P3`: optional.

Difficulty:

- `S`: a bounded local change.
- `M`: several known components.
- `L`: substantial cross-component or security/lifecycle reasoning.
- `XL`: must be split (none remain).

Model tier: `fast`, `standard`, `strongest`. This is a recommendation only.
The gates do not relax. No exact model names are mapped, because none were
verified in this environment.

## Implementation-session protocol

1. Read this README, the HLD, `architecture.md` §Target, and the spec plus its `depends_on`.
2. Check that every `depends_on` is `DONE`. Otherwise, set `BLOCKED` with `blocked_by` and stop.
3. Set `status: "IN_PROGRESS"` and `updated`. Add a status-history line.
4. Implement only the spec's scope. Do not touch AWS behavior unless the spec says so. Run the AWS regression gate that the spec names.
5. Run the validation section. Record the commands and results (no secrets) under "Execution evidence".
6. A pull request is optional. The operator decides. **The default is to push the change straight to `main` and open no pull request.** Ask only when the change is large, risky, or touches AWS behaviour.
   - No pull request: skip `IN_REVIEW`. Go to step 7.
   - Pull request: set `IN_REVIEW` and open one PR mapped to the spec ID. Go to step 7 after the merge.
7. When the change is on `main` and the gates pass, set `DONE` and `completed`. Record in the status history whether a pull request was used. Re-check the direct dependents' `blocked_by`.
8. Update the index table below if the status, priority, or dependencies changed.

## Index

| ID | Folder | Title | Status | Pri | Diff | Tier | Depends on | Milestone |
|---|---|---|---|---|---|---|---|---|
| CIVO-010 | [010-provider-command-surface](010-provider-command-surface/spec.md) | `PROVIDER` operator input and Make dispatch | DONE | P1 | S | standard | — | M0 |
| CIVO-015 | [015-governance-adrs-constitution](015-governance-adrs-constitution/spec.md) | ADRs 0027–0031, constitution §20, architecture §10a | DONE | P0 | M | strongest | — | M0 |
| CIVO-020 | [020-civo-feasibility-spike](020-civo-feasibility-spike/spec.md) | Throwaway-cluster feasibility spike and report | DONE | P0 | M | standard | — | M0 |
| CIVO-025 | [025-civo-persistent-stack](025-civo-persistent-stack/spec.md) | `persistent-civo` network and reserved IP | DONE | P1 | S | standard | 010, 015 | M1 |
| CIVO-030 | [030-civo-terraform-cluster](030-civo-terraform-cluster/spec.md) | `cluster-civo` firewall and k3s cluster | DONE | P1 | M | standard | 010, 015, 020, 025 | M1 |
| CIVO-040 | [040-civo-cluster-scripts](040-civo-cluster-scripts/spec.md) | Cluster scripts, kubeconfig, guards, leak sweep | DONE | P1 | M | standard | 030 | M1 |
| CIVO-045 | [045-argo-scripts-civo-branches](045-argo-scripts-civo-branches/spec.md) | `argo-up`/`argo-down` Civo branches | DONE | P1 | M | standard | 040, 050 | M1 |
| CIVO-050 | [050-gitops-civo-target-baseline](050-gitops-civo-target-baseline/spec.md) | Hoist portable components; `target: civo` tree; golden AWS render | DONE | P1 | M | standard | 010 | M1 |
| CIVO-060 | [060-civo-ingress-envoy-lb](060-civo-ingress-envoy-lb/spec.md) | Civo LB via Envoy Service, Gateway 80/443 | DONE | P1 | M | standard | 045 | M1 |
| CIVO-065 | [065-cert-manager-install](065-cert-manager-install/spec.md) | cert-manager installed on civo, target-gated | DONE | P1 | S | standard | 050 | M1 |
| CIVO-070 | [070-letsencrypt-http01-tls](070-letsencrypt-http01-tls/spec.md) | Let's Encrypt HTTP-01 TLS at Envoy, Secret persistence | READY | P1 | M | standard | 060, 065, 110 | M1 |
| CIVO-080 | [080-rolesanywhere-ca-ceremony](080-rolesanywhere-ca-ceremony/spec.md) | Offline CA ceremony and committed material | DONE | P0 | M | strongest | 015 | M1 |
| CIVO-082 | [082-rolesanywhere-terraform](082-rolesanywhere-terraform/spec.md) | Trust anchor, profile, roles, lab-role additions | IN_PROGRESS | P0 | M | strongest | 080 | M1 |
| CIVO-085 | [085-workload-certificate-issuance](085-workload-certificate-issuance/spec.md) | CA issuer Secret at argo-up, per-consumer Certificates | READY | P0 | M | strongest | 045, 050, 065, 080 | M1 |
| CIVO-090 | [090-credential-helper-sidecar](090-credential-helper-sidecar/spec.md) | Credential helper image and sidecar pattern | READY | P0 | M | standard | 082, 085 | M1 |
| CIVO-100 | [100-eso-on-civo](100-eso-on-civo/spec.md) | External Secrets on Civo via sidecar | READY | P1 | S | standard | 090 | M1 |
| CIVO-110 | [110-external-dns-on-civo](110-external-dns-on-civo/spec.md) | ExternalDNS on Civo via sidecar | READY | P1 | S | standard | 090, 060 | M1 |
| CIVO-120 | [120-cnpg-on-civo-persistence](120-cnpg-on-civo-persistence/spec.md) | CNPG on Civo with persistence through object-store backups | READY | P1 | L | strongest | 050, 100, 180 | M1 |
| CIVO-130 | [130-e2e-tests-civo](130-e2e-tests-civo/spec.md) | E2E suite on Civo | READY | P1 | M | standard | 045, 060 | M1 |
| CIVO-140 | [140-ci-workflow-civo](140-ci-workflow-civo/spec.md) | `lab.yml` provider input, token decrypt, concurrency, cleanup | READY | P1 | M | standard | 045, 015 | M1 |
| CIVO-150 | [150-teardown-recreate-validation](150-teardown-recreate-validation/spec.md) | Full lifecycle validation on Civo | READY | P1 | M | strongest | 120, 110, 070, 130 | M1 |
| CIVO-160 | [160-observability-on-civo](160-observability-on-civo/spec.md) | Observability stack on Civo | READY | P1 | M | standard | 050, 100 | M1 |
| CIVO-170 | [170-civo-cluster-autoscaler](170-civo-cluster-autoscaler/spec.md) | Cluster autoscaler 1–3 on the Large pool | READY | P3 | S | standard | 030 | M2 |
| CIVO-175 | [175-right-size-requests-and-sku](175-right-size-requests-and-sku/spec.md) | Right-size requests/limits, re-evaluate SKU | READY | P2 | M | standard | 160, 170 | M2 |
| CIVO-180 | [180-cnpg-backups-object-store](180-cnpg-backups-object-store/spec.md) | Shared logical backup and restore jobs with an S3 bucket | READY | P1 | M | standard | 082, 085, 100 | M1 |
| CIVO-185 | [185-aws-logical-backup-migration](185-aws-logical-backup-migration/spec.md) | Migrate the AWS target to the shared logical backups | READY | P2 | M | strongest | 120, 180 | M2 |
| CIVO-186 | [186-cross-provider-backup-promotion](186-cross-provider-backup-promotion/spec.md) | Promote dumps between providers; restore either target from the other | READY | P2 | S | standard | 180, 185 | M2 |
| CIVO-190 | [190-proxy-protocol-client-ip](190-proxy-protocol-client-ip/spec.md) | Proxy protocol and client IP | READY | P3 | S | fast | 060 | M2 |
| CIVO-200 | [200-identity-hardening](200-identity-hardening/spec.md) | Intermediate CA and Certificate approval policy | READY | P2 | M | strongest | 085 | M2 |
| CIVO-205 | [205-lab-role-least-privilege-review](205-lab-role-least-privilege-review/spec.md) | `lab-role` least-privilege review for civo-related statements | DRAFT | P2 | M | strongest | 082, 200 | M2 |

The headers in each `spec.md` are the source of truth. Keep this table in sync.
