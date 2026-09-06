# Review of `docs/architecture.md` against the repository (2026-09-06)

Baseline: branch `main`, commit `cfbb59bd340b6356bad3fb2493b41fa3a337efe5`.
Scope: factual drift between the architecture document (and adjacent
`README.md`/`CLAUDE.md` lines) and what exists on disk. Fixes are collected
as a documentation pass inside `specs/civo/015-governance-adrs-constitution`
so that the Civo amendments land on an accurate base.

## Stale or inaccurate statements

| # | Location | Says | Reality | Fix |
|---|---|---|---|---|
| 1 | `architecture.md:14-16`, §3 items 6–7, §14, §21, §22, §28 | Kafka (Strimzi) is a running platform component; Kafka data is persistent; validation produces Kafka data | Kafka removed from the running platform by ADR 0017; no `gitops/` Kafka component exists; spec 025 deferred | Mark Kafka as deferred wherever it is listed as current; keep §14 as target-state with a "deferred (ADR 0017)" banner |
| 2 | `architecture.md:180-260` (§5 repository tree) | `gitops/platform/{argocd,aws,autoscaling,gateway,observability}/`, `gitops/data/{postgres,kafka,debezium}/`, `gitops/workloads/integration/`, `gitops/bootstrap/root-application.yaml`, `terraform/live/.../argocd-bootstrap/`, `secrets-store-csi/` | Actual: `gitops/bootstrap/` (Helm chart, `templates/root-application.yaml`), `gitops/templates/platform/aws/<component>/` (flat, 25 files). No `secrets-store-csi`, no `argocd-bootstrap` unit (ADR 0012), no `data/`, no `workloads/` | Replace the tree with the real one; note ESO instead of secrets-store-csi |
| 3 | `architecture.md:579-603` (§10a) | Every component is one Helm chart with `values.yaml` + `values-aws.yaml` + `values-local.yaml`; `local` forces `ClusterIP` in `values-local.yaml` | One umbrella chart; per-file `{{- if eq .Values.target "aws" }}` gates; no `values-<target>.yaml` exists; `local` target renders an empty chart; `make kind-up`/`minikube-up` do not exist | Describe the umbrella-chart gating as implemented; mark `local` as specified but not implemented (spec 022) |
| 4 | `architecture.md:26,101,356,416-419,611,909-1026,1192,1216,1341,1973` | Runtime secrets live in AWS Secrets Manager; `persistent-up` creates Secrets Manager resources; `persistent-down` deletes Secrets Manager contents | ADR 0023 moved runtime config and secrets to SSM Parameter Store (`/<project>/...`); no `aws_secretsmanager_secret` resource exists; the only Secrets Manager call is `get-random-password` | Replace "Secrets Manager" with "SSM Parameter Store (ADR 0023)" in those places; keep Secrets Manager only as an allowed option |
| 5 | `architecture.md:195` and §21a/§22 mentions of Terraform-installed Argo CD | `argocd-bootstrap` Terraform unit | Argo CD installed by `scripts/argo-up.sh` (ADR 0012) | Remove the unit from the tree; §7 already says "Terraform may install the initial Argo CD"; align with ADR 0012 |
| 6 | `architecture.md:446, 1068` and §19 | Tempo and OTel Collector are part of the running stack | Deferred by ADR 0018 to spec 029 | Mark deferred |
| 7 | `architecture.md:509-517` (§9 system node) and ADR 0019 | System-node pinning via `node-type=system` | ADR 0019 replaced pinning with spot anti-affinity for most components; `node-type: system` still used by Karpenter and external-dns only | Describe both mechanisms accurately |
| 8 | `README.md:19-24` | Full disposable stack including Kafka (spec 024) implemented | Kafka absent; "024" is a pre-renumber ID | Correct the list and IDs |
| 9 | `CLAUDE.md:68` | VPC/subnets deferred to spec 021; default VPC used | Spec 021 implemented; dedicated VPC exists (`terraform/live/persistent/vpc`, ADR 0020) | Update the lifecycle list |
| 10 | `terraform/live/persistent/README.md` | Describes a `${PROJECT_NAME}-secrets` Secrets Manager secret | SSM parameters instead | Update |
| 11 | `scripts/state-down.sh:30` and `root.hcl:26-28` | State prefixes `disposable`, `ci` | Real prefix is `cluster/`; `terraform/live/ci/` does not exist | Code fix (in CIVO-040), doc note in §33 |
| 12 | `architecture.md` §5 lists four workflows (`validate.yml`, `platform-integration.yml`, `kind-integration.yml`, stale cleanup) | Target state | Only `lab.yml` exists | Label as target state, not current |

## Accurate and load-bearing (keep as-is)

- §6 lifecycle classes and the State layer text (ADR 0004/0005).
- §7 ownership split and the "never both" invariant.
- §10 dedicated VPC, no NAT (ADR 0020).
- §11–12 NLB + ACM edge and ExternalDNS ownership (ADR 0011, 0002).
- §13 CNPG and VolumeSnapshot recovery (ADR 0009, 0013).
- §17a account bootstrap and GitHub OIDC (ADR 0021, 0022).
- §21 deletion ordering and §23–24 shutdown postconditions, which `scripts/argo-down.sh` implements faithfully.
- §33 state separation and locking (native S3 lockfile).
- §39 tagging standard.

## Structural recommendation

`docs/architecture.md` is 1999 lines and mixes target state, current
state, and procedure. Two companion documents now carry the current state
so the architecture document can stay a north star:

- `docs/aws-platform-design.md` — how the AWS platform works today, by stage, with file references.
- `docs/argocd-design.md` — the Argo CD bootstrap, app-of-apps, ordering, and teardown design.
- `docs/civo-high-level-design.md` — the Civo target.

CIVO-015 applies the fixes in the table above and adds a short "Current
state vs target state" note at the top of `architecture.md` pointing to the
three companion documents.
