# Specs

Specs are grouped by execution target. Each spec is a folder with a `spec.md`.

| Folder | Holds | `id` prefix |
|---|---|---|
| `aws/` | AWS/EKS target specs | `AWS-` |
| `civo/` | Civo target package (see its README) | `CIVO-` |
| `hetzner/` | Hetzner target package (see its README) | `HETZ-` |
| `local/` | `local` (kind) target specs | `LOCAL-` |
| `shared/` | Specs that apply to every target, including the constitution | `SHARED-` |

## Folder name

`NNN-X-name`, for example `aws/025-Z-kafka`.

- `NNN` (with an optional sub-number such as `006-1`) and the front-matter
  `id` are the stable identifiers. Never renumber them.
- `X` is the status letter. When `status:` changes, rename the folder in the
  same commit and update links to it.

## Status letters

| Letter | Meaning | `status:` values |
|---|---|---|
| `D` | done | `DONE` |
| `A` | active | `IN_PROGRESS` |
| `P` | planned | `DRAFT`, `READY`, `BLOCKED` |
| `Z` | closed, not done | `DEFERRED`, `SUPERSEDED`, `CANCELLED` |

The front-matter `status:` is the source of truth; the letter is a coarse view
of it. Status meanings are in `civo/README.md` (Status protocol).

Run `make specs-check` after any spec move or status change.
