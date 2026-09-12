---
id: "LOCAL-110"
title: "README quickstart and workstation prerequisites"
status: "READY"
priority: "P2"
milestone: "M2"
type: "documentation"
difficulty: "S"
recommended_model_tier: "fast"
model_rationale: "Prose from facts already recorded in LOCAL-010 through LOCAL-090 evidence"
effort_estimate: "One short session (1–2 h)"
estimate_confidence: "high"
depends_on: ["LOCAL-090"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: null
---

# LOCAL-110 — README quickstart and workstation prerequisites

## 1. Outcome and rationale

A developer who has never seen the repository can go from clone to
`http://argo.localhost:8080` by following one README section, and knows
the three things that commonly go wrong (a non-local kubectl context,
memory, `*.localhost` in Safari and on the command line).

## 2. Scope and non-goals

In scope:
- `README.md` section "Run it locally": prerequisites (a running local
  cluster — minikube `--memory 6g --cpus 4` or kind — with its context
  current; kubectl; helm; AWS credentials with `kms:Decrypt` on
  `alias/lab-secrets`), the commands (`PROVIDER=local make up`,
  `make local-forward`, `make test`, `make down`), where the data lives on
  the node and the optional `minikube mount` / kind `extraMounts`
  one-liner to keep it in the repository's gitignored `.local/`, how to
  open Argo CD and Grafana (Chrome/Firefox direct; Safari and curl need
  `/etc/hosts` or `--resolve`), how to pick a branch (`TARGET_REVISION`;
  push first), how to change the forward port (`LOCAL_HOST_PORT`), and
  that the minikube `metrics-server` addon must stay off.
- `docs/architecture.md` §10a cross-link to `specs/local/` (LOCAL-015
  already rewrote the section; this adds the quickstart pointer).
- A short troubleshooting list: "context does not look local" →
  `LOCAL_CONTEXT_PATTERN` or switch context; Prometheus evicted → memory;
  port 8080 busy → `LOCAL_HOST_PORT`; password mismatch after ciphertext
  change → delete the `local-retain` PV and the node directory.

Not in scope:
- Changing any behaviour.
- Driver-specific tuning beyond the one-liners above.

## 3. Current state / evidence

`README.md` documents the AWS and Civo flows; nothing about local.
Constitution §18 (as amended) and ADR 0032 are the normative text; this is
the operational text.

## 4. Design and contracts

Placeholders only (`<root-domain>` is not needed here at all). No real
passwords, hostnames, or account IDs. The section is under 80 lines.

## 5. Files/components affected

`README.md`; `docs/architecture.md` (one pointer).

## 6. Implementation steps

1. Write the section from LOCAL-010/020/090 evidence.
2. Have one person follow it on a clean clone; fix what tripped them.

## 7. Dependencies and blockers

LOCAL-090 (the flow is proven).

## 8. Acceptance criteria

- A clean-clone walkthrough succeeds by following only the README.
- Every troubleshooting entry maps to a message the scripts actually print.

## 9. Validation

Manual walkthrough.

## 10. AWS regression protection

Docs only.

## 11. Rollout and rollback/recovery

Revert.

## 12. Risks and unresolved questions

None.

## 13. Definition of done

- [ ] README section and pointer landed; walkthrough done
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as `DRAFT` (blocked on LOCAL-090).
