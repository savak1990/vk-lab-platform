# ADR 0015: Business applications live in separate monorepos; this repo owns only their Application pointers

## Status

Accepted

## Context

The platform is expanding beyond infrastructure: the first business application (a set of microservices forming one product) is coming, with more applications expected later. This repo is PLATFORM-ONLY — business application source code must not be added to it — so the application's code, Dockerfiles, and per-service manifests need a home outside this repo. That raises a GitOps topology question `docs/architecture.md` and the existing specs don't answer: given multiple business-app repos will eventually exist, where do their Argo CD `Application`/app-of-apps manifests live, and how many levels of app-of-apps are needed?

The existing pattern in `gitops/templates/platform/aws/*/application.yaml` already establishes "one child Application per platform component, rendered by the `root` app-of-apps." The open question was whether business apps should extend that same flat list, or get their own nesting.

The deciding constraint is that the EKS cluster is Disposable (`make down`/`make up`): everything must be reconstructible from the `root` Application alone. That rules out a repo self-registering its own `Application` via its own CI (`kubectl apply`) — after a teardown, nothing re-applies it until that app's CI happens to run again for an unrelated reason. It also means the images a business app deploys must survive teardown, which fixes ECR to the Persistent lifecycle class, not Disposable: if images were deleted with the cluster, `make up` would recreate Applications pointing at tags that no longer exist, breaking the RECREATE → VERIFY RECOVERY leg of the full lifecycle acceptance test.

Cross-repo CI also needs its own AWS credentials path. The existing GitHub OIDC trust policy (spec 013) is scoped to `repo:<org>/vk-lab-platform:*`; a business-app monorepo is a different repo and won't match that `sub` claim, so it needs its own narrowly-scoped role.

## Decision

**Two-level app-of-apps, split across repos by ownership, not flattened into one list.**

- **This platform repo owns exactly one pointer `Application` per business application** — `gitops/templates/apps/<app-name>/application.yaml`, rendered by the existing `root` app-of-apps alongside `platform/`. Its `source.repoURL` points at the application's own monorepo; its `source.path` points at that monorepo's own app-of-apps chart. This is a reference, the same shape as a GitOps secret reference — it does not violate PLATFORM-ONLY.
- **Each application monorepo owns its own app-of-apps**, fanning out to one child `Application` per microservice it contains. Adding a microservice is a monorepo-only change (edit its own values list); adding a whole new application is one small file in this repo.
- **ApplicationSet's git-directory generator is not adopted now.** The Argo CD Helm chart (`argo-up.sh` installs `argo-helm/argo-cd`) bundles the ApplicationSet controller, so it remains available, but a Helm-templated values list — matching the pattern `platform/aws/*/application.yaml` already uses — is simpler for one operator managing a couple of services per app. Revisit only if "drop a folder, no chart edit" becomes a real requirement.
- **Container images are Persistent-lifecycle.** ECR repositories for business-app images are created by this repo's Terraform, in the persistent stack, not the disposable one, with a lifecycle policy capping untagged image retention for cost. They are never deleted by `make down`.
- **CI in each monorepo authenticates to AWS via its own OIDC-trusted IAM role**, scoped to ECR push only (`ecr:GetAuthorizationToken`, `BatchCheckLayerAvailability`, `PutImage`, `Upload*` actions), trusted only from that monorepo's `sub` claim. This role and its trust policy are created by this platform repo's Terraform (bootstrap/persistent, alongside the existing OIDC provider), since IAM and the OIDC provider are this repo's responsibility regardless of which repo the workload code lives in.
- **CD handoff is a git commit, not a live cluster call.** Each monorepo's CI builds and pushes only the services whose paths changed, tags images by commit SHA (never `latest`, so Argo's diff stays meaningful), and commits the new SHA into that monorepo's own app-of-apps values file. Argo reconciles on its next sync. This is deliberately chosen over Argo CD Image Updater: it needs no extra controller running in a disposable cluster, and it works even while the cluster is torn down — the push and the commit both succeed against a destroyed cluster, and Argo catches up once `make up` brings it back.
- **Each business application gets its own `AppProject`** (namespace + resource whitelist) rather than continuing to use `project: default` once business apps exist. `default` remains acceptable only while the tree under `root` is platform-only.

## Consequences

- `gitops/templates/apps/` is a new directory alongside the existing `gitops/templates/platform/`; `root`'s existing render-everything-under-`gitops/templates` behavior picks up new application pointers with no change to `gitops/bootstrap`.
- A new Persistent-lifecycle Terraform unit (or an addition to an existing persistent unit) is needed for per-application ECR repositories, each tagged per the standard tagging block (`Lifecycle=persistent`).
- A new IAM role + OIDC trust policy is needed per application monorepo (or one role reused with a `sub` condition covering multiple monorepos under the same org, if that narrowing is acceptable) — this is platform-repo Terraform work, tracked separately from the monorepo's own CI workflow files.
- Business apps that depend on Postgres/Kafka cannot rely on Argo sync-wave numbers alone for readiness across separate Applications (same caveat already documented for platform components) — a `PreSync` hook waiting on the concrete dependency (a Secret key, a CRD's `Established` condition) is required, not wave ordering.
- The monorepo's own build workflow must exclude its `gitops/`/`deploy/` path from its own change-trigger filter, or the tag-commit in the CD step will retrigger the build.
- If a future application genuinely needs per-service auto-discovery without a chart edit, this ADR's ApplicationSet decision should be revisited explicitly rather than silently mixed with the Helm-loop pattern used elsewhere.
