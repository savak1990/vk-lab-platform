---
id: "LOCAL-015"
title: "ADR 0032, constitution §17/§18/§20, architecture §10a, delete specs 022/024"
status: "READY"
priority: "P0"
milestone: "M0"
type: "governance"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "Prose edits with a fixed list of files; the design decisions are already made in this package"
effort_estimate: "One session (2–3 h)"
estimate_confidence: "high"
depends_on: []
blocked_by: []
supersedes: ["ADR 0006", "spec 022", "spec 024"]
created: "2026-09-11"
updated: "2026-09-11"
completed: null
---

# LOCAL-015 — ADR 0032, constitution §17/§18/§20, architecture §10a, delete specs 022/024

## 1. Outcome and rationale

The governing documents describe `local` the way this package builds it: a
third `PROVIDER` that reuses the lifecycle command surface on a
developer-owned cluster, with lifecycle classes mapped to local artifacts
and KMS decrypt as its single AWS call.
The old design (gitops-only `target`, `make kind-up`/`make minikube-up`
outside the lifecycle classes, placeholder secrets by default,
`kubectl port-forward`) is removed rather than left to contradict the code.
Constitution §13 requires this to land before implementation is marked done.

## 2. Scope and non-goals

In scope:
- New `docs/adr/0032-local-third-provider.md`.
- `docs/adr/0006-local-dev-mode-target.md` status → `Superseded by ADR 0032`.
- Constitution §17, §18, §20 text edits (exact wording in §4 below).
- `docs/architecture.md` §10a rewrite; the four other `architecture.md`
  mentions of spec 022/024 (`:236,:881,:1023,:1182` at baseline).
- Delete `specs/022-local-dev-mode/` and `specs/024-ci-kind-integration-test/`.
- Fix every cross-reference in the file list in §5.

Not in scope:
- Any code, Makefile, script, or gitops change.
- Re-litigating the decisions in `decisions.md`.

## 3. Current state / evidence

