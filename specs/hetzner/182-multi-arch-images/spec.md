---
id: "HETZ-182"
title: "Repo-built images published for linux/arm64 as well as linux/amd64"
status: "DRAFT"
priority: "P0"
milestone: "M1"
type: "implementation"
difficulty: "S"
recommended_model_tier: "fast"
model_rationale: "A buildx flag and a digest rule; the only judgement is which spec owns each pin"
effort_estimate: "Under two hours"
estimate_confidence: "high"
depends_on: ["CIVO-180"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: ""
---

# HETZ-182 — Multi-arch images

## 1. Outcome and rationale

Every image this repository builds is published as a manifest list with
`linux/amd64` and `linux/arm64` layers, and every image the platform pins
by digest uses the manifest-list digest. Hetzner nodes are arm64 (CAX);
without this, the backup CronJob and the restore Job from CIVO-180 cannot
start there, and CNPG persistence (HETZ-120) has no mechanism.

## 2. Scope and non-goals

In scope: the `images/pg-backup` build workflow from CIVO-180, its digest
pin in `gitops/values.yaml`, and a repository rule for future images.
Not in scope: the credential-helper pin (HETZ-085 owns that line), any
upstream chart image (all verified multi-arch in `research.md`), and any
change to what the images do.

## 3. Current state / evidence

- CIVO-180 is `READY` and unstarted at the baseline date. Its §4 describes a single-platform `docker build` in a GitHub Actions workflow and a digest pin.
- `research.md` (ARM row) lists every upstream image as multi-arch and names `images/pg-backup` as the only risk.
- No other repo-built image exists (`.github/workflows/` holds `lab.yml` and `lifecycle-test.yml` only).

## 4. Design and contracts

- Amend CIVO-180 §4 before it is implemented: the workflow uses `docker/setup-qemu-action`, `docker/setup-buildx-action` and `docker/build-push-action` with `platforms: linux/amd64,linux/arm64`, pushes to GHCR under the repository, and writes the **manifest-list digest** to the job summary.
- The values pin `postgres.backup.image` (name per CIVO-180) is the manifest-list digest. A per-platform digest is never pinned.
- Rule recorded in `CLAUDE.md` (one line under Validation): every repo-built image is a two-platform manifest list; `docker manifest inspect` is part of the image's validation.
- Base image for `pg-backup` must itself be multi-arch (`postgres:17` and `amazon/aws-cli` are; the aws-cli binary install method, if any, must select the architecture at build time with `TARGETARCH`).

## 5. Files/components affected

- `specs/civo/180-cnpg-backups-object-store/spec.md` §4 and §8 (amendment, with a status-history line).
- `.github/workflows/<pg-backup build>.yml` (as CIVO-180 names it).
- `images/pg-backup/Dockerfile` — `ARG TARGETARCH` where a binary download depends on it.
- `gitops/values.yaml` — digest pin.
- `CLAUDE.md` — one validation line.

## 6. Implementation steps

1. Amend CIVO-180 §4 and §8 with the buildx requirement and the manifest-inspect acceptance check. Add the status-history line.
2. If CIVO-180 is already `IN_PROGRESS` or `DONE`, apply the change to the workflow and Dockerfile directly and rebuild.
3. Run the workflow; record the manifest-list digest and both platform digests.
4. Pin the manifest-list digest in values; render `aws`, `civo`, `hetzner`.
5. Add the `CLAUDE.md` line.

## 7. Dependencies and blockers

CIVO-180 supplies the image and the workflow. This spec can land as an
amendment before CIVO-180 starts, which is the cheapest path.

## 8. Acceptance criteria

- `docker manifest inspect ghcr.io/<repo>/pg-backup@<digest>` lists `linux/amd64` and `linux/arm64`.
- `docker run --platform linux/arm64 … pg_dump --version` and `aws --version` succeed under QEMU.
- The values pin equals the manifest-list digest.
- CIVO-180's backup CronJob on Civo (amd64) runs on the new image with identical output.

## 9. Validation

Offline: workflow lint (`actionlint`), `docker manifest inspect`. No cloud
resources.

## 10. AWS regression protection

The AWS target does not use the image until CIVO-185. Civo uses the amd64
layer, whose content is built from the same Dockerfile as before; one
CronJob run on Civo confirms identical behaviour.

## 11. Rollout and rollback/recovery

Rollback is the previous digest pin. The workflow change is additive.

## 12. Risks and unresolved questions

- QEMU builds of `postgres`-based images are slow (several minutes); acceptable for a rarely rebuilt image.
- If the Dockerfile downloads a static AWS CLI, the download URL must switch on `TARGETARCH`; `pip install awscli` avoids the problem at the cost of image size.

## 13. Definition of done

- [ ] Acceptance criteria met and recorded
- [ ] CIVO-180 amended and its index row unchanged in status
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
