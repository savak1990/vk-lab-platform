---
id: "HETZ-150"
title: "Full lifecycle validation on Hetzner: create, write, destroy, verify, recreate, verify, destroy, no leaks"
status: "READY"
priority: "P1"
milestone: "M1"
type: "validation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "Judging leak and persistence evidence across a resource model where load balancers, volumes and IPs outlive servers"
effort_estimate: "One session (4–6 h wall clock, mostly waiting)"
estimate_confidence: "medium"
depends_on: ["HETZ-070", "HETZ-120", "HETZ-130"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: ""
---

# HETZ-150 — Lifecycle validation

## 1. Outcome and rationale

The constitution §11 acceptance test passes on Hetzner end to end with
recorded evidence. A classification table names the owner and the
destroy/retain policy for every Hetzner and AWS resource the target uses.
The distinguishing risk on Hetzner: nothing is "the cluster". Servers,
load balancers, volumes and primary IPs are independent billable objects,
and only servers and the firewall are in Terraform state.

Read `specs/civo/150-teardown-recreate-validation/spec.md` first.

## 2. Scope and non-goals

In scope: the runbook `tests/manual/hetzner-150-lifecycle.md`, its
execution, the evidence, the classification table, the leak checks, the
cost record. Not in scope: code changes beyond small fixes found during
the run; those go to the owning spec.

## 3. Current state / evidence

AWS runbooks live under `tests/manual/`. `argo-down.sh` has the dump gate
and the LB-gone wait (HETZ-045). `cluster-down.sh` has the label sweep
(HETZ-040). `hcloud <resource> list -l project=<project> -o json` lists
every labelled resource.

## 4. Design and contracts

Classification table, filled during execution:

| Resource | Lifecycle | Owner | On `argo-down` | On `cluster-down` | On `persistent-down` | On `bootstrap-down` |
|---|---|---|---|---|---|---|
| Servers ×3 (`cax21`) | cluster | Terraform | — | destroyed | — | — |
| Primary IPv4/IPv6 ×3 | cluster | Terraform via server (`auto_delete` confirmed) | — | deleted with the server; swept if detached | — | — |
| Firewall | cluster | Terraform | — | destroyed | — | — |
| hcloud LB11 | cluster | CCM via Envoy Service | deleted (gate waits for it) | must be absent; swept by label | — | — |
| CSI volumes (CNPG, observability) | cluster (Delete class) | CSI | deleted with PVCs (PVC wait) | must be absent; swept by label | — | — |
| Network, subnet, SSH key | persistent | Terraform | — | untouched | destroyed | — |
| Route 53 records | cluster | ExternalDNS | deleted (gate) | must be absent | — | — |
| Route 53 zone `hetzner.` | bootstrap | Terraform | — | — | — | destroyed |
| TLS Secret copy (SSM) | persistent | scripts | written | — | deleted | — |
| S3 dumps | persistent | backup job | written | untouched | emptied after confirmation | — |
| Roles Anywhere anchor/profile/roles | bootstrap | Terraform | — | — | — | destroyed |
| CA files, SSH key files | bootstrap (Git) | operator | — | — | — | rotate/delete manually |
| SSM parameters | per layer | Terraform | — | cluster ones destroyed | persistent ones destroyed | bootstrap ones destroyed |
| `kube-system/hcloud` Secret, CCM release | cluster | `argo-up` | dies with the cluster | — | — | — |
| KMS key, OIDC, lab-role | account | Terraform | — | — | — | — (account-down only) |

Steps, each with its command and result recorded:

1. `PROVIDER=aws make status` and `PROVIDER=civo make status` (before).
2. `PROVIDER=hetzner make full-up`.
3. Verify: 3 nodes Ready, no `uninitialized` taint, Argo `Synced/Healthy`,
   Envoy LB with an IPv4, `argo.hetzner.<root-domain>` resolves to it,
   wildcard certificate `Ready` from the production issuer, ESO Secrets
   synced, CNPG `Healthy`, Grafana reachable, `hcloud load-balancer list`
   shows one LB, `hcloud volume list` shows the expected volumes.
4. Write rows through the Postgres e2e test; run `PROVIDER=hetzner make test`.
5. `PROVIDER=hetzner make down`. Confirm the dump gate ran.
6. Verify: `hcloud server|load-balancer|volume|primary-ip|firewall list -l project=vk-hetzner-lab` all empty; `hcloud network list` and `hcloud ssh-key list` show the persistent objects; Route 53 records gone; the TLS SSM parameter present; the dump in S3.
7. `PROVIDER=hetzner make up`. Note the new LB IP.
8. Verify the rows, the TLS Secret re-import (no new ACME order), DNS
   updated to the new IP.
9. `PROVIDER=hetzner make down`.
10. Leak check as in step 6.
11. `PROVIDER=aws make status` and `PROVIDER=civo make status` (after).
12. Record the cost from the Hetzner Console for the run window and the
    projected idle month against `research.md` shape C (43.89 EUR).

## 5. Files/components affected

`tests/manual/hetzner-150-lifecycle.md` (new); evidence in this spec.

## 6. Implementation steps

Run the runbook. Record every check with its command and result. Route
any fix to the owning spec and re-run the affected step.

## 7. Dependencies and blockers

HETZ-070, HETZ-120, HETZ-130 done. HETZ-160 expected in M1; HETZ-170 not
required.

## 8. Acceptance criteria

- Every verification passes. Zero leaks in the `hcloud` listings and in
  Route 53. Cost recorded and compared to the model.
- The AWS and Civo projects are untouched: `make status` before and after
  is identical for both.
- Step 6 proves that volumes and the LB are gone before servers are
  destroyed, not only after the sweep. If the sweep had to delete
  anything, record it as a finding against HETZ-045 or HETZ-040.

## 9. Validation

Real cloud, about 1 EUR.

## 10. AWS regression protection

AWS `make status` unchanged before and after. Civo `make status` unchanged
before and after. No AWS resources are created except SSM parameters,
Route 53 records in the hetzner zone, and S3 objects in the hetzner bucket.

## 11. Rollout and rollback/recovery

Validation only. `persistent-down` for hetzner cleans the artifacts if
needed.

## 12. Risks and unresolved questions

- A volume stuck `attached` after a force-deleted pod delays or blocks
  server deletion. Record the detach time.
- The control-plane server's primary IPv4 changes on every `make up`; the
  kubeconfig, the firewall `--tls-san` and the DNS all follow it. Verify
  that nothing cached the old address (HETZ-040 context rewrite).
- Hourly billing rounds up; a two-cycle run bills at least 2 h per
  resource.

## 13. Definition of done

- [ ] Runbook committed with evidence; classification table complete
- [ ] Cost recorded; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT. Not run.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