- Constitution §17 (`specs/000-constitution/spec.md:323`): "`make
  minikube-up` and `make kind-up` (the `local` target, §18) are separate,
  non-lifecycle-class commands…"
- §18 (`:329-350`): `local` is "a second execution target", AWS-free
  except opt-in KMS decrypt "instead of the default placeholder
  credentials"; §3 does not apply ("not a fifth class"); §4 does not apply
  ("fully throwaway"); §8 access "via `kubectl port-forward`".
- §20 (`:364`): "`PROVIDER` … selects Civo as a second, real (non-`local`)
  execution target… `local` remains AWS-free by design."
- `docs/architecture.md:501-531` §10a: "`PROVIDER` (aws/civo) and `target`
  (aws/local) are orthogonal"; "The Civo target renders with `target=aws`
  gitops values" (already stale — `scripts/argo-up.sh:408` sets
  `target=civo`); "`make minikube-up`/`make kind-up` … not yet implemented".
- ADR 0006 status `Accepted`.
- `grep -rl "spec 022\|spec 024\|022-local\|024-ci-kind" specs docs` at
  baseline lists 30 files (excluding `specs/local/`), see §5.

## 4. Design and contracts

**ADR 0032 — `local` as a third `PROVIDER` on a developer-owned cluster.** Sections: Status
(Accepted), Context (developer loop; ADR 0006 unimplemented and stale;
user decision 2026-09-11), Decision (`PROVIDER=local`; the cluster is
developer-owned — any of minikube, kind, k3d, Docker Desktop — and the
platform never creates or deletes it; `cluster-up` is a fail-closed
context guard; project `vk-local-lab`; `target` derived from `PROVIDER` by
`argo-up`, never set independently; lifecycle mapping table: cluster
outside the classes / Bootstrap = nothing / Persistent = the `local-retain`
data directory on the node / Disposable = every Argo-managed resource;
KMS decrypt is the only AWS call; Secrets created by `argo-up`; the
platform installs its own local-path provisioner; Envoy reached by
port-forward, hostname routes on `*.localhost`; no TLS; no backups — the
node directory is the persistence mechanism; observability trimmed),
Consequences (one command surface; `full-up` collapses to `up`; CI creates
its own cluster before `make up`; `*.localhost` resolver caveat; data
lives only as long as the developer's cluster; what `local` does not
prove — never a substitute for the `aws` lifecycle test), Alternatives rejected (from
`decisions.md` §4), Supersedes ADR 0006.

**Constitution §17** — replace the `minikube-up`/`kind-up` bullet with:

> - The `local` provider (§18) uses the same command pairs. `PROVIDER=local`
>   dispatches them; there is no separate local command set. The cluster
>   itself is developer-owned and outside the lifecycle classes: the
>   platform never creates or deletes it. For `local`, `state-*`,
>   `bootstrap-*`, `persistent-*`, and `cluster-down` are no-ops that exit
>   0; `cluster-up` only verifies the current kubectl context is a local
>   cluster and refuses otherwise; `up`/`down` install and remove the
>   Argo-managed platform (ADR 0032).

**Constitution §18** — rewrite as "Local Execution Provider Scope":

> The platform supports a third provider, `local` (a developer-owned
> cluster — minikube, kind, k3d, Docker Desktop — on a workstation or a CI
> runner), selected with `PROVIDER=local` (ADR 0032, `specs/local/`). The
> platform never creates or deletes that cluster. It is AWS-free except for exactly one call: `kms:Decrypt`
> of the committed ciphertext under `secrets/<project>/`, performed by
> `make argo-up` to create workload `Secret` objects directly. There is no
> placeholder-credential mode.
>
> - **§3 (Lifecycle Separation)** applies with the ADR 0032 mapping: the
>   cluster is outside the classes; Bootstrap = nothing; Persistent = the
>   `local-retain` data directory on the node; Disposable = every
>   Argo-managed resource.
> - **§4 (Persistence Safety)** applies to that directory: `make down` MUST
>   NOT delete it (the `local-retain` class reclaims `Retain` and volumes
>   re-bind by namespace/PVC name); `make down` → `make up` data survival
>   MUST be proven (LOCAL-090). There is no backup mechanism; deleting the
>   developer's cluster deletes the data.
> - **§5 (Security)** — `local` MUST NOT use SSM, Secrets Manager, External
>   Secrets, EKS Pod Identity, or IAM Roles Anywhere.
> - **§8 (Public Traffic)** — no Route 53, NLB, ACM, or ExternalDNS. Envoy
>   Gateway's Service is `ClusterIP`, reached by `kubectl port-forward`;
>   routes use `*.localhost` hostnames; there is no TLS.
> - **§9, §14, §16** are vacuously satisfied (no cloud resources).
>
> A successful `local` run is never a substitute for the `aws` full
> lifecycle test (§11) or §12's Definition of Done.

**Constitution §20** — first sentence becomes: "The `PROVIDER` operator
input selects Civo as a second cloud execution target (ADR 0027); `local`
(§18) is the third provider." Delete "It is not a substitute for §18's
`local` target. `local` remains AWS-free by design."

**architecture.md §10a** — three providers; `target` is derived from
`PROVIDER` by `argo-up` (`aws`→`aws`, `civo`→`civo`, `local`→`local`);
delete the "orthogonal" sentence, the "renders with `target=aws`" sentence,
and the "not yet implemented" paragraph; add the lifecycle mapping table
and a pointer to `specs/local/`.

## 5. Files/components affected

New: `docs/adr/0032-local-third-provider.md`.
Edited: `docs/adr/0006-local-dev-mode-target.md`,
`specs/000-constitution/spec.md`, `docs/architecture.md`.
Deleted: `specs/022-local-dev-mode/`, `specs/024-ci-kind-integration-test/`.
Cross-references (replace "spec 022"/"spec 024"/"ADR 0006" with
"`specs/local/`"/the matching LOCAL id/"ADR 0032" as fits each sentence):
`docs/adr/0007`, `0009`, `0016`, `0017`, `0018`, `0027`;
`docs/architecture-review-2026-09-06.md`; `docs/aws-platform-design.md`;
`specs/004`, `005`, `006`, `006-1`, `007`, `009`, `010`, `011`, `013`,
`014`, `016`, `019`, `023`, `025`, `026`, `027`, `034`; `specs/civo/140`.
Re-run the grep at implementation time; the baseline count is 30.

## 6. Implementation steps

1. Write ADR 0032 from the §4 outline.
2. Mark ADR 0006 superseded (status line + one-line pointer).
3. Apply the §17/§18/§20 text.
4. Rewrite architecture.md §10a; fix its other four mentions.
5. `git rm -r specs/022-local-dev-mode specs/024-ci-kind-integration-test`.
6. Fix each cross-reference file; re-run the grep until only
   `specs/local/` and ADR 0006's own supersession line match.
7. `yamllint`/markdown lint as the repo already runs; `make gitops-check`
   (no change expected — sanity).

## 7. Dependencies and blockers

None. Must be on `main` before LOCAL-010 is marked `DONE`.

## 8. Acceptance criteria

- ADR 0032 exists with all sections; ADR 0006 reads `Superseded`.
- Constitution §17 no longer names `kind-up`/`minikube-up`; §18 matches
  §4; §20 no longer says "non-`local`".
- architecture.md §10a has no "orthogonal", "renders with `target=aws`",
  or "not yet implemented" text for `local`.
- `specs/022-*` and `specs/024-*` are gone.
- `grep -rn "spec 022\|spec 024\|022-local\|024-ci-kind" specs docs`
  matches only `specs/local/` and ADR 0006's supersession line.

## 9. Validation

Offline only: the grep in §8; `make gitops-check`.

## 10. AWS regression protection

No code. `make gitops-check` golden diff empty by construction.

## 11. Rollout and rollback/recovery

Revert the commit.

## 12. Risks and unresolved questions

- Constitution §18's new "§4 applies" clause makes `down`→`up` data
  survival mandatory for local; LOCAL-090 carries it. If the spike
  (LOCAL-020) shows CNPG cannot adopt an existing directory, §18 must be
  re-amended to "data is throwaway" and LOCAL-040 narrowed — do not leave
  the constitution promising what the code cannot do.

## 13. Definition of done

- [ ] ADR 0032 written; ADR 0006 superseded
- [ ] §17/§18/§20 and §10a edited; specs 022/024 deleted
- [ ] Cross-reference grep clean; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as `READY`.
- 2026-09-11 — replanned: cluster is developer-owned; mapping and §17/§18 text updated.
