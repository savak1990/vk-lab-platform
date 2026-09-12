# Decisions

## 1. Accepted starting constraints (from the user, 2026-09-11)

- `PROVIDER=local` is a third provider next to `aws` and `civo`, reusing
  the full lifecycle command surface (`full-up`, `up`, `down`, `full-down`
  and the per-stage targets). Stages with no local meaning are no-ops.
- The platform does not create, configure, or delete the local cluster.
  The developer brings one (minikube today; kind, k3d, Docker Desktop
  equally). `cluster-up` only checks the current kubectl context is local
  (decided 2026-09-11, replacing an earlier kind-creates-the-cluster plan).
- Default project name `vk-local-lab`.
- No cloud services except AWS KMS to decrypt the committed ciphertext.
- Postgres data in a `Retain` volume on the node, provisioned by a
  platform-owned local-path provisioner; survives `make down`; dies with
  the cluster. No backups. Mounting the node path from the repository is
  an optional developer step.
- No DNS; Envoy reached by `kubectl port-forward`.
- Observability deployed, trimmed, always on.
- The e2e suite runs against the local cluster.
- A GitHub Actions workflow runs the whole lifecycle on a hosted runner.
- Every spec uses the `specs/civo/` YAML front-matter header.
- The stale root-level local specs are deleted, not amended.

## 2. ADR and amendments (proposed, LOCAL-015)

| ADR | Title | Conflict it resolves | Rationale | Reversibility |
|---|---|---|---|---|
| 0032 | `local` as a third `PROVIDER` on a developer-owned cluster, superseding ADR 0006 | ADR 0006 and architecture §10a say `target` and `PROVIDER` are orthogonal and `local` is target-only; constitution §17 exempts `kind-up`/`minikube-up` from the lifecycle surface; §20 calls `PROVIDER` "real (non-`local`)" | one command surface for three providers; the cluster is outside the lifecycle classes; Bootstrap = nothing, Persistent = the `local-retain` node directory, Disposable = every Argo-managed resource; gitops `target` is set from `PROVIDER` by `argo-up`, never chosen independently | high: delete the branches |
| Constitution §17 | remove the `kind-up`/`minikube-up` exemption; `local` uses the lifecycle surface; `cluster-up` is a guard, `cluster-down` a no-op | §17's "separate, non-lifecycle-class commands" sentence | one-command-per-class holds for local too; the cluster itself is explicitly outside the classes | high |
| Constitution §18 | "target" → "provider"; the one permitted AWS call is `kms:Decrypt` of committed ciphertext; §4 applies to the `local-retain` directory; port-forward stays the access path; keep "never a substitute for the `aws` full lifecycle test" | §18 forbids any AWS use and says data is throwaway | secrets stay in one mechanism; `down`/`up` data survival is a real guarantee worth stating | high |
| Constitution §20 | drop "real (non-`local`)"; "`local` is the third provider, §18" | §20 wording | consistency | high |
| architecture §10a | rewrite: three providers; `target` derived from `PROVIDER`; remove "not yet implemented" paragraph | stale text | — | high |
| ADR 0006 | mark Superseded by ADR 0032 | — | keeps history | — |
| Specs 022, 024 | delete | superseded by this package | user decision: a rewrite is cleaner than an amendment | — |

## 3. Open decisions

| Decision | Options | Recommendation | Trade-offs | Reversible | Affected specs | Blocks READY |
|---|---|---|---|---|---|---|
| CI secrets for the local job | (a) reuse `secrets/vk-local-lab/` (the personal lab's passwords) on the public runner; (b) `PROJECT_NAME=vk-local-ci` with `FIXED_TEST_PASSWORDS=true`, `persistent-up` runs `generate-secrets` when the directory is missing (needs `kms:Encrypt`; the lab role has it) | **(b)** — mirrors what `lifecycle-test.yml` already does for `vk-lab-ci` | (a) is simpler but places real lab passwords on a shared runner; (b) needs one extra branch in `persistent-up` | high | 010, 090 | no |
| Forward port | 8080 (default) vs 80 (`http://argo.localhost` with no port) | 8080 for M1; `LOCAL_HOST_PORT` overrides | 80 needs privileges on some systems | high | 050 | no |
| Storage provisioner | (a) the cluster's bundled provisioner; (b) platform-owned local-path-provisioner Application | **Decided 2026-09-11: (b).** minikube (`storage-provisioner`, `/tmp/hostpath-provisioner`) and kind (`rancher.io/local-path`, version varies) differ; owning it makes `pathPattern` and the node path identical everywhere | one more Application; version-pinned | high | 040 | no |
| Argo source for a developer branch | (a) push the branch, `argo-up` sets `targetRevision` to it; (b) in-cluster Gitea mirroring the working tree | (a) | (b) gives unpushed iteration but adds a component and a push step of its own | high | 010 | no |
| Data-loss gate on local | honour `CI_TEARDOWN_ALLOW_DATA_LOSS` (as civo) vs none | none — `make down` loses nothing; the platform never deletes the cluster or the node directory | — | high | 010 | no |
| Repo-folder data location | mount `.local/` onto the node path by default vs optional | optional (LOCAL-110 one-liner) — a default would need per-tool cluster configuration the platform no longer owns | data location differs per developer | high | 110 | no |

## 4. Rejected alternatives

- `make kind-up` / `make minikube-up` outside the lifecycle classes (spec
  022, constitution §17): two command surfaces, no `full-up` parity, no CI
  reuse.
- `target=local` independent of `PROVIDER` (ADR 0006): a fourth axis with no
  consumer; every script would still need a local branch.
- Path-based routing (`/argo`, `/grafana`, spec 022 Req 9): changes the
  shared HTTPRoutes and Grafana's `root_url` for one target; hostname
  routing on `*.localhost` keeps the routes identical.
- `cloud-provider-kind` LoadBalancer emulation: sudo, ephemeral host ports,
  alpha, kind-only.
- The platform creating the cluster (`kind create cluster` from `make
  cluster-up`, first draft of this package): ties the Makefile to one
  tool's config format, cannot serve the user's existing minikube, and
  makes `down` delete the cluster. Replaced by the context guard.
- NodePort + kind `extraPortMappings` for Envoy: depends on the cluster
  tool's port mapping; port-forward works everywhere.
- Random passwords when no AWS credentials exist (spec 022 Req 11): a
  second secrets path and a password/data-directory consistency problem;
  the user has KMS access and wants one path.
- Sealed Secrets: the key is per cluster; a recreated kind cluster cannot
  decrypt old material.
- Relying on the cluster's bundled storage provisioner: differs per tool.
- Tempo/OTel in M1: not deployed on any target yet (ADR 0018, spec 029).
